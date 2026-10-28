import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';

import '../../../core/network/api_models.dart';
import '../../../core/realtime/tracking_hub_service.dart';
import '../../../core/services/auth_session_service.dart';
import '../../../core/services/push_notifications_service.dart';
import '../driver_routes.dart';
import '../repositories/driver_repository.dart';
import '../views/driver_payment_view.dart';
import '../views/driver_notifications_view.dart';

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

class DriverController extends GetxController {
  DriverController(this._repository, this._session);
  final DriverRepository _repository;
  final AuthSessionService _session;
  final isLoading = false.obs;
  final RxnString error = RxnString();
  final Rxn<Position> currentPosition = Rxn<Position>();
  final Rxn<Map<String, Object?>> profile = Rxn<Map<String, Object?>>();
  final rides = <Map<String, Object?>>[].obs;
  final notifications = <Map<String, Object?>>[].obs;
  final RxDouble walletBalance = 0.0.obs;
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
  StreamSubscription<Position>? _locationSubscription;
  bool _locationPermissionNoticeShown = false;
  StreamSubscription<TrackingHubEvent>? _hubEventSubscription;
  StreamSubscription<void>? _hubConnectionSubscription;
  bool _refreshInFlight = false;
  bool _initialSnapshotLoaded = false;
  final List<TrackingHubEvent> _eventsReceivedDuringRefresh =
      <TrackingHubEvent>[];
  bool _locationUpdateInFlight = false;
  DateTime? _lastLocationSentAt;
  Position? _lastSentPosition;
  final Map<int, int> _requestVersions = {};
  int _requestSnapshotVersion = 0;
  final cancellationRequestsInFlight = <int>{}.obs;

  static const _trackableRideStatuses = <int>{3, 4, 5, 8, 9};

  int? get currentUserId => _session.currentUserId.value;

  PassengerLocationUpdate? passengerLocationForRide(int rideId) =>
      passengerLocationsByRideId[rideId];

  @override
  void onReady() {
    super.onReady();
    unawaited(_startRealtimeAndLocation());
  }

