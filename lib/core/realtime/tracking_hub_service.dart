import 'dart:async';
import 'dart:math' as math;
import 'package:dio/dio.dart';

import 'package:get/get.dart' hide Response;
import 'package:signalr_netcore/signalr_client.dart';

import '../config/app_environment.dart';
import '../storage/secure_storage_service.dart';
import '../network/api_client.dart';
import '../services/auth_session_service.dart';
import '../services/startup_connection_service.dart';
import 'state_change_coordinator.dart';

/// Owns the authenticated tracking Hub connection for an active ride.
/// Ride membership is restored after a successful automatic reconnect.
class TrackingHubEvent {
  const TrackingHubEvent(this.name, this.payload);

  final String name;
  final Map<String, Object?> payload;
}

class TrackingHubService extends GetxService {
  TrackingHubService(this._storage,
      {HubConnection Function()? connectionFactory})
      : _connectionFactory = connectionFactory {
    stateChanges = StateChangeCoordinator(onStatusChanged: () {
      isStateSynchronized.value =
          supportsStateRecovery.value && stateChanges.synchronized;
    });
  }

  final SecureStorageService _storage;
  final HubConnection Function()? _connectionFactory;
  final _reconnectRandom = math.Random();
  StreamSubscription<void>? _apiRecovery;
  Worker? _apiAvailabilityWorker;
  final Set<int> _rideIds = <int>{};
  final Set<Object> _userEventListeners = <Object>{};
  Map<String, Object?>? _nearbyDriverSubscription;
  HubConnection? _connection;
  bool _foreground = true;
  bool get _hasInterest =>
      _rideIds.isNotEmpty ||
      _userEventListeners.isNotEmpty ||
      _nearbyDriverSubscription != null;
  StartupConnectionService? get _availability =>
      Get.isRegistered<StartupConnectionService>()
          ? Get.find<StartupConnectionService>()
          : null;

  @override
  void onInit() {
    super.onInit();
    final availability = _availability;
    if (availability != null) {
      _apiRecovery = availability.recovered.listen((_) {
        unawaited(reconnectAfterApiRecovery());
      });
      _apiAvailabilityWorker =
          ever(availability.runtimeUnavailable, (bool unavailable) {
        if (unavailable) {
          unawaited(_suspendForApiOutage());
        }
      });
    }
  }

  Future<void> _suspendForApiOutage() async {
    // Keep subscriptions and state cursors, but stop SignalR's internal retries.
    _connectionGeneration++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _stateRecoveryRetry?.cancel();
    _stateRecoveryTask = null;
    _connectTask = null;
    stateChanges.disconnected();
    final previous = _connection;
    _connection = null;
    isConnected.value = false;
    if (previous != null) {
      try {
        await previous.stop().timeout(const Duration(seconds: 3));
      } on Object {
        /* The gate remains closed until an explicit retry succeeds. */
      }
    }
  }

  Future<void> setForeground(bool foreground) async {
    final resumed = foreground && !_foreground;
    _foreground = foreground;
    if (!foreground) {
      stateChanges.disconnected();
      _stateRecoveryTask = null;
    }
    if (_connection?.state != HubConnectionState.Connected) {
      if (resumed && _hasInterest) await _ensureConnected();
      return;
    }
    try {
      await _connection!.invoke('SetForeground', args: <Object>[foreground]);
    } on Object {/* Reconnect restores presence. */}
    if (resumed) await recoverState();
  }

  Future<void>? _connectTask;
  Timer? _retryTimer;
  int _connectionGeneration = 0;
  int _rideSubscriptionGeneration = 0;
  final RxBool isConnected = false.obs;
  final RxBool supportsStateRecovery = false.obs;
  final RxBool isStateSynchronized = false.obs;
  late final StateChangeCoordinator stateChanges;
  Future<void>? _stateRecoveryTask;
  Timer? _stateRecoveryRetry;
  final StreamController<TrackingHubEvent> _events =
      StreamController<TrackingHubEvent>.broadcast();
  final StreamController<void> _connectionRestored =
      StreamController<void>.broadcast();
  Future<void> Function()? onSessionRevoked;

