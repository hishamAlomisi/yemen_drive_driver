import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../network/api_client.dart';
import '../network/api_models.dart';
import '../realtime/realtime_state_binding.dart';
import '../realtime/tracking_hub_service.dart';
import 'auth_session_service.dart';

/// Keeps unread counts and delivery receipts alive outside the chat screen.
/// Fetching or receiving a message acknowledges delivery only; the visible
/// conversation explicitly acknowledges reading after rendering the message.
class RideChatService extends GetxService with WidgetsBindingObserver {
  RideChatService(this._api, this._session, this._hub);

  final ApiClient _api;
  final AuthSessionService _session;
  final TrackingHubService _hub;
  final unreadByRide = <int, int>{}.obs;
  final _receivedIds = <int>{};
  final _deliveredIds = <int>{};
  final _readIds = <int>{};
  final _acknowledging = <String>{};
  final _updates = StreamController<TrackingHubEvent>.broadcast();
  Stream<TrackingHubEvent> get updates => _updates.stream;
  StreamSubscription<TrackingHubEvent>? _events;
  StreamSubscription<void>? _restored;
  RealtimeStateBinding? _binding;
  Worker? _accountWorker;
  Worker? _authWorker;
  Timer? _fallback;
  Future<void>? _refreshTask;
  bool _refreshAgain = false;
  bool _foreground = true;
  int _accountEpoch = 0;
  int _eventVersion = 0;
  bool Function()? _visible;
  int? _visibleRideId;

