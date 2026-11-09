import '../../../shared/widgets/ride_financial_follow_up.dart';
import '../../../core/network/api_client.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';

import '../../../core/network/api_models.dart';
import '../../../core/realtime/tracking_hub_service.dart';
import '../../../core/realtime/state_change_coordinator.dart';
import '../../../core/services/auth_session_service.dart';
import '../../../core/services/push_notifications_service.dart';
import '../../../core/services/driver_location_tracker.dart';
import '../../../core/services/driver_route_outbox.dart';
import '../../../core/services/startup_connection_service.dart';
import '../driver_routes.dart';
import '../models/driver_ride_payment_state.dart';
import '../models/driver_request_route.dart';
import '../repositories/driver_repository.dart';
import '../repositories/route_repository.dart';
import '../views/driver_payment_view.dart';
import '../views/driver_notifications_view.dart';
import '../views/driver_request_route_view.dart';

/// The latest verified passenger GPS sample for one assigned ride.
///
/// This exists only in memory while the driver is handling the ride. The
/// public ride-sharing flow never reads this value.
class PassengerLocationUpdate {
  const PassengerLocationUpdate({
    required this.latitude,
    required this.longitude,
    required this.observedAtUtc,
    this.bearing,
  });

  final double latitude;
  final double longitude;
  final double? bearing;
  final DateTime observedAtUtc;
}

class DriverController extends GetxController with WidgetsBindingObserver {
  DriverController(this._repository, this._session, {RouteRepository? routes}) {
    requestRouteCache = DriverRequestRouteCache(
        () => routes ?? ApiRoutesRepository(Get.find<ApiClient>()));
  }
  final DriverRepository _repository;
  final AuthSessionService _session;
  late final DriverRequestRouteCache requestRouteCache;
  final isLoading = false.obs;
  final RxnString error = RxnString();
  final Rxn<Position> currentPosition = Rxn<Position>();
  final Rxn<Map<String, Object?>> profile = Rxn<Map<String, Object?>>();
  final rides = <Map<String, Object?>>[].obs;
  final notifications = <Map<String, Object?>>[].obs;
  final RxDouble walletBalance = 0.0.obs;
  final RxDouble walletLedgerDebt = 0.0.obs;
  final walletTransactions = <Map<String, Object?>>[].obs;
  final isWalletLoading = false.obs;
  final isWalletLoaded = false.obs;
  final RxDouble driverAccountBalance = 0.0.obs;
  final RxDouble driverCommissionTotal = 0.0.obs;
  final driverAccountTransactions = <Map<String, Object?>>[].obs;
  final isDriverAccountLoading = false.obs;
  final Rx<DateTime> financialFrom = DateTime.now().obs;
  final Rx<DateTime> financialTo = DateTime.now().obs;
  final RxString financialSearch = ''.obs;
  final RxnInt financialType = RxnInt();
  final RxBool financialFiltersVisible = false.obs;
  final RxnInt focusedRideId = RxnInt();
  final paymentEnabledRideIds = <int>{};
  final passengerLocationsByRideId = <int, PassengerLocationUpdate>{}.obs;
  final Set<int> _paymentChecksInFlight = <int>{};
  final Map<int, Future<void>> _rideRefreshes = {};
  final Set<int> _rideRefreshRequested = {};
  final Map<int, int> _rideSnapshotVersions = {};
  DriverLocationTracker? _locationTracker;
  final locationStatus = DriverLocationStatus.locating.obs;
  final Rxn<DateTime> lastLocationSentAt = Rxn<DateTime>();
  Timer? _automaticSyncTimer;
  bool _paused = false;
  bool _refreshQueued = false;
  StreamSubscription<TrackingHubEvent>? _hubEventSubscription;
  StreamSubscription<void>? _hubConnectionSubscription;
  StreamSubscription<void>? _apiRecoverySubscription;
  Future<void> Function(Map<String, String>)? _notificationOpenedHandler;
  bool _refreshInFlight = false;
  Future<void>? _loadTask;
  bool _initialSnapshotLoaded = false;
  final Map<String, TrackingHubEvent> _eventsReceivedDuringRefresh = {};
  final Set<int> _legacyRideRefreshes = {};
  final Set<int> _legacyPaymentRefreshes = {};
  Timer? _legacyRefreshTimer;
  bool _legacyNotificationsRefresh = false;
  bool _locationUpdateInFlight = false;
  ({Position position, int driverId, int? rideId})? _pendingLivePosition;
  Timer? _liveLocationRetry;
  DriverRouteOutbox? _routeOutbox;
  Timer? _routeRetry;
  final RxnString routeRecordingError = RxnString();
  int? _viewedRideId;
  DateTime? _viewedUntil;
  DateTime? _lastLocationSentAt;
  Position? _lastSentPosition;
  int? _lastSentRideId;
  int? _lastTrackingRideId;
  final Map<int, int> _requestVersions = {};
  int _requestSnapshotVersion = 0;
  final cancellationRequestsInFlight = <int>{}.obs;

  static const _trackableRideStatuses = <int>{3, 4, 5, 8, 9};

  int? get currentUserId => _session.currentUserId.value;

  TrackingHubService? get _hub => Get.isRegistered<TrackingHubService>()
      ? Get.find<TrackingHubService>()
      : null;
  int get _rideEpoch =>
      _hub?.stateChanges.epochForResources(const {'ride'}) ?? 0;
  int get _snapshotEpoch =>
      _hub?.stateChanges
          .epochForResources(const {'ride', 'profile', 'catalog'}) ??
      0;
  int get _notificationEpoch =>
      _hub?.stateChanges.epochForResources(const {'notifications'}) ?? 0;
  int get _walletEpoch =>
      _hub?.stateChanges.epochForResources(const {'wallet', 'account'}) ?? 0;
  bool get _apiUnavailable =>
      Get.isRegistered<StartupConnectionService>() &&
      Get.find<StartupConnectionService>().runtimeUnavailable.value;
  bool get _durableSynchronized =>
      _hub?.supportsStateRecovery.value == true &&
      _hub?.isStateSynchronized.value == true &&
      _hub?.stateChanges.covers(this) == true;

  Future<void> _reconcileState(List<StateChange> changes) async {
    if (isClosed) return;
    final resources = changes.map((change) => change.resource).toSet();
    if (resources.any({'ride', 'profile', 'catalog'}.contains)) {
      // The authorized list also removes requests no longer available to us.
      await _queueSnapshotLoad(false);
    } else if (resources.contains('notifications')) {
      await _refreshNotifications(announceRequests: true, requireSuccess: true);
    }
    if (resources.any({'wallet', 'account'}.contains)) {
      await _queueWalletLoad();
      if (_driverAccountLoaded) await _queueDriverAccountLoad();
    }
  }

  PassengerLocationUpdate? passengerLocationForRide(int rideId) =>
      passengerLocationsByRideId[rideId];