  Stream<TrackingHubEvent> get events => _events.stream;
  Stream<void> get connectionRestored => _connectionRestored.stream;

  void _invalidatePendingBusinessReads() {
    if (Get.isRegistered<ApiClient>()) {
      Get.find<ApiClient>().invalidatePendingReads();
    }
  }

  Future<void> setUserEventListening(Object owner, bool listen) async {
    if (listen) {
      _userEventListeners.add(owner);
      await _ensureConnected();
    } else {
      _userEventListeners.remove(owner);
    }
    if (_userEventListeners.isEmpty && _rideIds.isEmpty) {
      await disconnect();
    }
  }

  Future<void> setRideSubscriptions(Iterable<int> rideIds) async {
    final desired = rideIds.where((id) => id > 0).toSet();
    final removed = _rideIds.difference(desired);
    final added = desired.difference(_rideIds);
    if (removed.isNotEmpty || added.isNotEmpty) _rideSubscriptionGeneration++;
    _rideIds
      ..clear()
      ..addAll(desired);

    if (_rideIds.isEmpty) {
      for (final rideId in removed) {
        await _invokeIfConnected('LeaveRide', rideId);
      }
      if (_userEventListeners.isEmpty) await disconnect();
      return;
    }

    await _ensureConnected();
    if (!_isConnected) return;
    for (final rideId in removed) {
      await _invokeIfConnected('LeaveRide', rideId);
    }
    for (final rideId in added) {
      await _invokeIfConnected('JoinRide', rideId);
    }
  }

  Future<bool> publishDriverLocation(Map<String, Object?> payload) async {
    if (_availability?.runtimeUnavailable.value == true) return false;
    final scope = await _captureLocationScope(trackRideChanges: true);
    if (scope == null) return false;
    try {
      await _ensureConnected().timeout(const Duration(seconds: 5));
    } on Object {/* Keep HTTP GPS updates available while Hub reconnects. */}
    if (!await _locationScopeStillCurrent(scope)) return false;
    final connection = _connection;
    if (connection != null &&
        connection.state == HubConnectionState.Connected) {
      try {
        await connection.invoke('PublishDriverLocation',
            args: <Object>[payload]).timeout(const Duration(seconds: 12));
        return _locationScopeCurrent(scope);
      } on Object {
        /* Retry the same timestamp through the authenticated API. */
      }
    }
    if (!await _locationScopeStillCurrent(scope)) return false;
    if (!Get.isRegistered<ApiClient>()) return false;
    try {
      final response =
          await _postScopedLocation('tracking/driver-location', payload, scope);
      final body = response.data;
      return _locationScopeCurrent(scope) &&
          body is Map &&
          body['success'] == true &&
          body['data'] is Map &&
          (body['data'] as Map)['accepted'] == true;
    } on Object {
      return false;
    }
  }