  Future<void> _startRealtimeAndLocation() async {
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
    await _startRealLocationUpdates();
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
      Get.offAllNamed<void>(DriverRoutes.wallet, arguments: payload);
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
      _hubEventSubscription = hub.events.listen(_handleHubEvent);
      _hubConnectionSubscription = hub.connectionRestored.listen((_) {
        if (_initialSnapshotLoaded) unawaited(load(showLoading: false));
      });
      await hub.setUserEventListening(this, true);
    }
    await load();
    _initialSnapshotLoaded = true;
  }

  void _handleHubEvent(TrackingHubEvent event) {
    if (_refreshInFlight) {
      _eventsReceivedDuringRefresh.add(event);
      return;
    }
    final payload = event.payload;
    if (event.name == 'notificationCreated') {
      unawaited(_refreshNotifications(announceRequests: true));
      return;
    }
    final rideId = int.tryParse('${payload['id'] ?? payload['rideId'] ?? ''}');
    if (rideId == null) return;

    if (event.name == 'passengerLocationUpdated') {
      _applyPassengerLocationUpdate(rideId, payload);
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
      if (paymentEnabledRideIds.contains(rideId)) {
        unawaited(_refreshEnabledPayment(rideId));
      }
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
      unawaited(refreshRide(rideId).catchError((Object _) {}));
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
  }

  /// A delayed Hub event must pass the same check as a push notification.
  Future<void> receiveAvailableRequest(Map<String, Object?> payload, int rideId) async {
    final snapshotVersion = _requestSnapshotVersion;
    final version = (_requestVersions[rideId] ?? 0) + 1;
    _requestVersions[rideId] = version;
    try {
      if (!await _repository.isRequestAvailable(rideId) ||
          _requestVersions[rideId] != version ||
          _requestSnapshotVersion != snapshotVersion || isClosed) return;
      _upsertRide(payload, rideId);
      await _refreshNotifications(announceRequests: true);
    } on Object {
      // A reconnect snapshot will retry; an unverified event is never displayed.
    }
  }

  Future<void> requestCancellation(Map<String, Object?> ride) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null || cancellationRequestsInFlight.contains(id)) return;
    final reason = TextEditingController();
    final submitted = await Get.dialog<String>(AlertDialog(
      title: const Text('إلغاء الرحلة'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${ride['status']}' == '5'
            ? 'يُرسل الطلب إلى الراكب، وتستمر الرحلة حتى موافقته.'
            : 'سيتم إلغاء الرحلة قبل بدءها.'),
        TextField(controller: reason, maxLength: 1000,
            decoration: const InputDecoration(labelText: 'سبب الإلغاء')),
      ]),
      actions: [
        TextButton(onPressed: () => Get.back<String>(), child: const Text('رجوع')),
        FilledButton(onPressed: () {
          if (reason.text.trim().length >= 3) Get.back(result: reason.text.trim());
        }, child: const Text('إرسال')),
      ],
    ));
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400), reason.dispose));
    // Dialog reverse animations may still be reading the editing value.
    if (submitted == null) return;
    cancellationRequestsInFlight.add(id);
    try {
      final result = await _repository.requestRideCancellation(id, submitted);
      Get.snackbar('تم تسجيل الطلب', '${result['rideStatus']}' == '7'
          ? 'أُلغيت الرحلة وأصبحت متاحاً.' : 'بانتظار موافقة الراكب. تستمر الرحلة حالياً.');
      await load(showLoading: false);
    } on Object {
      Get.snackbar('تعذر إلغاء الرحلة', 'تحقق من حالة الرحلة ثم أعد المحاولة.');
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
          final latest = await _repository.getRide(rideId);
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
    _prunePassengerLocations();
    if (!Get.isRegistered<TrackingHubService>()) return;
    final rideIds = rides
        .where(_isTrackableDriverRide)
        .map((ride) => int.tryParse('${ride['id']}'))
        .whereType<int>();
    unawaited(Get.find<TrackingHubService>().setRideSubscriptions(rideIds));
  }

  Future<void> load({bool showLoading = true}) async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    // A fresh reconnect snapshot supersedes earlier invitation verification.
    _requestSnapshotVersion++;
    if (showLoading) {
      isLoading.value = true;
      error.value = null;
    }
    try {
      final snapshot = await _repository.load(_session.currentUserId.value);
      profile.value = snapshot.profile;
      final previousRides = {
        for (final ride in rides) '${ride['id']}': ride,
      };
      rides.assignAll(snapshot.rides.map((ride) {
        final previous = previousRides['${ride['id']}'];
        if (previous != null &&
            (int.tryParse('${previous['routeVersion']}') ?? 0) >
                (int.tryParse('${ride['routeVersion']}') ?? 0)) {
          return previous;
        }
        return ride;
      }));
      _prunePassengerLocations();
      paymentEnabledRideIds
        ..clear()
        ..addAll(snapshot.rides
            .where((ride) =>
                ride['customerPaymentEnabled'] == true &&
                ride['paymentCompleted'] != true)
            .map((ride) => int.tryParse('${ride['id']}'))
            .whereType<int>());
      final activeRideIds = snapshot.rides
          .where(
            (ride) =>
                ride['driverId']?.toString() ==
                    _session.currentUserId.value?.toString() &&
                _trackableRideStatuses.contains(
                  int.tryParse('${ride['status']}'),
                ),
          )
          .map((ride) => int.tryParse('${ride['id']}'))
          .whereType<int>();
      if (Get.isRegistered<TrackingHubService>()) {
        unawaited(
          Get.find<TrackingHubService>().setRideSubscriptions(activeRideIds),
        );
      }
      notifications.assignAll(await _repository.notifications());
    } catch (exception) {
      // A transient polling failure must not hide the last usable snapshot.
      if (showLoading || rides.isEmpty) error.value = exception.toString();
    } finally {
      _refreshInFlight = false;
      if (showLoading) isLoading.value = false;
      if (_eventsReceivedDuringRefresh.isNotEmpty) {
        final queued = List<TrackingHubEvent>.of(_eventsReceivedDuringRefresh);
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

  Future<void> updateStatus(
      Map<String, Object?> ride, int status, String label) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null) return;
    try {
      await _repository.updateRideStatus(rideId: id, status: status);
      Get.snackbar('تم التحديث', 'أصبحت الحالة: $label');
      await load();
    } catch (exception) {
      final message = exception is ApiProblemDetails
          ? (exception.detail?.trim().isNotEmpty == true
              ? exception.detail!
              : exception.title)
          : exception.toString();
      Get.snackbar('تعذر التحديث', message);
    }
  }

  Future<void> enableCustomerPayment(Map<String, Object?> ride) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null || ride['paymentCompleted'] == true) return;
    try {
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
    if (!paymentEnabledRideIds.contains(rideId) ||
        !_paymentChecksInFlight.add(rideId)) {
      return;
    }
    try {
      if (!await _repository.isRidePaymentCompleted(rideId)) return;
      paymentEnabledRideIds.remove(rideId);
      final index =
          rides.indexWhere((ride) => int.tryParse('${ride['id']}') == rideId);
      if (index >= 0) {
        rides[index] = <String, Object?>{
          ...rides[index],
          'paymentCompleted': true,
        };
      }
      Get.snackbar('تم الدفع', 'تم تأكيد تحصيل مبلغ الرحلة.');
    } catch (_) {
      // A reconnect or the next payment event can reconcile this state.
    } finally {
      _paymentChecksInFlight.remove(rideId);
    }
  }

  Future<void> _refreshNotifications({bool announceRequests = false}) async {
    try {
      notifications.assignAll(await _repository.notifications());
      if (announceRequests && Get.isRegistered<PushNotificationsService>()) {
        for (final item in notifications) {
          await Get.find<PushNotificationsService>().showRideRequestNotification(item);
        }
      }
    } catch (_) {
      // The notification snapshot remains available if this request fails.
    }
  }

  Future<void> openCashPayment(Map<String, Object?> ride) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null) return;
    Map<String, Object?> latest;
    try {
      latest = await _repository.getRideForPayment(id);
      if (latest['waitingIsOpen'] == true) {
        Get.snackbar('الانتظار مفتوح',
            'استأنف الرحلة أو اسحب طلب الانتظار قبل التحصيل.');
        return;
      }
      if ('${latest['status']}' == '5' &&
          latest['customerPaymentEnabled'] != true) {
        // Freeze the agreed route and fare before the collection screen opens.
        // The API also refuses this transition while a route request is pending.
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

  Future<void> loadWallet() async {
    if (isWalletLoading.value) return;
    isWalletLoading.value = true;
    try {
      final wallet = await _repository.getWallet();
      walletBalance.value = _number(wallet['balance']);
      final items = wallet['transactions'];
      walletTransactions.assignAll(items is List
          ? items
              .whereType<Map<Object?, Object?>>()
              .map((item) => Map<String, Object?>.from(item))
              .toList()
          : const <Map<String, Object?>>[]);
      isWalletLoaded.value = true;
    } catch (_) {
      Get.snackbar('تعذر تحميل المحفظة', 'تحقق من الاتصال ثم أعد المحاولة.');
    } finally {
      isWalletLoading.value = false;
    }
  }

  Future<void> loadDriverAccount() async {
    if (isDriverAccountLoading.value) return;
    isDriverAccountLoading.value = true;
    try {
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
      driverAccountBalance.value = _number(report['balance']);
      driverCommissionTotal.value = _number(report['totalCommission']);
      final items = report['transactions'];
      driverAccountTransactions.assignAll(items is List
          ? items
              .whereType<Map<Object?, Object?>>()
              .map((item) => Map<String, Object?>.from(item))
              .toList()
          : const <Map<String, Object?>>[]);
    } catch (exception) {
      Get.snackbar(
          'تعذر تحميل حساب السائق', 'تحقق من الاتصال ثم أعد المحاولة.');
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
          'originLatitude': _number(ride['driverLatitude']),
          'originLongitude': _number(ride['driverLongitude']),
          'destinationLatitude': lat,
          'destinationLongitude': lng,
          'title': title,
          'followsDestination': followsDestination,
        });
  }

  Future<void> updateLocation() async {
    final ready = await _ensureLocationAccess(showMessage: true);
    if (!ready) return;
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      await _publishLocation(position, showMessage: true, force: true);
    } catch (exception) {
      Get.snackbar('تعذر تحديث الموقع', 'تعذر قراءة موقع الجهاز الحالي.');
    }
  }

  Future<void> _startRealLocationUpdates() async {
    final ready = await _ensureLocationAccess();
    if (!ready) return;
    try {
      final current = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      await _publishLocation(current);
      await _locationSubscription?.cancel();
      _locationSubscription = Geolocator.getPositionStream(
        locationSettings: _driverLocationStreamSettings(),
      ).listen(
        (position) => unawaited(_publishLocation(position)),
        onError: (_) {},
      );
    } catch (_) {
      // The driver can still retry explicitly with the location button.
    }
  }

  LocationSettings _driverLocationStreamSettings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        // Waiting requires fresh GPS fixes even while the car is stationary.
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 3),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'سائق يمن درايف يتتبع موقعك',
          notificationText: 'يستمر تحديث موقعك لإظهاره للركاب أثناء العمل.',
          notificationChannelName: 'تتبع موقع السائق',
          notificationIcon: AndroidResource(name: 'ic_stat_yemendrive'),
          setOngoing: true,
        ),
      );
    }

    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  Future<bool> _ensureLocationAccess({bool showMessage = false}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (showMessage) {
        Get.snackbar('الموقع غير مفعل', 'فعّل خدمة الموقع في الجهاز أولًا.');
      }
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (showMessage) {
        Get.snackbar('صلاحية الموقع مطلوبة',
            'امنح تطبيق السائق صلاحية الموقع لتحديث موقعك الحقيقي.');
      } else {
        _showDriverLocationPermissionNotice(permission);
      }
      return false;
    }
    return true;
  }

  void _showDriverLocationPermissionNotice(LocationPermission permission) {
    if (_locationPermissionNoticeShown || isClosed) return;
    _locationPermissionNoticeShown = true;
    final message = permission == LocationPermission.deniedForever
        ? 'لن يتم إرسال موقعك لأن صلاحية الموقع غير متاحة.'
        : 'لم تُمنح صلاحية الموقع، لذلك لن يتم إرسال موقعك للركاب.';
    Get.snackbar('تتبع الموقع غير مفعل', message);
  }

  Future<void> _publishLocation(
    Position position, {
    bool showMessage = false,
    bool force = false,
  }) async {
    currentPosition.value = position;
    final driverId = _session.currentUserId.value;
    if (driverId == null || _locationUpdateInFlight) return;
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
        lastUpdate != null &&
        DateTime.now().difference(lastUpdate) < const Duration(seconds: 2) &&
        movedMeters < 5) {
      return;
    }

    if (!position.accuracy.isFinite ||
        position.accuracy <= 0 ||
        position.accuracy > 75) {
      return;
    }

    _locationUpdateInFlight = true;
    try {
      Map<String, Object?>? activeRide;
      for (final ride in rides) {
        if ('${ride['driverId'] ?? ''}' == '$driverId' &&
            <int>{3, 4, 5, 8, 9}.contains(int.tryParse('${ride['status']}'))) {
          activeRide = ride;
          break;
        }
      }
      final hub = Get.isRegistered<TrackingHubService>()
          ? Get.find<TrackingHubService>()
          : null;
      if (hub == null) return;
      final sent = await hub.publishDriverLocation(<String, Object?>{
        'rideId':
            activeRide == null ? null : int.tryParse('${activeRide['id']}'),
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
      });
      if (!sent) return;
      _lastLocationSentAt = DateTime.now();
      _lastSentPosition = position;
      if (showMessage) {
        Get.snackbar('تم تحديث الموقع', 'تم إرسال موقعك الحقيقي الحالي.');
      }
    } finally {
      _locationUpdateInFlight = false;
    }
  }

  Future<void> signOut() async {
    await _session.signOut();
    Get.offAllNamed<void>(DriverRoutes.login);
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
    return status == 8;
  }

  @override
  void onClose() {
    _locationSubscription?.cancel();
    _hubEventSubscription?.cancel();
    _hubConnectionSubscription?.cancel();
    passengerLocationsByRideId.clear();
    if (Get.isRegistered<TrackingHubService>()) {
      unawaited(
        Get.find<TrackingHubService>().setUserEventListening(this, false),
      );
    }
    super.onClose();
  }
}