  bool get _eligible =>
      !isClosed &&
      _session.isAuthenticated.value &&
      _session.currentUserId.value != null;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _events = _hub.events.listen(_handleEvent);
    _restored = _hub.connectionRestored.listen((_) => unawaited(refresh()));
    _accountWorker = ever(_session.currentUserId, (_) => _accountChanged());
    _authWorker = ever(_session.isAuthenticated, (_) => _accountChanged());
    _fallback = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_foreground) unawaited(refresh());
    });
    _accountChanged();
  }

  void _accountChanged() {
    _accountEpoch++;
    _eventVersion++;
    _receivedIds.clear();
    _deliveredIds.clear();
    _readIds.clear();
    _acknowledging.clear();
    unreadByRide.clear();
    _visible = null;
    _visibleRideId = null;
    _binding?.dispose();
    _binding = null;
    if (!_eligible) {
      return;
    }
    _binding = RealtimeStateBinding(
      owner: this,
      resources: const {'messages'},
      accepts: (change) => change.resource == 'messages',
      refresh: () => refresh(requireSuccess: true),
    );
    unawaited(refresh());
  }

  void showConversation(int rideId, bool Function() visible) {
    _visibleRideId = rideId;
    _visible = visible;
    unawaited(refresh());
  }

  void hideConversation(int rideId) {
    if (_visibleRideId != rideId) return;
    _visibleRideId = null;
    _visible = null;
  }

  bool isConversationVisible(int rideId) =>
      _eligible &&
      _foreground &&
      _visibleRideId == rideId &&
      (_visible?.call() ?? false);

  int unreadFor(int rideId) => unreadByRide[rideId] ?? 0;

  void _handleEvent(TrackingHubEvent event) {
    if (!_eligible ||
        !{'rideMessageCreated', 'rideMessageUpdated'}.contains(event.name))
      return;
    final row = event.payload;
    final rideId = int.tryParse('${row['rideId']}');
    final id = int.tryParse('${row['id']}');
    final userId = _session.currentUserId.value;
    if (rideId == null ||
        id == null ||
        ('${row['senderId']}' != '$userId' &&
            '${row['recipientId']}' != '$userId')) return;
    _eventVersion++;
    if (row['deliveredAtUtc'] != null) _deliveredIds.add(id);
    if (row['readAtUtc'] != null) _readIds.add(id);
    if (event.name == 'rideMessageCreated' &&
        _receivedIds.add(id) &&
        '${row['recipientId']}' == '$userId' &&
        row['readAtUtc'] == null) {
      unreadByRide[rideId] = unreadFor(rideId) + 1;
    }
    _updates.add(event);
    if ('${row['recipientId']}' == '$userId') {
      unawaited(acknowledge(rideId, [row]));
    }
    unawaited(refresh());
  }

  Future<void> refresh({bool requireSuccess = false}) async {
    if (!_eligible || !_foreground) return;
    if (_refreshTask != null) {
      _refreshAgain = true;
      try {
        await _refreshTask;
      } on Object {
        if (requireSuccess) rethrow;
      }
      return;
    }
    final task = _refreshCounts();
    _refreshTask = task;
    try {
      await task;
    } on Object {
      if (requireSuccess) rethrow;
    } finally {
      _refreshTask = null;
      if (_refreshAgain && _eligible) {
        _refreshAgain = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> _refreshCounts() async {
    final account = _accountEpoch;
    final version = _eventVersion;
    final epoch = _binding?.epoch;
    final result = await _api.execute<Map<String, Object?>>(
      model: 'RideMessageModel',
      operation: 'report',
      data: const {},
      parse: (json) => json is Map ? Map<String, Object?>.from(json) : {},
    );
    if (!_eligible || account != _accountEpoch) return;
    if (epoch != null) _binding?.verify(epoch);
    if (result is! ApiSuccess<Map<String, Object?>>) {
      throw StateError('تعذر تحديث عدد الرسائل');
    }
    if (version != _eventVersion) {
      _refreshAgain = true;
      return;
    }
    final counts = <int, int>{};
    for (final row in parseRows(result.data['rides'])) {
      final id = int.tryParse('${row['rideId']}');
      if (id != null) counts[id] = int.tryParse('${row['unreadCount']}') ?? 0;
    }
    unreadByRide.assignAll(counts);
    for (final entry in counts.entries) {
      final rideId = entry.key;
      final count = entry.value;
      if (count > 0 && !isConversationVisible(rideId)) {
        // A summary alone is not delivery. Fetch the actual newest messages
        // before acknowledging only the rows this device received.
        final page = await _api.execute<List<Map<String, Object?>>>(
          model: 'RideMessageModel',
          operation: 'list',
          data: {'rideId': rideId, 'pageSize': 100},
          parse: parseRows,
        );
        if (!_eligible || account != _accountEpoch) return;
        if (page is ApiSuccess<List<Map<String, Object?>>>) {
          await acknowledge(rideId, page.data);
        }
      }
    }
  }

  Future<List<Map<String, Object?>>> acknowledge(
      int rideId, Iterable<Map<String, Object?>> messages,
      {bool read = false}) async {
    if (!_eligible || (read && !isConversationVisible(rideId))) return [];
    final account = _accountEpoch;
    final userId = _session.currentUserId.value;
    final received = messages.toList();
    for (final row in received) {
      final id = int.tryParse('${row['id']}');
      if (id == null || id <= 0) continue;
      _receivedIds.add(id);
      if (row['deliveredAtUtc'] != null) _deliveredIds.add(id);
      if (row['readAtUtc'] != null) _readIds.add(id);
    }
    final ids = received
        .where((row) => '${row['recipientId']}' == '$userId')
        .where((row) =>
            read ? row['readAtUtc'] == null : row['deliveredAtUtc'] == null)
        .map((row) => int.tryParse('${row['id']}'))
        .whereType<int>()
        .where(
            (id) => id > 0 && !(read ? _readIds : _deliveredIds).contains(id))
        .toSet()
        .toList();
    final rows = <Map<String, Object?>>[];
    for (var offset = 0; offset < ids.length; offset += 100) {
      if (!_eligible ||
          account != _accountEpoch ||
          (read && !isConversationVisible(rideId))) break;
      final batch = ids
          .skip(offset)
          .take(100)
          .where((id) => !_acknowledging.contains('$read:$id'))
          .toList();
      if (batch.isEmpty) continue;
      final keys = batch.map((id) => '$read:$id').toList();
      _acknowledging.addAll(keys);
      try {
        final result = await _api.execute<List<Map<String, Object?>>>(
          model: 'RideMessageModel',
          operation: 'update',
          data: {
            'rideId': rideId,
            'messageIds': batch,
            'markDelivered': true,
            'markRead': read
          },
          parse: parseRows,
        );
        if (!_eligible || account != _accountEpoch) return [];
        if (result is ApiSuccess<List<Map<String, Object?>>>) {
          for (final row in result.data) {
            final id = int.tryParse('${row['id']}');
            if (id == null) continue;
            if (row['deliveredAtUtc'] != null) _deliveredIds.add(id);
            if (row['readAtUtc'] != null) _readIds.add(id);
            _updates.add(TrackingHubEvent('rideMessageUpdated', row));
          }
          rows.addAll(result.data);
        }
      } on Object {
        // A later canonical refresh retries receipts; never claim delivery
        // or reading locally when the server has not confirmed it.
      } finally {
        if (account == _accountEpoch) _acknowledging.removeAll(keys);
      }
    }
    if (read && rows.isNotEmpty) unawaited(refresh());
    return rows;
  }

  static List<Map<String, Object?>> parseRows(Object? json) => json is List
      ? json
          .whereType<Map<Object?, Object?>>()
          .map((row) => Map<String, Object?>.from(row))
          .toList()
      : json is Map
          ? [Map<String, Object?>.from(json)]
          : [];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(refresh());
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _accountEpoch++;
    _binding?.dispose();
    _events?.cancel();
    _restored?.cancel();
    _accountWorker?.dispose();
    _authWorker?.dispose();
    _fallback?.cancel();
    _updates.close();
    super.onClose();
  }
}