  Future<Map<String, Object?>> publishDriverLocationBatch(
      Map<String, Object?> payload) async {
    if (_availability?.runtimeUnavailable.value == true) {
      throw const FormatException('تعذّر الاتصال بالخادم لحفظ نقاط المسار.');
    }
    // Archived samples keep their ride id even after transport ends. Account
    // and session scope still applies to every fallback and acknowledgement.
    final scope = await _captureLocationScope(trackRideChanges: false);
    if (scope == null || !await _locationScopeStillCurrent(scope)) {
      throw const FormatException('تغيرت جلسة السائق قبل إرسال نقاط المسار.');
    }
    final connection = _connection;
    if (connection?.state == HubConnectionState.Connected) {
      try {
        final result = await connection!.invoke('PublishDriverLocationBatch',
            args: <Object>[payload]).timeout(const Duration(seconds: 15));
        if (!_locationScopeCurrent(scope)) {
          throw const FormatException(
              'تغيرت جلسة السائق أثناء إرسال نقاط المسار.');
        }
        if (result is Map<String, Object?>) return result;
        if (result is Map) return Map<String, Object?>.from(result);
      } on Object {/* Retry identical sample IDs through HTTP. */}
    }
    if (!await _locationScopeStillCurrent(scope)) {
      throw const FormatException(
          'تغيرت جلسة السائق قبل إعادة إرسال نقاط المسار.');
    }
    try {
      final response = await _postScopedLocation(
          'tracking/driver-location-batch', payload, scope);
      if (!_locationScopeCurrent(scope)) {
        throw const FormatException(
            'تغيرت جلسة السائق أثناء إرسال نقاط المسار.');
      }
      final raw = response.data;
      if (raw is Map && raw['success'] == true && raw['data'] is Map) {
        return Map<String, Object?>.from(raw['data'] as Map);
      }
      throw const FormatException('لم يؤكد الخادم حفظ نقاط المسار.');
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return {'enabled': false};
      rethrow;
    }
  }

  Future<_LocationScope?> _captureLocationScope(
      {required bool trackRideChanges}) async {
    final generation = _connectionGeneration;
    final rideGeneration =
        trackRideChanges ? _rideSubscriptionGeneration : null;
    final session = Get.isRegistered<AuthSessionService>()
        ? Get.find<AuthSessionService>()
        : null;
    final userId = session?.currentUserId.value;
    if (session != null && (!session.isAuthenticated.value || userId == null)) {
      return null;
    }
    final token = await _storage.accessToken;
    if (token == null || token.isEmpty) return null;
    final scope =
        _LocationScope(generation, rideGeneration, session, userId, token);
    return _locationScopeCurrent(scope) ? scope : null;
  }

  bool _locationScopeCurrent(_LocationScope scope) =>
      !isClosed &&
      scope.generation == _connectionGeneration &&
      (scope.rideGeneration == null ||
          scope.rideGeneration == _rideSubscriptionGeneration) &&
      (scope.session == null ||
          Get.isRegistered<AuthSessionService>() &&
              identical(Get.find<AuthSessionService>(), scope.session) &&
              scope.session!.isAuthenticated.value &&
              scope.session!.currentUserId.value == scope.userId);

  Future<bool> _locationScopeStillCurrent(_LocationScope scope) async {
    if (!_locationScopeCurrent(scope)) return false;
    final token = await _storage.accessToken;
    return _locationScopeCurrent(scope) && token == scope.token;
  }