  @override
  void onReady() {
    super.onReady();
    _notificationOpenedHandler = _handleOpenedNotification;
    _session.onNotificationOpened = _notificationOpenedHandler;
    WidgetsBinding.instance.addObserver(this);
    if (Get.isRegistered<StartupConnectionService>()) {
      _apiRecoverySubscription =
          Get.find<StartupConnectionService>().recovered.listen((_) {
        if (isClosed || _paused || !_session.isAuthenticated.value) return;
        // Reconcile canonical reads; never repeat heading, payment or other
        // user commands whose outcome may be unknown after a lost response.
        unawaited(load(showLoading: false));
        if (isWalletLoaded.value) unawaited(loadWallet(quiet: true));
        if (_driverAccountLoaded) {
          unawaited(_queueDriverAccountLoad().catchError((Object _) {}));
        }
        unawaited(_locationTracker?.refresh() ?? Future<void>.value());
        _retryLatestLocation();
      });
    }
    _automaticSyncTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_paused &&
          !isClosed &&
          _session.isAuthenticated.value &&
          !_apiUnavailable &&
          !_durableSynchronized) {
        unawaited(load(showLoading: false));
      }
    });
    unawaited(_startRealtimeAndLocation());
  }

  Future<void> _startRealtimeAndLocation() async {
    if (const bool.fromEnvironment('DURABLE_DRIVER_SAMPLES')) {
      _routeOutbox = DriverRouteOutbox(
        store: SqliteDriverRouteStore(),
        send: (payload) =>
            Get.find<TrackingHubService>().publishDriverLocationBatch(payload),
        isCurrentAccount: (id) =>
            !isClosed && currentUserId == id && _session.isAuthenticated.value,
        onChanged: () {
          if (!isClosed)
            routeRecordingError.value = _routeOutbox?.failure?.toString();
        },
      );
      _routeRetry = Timer.periodic(const Duration(seconds: 5), (_) {
        if (currentUserId != null) unawaited(_flushRouteSamples());
      });
      unawaited(_flushRouteSamples());
    }
    _locationTracker = DriverLocationTracker(
      adaptive: const bool.fromEnvironment('DURABLE_DRIVER_SAMPLES'),
      onPosition: _publishLocation,
      onStatus: (status) {
        if (!isClosed) locationStatus.value = status;
      },
      onAccessRequired: _showLocationAccessPrompt,
    );
    unawaited(_locationTracker!.start());
    await _startRealtimeAndLoad();
    final arguments = Get.arguments;
    if (arguments is Map && arguments['openNotification'] == true) {
      final rawPayload = arguments['pushNotification'];
      if (rawPayload is Map) {
        await _openPushNotification(
          rawPayload.map((key, value) => MapEntry('$key', '$value')),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    unawaited(_hub?.setForeground(!_paused) ?? Future<void>.value());
    if (_paused || isClosed || !_session.isAuthenticated.value) return;
    unawaited(_locationTracker?.refresh() ?? Future<void>.value());
    _retryLatestLocation();
    unawaited(load(showLoading: false));
    if (isWalletLoaded.value) unawaited(loadWallet(quiet: true));
  }

  Future<void> _openPushNotification(Map<String, String> payload) async {
    final id = int.tryParse('${payload['notificationId'] ?? ''}');
    final notification = id == null
        ? null
        : notifications
            .where((item) => int.tryParse('${item['id']}') == id)
            .firstOrNull;
    final action = payload['action']?.trim().toLowerCase();
    final rideId = int.tryParse('${payload['rideId'] ?? ''}');
    if (_opensWallet(action, payload)) {
      if (notification != null) await markNotificationRead(notification);
      var found = false;
      Get.until((route) {
        found = route.settings.name == DriverRoutes.wallet;
        return found || route.isFirst;
      });
      if (!found) Get.toNamed<void>(DriverRoutes.wallet, arguments: payload);
      unawaited(loadWallet());
      return;
    }

    if (notification == null) {
      final cancellationId =
          int.tryParse('${payload['cancellationRequestId'] ?? ''}');
      if (cancellationId != null &&
          _cancellationNotificationActionable(rideId)) {
        showNotifications();
        return;
      }
      final cashPaymentId =
          int.tryParse('${payload['cashPaymentRequestId'] ?? ''}');
      if (cashPaymentId != null) {
        showNotifications();
        return;
      }
      if (rideId != null) {
        focusedRideId.value = rideId;
        final ride = rides
            .where((item) => int.tryParse('${item['id']}') == rideId)
            .firstOrNull;
        if (ride != null && action == 'open_active_ride') {
          await openPickupNavigation(ride);
        }
        return;
      }
      showNotifications();
      return;
    }

    final cancellationId = cancellationRequestId(notification);
    if (cancellationId != null &&
        notification['isRead'] != true &&
        _cancellationNotificationActionable(notificationRideId(notification))) {
      showNotifications();
      return;
    }
    final cashPaymentId = cashPaymentRequestId(notification);
    final notificationRideIdValue = notificationRideId(notification);
    if (cashPaymentId != null &&
        _cashNotificationActionable(notification, notificationRideIdValue)) {
      showNotifications();
      return;
    }
    if (notificationRideIdValue != null)
      focusedRideId.value = notificationRideIdValue;
    await markNotificationRead(notification);
    showNotifications();
  }

  Future<void> _handleOpenedNotification(Map<String, String> payload) async {
    if (isClosed || !_session.isAuthenticated.value) return;
    await load(showLoading: false);
    if (isClosed || !_session.isAuthenticated.value) return;
    await _openPushNotification(payload);
  }

  bool _opensWallet(String? action, Map<String, String> payload) =>
      action == 'open_wallet' ||
      action == 'open_wallet_transaction' ||
      action == 'open_driver_wallet' ||
      action == 'open_driver_account' ||
      payload['walletTransactionId']?.isNotEmpty == true ||
      payload['driverSettlementPaymentId']?.isNotEmpty == true;

  Future<void> _startRealtimeAndLoad() async {
    if (Get.isRegistered<TrackingHubService>()) {
      final hub = Get.find<TrackingHubService>();
      hub.stateChanges.register(this, _reconcileState);
      _hubEventSubscription = hub.events.listen(_handleHubEvent);
      _hubConnectionSubscription = hub.connectionRestored.listen((_) {
        if (_initialSnapshotLoaded) unawaited(load(showLoading: false));
        if (isWalletLoaded.value) unawaited(loadWallet(quiet: true));
        _retryLatestLocation();
      });
      unawaited(hub.setUserEventListening(this, true));
    }
    await load();
    _initialSnapshotLoaded = true;
  }

  void _handleHubEvent(TrackingHubEvent event) {
    if (isClosed) return;
    if (event.name == 'trackingDemandChanged') {
      _viewedRideId = event.payload['hasViewers'] == true
          ? int.tryParse('${event.payload['rideId']}')
          : null;
      _viewedUntil = DateTime.tryParse('${event.payload['expiresAtUtc']}');
      _updateTrackingActivity();
      return;
    }
    // Location delivery is independent from a slow business-state snapshot.
    // Never queue every GPS packet behind an HTTP request.
    if (event.name == 'passengerLocationUpdated') {
      final rideId =
          int.tryParse('${event.payload['rideId'] ?? event.payload['id']}');
      if (rideId != null) _applyPassengerLocationUpdate(rideId, event.payload);
      return;
    }
    if (event.name == 'driverLocationUpdated' ||
        event.name == 'nearbyDriverLocationUpdated') return;
    if (_hub?.supportsStateRecovery.value == true &&
        !const {
          'driverLocationUpdated',
          'passengerLocationUpdated',
          'nearbyDriverLocationUpdated',
          'trackingDemandChanged'
        }.contains(event.name)) {
      return;
    }
    if (_refreshInFlight) {
      final key =
          '${event.name}:${event.payload['rideId'] ?? event.payload['id'] ?? ''}';
      _eventsReceivedDuringRefresh.remove(key);
      if (_eventsReceivedDuringRefresh.length >= 128) {
        _eventsReceivedDuringRefresh
            .remove(_eventsReceivedDuringRefresh.keys.first);
        _refreshQueued = true; // A full snapshot restores any evicted resource.
      }
      _eventsReceivedDuringRefresh[key] = event;
      return;
    }
    final payload = event.payload;
    if (event.name == 'notificationCreated') {
      _legacyNotificationsRefresh = true;
      _scheduleLegacyRefresh();
      return;
    }
    final rideId = int.tryParse('${payload['id'] ?? payload['rideId'] ?? ''}');
    if (rideId == null) return;

    if (event.name == 'rideArrivalUpdated' ||
        event.name == 'rideCancellationUpdated' ||
        event.name == 'rideRouteChangeUpdated' ||
        event.name == 'cashApprovalUpdated') {
      _legacyRideRefreshes.add(rideId);
      _scheduleLegacyRefresh();
      return;
    }

    if (event.name == 'rideAvailable') {
      unawaited(receiveAvailableRequest(payload, rideId));
      return;
    }
    if (event.name == 'rideUnavailable') {
      _requestVersions[rideId] = (_requestVersions[rideId] ?? 0) + 1;
      rides.removeWhere((ride) =>
          int.tryParse('${ride['id']}') == rideId &&
          '${ride['driverId'] ?? ''}' != '${currentUserId ?? ''}');
      return;
    }
    if (event.name == 'paymentUpdated') {
      _legacyPaymentRefreshes.add(rideId);
      _legacyRideRefreshes.add(rideId);
      _scheduleLegacyRefresh();
      return;
    }
    if (event.name == 'rideStatusUpdated') {
      final rideStatus = int.tryParse('${payload['rideStatus'] ?? ''}');
      if (rideStatus != null && rideStatus != 1 && rideStatus != 2) {
        _requestVersions[rideId] = (_requestVersions[rideId] ?? 0) + 1;
      }
      if (rideStatus == 6 || rideStatus == 7) {
        unawaited(load(showLoading: false));
      }
      final index =
          rides.indexWhere((ride) => int.tryParse('${ride['id']}') == rideId);
      if (rideStatus != null && index >= 0) {
        final updatedRide = Map<String, Object?>.from(rides[index]);
        updatedRide['status'] = rideStatus;
        if (payload.containsKey('passengerBoardedAtUtc')) {
          updatedRide['passengerBoardedAtUtc'] =
              payload['passengerBoardedAtUtc'];
        }
        if (payload.containsKey('customerPaymentEnabled')) {
          updatedRide['customerPaymentEnabled'] =
              payload['customerPaymentEnabled'] == true;
        }
        rides[index] = updatedRide;
        if (!_trackableRideStatuses.contains(rideStatus)) {
          passengerLocationsByRideId.remove(rideId);
        }
        _syncActiveRideSubscriptions();
      }
      // Route approvals keep the same ride status. Fetch the authoritative
      // destination and fare for every update, including these approvals.
      _legacyRideRefreshes.add(rideId);
      _scheduleLegacyRefresh();
      return;
    }
    if (event.name != 'offerUpdated') return;

    final driverId = int.tryParse('${payload['driverId'] ?? ''}');
    final assignedDriverId =
        int.tryParse('${payload['assignedDriverId'] ?? ''}');
    final rideStatus = int.tryParse('${payload['rideStatus'] ?? ''}');
    if (rideStatus == 3) {
      _requestVersions[rideId] = (_requestVersions[rideId] ?? 0) + 1;
    }
    if (rideStatus == 3 && assignedDriverId == currentUserId) {
      final rawRide = payload['rideSnapshot'];
      if (rawRide is Map<Object?, Object?>) {
        _upsertRide(Map<String, Object?>.from(rawRide), rideId);
        _syncActiveRideSubscriptions();
      }
      return;
    }
    if (rideStatus == 3 && assignedDriverId != currentUserId) {
      rides.removeWhere((ride) => int.tryParse('${ride['id']}') == rideId);
      _syncActiveRideSubscriptions();
      return;
    }

    final index =
        rides.indexWhere((ride) => int.tryParse('${ride['id']}') == rideId);
    if (index < 0 || driverId != currentUserId) return;
    final updatedRide = Map<String, Object?>.from(rides[index]);
    updatedRide['driverOfferAmount'] = payload['amount'];
    updatedRide['driverOfferExpiresAtUtc'] = payload['expiresAtUtc'];
    updatedRide['driverOfferStatus'] = payload['status'];
    rides[index] = updatedRide;
  }

  void _scheduleLegacyRefresh() {
    if (isClosed || _legacyRefreshTimer != null) return;
    _legacyRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      _legacyRefreshTimer = null;
      if (isClosed) return;
      final ids = _legacyRideRefreshes.toList(growable: false);
      final payments = Set<int>.of(_legacyPaymentRefreshes);
      final notifications = _legacyNotificationsRefresh;
      _legacyRideRefreshes.clear();
      _legacyPaymentRefreshes.clear();
      _legacyNotificationsRefresh = false;
      // The shared recovery callback refreshes snapshots once the API returns.
      if (_apiUnavailable || _paused) return;
      for (final id in ids) {
        if (payments.contains(id) && paymentEnabledRideIds.contains(id)) {
          unawaited(_refreshEnabledPayment(id));
        } else {
          unawaited(refreshRide(id).catchError((Object _) {}));
        }
      }
      if (notifications) {
        unawaited(_refreshNotifications(announceRequests: true));
        unawaited(loadWallet(quiet: true));
      }
    });
  }

  void _applyPassengerLocationUpdate(
    int rideId,
    Map<String, Object?> payload,
  ) {
    final ride = rides
        .where((item) => int.tryParse('${item['id']}') == rideId)
        .firstOrNull;
    if (ride == null || !_isTrackableDriverRide(ride)) return;

    final latitude = _finiteNumber(payload['latitude']);
    final longitude = _finiteNumber(payload['longitude']);
    final observedAt =
        DateTime.tryParse('${payload['observedAtUtc'] ?? ''}')?.toUtc();
    if (latitude == null ||
        longitude == null ||
        observedAt == null ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return;
    }

    final bearing = _finiteNumber(payload['bearing']);
    final previous = passengerLocationsByRideId[rideId];
    if (previous != null && !observedAt.isAfter(previous.observedAtUtc)) return;

    passengerLocationsByRideId[rideId] = PassengerLocationUpdate(
      latitude: latitude,
      longitude: longitude,
      bearing:
          bearing != null && bearing >= 0 && bearing < 360 ? bearing : null,
      observedAtUtc: observedAt,
    );
  }

  bool _isTrackableDriverRide(Map<String, Object?> ride) =>
      ride['driverId']?.toString() == currentUserId?.toString() &&
      _trackableRideStatuses.contains(int.tryParse('${ride['status']}'));

  void _prunePassengerLocations() {
    final activeRideIds = rides
        .where(_isTrackableDriverRide)
        .map((ride) => int.tryParse('${ride['id']}'))
        .whereType<int>()
        .toSet();
    final staleRideIds = passengerLocationsByRideId.keys
        .where((rideId) => !activeRideIds.contains(rideId))
        .toList(growable: false);
    for (final rideId in staleRideIds) {
      passengerLocationsByRideId.remove(rideId);
    }
  }

  double? _finiteNumber(Object? value) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  void _upsertRide(Map<String, Object?> ride, int rideId) {
    final index =
        rides.indexWhere((item) => int.tryParse('${item['id']}') == rideId);
    if (index < 0) {
      rides.insert(0, Map<String, Object?>.from(ride));
    } else {
      final previous = rides[index];
      final previousVersion = int.tryParse('${previous['routeVersion']}') ?? 0;
      final nextVersion = int.tryParse('${ride['routeVersion']}') ?? 0;
      if (nextVersion < previousVersion) return;
      rides[index] = {...previous, ...ride};
    }
    _rideSnapshotVersions[rideId] = (_rideSnapshotVersions[rideId] ?? 0) + 1;
  }

  /// A delayed Hub event must pass the same check as a push notification.
  Future<void> receiveAvailableRequest(
      Map<String, Object?> payload, int rideId) async {
    final snapshotVersion = _requestSnapshotVersion;
    final version = (_requestVersions[rideId] ?? 0) + 1;
    _requestVersions[rideId] = version;
    try {
      if (!await _repository.isRequestAvailable(rideId) ||
          _requestVersions[rideId] != version ||
          _requestSnapshotVersion != snapshotVersion ||
          isClosed) return;
      _upsertRide(payload, rideId);
      await _refreshNotifications(announceRequests: true);
    } on Object {
      // A reconnect snapshot will retry; an unverified event is never displayed.
    }
  }

  Future<void> requestCancellation(Map<String, Object?> ride,
      {String? initialReason}) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null || cancellationRequestsInFlight.contains(id)) return;
    final reason = TextEditingController(text: initialReason);
    final submitted = await Get.dialog<String>(AlertDialog(
      title: Text(operationalText('إلغاء الرحلة', 'Cancel ride')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${ride['status']}' == '5'
            ? operationalText(
                'اطلب التوقف في مكان آمن أولاً. الإرسال يؤكد أن النقل توقف فعلياً؛ تُراجع المسؤولية والمبالغ بشكل مستقل.',
                'Stop in a safe location first. Sending confirms transport has physically ended; responsibility and money are reviewed separately.')
            : operationalText('سيتم إلغاء الرحلة قبل بدءها.',
                'The ride will be cancelled before starting.')),
        TextField(
            controller: reason,
            maxLength: 1000,
            decoration: InputDecoration(
                labelText:
                    operationalText('سبب الإلغاء', 'Cancellation reason'))),
      ]),
      actions: [
        TextButton(
            onPressed: () => Get.back<String>(),
            child: Text(operationalText('رجوع', 'Back'))),
        FilledButton(
            onPressed: () {
              if (reason.text.trim().length >= 3)
                Get.back(result: reason.text.trim());
            },
            child: Text(operationalText('إرسال', 'Submit'))),
      ],
    ));
    unawaited(Future<void>.delayed(
        const Duration(milliseconds: 400), reason.dispose));
    // Dialog reverse animations may still be reading the editing value.
    if (submitted == null) return;
    cancellationRequestsInFlight.add(id);
    try {
      // Cancellation can freeze the travelled fare just like finishing a ride.
      // Preserve recorded points before the server captures that boundary.
      if ('${ride['status']}' == '5' || ride['startedAtUtc'] != null) {
        await ensureRouteSamplesSaved(id);
      }
      final result = await _repository.requestRideCancellation(id, submitted,
          safeStopConfirmed: '${ride['status']}' == '5');
      Get.snackbar(
          operationalText('تم تسجيل الطلب', 'Request recorded'),
          '${result['rideStatus']}' == '7'
              ? operationalText(
                  'أُلغي النقل. يبقى استقبال الطلبات مرتبطاً باختيارك وأهليتك لدى الشركة.',
                  'Transport cancelled. Your request availability remains under your control and company eligibility.')
              : operationalText(
                  'انتهى الالتزام بالنقل. تُراجع المسؤولية والمبالغ في متابعة الرحلة.',
                  'Transport ended. Review responsibility and money in ride follow-up.'));
      await load(showLoading: false);
    } on Object {
      Get.snackbar(
          operationalText('تعذر إلغاء الرحلة', 'Could not cancel ride'),
          operationalText('تحقق من حالة الرحلة ثم أعد المحاولة.',
              'Check the confirmed ride state and try again.'));
    } finally {
      cancellationRequestsInFlight.remove(id);
    }
  }

  /// Coalesce updates without losing an approval that arrives during a fetch.
  Future<void> refreshRide(int rideId) {
    _rideRefreshRequested.add(rideId);
    return _rideRefreshes.putIfAbsent(rideId, () async {
      try {
        do {
          _rideRefreshRequested.remove(rideId);
          final account = currentUserId;
          final epoch = _rideEpoch;
          final latest = await _repository.getRide(rideId);
          if (isClosed || account != currentUserId) return;
          if (epoch != _rideEpoch) {
            _rideRefreshRequested.add(rideId);
            continue;
          }
          _upsertRide(latest, rideId);
          if (latest['customerPaymentEnabled'] == true &&
              latest['paymentCompleted'] != true) {
            paymentEnabledRideIds.add(rideId);
          } else {
            paymentEnabledRideIds.remove(rideId);
          }
          _syncActiveRideSubscriptions();
        } while (_rideRefreshRequested.contains(rideId));
      } finally {
        _rideRefreshes.remove(rideId);
      }
    });
  }

  void _syncActiveRideSubscriptions() {
    _updateTrackingActivity();
    _prunePassengerLocations();
    final account = currentUserId;
    final activeRide = account == null ? null : _activeTrackingRideId(account);
    if (_lastTrackingRideId != activeRide) {
      _lastTrackingRideId = activeRide;
      if (activeRide != null) {
        unawaited(_locationTracker?.refresh() ?? Future<void>.value());
      }
    }
    if (!Get.isRegistered<TrackingHubService>()) return;
    final rideIds = rides
        .where(_isTrackableDriverRide)
        .map((ride) => int.tryParse('${ride['id']}'))
        .whereType<int>();
    unawaited(Get.find<TrackingHubService>().setRideSubscriptions(rideIds));
  }

  Future<void> load({bool showLoading = true}) async {
    try {
      await _queueSnapshotLoad(showLoading);
    } on Object {
      // The last usable snapshot stays visible. Durable owners retry failures.
    }
  }

  Future<void> _queueSnapshotLoad(bool showLoading) {
    if (_loadTask != null) {
      _refreshQueued = true;
      return _loadTask!;
    }
    late final Future<void> task;
    task = (() async {
      do {
        _refreshQueued = false;
        await _loadOnce(showLoading: showLoading);
      } while (_refreshQueued && !isClosed);
    })()
        .whenComplete(() {
      if (identical(_loadTask, task)) _loadTask = null;
    });
    _loadTask = task;
    return task;
  }

  Future<void> _loadOnce({required bool showLoading}) async {
    if (isClosed) return;
    _refreshInFlight = true;
    // A fresh reconnect snapshot supersedes earlier invitation verification.
    _requestSnapshotVersion++;
    if (showLoading) {
      isLoading.value = true;
      error.value = null;
    }
    final versionsAtStart = Map<int, int>.of(_rideSnapshotVersions);
    try {
      final needsIdentity =
          _session.isAuthenticated.value && currentUserId == null;
      if (needsIdentity && !await _session.ensureIdentity()) {
        throw const FormatException(
            'تعذر تأكيد حساب السائق. أعد تحديث الاتصال.');
      }
      if (isClosed) return;
      if (needsIdentity) {
        unawaited(_locationTracker?.refresh() ?? Future<void>.value());
      }
      final account = currentUserId;
      final epoch = _snapshotEpoch;
      final snapshot = await _repository.load(_session.currentUserId.value);
      if (isClosed || account != currentUserId) return;
      if (epoch != _snapshotEpoch) {
        _refreshQueued = true;
        return;
      }
      profile.value = snapshot.profile;
      final previousRides = {
        for (final ride in rides) '${ride['id']}': ride,
      };
      rides.assignAll(snapshot.rides.map((ride) {
        final previous = previousRides['${ride['id']}'];
        final rideId = int.tryParse('${ride['id']}');
        if (previous != null &&
            ((_rideSnapshotVersions[rideId] ?? 0) !=
                    (versionsAtStart[rideId] ?? 0) ||
                (int.tryParse('${previous['routeVersion']}') ?? 0) >
                    (int.tryParse('${ride['routeVersion']}') ?? 0))) {
          return previous;
        }
        return ride;
      }));
      _prunePassengerLocations();
      paymentEnabledRideIds
        ..clear()
        ..addAll(rides
            .where((ride) =>
                ride['customerPaymentEnabled'] == true &&
                ride['paymentCompleted'] != true)
            .map((ride) => int.tryParse('${ride['id']}'))
            .whereType<int>());
      _syncActiveRideSubscriptions();
      await _refreshNotifications(announceRequests: true, requireSuccess: true);
    } catch (exception) {
      // A transient polling failure must not hide the last usable snapshot.
      if (showLoading || rides.isEmpty) error.value = exception.toString();
      rethrow;
    } finally {
      _refreshInFlight = false;
      if (showLoading) isLoading.value = false;
      if (_eventsReceivedDuringRefresh.isNotEmpty) {
        final queued =
            List<TrackingHubEvent>.of(_eventsReceivedDuringRefresh.values);
        _eventsReceivedDuringRefresh.clear();
        for (final event in queued) {
          _handleHubEvent(event);
        }
      }
    }
  }

  Future<void> markRequestViewed(Map<String, Object?> ride) async {
    final id = int.tryParse('${ride['id']}');
    final price = num.tryParse('${ride['customerPrice']}');
    if (id == null || price == null) return;
    await _repository.markRequestViewed(rideId: id, customerPrice: price);
  }

  Future<void> sendOffer(Map<String, Object?> ride) async {
    final rideId = int.tryParse('${ride['id']}');
    final driverId = _session.currentUserId.value;
    if (rideId == null || driverId == null) return;
    final controller =
        TextEditingController(text: '${ride['customerPrice'] ?? ''}');
    final minimum = num.tryParse('${ride['minCustomerPrice']}') ?? 1;
    final maximum = num.tryParse('${ride['maxCustomerPrice']}') ?? 999999999;
    final amount = await Get.dialog<String>(AlertDialog(
        title: const Text('إرسال عرض'),
        content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: 'السعر',
                helperText: 'المسموح: $minimum – $maximum ر.ي')),
        actions: [
          TextButton(
              onPressed: () => Get.back<void>(), child: const Text('إلغاء')),
          FilledButton(
              onPressed: () {
                final price = num.tryParse(controller.text.trim());
                if (price == null ||
                    price < minimum ||
                    price > maximum ||
                    price != price.round()) {
                  Get.snackbar('السعر خارج الحد',
                      'أدخل أجرة صحيحة من $minimum إلى $maximum ر.ي');
                  return;
                }
                Get.back(result: controller.text);
              },
              child: const Text('إرسال'))
        ]));
    if (amount == null) return;
    try {
      await _repository.sendOffer(
          rideId: rideId,
          driverId: driverId,
          amount: num.tryParse(amount) ?? 0);
      Get.snackbar('تم الإرسال', 'تم إرسال عرضك للعميل');
      await load();
    } catch (exception) {
      final message = exception is ApiProblemDetails
          ? (exception.detail?.trim().isNotEmpty == true
              ? exception.detail!
              : exception.title)
          : exception is FormatException
              ? exception.message.toString()
              : exception.toString();
      Get.snackbar('تعذر الإرسال', message);
    }
  }

  final Set<int> _statusUpdatesInFlight = {};
  Future<void> updateStatus(
      Map<String, Object?> ride, int status, String label) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null || !_statusUpdatesInFlight.add(id)) return;
    try {
      final payment = DriverRidePaymentState(ride);
      if (status == 5 && payment.startBlocked) {
        Get.snackbar('بانتظار الدفع', payment.message!);
        return;
      }
      if (status == 6) {
        await finishTransport(ride);
        return;
      }
      bool confirmPassengerBoarding = false;
      if (status == 5 && ride['passengerBoardedAtUtc'] == null) {
        final confirmed = await Get.dialog<bool>(AlertDialog(
          title: const Text('تأكيد صعود الراكب'),
          content: const Text(
              'لم يؤكد الراكب الصعود من تطبيقه. هل صعد فعلياً إلى السيارة وتريد بدء الرحلة الآن؟'),
          actions: [
            TextButton(
                onPressed: () => Get.back(result: false),
                child: const Text('لم يصعد بعد')),
            FilledButton(
                onPressed: () => Get.back(result: true),
                child: const Text('صعد الراكب، ابدأ الرحلة')),
          ],
        ));
        if (confirmed != true) return;
        confirmPassengerBoarding = true;
      }
      if (status == 5) await ensureRouteSamplesSaved(id);
      await _repository.updateRideStatus(
          rideId: id,
          status: status,
          confirmPassengerBoarding: confirmPassengerBoarding);
      Get.snackbar('تم التحديث', 'أصبحت الحالة: $label');
      await refreshRide(id);
      unawaited(_locationTracker?.refresh() ?? Future<void>.value());
      final latest =
          rides.where((item) => '${item['id']}' == '$id').firstOrNull;
      if (latest != null && '${latest['status']}' == '$status' && !isClosed) {
        if (status == 4) {
          unawaited(openPickupNavigation(latest));
        } else if (status == 5) {
          unawaited(openDestinationNavigation(latest));
        }
      }
      unawaited(load(showLoading: false));
    } catch (exception) {
      final message = exception is ApiProblemDetails
          ? (exception.detail?.trim().isNotEmpty == true
              ? exception.detail!
              : exception.title)
          : exception.toString();
      Get.snackbar('تعذر التحديث', message);
    } finally {
      _statusUpdatesInFlight.remove(id);
    }
  }

  final changingReadiness = false.obs;
  Future<void> changeReadiness(bool enabled) async {
    if (changingReadiness.value) return;
    changingReadiness.value = true;
    try {
      final result = await Get.find<ApiClient>().execute<Object?>(
          model: 'DriverReadinessModel',
          operation: 'update',
          data: {'acceptsNewRequests': enabled});
      if (result is ApiFailure) throw result.problem;
      await load(showLoading: false);
    } catch (error) {
      Get.snackbar('تعذر تغيير التوفر', '$error');
    } finally {
      changingReadiness.value = false;
    }
  }

  Future<void> openFinancialFollowUp(Map<String, Object?> ride) async {
    final id = int.tryParse('${ride['id']}');
    if (id != null)
      await Get.to<void>(
          () => RideFinancialFollowUp(rideId: id, isDriver: true));
    await load(showLoading: false);
  }

  Future<void> finishTransport(Map<String, Object?> ride) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null) return;
    final approved = await Get.dialog<bool>(AlertDialog(
      title: Text(operationalText('إنهاء خدمة النقل', 'End transport service')),
      content: Text(operationalText(
          'أكد وصول الراكب أو انتهاء النقل فعلياً عند نقطة آمنة. يبقى أي مبلغ غير مدفوع أو استرداد للمراجعة، ولا يُسجل المال مقبوضاً.',
          'Confirm arrival or physical termination at a safe location. Unpaid balances and refunds remain separate; no receipt is fabricated.')),
      actions: [
        TextButton(
            onPressed: () => Get.back(result: false),
            child: Text(operationalText('رجوع', 'Back'))),
        FilledButton(
            onPressed: () => Get.back(result: true),
            child: Text(operationalText('انتهى النقل عند نقطة آمنة',
                'Transport ended at a safe location')))
      ],
    ));
    if (approved != true) return;
    try {
      await ensureRouteSamplesSaved(id);
      final result = await Get.find<ApiClient>().execute<Object?>(
          model: 'RideServiceModel',
          operation: 'finish',
          data: {
            'rideId': id,
            'reason': 'أكد السائق انتهاء النقل عند نقطة آمنة'
          });
      if (result is ApiFailure) throw result.problem;
      await load(showLoading: false);
      await openFinancialFollowUp(ride);
    } catch (error) {
      Get.snackbar('تعذر تأكيد الإنهاء', '$error');
    }
  }

  Future<void> enableCustomerPayment(Map<String, Object?> ride) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null ||
        ride['paymentCompleted'] == true ||
        ride['walletPaymentPending'] == true) {
      return;
    }
    try {
      await ensureRouteSamplesSaved(id);
      await _repository.updateRideStatus(
          rideId: id,
          status: int.tryParse('${ride['status']}') ?? 5,
          customerPaymentEnabled: true);
      paymentEnabledRideIds.add(id);
      Get.snackbar('تمكين الدفع', 'أصبح بإمكان العميل إتمام الدفع الآن.');
      await load(showLoading: false);
    } catch (exception) {
      Get.snackbar('تعذر تمكين الدفع', exception.toString());
    }
  }

  Future<void> _refreshEnabledPayment(int rideId) async {
    if (!paymentEnabledRideIds.contains(rideId)) return;
    if (!_paymentChecksInFlight.add(rideId)) {
      // Keep the newest provider event when the previous detail request is
      // still running. refreshRide coalesces it into a subsequent fetch.
      unawaited(refreshRide(rideId).catchError((Object _) {}));
      return;
    }
    try {
      await refreshRide(rideId);
      final paidRide = rides
          .where((ride) => int.tryParse('${ride['id']}') == rideId)
          .firstOrNull;
      if (paidRide == null || paidRide['paymentCompleted'] != true) return;
      paymentEnabledRideIds.remove(rideId);
      Get.snackbar('تم الدفع', DriverRidePaymentState(paidRide).paidMessage);
    } catch (_) {
      // A reconnect or the next payment event can reconcile this state.
    } finally {
      _paymentChecksInFlight.remove(rideId);
    }
  }

  Future<void>? _notificationTask;
  bool _notificationsQueued = false;
  final Set<String> _announcedRouteDeviationNotifications = {};
  Future<void> _refreshNotifications(
      {bool announceRequests = false, bool requireSuccess = false}) async {
    try {
      if (_notificationTask != null) {
        _notificationsQueued = true;
        await _notificationTask;
        return;
      }
      late final Future<void> task;
      task = (() async {
        do {
          _notificationsQueued = false;
          final account = currentUserId;
          final epoch = _notificationEpoch;
          final latest = await _repository.notifications();
          if (isClosed || account != currentUserId) return;
          if (epoch != _notificationEpoch) {
            _notificationsQueued = true;
            continue;
          }
          notifications.assignAll(latest);
          if (announceRequests) _announceRouteDeviations();
          if (announceRequests &&
              Get.isRegistered<PushNotificationsService>()) {
            for (final item in notifications) {
              if (item['isRead'] == true) continue;
              await Get.find<PushNotificationsService>()
                  .showRideRequestNotification(item);
            }
          }
        } while (_notificationsQueued && !isClosed);
      })()
          .whenComplete(() {
        if (identical(_notificationTask, task)) _notificationTask = null;
      });
      _notificationTask = task;
      await task;
    } catch (_) {
      if (requireSuccess) rethrow;
      // The notification snapshot remains available if this request fails.
    }
  }

  void _announceRouteDeviations() {
    if (_paused || Get.key.currentState == null) return;
    for (final item in notifications) {
      if (item['isRead'] == true || item['id'] == null) continue;
      Map<Object?, Object?> data;
      try {
        final decoded = jsonDecode('${item['dataJson'] ?? '{}'}');
        if (decoded is! Map) continue;
        data = Map<Object?, Object?>.from(decoded);
      } on Object {
        continue;
      }
      if (data['action'] != 'route_deviation_reported') continue;
      final key = '$currentUserId:${item['id']}';
      if (!_announcedRouteDeviationNotifications.add(key)) continue;
      Get.snackbar(
        '${item['title'] ?? 'بلاغ انحراف عن مسار الرحلة'}',
        '${item['body'] ?? 'أرسل الراكب بلاغاً عن انحراف مسار الرحلة.'}',
        icon: const Icon(Icons.alt_route_rounded),
        duration: const Duration(seconds: 6),
        mainButton: TextButton(
          onPressed: showNotifications,
          child: const Text('عرض الإشعار'),
        ),
      );
    }
  }

  Future<void> openCashPayment(Map<String, Object?> ride) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null) return;
    Map<String, Object?> latest;
    try {
      latest = await _repository.getRideForPayment(id);
      _upsertRide(latest, id);
      final paymentState = DriverRidePaymentState(latest);
      if (!paymentState.cashSelected && !paymentState.completed) {
        await Get.to<void>(() => DriverPaymentView(
            ride: latest,
            repository: _repository,
            hub: Get.find<TrackingHubService>()));
        await load(showLoading: false);
        return;
      }
      if (latest['paymentCompleted'] == true ||
          latest['walletPaymentPending'] == true) {
        Get.snackbar(
            'حالة الدفع',
            latest['paymentCompleted'] == true
                ? '${DriverRidePaymentState(latest).paidMessage}؛ يمكنك إنهاء الرحلة عند اكتمالها.'
                : 'العميل يجري عملية دفع بالمحفظة. انتظر تأكيد النتيجة قبل التحصيل.');
        return;
      }
      if (latest['waitingIsOpen'] == true) {
        Get.snackbar('الانتظار مفتوح',
            'استأنف الرحلة أو اسحب طلب الانتظار قبل التحصيل.');
        return;
      }
      if ('${latest['status']}' == '5' &&
          latest['customerPaymentEnabled'] != true) {
        // Freeze the agreed route and fare before the collection screen opens.
        // The API also refuses this transition while a route request is pending.
        await ensureRouteSamplesSaved(id);
        await _repository.updateRideStatus(
            rideId: id, status: 5, customerPaymentEnabled: true);
        latest = await _repository.getRideForPayment(id);
        _upsertRide(latest, id);
        paymentEnabledRideIds.add(id);
      }
    } catch (error) {
      Get.snackbar(
          'تعذر تحديث الأجرة',
          error is ApiProblemDetails
              ? error.detail ?? error.title
              : 'تحقق من الاتصال لتأكيد إجمالي الرحلة قبل التحصيل.');
      return;
    }
    await Get.to<void>(() => DriverPaymentView(
          ride: latest,
          repository: _repository,
          hub: Get.find<TrackingHubService>(),
        ));
    await load(showLoading: false);
  }

  bool _walletRefreshRequested = false;
  Future<void>? _walletTask;
  Future<void> loadWallet({bool quiet = false}) async {
    try {
      await _queueWalletLoad();
    } catch (_) {
      if (!quiet)
        Get.snackbar('تعذر تحميل المحفظة', 'تحقق من الاتصال ثم أعد المحاولة.');
    }
  }

  Future<void> _queueWalletLoad() {
    if (_walletTask != null) {
      _walletRefreshRequested = true;
      return _walletTask!;
    }
    late final Future<void> task;
    task = _loadWalletSnapshot().whenComplete(() {
      if (identical(_walletTask, task)) _walletTask = null;
    });
    _walletTask = task;
    return task;
  }

  Future<void> _loadWalletSnapshot() async {
    isWalletLoading.value = true;
    try {
      do {
        _walletRefreshRequested = false;
        final account = currentUserId;
        final epoch = _walletEpoch;
        final wallet = await _repository.getWallet();
        if (isClosed || account != currentUserId) return;
        if (epoch != _walletEpoch) {
          _walletRefreshRequested = true;
          continue;
        }
        walletBalance.value = _number(wallet['balance']);
        walletLedgerDebt.value = _number(wallet['ledgerDebt']);
        final items = wallet['transactions'];
        walletTransactions.assignAll(items is List
            ? items
                .whereType<Map<Object?, Object?>>()
                .map((item) => Map<String, Object?>.from(item))
                .toList()
            : const <Map<String, Object?>>[]);
        isWalletLoaded.value = true;
      } while (_walletRefreshRequested);
    } finally {
      isWalletLoading.value = false;
    }
  }

  Future<void> loadDriverAccount() async {
    try {
      await _queueDriverAccountLoad();
    } on Object {
      Get.snackbar(
          'تعذر تحميل حساب السائق', 'تحقق من الاتصال ثم أعد المحاولة.');
    }
  }

  bool _driverAccountLoaded = false;
  bool _driverAccountQueued = false;
  Future<void>? _driverAccountTask;
  Future<void> _queueDriverAccountLoad() {
    if (_driverAccountTask != null) {
      _driverAccountQueued = true;
      return _driverAccountTask!;
    }
    late final Future<void> task;
    task = (() async {
      do {
        _driverAccountQueued = false;
        await _loadDriverAccountSnapshot();
      } while (_driverAccountQueued && !isClosed);
    })()
        .whenComplete(() {
      if (identical(_driverAccountTask, task)) _driverAccountTask = null;
    });
    _driverAccountTask = task;
    return task;
  }

  Future<void> _loadDriverAccountSnapshot() async {
    isDriverAccountLoading.value = true;
    try {
      final account = currentUserId;
      final epoch = _walletEpoch;
      final from = financialFrom.value;
      final to = financialTo.value;
      final report = await _repository.getFinancialReport(<String, Object?>{
        'from':
            DateTime(from.year, from.month, from.day).toUtc().toIso8601String(),
        'to': DateTime(to.year, to.month, to.day).toUtc().toIso8601String(),
        if (financialSearch.value.trim().isNotEmpty)
          'query': financialSearch.value.trim(),
        if (financialType.value != null) 'entryType': financialType.value,
      });
      if (isClosed || account != currentUserId) return;
      if (epoch != _walletEpoch) {
        _driverAccountQueued = true;
        return;
      }
      _driverAccountLoaded = true;
      driverAccountBalance.value = _number(report['balance']);
      driverCommissionTotal.value = _number(report['totalCommission']);
      final items = report['transactions'];
      driverAccountTransactions.assignAll(items is List
          ? items
              .whereType<Map<Object?, Object?>>()
              .map((item) => Map<String, Object?>.from(item))
              .toList()
          : const <Map<String, Object?>>[]);
    } finally {
      isDriverAccountLoading.value = false;
    }
  }

  void setFinancialDateRange(DateTime from, DateTime to) {
    financialFrom.value = DateTime(from.year, from.month, from.day);
    financialTo.value = DateTime(to.year, to.month, to.day);
    unawaited(loadDriverAccount());
  }

  void setFinancialFilters({String? query, int? type}) {
    if (query != null) financialSearch.value = query;
    financialType.value = type;
    unawaited(loadDriverAccount());
  }

  double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;

  Future<void> openPickupNavigation(Map<String, Object?> ride) =>
      _openNavigation(ride, ride['pickupLatitude'], ride['pickupLongitude'],
          'نقطة انطلاق العميل');

  Future<void> openRequestRoutePreview(Map<String, Object?> ride) async {
    final pickup =
        requestCoordinates(ride['pickupLatitude'], ride['pickupLongitude']);
    final destination = requestCoordinates(
        ride['destinationLatitude'], ride['destinationLongitude']);
    if (pickup == null || destination == null) {
      Get.snackbar('المسار غير متاح',
          'لم تصل إحداثيات الانطلاق والوجهة لهذا الطلب. يمكنك تحديث الطلبات والمحاولة مجدداً.');
      return;
    }
    await Get.to<void>(() => DriverRequestRouteView(
          ride: ride,
          cache: requestRouteCache,
          pickup: pickup,
          destination: destination,
          driverOrigin: currentRequestOrigin(currentPosition.value),
        ));
  }

  Future<void> openDestinationNavigation(Map<String, Object?> ride) async {
    if (ride['destinationAvailable'] != true) {
      Get.snackbar('الوجهة محمية', 'تظهر إحداثيات الوجهة بعد قبول العرض فقط.');
      return;
    }
    await _openNavigation(ride, ride['destinationLatitude'],
        ride['destinationLongitude'], 'وجهة الرحلة',
        followsDestination: true);
  }

  Future<void> _openNavigation(Map<String, Object?> ride, Object? latitude,
      Object? longitude, String title,
      {bool followsDestination = false}) async {
    final lat = double.tryParse('$latitude');
    final lng = double.tryParse('$longitude');
    if (lat == null || lng == null) {
      Get.snackbar('المسار غير متاح', 'لا توجد إحداثيات صالحة لفتح المسار.');
      return;
    }
    await Get.toNamed<void>(DriverRoutes.navigation,
        arguments: <String, Object?>{
          'rideId': int.tryParse('${ride['id']}'),
          'originLatitude': currentPosition.value?.latitude ??
              _finiteNumber(ride['driverLatitude']),
          'originLongitude': currentPosition.value?.longitude ??
              _finiteNumber(ride['driverLongitude']),
          'destinationLatitude': lat,
          'destinationLongitude': lng,
          'title': title,
          'followsDestination': followsDestination,
        });
  }

  Future<void> updateLocation() async {
    await _locationTracker?.refresh(prompt: true);
  }

  Future<void> _showLocationAccessPrompt(DriverLocationStatus status) async {
    if (isClosed || Get.key.currentState == null) return;
    final disabled = status == DriverLocationStatus.serviceDisabled;
    final openSettings = await Get.dialog<bool>(AlertDialog(
      title: Text(disabled ? 'تفعيل موقع الجهاز' : 'صلاحية الموقع مطلوبة'),
      content: Text(disabled
          ? 'فعّل GPS ليحدث موقعك تلقائياً ويتمكن الراكب من تتبعك.'
          : 'امنح تطبيق السائق صلاحية الموقع من إعدادات التطبيق لبدء التتبع التلقائي.'),
      actions: [
        TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('لاحقاً')),
        FilledButton(
            onPressed: () => Get.back(result: true),
            child: Text(disabled ? 'تفعيل الموقع' : 'فتح الإعدادات')),
      ],
    ));
    if (openSettings != true || isClosed) return;
    if (disabled) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
    unawaited(_locationTracker?.refresh() ?? Future<void>.value());
  }

  Future<void> _publishLocation(
    Position position, {
    bool showMessage = false,
    bool force = false,
  }) async {
    if (isClosed || !_session.isAuthenticated.value) return;
    final age = DateTime.now().toUtc().difference(position.timestamp.toUtc());
    if (age > const Duration(seconds: 30) ||
        age < const Duration(seconds: -5) ||
        !position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude.abs() > 90 ||
        position.longitude.abs() > 180 ||
        !position.accuracy.isFinite ||
        position.accuracy <= 0) return;
    final previous = currentPosition.value;
    if (previous != null && position.timestamp.isBefore(previous.timestamp)) {
      return;
    }
    // Display the actual device fix even while Android provides approximate
    // location. Only accurate fixes may enter the shared/financial route.
    currentPosition.value = position;
    _updateTrackingActivity();
    if (position.accuracy > 75) return;
    final driverId = _session.currentUserId.value;
    if (driverId == null) return;
    final rideId = _activeTrackingRideId(driverId);
    if (rideId != null && _routeOutbox != null) {
      try {
        // Persistence is independent of visual coalescing and a slow upload.
        await _routeOutbox!
            .record(driverId, rideId, _locationPayload(position));
        final enabled = await _routeOutbox!.flush(driverId, rideId: rideId);
        if (enabled) {
          if (!isClosed && currentUserId == driverId) {
            lastLocationSentAt.value = position.timestamp;
          }
          return;
        }
      } on Object catch (failure) {
        routeRecordingError.value = '$failure';
        return;
      }
    }
    _pendingLivePosition =
        (position: position, driverId: driverId, rideId: rideId);
    if (_liveLocationRetry?.isActive == true) return;
    await _flushLiveLocation(showMessage: showMessage, force: force);
  }

  void _retryLatestLocation() {
    _liveLocationRetry?.cancel();
    unawaited(_flushLiveLocation());
  }

  Future<void> _flushLiveLocation(
      {bool showMessage = false, bool force = false}) async {
    if (_locationUpdateInFlight) return;
    _locationUpdateInFlight = true;
    try {
      while (_pendingLivePosition != null && !isClosed) {
        final latest = _pendingLivePosition!;
        _pendingLivePosition = null;
        // A retry keeps the original account, ride and device timestamp. It
        // must never attach an old fix to a different trip or logged-in user.
        if (!_session.isAuthenticated.value ||
            currentUserId != latest.driverId ||
            _activeTrackingRideId(latest.driverId) != latest.rideId ||
            DateTime.now()
                    .toUtc()
                    .difference(latest.position.timestamp.toUtc()) >
                const Duration(seconds: 28)) continue;
        final sent = await _sendLiveLocation(latest.position,
            driverId: latest.driverId,
            rideId: latest.rideId,
            showMessage: showMessage,
            force: force);
        if (!sent) {
          // Retain only the newest actual sample while transport recovers.
          _pendingLivePosition ??= latest;
          break;
        }
      }
    } finally {
      _locationUpdateInFlight = false;
      if (!isClosed && _pendingLivePosition != null) {
        _liveLocationRetry?.cancel();
        _liveLocationRetry = Timer(const Duration(seconds: 3), () {
          unawaited(_flushLiveLocation());
        });
      }
    }
  }

  int? _activeTrackingRideId(int driverId) {
    for (final ride in rides) {
      if ('${ride['driverId'] ?? ''}' == '$driverId' &&
          _trackableRideStatuses.contains(int.tryParse('${ride['status']}'))) {
        return int.tryParse('${ride['id']}');
      }
    }
    return null;
  }

  Map<String, Object?> _locationPayload(Position position) => {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'bearing': position.heading.isFinite && position.heading >= 0
            ? position.heading % 360
            : null,
        'speed': position.speed.isFinite && position.speed >= 0
            ? position.speed
            : null,
        'accuracy': position.accuracy,
        'observedAtUtc': position.timestamp.toUtc().toIso8601String(),
      };

  void _updateTrackingActivity() {
    final account = currentUserId;
    final rideId = account == null ? null : _activeTrackingRideId(account);
    final viewed = rideId != null &&
        _viewedRideId == rideId &&
        (_viewedUntil?.isAfter(DateTime.now().toUtc()) ?? false);
    unawaited(_locationTracker?.setActivity(
            activeRide: rideId != null,
            viewed: viewed,
            moving: (currentPosition.value?.speed ?? 0) > 1.2,
            available: profile.value?['acceptsNewRequests'] != false) ??
        Future<void>.value());
  }

  Future<void> _flushRouteSamples() async {
    final account = currentUserId;
    if (_routeOutbox == null || account == null) return;
    try {
      final activeRide = _activeTrackingRideId(account);
      if (activeRide != null)
        await _routeOutbox!.flush(account, rideId: activeRide);
      await _routeOutbox!.flush(account);
    } on Object {
      // IDs and timestamps remain in SQLite until a later confirmed retry.
    }
  }

  Future<void> ensureRouteSamplesSaved(int rideId) async {
    final account = currentUserId;
    if (_routeOutbox != null && account != null) {
      await _routeOutbox!.requireSaved(account, rideId);
    }
  }

  Future<bool> _sendLiveLocation(Position position,
      {required int driverId,
      required int? rideId,
      required bool showMessage,
      required bool force}) async {
    if (driverId != currentUserId ||
        !_session.isAuthenticated.value ||
        isClosed) return false;
    if (DateTime.now().toUtc().difference(position.timestamp.toUtc()) >
        const Duration(seconds: 28)) return false;
    final previous = _lastSentPosition;
    final lastUpdate = _lastLocationSentAt;
    final movedMeters = previous == null
        ? double.infinity
        : Geolocator.distanceBetween(
            previous.latitude,
            previous.longitude,
            position.latitude,
            position.longitude,
          );
    if (!force &&
        _lastSentRideId == rideId &&
        lastUpdate != null &&
        DateTime.now().difference(lastUpdate) < const Duration(seconds: 2) &&
        movedMeters < 5) {
      return false;
    }

    if (!position.accuracy.isFinite ||
        position.accuracy <= 0 ||
        position.accuracy > 75) {
      return false;
    }

    try {
      final hub = Get.isRegistered<TrackingHubService>()
          ? Get.find<TrackingHubService>()
          : null;
      if (hub == null) return false;
      final sent = await hub.publishDriverLocation(<String, Object?>{
        'rideId': rideId,
        ..._locationPayload(position),
      });
      if (!sent) return false;
      if (isClosed ||
          currentUserId != driverId ||
          !_session.isAuthenticated.value ||
          _activeTrackingRideId(driverId) != rideId) return true;
      _lastLocationSentAt = DateTime.now();
      if (!isClosed) lastLocationSentAt.value = _lastLocationSentAt;
      _lastSentPosition = position;
      _lastSentRideId = rideId;
      if (showMessage) {
        Get.snackbar('تم تحديث الموقع', 'تم إرسال موقعك الحقيقي الحالي.');
      }
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> signOut() async {
    await _session.signOut();
  }

  int get unreadNotifications =>
      notifications.where((item) => item['isRead'] != true).length;

  Future<Map<String, Object?>> getCancellationRequest(int id) =>
      _repository.getCancellationRequest(id);

  bool cashNotificationActionable(Map<String, Object?> item) =>
      _cashNotificationActionable(item, notificationRideId(item));

  int? cancellationRequestId(Map<String, Object?> notification) {
    final raw = notification['dataJson']?.toString();
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is Map)
        return int.tryParse('${value['cancellationRequestId']}');
    } catch (_) {
      // A normal notification may not carry structured data.
    }
    return null;
  }

  int? cashPaymentRequestId(Map<String, Object?> notification) {
    final raw = notification['dataJson']?.toString();
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is Map) return int.tryParse('${value['cashPaymentRequestId']}');
    } catch (_) {
      // A normal notification may not carry structured data.
    }
    return null;
  }

  int? notificationRideId(Map<String, Object?> notification) {
    final raw = notification['dataJson']?.toString();
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is Map) return int.tryParse('${value['rideId']}');
    } catch (_) {}
    return null;
  }

  bool _cashNotificationActionable(
      Map<String, Object?> notification, int? rideId) {
    if (notification['isRead'] == true) return false;
    if (rideId == null) return true;
    final ride =
        rides.where((item) => '${item['id']}' == '$rideId').firstOrNull;
    if (ride == null) return true;
    final status = int.tryParse('${ride['status']}');
    return status != 6 &&
        status != 7 &&
        ride['paymentCompleted'] != true &&
        int.tryParse('${ride['cashPaymentRequestStatus']}') != 3;
  }

  Future<void> decideCashPaymentRequest(int requestId, bool accept,
      [int? rideId]) async {
    if (Get.isDialogOpen ?? false) Get.back<void>();
    try {
      await _repository.decideCashPaymentRequest(
          requestId: requestId, accept: accept);
      // The decision is consumed once. Mark the source notification read so
      // it cannot reopen the same dialog or remain in the unread badge.
      final notificationIndex = notifications.indexWhere(
        (item) => cashPaymentRequestId(item) == requestId,
      );
      if (notificationIndex >= 0) {
        final notificationId =
            int.tryParse('${notifications[notificationIndex]['id'] ?? ''}');
        if (notificationId != null) {
          try {
            await _repository.markNotificationRead(notificationId);
          } on Object {
            // The payment decision is authoritative even if the read marker
            // cannot be synchronized immediately.
          }
        }
        notifications[notificationIndex] = <String, Object?>{
          ...notifications[notificationIndex],
          'isRead': true,
        };
      }
      Get.snackbar(
        accept ? 'تم تأكيد الدفع النقدي' : 'تم رفض الدفع النقدي',
        accept
            ? 'افتح الرحلة وسجل التحصيل النقدي لإتمام الدفع.'
            : 'أُبلغ العميل بأن النقد لم يُستلم.',
      );
      await load(showLoading: false);
      if (accept && rideId != null) {
        final ride =
            rides.where((item) => '${item['id']}' == '$rideId').firstOrNull;
        if (ride != null) await openCashPayment(ride);
      }
    } catch (_) {
      Get.snackbar(
          'تعذر تسجيل القرار', 'تحقق من حالة طلب الدفع ثم حاول مرة أخرى.');
    }
  }

  Future<void> decideCancellation(int requestId, String operation) async {
    if (Get.isDialogOpen ?? false) Get.back<void>();
    try {
      await _repository.decideRideCancellation(
        requestId: requestId,
        operation: operation,
      );
      final notificationIndex = notifications.indexWhere(
        (item) => cancellationRequestId(item) == requestId,
      );
      if (notificationIndex >= 0) {
        final notificationId =
            int.tryParse('${notifications[notificationIndex]['id'] ?? ''}');
        if (notificationId != null) {
          try {
            await _repository.markNotificationRead(notificationId);
          } on Object {
            // The cancellation decision is authoritative even if its read
            // marker needs a later synchronization.
          }
        }
        notifications[notificationIndex] = <String, Object?>{
          ...notifications[notificationIndex],
          'isRead': true,
        };
      }
      final message = switch (operation) {
        'accept' => 'تم تسجيل موافقتك على إلغاء الرحلة.',
        'refer' => 'أُحيل الطلب إلى الإدارة للمراجعة.',
        _ => 'تم رفض طلب الإلغاء وأُبلغ العميل.',
      };
      Get.snackbar('تم تسجيل القرار', message);
      await load(showLoading: false);
    } catch (_) {
      Get.snackbar('تعذر تسجيل القرار', 'تحقق من حالة الطلب ثم حاول مرة أخرى.');
    }
  }

  Future<void> chooseCancellationRefund(
      int requestId, int method, int revision) async {
    await _repository.chooseCancellationRefund(requestId, method, revision);
    await load(showLoading: false);
  }

  void showNotifications() {
    Get.to<void>(() => const DriverNotificationsView());
  }

  Future<void> markNotificationRead(Map<String, Object?> item) async {
    if (item['isRead'] == true) return;
    final id = int.tryParse('${item['id'] ?? ''}');
    if (id == null) return;
    try {
      await _repository.markNotificationRead(id);
      final index = notifications.indexWhere(
        (value) => int.tryParse('${value['id']}') == id,
      );
      if (index >= 0) {
        notifications[index] = <String, Object?>{
          ...notifications[index],
          'isRead': true,
        };
      }
    } on Object {
      Get.snackbar('تعذر تحديث الإشعار', 'تحقق من الاتصال ثم حاول مرة أخرى.');
    }
  }

  bool _cancellationNotificationActionable(int? rideId) {
    if (rideId == null) return true;
    final ride =
        rides.where((item) => '${item['id']}' == '$rideId').firstOrNull;
    if (ride == null) return true;
    final status = int.tryParse('${ride['status']}');
    return status == 8 || status == 7;
  }

  @override
  void onClose() {
    _legacyRefreshTimer?.cancel();
    _eventsReceivedDuringRefresh.clear();
    if (identical(_session.onNotificationOpened, _notificationOpenedHandler)) {
      _session.onNotificationOpened = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _automaticSyncTimer?.cancel();
    _routeRetry?.cancel();
    _liveLocationRetry?.cancel();
    _pendingLivePosition = null;
    unawaited(_locationTracker?.stop() ?? Future<void>.value());
    _hubEventSubscription?.cancel();
    _hubConnectionSubscription?.cancel();
    _apiRecoverySubscription?.cancel();
    passengerLocationsByRideId.clear();
    if (Get.isRegistered<TrackingHubService>()) {
      Get.find<TrackingHubService>().stateChanges.unregister(this);
      unawaited(
        Get.find<TrackingHubService>().setUserEventListening(this, false),
      );
    }
    super.onClose();
  }
}
