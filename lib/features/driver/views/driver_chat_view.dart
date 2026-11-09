import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_models.dart';
import '../../../core/realtime/tracking_hub_service.dart';
import '../../../core/realtime/realtime_state_binding.dart';
import '../../../core/services/auth_session_service.dart';
import '../../../core/services/ride_chat_service.dart';
import '../../../core/services/chat_message_sound.dart';
import '../../../shared/widgets/chat_quick_replies.dart';
import '../../../shared/widgets/chat_message_status.dart';

class DriverChatView extends StatefulWidget {
  const DriverChatView({required this.rideId, super.key});

  final String rideId;

  @override
  State<DriverChatView> createState() => _DriverChatViewState();
}

class _DriverChatViewState extends State<DriverChatView>
    with WidgetsBindingObserver {
  static const int _pageSize = 50;

  final _input = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <Map<String, Object?>>[];
  bool _loading = true;
  bool _loadingOlder = false;
  bool _hasOlderMessages = false;
  bool _sending = false;
  bool _latestLoadInFlight = false;
  bool _reloadRequested = false;
  bool _foreground = true;
  bool _initialLoaded = false;
  bool _markingRead = false;
  int _temporaryId = -1;
  Timer? _refreshTimer;
  final _soundedIds = <int>{};
  final _pendingOwnEvents = <int, Map<String, Object?>>{};
  StreamSubscription<TrackingHubEvent>? _eventSubscription;
  StreamSubscription<void>? _connectionSubscription;
  RealtimeStateBinding? _stateBinding;

  ApiClient get _api => Get.find<ApiClient>();
  AuthSessionService get _session => Get.find<AuthSessionService>();
  TrackingHubService get _hub => Get.find<TrackingHubService>();
  RideChatService get _chat => Get.find<RideChatService>();
  int get _rideId => int.tryParse(widget.rideId) ?? 0;
  bool get _visible =>
      mounted && _foreground && (ModalRoute.of(context)?.isCurrent ?? false);
  bool get _atBottom =>
      !_scrollController.hasClients ||
      _scrollController.position.maxScrollExtent -
              _scrollController.position.pixels <=
          120;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_markVisibleRead);
    if (!Get.isRegistered<RideChatService>()) {
      Get.put(RideChatService(_api, _session, _hub), permanent: true);
    }
    _chat.showConversation(_rideId, () => _visible);
    _stateBinding = RealtimeStateBinding(
        owner: this,
        resources: const {'messages'},
        accepts: (change) =>
            change.resource == 'messages' &&
            '${change.resourceId}' == widget.rideId,
        refresh: () => _load(requireSuccess: true));
    _eventSubscription = _chat.updates.listen(_handleHubEvent);
    _connectionSubscription = _hub.connectionRestored.listen((_) {
      unawaited(_load());
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_visible) unawaited(_load(quiet: true));
    });
    unawaited(_load());
  }

  Future<void> _load(
      {bool older = false,
      bool requireSuccess = false,
      bool quiet = false}) async {
    if (_latestLoadInFlight || (older && _loadingOlder)) {
      if (!older) _reloadRequested = true;
      if (requireSuccess) throw StateError('Messages refresh is in progress');
      return;
    }
    if (older && _messages.isEmpty) return;
    if (older) {
      _loadingOlder = true;
    } else {
      _latestLoadInFlight = true;
      if (_messages.isEmpty) _loading = true;
    }
    final shouldScrollToBottom = !older &&
        (_messages.isEmpty ||
            !_scrollController.hasClients ||
            _scrollController.position.maxScrollExtent -
                    _scrollController.position.pixels <=
                120);
    if (mounted) setState(() {});
    final epoch = _stateBinding?.epoch;
    try {
      final data = <String, Object?>{
        'rideId': widget.rideId,
        'pageSize': _pageSize,
      };
      if (older) {
        final cursor = _messages.first;
        data['beforeId'] = cursor['id'];
        data['beforeCreatedAtUtc'] = cursor['createdAtUtc'];
      }
      final result = await _api.execute<List<Map<String, Object?>>>(
        model: 'RideMessageModel',
        operation: 'list',
        data: data,
        parse: (json) => json is List
            ? json
                .whereType<Map<Object?, Object?>>()
                .map((item) => Map<String, Object?>.from(item))
                .toList()
            : <Map<String, Object?>>[],
      );
      if (epoch != null) _stateBinding?.verify(epoch);
      if (result is ApiFailure<List<Map<String, Object?>>>) {
        throw StateError(result.problem.title);
      }
      if (result is ApiSuccess<List<Map<String, Object?>>>) {
        if (!mounted) return;
        if (older) {
          _mergeMessages(result.data);
          _hasOlderMessages = result.data.length == _pageSize;
        } else {
          if (_initialLoaded) _soundNewIncoming(result.data);
          _mergeMessages(result.data, scrollToBottom: shouldScrollToBottom);
          _initialLoaded = true;
          if (!_hasOlderMessages) {
            _hasOlderMessages = result.data.length == _pageSize;
          }
        }
        unawaited(_chat.acknowledge(_rideId, result.data));
        _scheduleMarkRead();
      }
    } catch (error) {
      if (mounted &&
          error is! StateSnapshotSuperseded &&
          !requireSuccess &&
          !quiet) {
        Get.snackbar('تعذر تحميل المحادثة', 'تحقق من الاتصال وحاول مجدداً.');
      }
      if (requireSuccess) rethrow;
    } finally {
      if (older) {
        _loadingOlder = false;
      } else {
        _latestLoadInFlight = false;
        _loading = false;
      }
      if (mounted) setState(() {});
      if (mounted && _reloadRequested && !older) {
        _reloadRequested = false;
        unawaited(_load(quiet: true));
      }
    }
  }

  void _handleHubEvent(TrackingHubEvent event) {
    if (!{'rideMessageCreated', 'rideMessageUpdated'}.contains(event.name) ||
        '${event.payload['rideId'] ?? ''}' != widget.rideId) {
      return;
    }
    if (mounted) {
      if (event.name == 'rideMessageCreated')
        _soundNewIncoming([event.payload]);
      final shouldScrollToBottom = _messages.isEmpty ||
          !_scrollController.hasClients ||
          _scrollController.position.maxScrollExtent -
                  _scrollController.position.pixels <=
              120;
      setState(
        () => _mergeMessages(
          <Map<String, Object?>>[
            // Message content is immutable. A delayed duplicate create must
            // not replace the canonical row already loaded for this id.
            if (event.name == 'rideMessageCreated' &&
                _messages.any((row) => row['id'] == event.payload['id']))
              {
                ...event.payload,
                ..._messages
                    .firstWhere((row) => row['id'] == event.payload['id'])
              }
            else
              event.payload,
          ],
          scrollToBottom: shouldScrollToBottom,
        ),
      );
      _scheduleMarkRead();
    }
  }

  void _soundNewIncoming(Iterable<Map<String, Object?>> incoming) {
    if (!_visible) return;
    final known = _messages.map((message) => '${message['id']}').toSet();
    var play = false;
    for (final message in incoming) {
      final id = int.tryParse('${message['id']}');
      if (id != null &&
          id > 0 &&
          !known.contains('$id') &&
          '${message['recipientId']}' == '${_session.currentUserId.value}' &&
          message['readAtUtc'] == null &&
          _soundedIds.add(id)) play = true;
    }
    if (play) unawaited(ChatMessageSound.play());
  }

  void _scheduleMarkRead() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _markVisibleRead());
  }

  void _markVisibleRead() {
    if (!_visible || !_atBottom || _markingRead || !_initialLoaded) return;
    _markingRead = true;
    unawaited(_chat.acknowledge(_rideId, _messages, read: true).then((rows) {
      if (mounted && rows.isNotEmpty) setState(() => _mergeMessages(rows));
    }).whenComplete(() => _markingRead = false));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_load(quiet: true));
      _scheduleMarkRead();
    }
  }

  void _mergeMessages(
    Iterable<Map<String, Object?>> incoming, {
    bool scrollToBottom = false,
  }) {
    final byId = <String, Map<String, Object?>>{
      for (final message in _messages) '${message['id']}': message,
    };
    for (final message in incoming) {
      final id = '${message['id']}';
      final serverId = int.tryParse(id);
      if (_sending &&
          serverId != null &&
          serverId > 0 &&
          '${message['senderId']}' == '${_session.currentUserId.value}' &&
          _messages.any((row) =>
              row['pending'] == true && row['content'] == message['content'])) {
        // Both the sender echo and a canonical refresh can beat the POST
        // response. Merge them by server id once that response replaces the
        // pending bubble, preserving simultaneous sends from another device.
        final previous = _pendingOwnEvents[serverId];
        _pendingOwnEvents[serverId] = {
          ...?previous,
          ...message,
          'deliveredAtUtc':
              message['deliveredAtUtc'] ?? previous?['deliveredAtUtc'],
          'readAtUtc': message['readAtUtc'] ?? previous?['readAtUtc'],
        };
        continue;
      }
      final previous = byId[id];
      byId[id] = {
        ...?previous,
        ...message,
        // A stale list response or duplicate create cannot undo receipts.
        'deliveredAtUtc':
            message['deliveredAtUtc'] ?? previous?['deliveredAtUtc'],
        'readAtUtc': message['readAtUtc'] ?? previous?['readAtUtc'],
      };
    }
    final merged = byId.values.toList()
      ..sort((left, right) {
        final leftTime = DateTime.tryParse('${left['createdAtUtc'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final rightTime = DateTime.tryParse('${right['createdAtUtc'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final timeOrder = leftTime.compareTo(rightTime);
        if (timeOrder != 0) return timeOrder;
        return (int.tryParse('${left['id']}') ?? 0)
            .compareTo(int.tryParse('${right['id']}') ?? 0);
      });
    _messages
      ..clear()
      ..addAll(merged);
    if (scrollToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        unawaited(_scrollController
            .animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
            )
            .then((_) => _markVisibleRead()));
      });
    }
  }

  Future<void> _send() async {
    final content = _input.text.trim();
    if (content.isEmpty || _sending) return;
    final temporaryId = _temporaryId--;
    final pending = <String, Object?>{
      'id': temporaryId,
      'rideId': _rideId,
      'senderId': _session.currentUserId.value,
      'content': content,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'pending': true,
    };
    setState(() {
      _sending = true;
      _messages.removeWhere((message) =>
          message['failed'] == true && message['content'] == content);
      _mergeMessages([pending], scrollToBottom: true);
    });
    _input.clear();
    try {
      final result = await _api.execute<Map<String, Object?>>(
        model: 'RideMessageModel',
        operation: 'add',
        data: <String, Object?>{
          'rideId': widget.rideId,
          'content': content,
          'messageType': 'Text',
        },
        parse: (json) =>
            json is Map ? Map<String, Object?>.from(json) : <String, Object?>{},
      );
      if (result is ApiSuccess<Map<String, Object?>>) {
        if (!mounted) return;
        _messages.removeWhere((message) => message['id'] == temporaryId);
        _mergeMessages(
          <Map<String, Object?>>[result.data, ..._pendingOwnEvents.values],
          scrollToBottom: true,
        );
        _pendingOwnEvents.clear();
      } else {
        _sendFailed(temporaryId, content);
        Get.snackbar('تعذر إرسال الرسالة', 'حاول مرة أخرى.');
      }
    } catch (_) {
      _sendFailed(temporaryId, content);
      Get.snackbar('تعذر إرسال الرسالة', 'تحقق من الاتصال وحالة الرحلة.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _sendFailed(int id, String content) {
    if (!mounted) return;
    final index = _messages.indexWhere((message) => message['id'] == id);
    if (index >= 0) {
      _messages[index] = {
        ..._messages[index],
        'pending': false,
        'failed': true
      };
    }
    _mergeMessages(_pendingOwnEvents.values, scrollToBottom: true);
    _pendingOwnEvents.clear();
    if (_input.text.isEmpty) _input.text = content;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('محادثة العميل')),
        body: Column(
          children: <Widget>[
            Expanded(
              child: _loading && _messages.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _messages.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: const <Widget>[
                                Padding(
                                  padding: EdgeInsets.only(top: 96),
                                  child: Center(
                                    child: Text('ابدأ المحادثة مع العميل.'),
                                  ),
                                ),
                              ],
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.all(12),
                              itemCount: _messages.length +
                                  (_hasOlderMessages ? 1 : 0),
                              itemBuilder: (_, index) {
                                if (_hasOlderMessages && index == 0) {
                                  return Center(
                                    child: TextButton.icon(
                                      onPressed: _loadingOlder
                                          ? null
                                          : () => _load(older: true),
                                      icon: _loadingOlder
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(Icons.history_rounded),
                                      label: const Text('تحميل رسائل أقدم'),
                                    ),
                                  );
                                }
                                final messageIndex =
                                    _hasOlderMessages ? index - 1 : index;
                                final message = _messages[messageIndex];
                                final senderId = int.tryParse(
                                  '${message['senderId'] ?? ''}',
                                );
                                final isDriverMessage = senderId != null &&
                                    senderId == _session.currentUserId.value;
                                return Align(
                                  alignment: isDriverMessage
                                      ? AlignmentDirectional.centerStart
                                      : AlignmentDirectional.centerEnd,
                                  child: Container(
                                    constraints: BoxConstraints(
                                      maxWidth:
                                          MediaQuery.sizeOf(context).width *
                                              .76,
                                    ),
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 13,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isDriverMessage
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                          : Theme.of(context)
                                              .colorScheme
                                              .surface,
                                      borderRadius:
                                          BorderRadiusDirectional.only(
                                        topStart: const Radius.circular(20),
                                        topEnd: const Radius.circular(20),
                                        bottomStart: Radius.circular(
                                          isDriverMessage ? 4 : 20,
                                        ),
                                        bottomEnd: Radius.circular(
                                          isDriverMessage ? 20 : 4,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text('${message['content'] ?? ''}',
                                            style: TextStyle(
                                                color: isDriverMessage
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .onPrimary
                                                    : Theme.of(context)
                                                        .colorScheme
                                                        .onSurface)),
                                        const SizedBox(height: 4),
                                        Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(_messageTime(message),
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color: isDriverMessage
                                                          ? Colors.white70
                                                          : Theme.of(context)
                                                              .colorScheme
                                                              .onSurfaceVariant)),
                                              if (isDriverMessage) ...[
                                                const SizedBox(width: 5),
                                                ChatMessageStatus(
                                                    message: message,
                                                    color: Colors.white70),
                                              ],
                                            ]),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
            ),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: ChatQuickReplies(controller: _input, suggestions: const [
                  'أنا في الطريق إليك',
                  'وصلت إلى نقطة الانطلاق',
                  'أين موقعك بالتحديد؟',
                  'سأصل خلال دقائق',
                  'يرجى الاستعداد للصعود',
                ])),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration:
                            const InputDecoration(hintText: 'اكتب رسالة'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filled(
                      onPressed: _sending ? null : _send,
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  @override
  void dispose() {
    _chat.hideConversation(_rideId);
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _scrollController.removeListener(_markVisibleRead);
    _stateBinding?.dispose();
    unawaited(_eventSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    _input.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _messageTime(Map<String, Object?> message) {
    final raw = '${message['createdAtUtc'] ?? ''}';
    final timestamp = DateTime.tryParse(
            raw.isNotEmpty && !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(raw)
                ? '${raw}Z'
                : raw)
        ?.toLocal();
    if (timestamp == null) return '';
    return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
  }
}