  Future<Response<Object?>> _postScopedLocation(
      String path, Map<String, Object?> payload, _LocationScope scope) async {
    final client = Get.find<ApiClient>().dio;
    final marker = Object();
    // ApiClient reads storage asynchronously and can refresh authentication.
    // This final request guard prevents it from rebinding an old GPS payload
    // to a replacement token, including on a 401 retry.
    final guard = InterceptorsWrapper(onRequest: (options, handler) {
      if (identical(options.extra['locationPublicationScope'], marker) &&
          (!_locationScopeCurrent(scope) ||
              options.headers['Authorization'] != 'Bearer ${scope.token}')) {
        handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            message: 'تغيرت جلسة الموقع؛ أُوقف إرسال العينة السابقة.'));
        return;
      }
      handler.next(options);
    });
    client.interceptors.add(guard);
    try {
      return await client.post<Object?>(path,
          data: payload,
          options: Options(extra: {'locationPublicationScope': marker}));
    } finally {
      client.interceptors.remove(guard);
    }
  }

  Future<void> setNearbyDriverSubscription({
    required int? serviceKindId,
    required int? serviceCatalogItemId,
    required double pickupLatitude,
    required double pickupLongitude,
    required int radiusMeters,
    required Iterable<int> initialDriverIds,
  }) async {
    _nearbyDriverSubscription = <String, Object?>{
      'serviceKindId': serviceKindId,
      'serviceCatalogItemId': serviceCatalogItemId,
      'pickupLatitude': pickupLatitude,
      'pickupLongitude': pickupLongitude,
      'radiusMeters': radiusMeters,
      'initialDriverIds': initialDriverIds.toSet().take(50).toList(),
    };
    await _ensureConnected();
    await _joinNearbyDriverSubscription(_connection);
  }

  Future<void> clearNearbyDriverSubscription() async {
    _nearbyDriverSubscription = null;
    final connection = _connection;
    if (connection == null ||
        connection.state != HubConnectionState.Connected) {
      return;
    }
    try {
      await connection.invoke('LeaveNearbyDrivers');
    } on Object {
      // Leaving a map subscription must not disrupt the ride screen.
    }
  }

  Future<void> disconnect() async {
    _connectionGeneration++;
    _userEventListeners.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _rideIds.clear();
    _nearbyDriverSubscription = null;
    _stateRecoveryRetry?.cancel();
    _stateRecoveryTask = null;
    supportsStateRecovery.value = false;
    stateChanges.reset();
    final connection = _connection;
    _connection = null;
    isConnected.value = false;
    if (connection != null &&
        connection.state != HubConnectionState.Disconnected) {
      try {
        await connection.stop();
      } on Object {
        // A failed or already-closed transport should not block sign-out.
      }
    }
  }

  bool get _isConnected => _connection?.state == HubConnectionState.Connected;

  Future<void> _ensureConnected() async {
    if (isClosed ||
        !_foreground ||
        _availability?.runtimeUnavailable.value == true) return;
    if (_isConnected) return;
    final pending = _connectTask;
    if (pending != null) {
      await pending;
      return;
    }

    final task = _startConnection();
    _connectTask = task;
    try {
      await task;
    } finally {
      if (identical(_connectTask, task)) _connectTask = null;
    }
  }

  Future<void> _startConnection() async {
    final current = _connection;
    if (current != null && current.state != HubConnectionState.Disconnected) {
      return;
    }
    final generation = _connectionGeneration;
    final url = AppEnvironment.signalRHubUrl.trim();
    if (url.isEmpty) return;

    final connection = _connectionFactory?.call() ??
        HubConnectionBuilder()
            .withUrl(
          url,
          options: HttpConnectionOptions(
            accessTokenFactory: () async => await _storage.accessToken ?? '',
          ),
        )
            .withAutomaticReconnect(
          retryDelays: <int>[
            0,
            1500 + _reconnectRandom.nextInt(1001),
            8000 + _reconnectRandom.nextInt(4001),
            24000 + _reconnectRandom.nextInt(12001),
          ],
        ).build();
    _connection = connection;
    connection.on('stateChanged', (arguments) {
      if (!identical(_connection, connection) ||
          arguments == null ||
          arguments.isEmpty) return;
      final payload = arguments.first;
      if (payload is! Map) return;
      final change = StateChange.parse(payload);
      _invalidatePendingBusinessReads();
      if (change != null) {
        stateChanges.observe(change);
      } else {
        stateChanges.disconnected();
        _stateRecoveryTask = null;
        unawaited(recoverState());
      }
    });
    connection.on('sessionRevoked', (_) {
      if (!identical(_connection, connection)) return;
      unawaited(_handleSessionRevoked());
    });
    for (final eventName in <String>[
      'rideAvailable',
      'rideUnavailable',
      'offerReceived',
      'offerUpdated',
      'rideRequestViewed',
      'rideSearchRecipientsUpdated',
      'rideCancellationUpdated',
      'rideArrivalUpdated',
      'rideRouteChangeUpdated',
      'rideStatusUpdated',
      'rideMessageCreated',
      'rideMessageUpdated',
      'paymentUpdated',
      'cashApprovalUpdated',
      'notificationCreated',
      'driverLocationUpdated',
      'passengerLocationUpdated',
      'nearbyDriverLocationUpdated',
      'nearbyDriverAvailabilityChanged',
      'trackingDemandChanged',
    ]) {
      connection.on(eventName, (arguments) {
        if (!identical(_connection, connection)) return;
        if (arguments == null || arguments.isEmpty) return;
        final rawPayload = arguments.first;
        if (rawPayload is! Map) return;
        final payload = <String, Object?>{};
        rawPayload.forEach((key, value) {
          if (key != null) payload[key.toString()] = value;
        });
        if (!const {
          'driverLocationUpdated',
          'passengerLocationUpdated',
          'nearbyDriverLocationUpdated',
          'nearbyDriverAvailabilityChanged',
          'trackingDemandChanged',
        }.contains(eventName)) {
          _invalidatePendingBusinessReads();
        }
        _events.add(TrackingHubEvent(eventName, payload));
      });
    }
    connection.onreconnecting(({Exception? error}) {
      if (!identical(_connection, connection)) return;
      isConnected.value = false;
      stateChanges.disconnected();
      _stateRecoveryTask = null;
      final availability = _availability;
      if (availability != null) unawaited(availability.checkNow());
    });
    connection.onreconnected(({String? connectionId}) {
      if (!identical(_connection, connection)) return;
      isConnected.value = true;
      unawaited(_restoreSubscriptionsAndNotify(connection));
    });
    connection.onclose(({Exception? error}) {
      if (identical(_connection, connection)) {
        isConnected.value = false;
        stateChanges.disconnected();
        _stateRecoveryTask = null;
        _connection = null;
        _scheduleReconnect();
        final availability = _availability;
        if (availability != null) unawaited(availability.checkNow());
      }
    });

    try {
      await connection.start();
      if (generation != _connectionGeneration) {
        await connection.stop();
        return;
      }
      _retryTimer?.cancel();
      _retryTimer = null;
      isConnected.value = connection.state == HubConnectionState.Connected;
      if (_isConnected) await _restoreSubscriptionsAndNotify(connection);
    } on Object {
      if (!identical(_connection, connection) ||
          generation != _connectionGeneration) return;
      _connection = null;
      isConnected.value = false;
      stateChanges.disconnected();
      _scheduleReconnect();
      final availability = _availability;
      if (availability != null) unawaited(availability.checkNow());
    }
  }

  Future<void> _restoreRideSubscriptions(HubConnection connection) async {
    if (!identical(_connection, connection) ||
        connection.state != HubConnectionState.Connected) {
      return;
    }
    for (final rideId in _rideIds.toList(growable: false)) {
      try {
        await connection.invoke('JoinRide', args: <Object>[rideId]);
      } on Object {
        // Reconnecting the transport must not interrupt the ride screen.
      }
    }
  }

  Future<void> _restoreSubscriptionsAndNotify(HubConnection connection) async {
    await setForeground(_foreground);
    await _restoreRideSubscriptions(connection);
    await _joinNearbyDriverSubscription(connection);
    if (identical(_connection, connection) &&
        connection.state == HubConnectionState.Connected) {
      _invalidatePendingBusinessReads();
      _connectionRestored.add(null);
      await recoverState();
    }
  }

  /// Recovery is feature detected. Older servers retain existing REST fallback.
  Future<void> recoverState() {
    final existing = _stateRecoveryTask;
    if (existing != null) return existing;
    late final Future<void> task;
    task = _recoverState().whenComplete(() {
      if (identical(_stateRecoveryTask, task)) _stateRecoveryTask = null;
    });
    _stateRecoveryTask = task;
    return task;
  }

  Future<void> _recoverState() async {
    final connection = _connection;
    final generation = _connectionGeneration;
    if (!_foreground || connection?.state != HubConnectionState.Connected)
      return;
    try {
      await stateChanges.recover((versions, afterStream) async {
        final result = await connection!.invoke('ReplayStateChanges',
            args: <Object>[versions, afterStream ?? '']);
        if (!identical(_connection, connection) ||
            generation != _connectionGeneration ||
            !_foreground) {
          throw StateError('State recovery connection changed');
        }
        if (result is! Map) throw const FormatException('Invalid state replay');
        supportsStateRecovery.value = result['supported'] == true;
        if (result['supported'] == true &&
            result['events'] is List &&
            (result['events'] as List).isNotEmpty) {
          _invalidatePendingBusinessReads();
        }
        return Map<Object?, Object?>.from(result);
      });
      _stateRecoveryRetry?.cancel();
    } on Object {
      // Recovery failure never certifies freshness. Retry this failed work while
      // retaining legacy fallback, without introducing a business-state poll.
      if (identical(_connection, connection) &&
          generation == _connectionGeneration) {
        isStateSynchronized.value = false;
        _stateRecoveryRetry?.cancel();
        if (supportsStateRecovery.value && _foreground) {
          _stateRecoveryRetry = Timer(
              const Duration(seconds: 3), () => unawaited(recoverState()));
        }
      }
    }
    isStateSynchronized.value =
        supportsStateRecovery.value && stateChanges.synchronized;
  }

  Future<void> _joinNearbyDriverSubscription(
    HubConnection? connection,
  ) async {
    final subscription = _nearbyDriverSubscription;
    if (subscription == null ||
        connection == null ||
        connection.state != HubConnectionState.Connected) {
      return;
    }
    try {
      await connection.invoke(
        'JoinNearbyDrivers',
        args: <Object>[subscription],
      );
    } on Object {
      // The REST nearby-driver snapshot stays visible if the map join fails.
    }
  }

  Future<void> _invokeIfConnected(String method, int rideId) async {
    final connection = _connection;
    if (connection == null ||
        connection.state != HubConnectionState.Connected) {
      return;
    }
    try {
      await connection.invoke(method, args: <Object>[rideId]);
    } on Object {
      // Live updates are supplemental; REST snapshots remain available.
    }
  }

  Future<void> _handleSessionRevoked() async {
    final handler = onSessionRevoked;
    if (handler != null) {
      await handler();
    } else {
      await disconnect();
    }
  }

  void _scheduleReconnect() {
    if (isClosed ||
        !_foreground ||
        _availability?.runtimeUnavailable.value == true) return;
    if (_rideIds.isEmpty && _userEventListeners.isEmpty) return;
    _retryTimer?.cancel();
    // Spread retries after an API/network outage instead of synchronizing all
    // driver clients on the same 15-second boundary.
    _retryTimer = Timer(
        Duration(milliseconds: 12000 + _reconnectRandom.nextInt(6001)), () {
      if (_rideIds.isNotEmpty || _userEventListeners.isNotEmpty) {
        unawaited(_ensureConnected());
      }
    });
  }

  /// Replace the transport after an API restart, retaining active ride and
  /// screen subscriptions even if SignalR exhausted its own retry schedule.
  Future<void> reconnectAfterApiRecovery() async {
    if (isClosed || !_foreground) return;
    _connectionGeneration++;
    _retryTimer?.cancel();
    _stateRecoveryRetry?.cancel();
    _stateRecoveryTask = null;
    _connectTask = null;
    stateChanges.disconnected();
    final previous = _connection;
    _connection = null;
    isConnected.value = false;
    if (previous != null) {
      try {
        await previous.stop().timeout(const Duration(seconds: 3));
      } on Object {/* A dead transport must not prevent a new connection. */}
    }
    if (!isClosed && _hasInterest) await _ensureConnected();
  }

  @override
  void onClose() {
    _apiRecovery?.cancel();
    _apiAvailabilityWorker?.dispose();
    unawaited(disconnect());
    stateChanges.dispose();
    unawaited(_events.close());
    unawaited(_connectionRestored.close());
    super.onClose();
  }
}

class _LocationScope {
  const _LocationScope(this.generation, this.rideGeneration, this.session,
      this.userId, this.token);
  final int generation;
  final int? rideGeneration;
  final AuthSessionService? session;
  final int? userId;
  final String token;
}
