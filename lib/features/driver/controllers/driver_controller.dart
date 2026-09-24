import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';

import '../../../core/services/auth_session_service.dart';
import '../../../core/network/api_models.dart';
import '../repositories/driver_repository.dart';
import '../driver_routes.dart';
import '../views/driver_payment_view.dart';

class DriverController extends GetxController {
  DriverController(this._repository, this._session);
  final DriverRepository _repository;
  final AuthSessionService _session;
  final isLoading = false.obs;
  final RxnString error = RxnString();
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
  Timer? _ridesPollingTimer;
  Timer? _paymentPollingTimer;
  final paymentEnabledRideIds = <int>{};
  StreamSubscription<Position>? _locationSubscription;
  bool _refreshInFlight = false;
  bool _locationUpdateInFlight = false;
  DateTime? _lastLocationSentAt;
  Position? _lastSentPosition;

  int? get currentUserId => _session.currentUserId.value;

  @override
  void onReady() {
    super.onReady();
    unawaited(_startRidesPolling());
    unawaited(_startRealLocationUpdates());
  }

  Future<void> _startRidesPolling() async {
    await load();
    _ridesPollingTimer?.cancel();
    _paymentPollingTimer?.cancel();
    _paymentPollingTimer = null;
    _ridesPollingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(load(showLoading: false));
    });
  }

  Future<void> load({bool showLoading = true}) async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    if (showLoading) {
      isLoading.value = true;
      error.value = null;
    }
    try {
      final snapshot = await _repository.load(_session.currentUserId.value);
      profile.value = snapshot.profile;
      rides.assignAll(snapshot.rides);
      paymentEnabledRideIds.removeWhere((id) => snapshot.rides.any((r) => '${r['id']}' == '$id' && r['paymentCompleted'] == true));
      notifications.assignAll(await _repository.notifications());
    } catch (exception) {
      // A transient polling failure must not hide the last usable snapshot.
      if (showLoading || rides.isEmpty) error.value = exception.toString();
    } finally {
      _refreshInFlight = false;
      if (showLoading) isLoading.value = false;
    }
  }

  Future<void> sendOffer(Map<String, Object?> ride) async {
    final rideId = int.tryParse('${ride['id']}');
    final driverId = _session.currentUserId.value;
    if (rideId == null || driverId == null) return;
    final controller =
        TextEditingController(text: '${ride['customerPrice'] ?? ''}');
    final amount = await Get.dialog<String>(AlertDialog(
        title: const Text('إرسال عرض'),
        content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'السعر')),
        actions: [
          TextButton(
              onPressed: () => Get.back<void>(), child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Get.back(result: controller.text),
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
      Get.snackbar('تعذر الإرسال', exception.toString());
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
      await _repository.updateRideStatus(rideId: id, status: int.tryParse('${ride['status']}') ?? 5, customerPaymentEnabled: true);
      paymentEnabledRideIds.add(id);
      _paymentPollingTimer ??= Timer.periodic(const Duration(seconds: 5), (_) => _pollEnabledPayments());
      Get.snackbar('تمكين الدفع', 'أصبح بإمكان العميل إتمام الدفع الآن.');
      await load(showLoading: false);
    } catch (exception) {
      Get.snackbar('تعذر تمكين الدفع', exception.toString());
    }
  }

  Future<void> _pollEnabledPayments() async {
    if (paymentEnabledRideIds.isEmpty) {
      _paymentPollingTimer?.cancel();
      _paymentPollingTimer = null;
      return;
    }
    await load(showLoading: false);
    final completed = paymentEnabledRideIds.where((id) => rides.any((r) => '${r['id']}' == '$id' && r['paymentCompleted'] == true)).toList();
    paymentEnabledRideIds.removeAll(completed);
    if (paymentEnabledRideIds.isEmpty) {
      _paymentPollingTimer?.cancel();
      _paymentPollingTimer = null;
      Get.snackbar('تم الدفع', 'تم تأكيد تحصيل مبلغ الرحلة.');
    }
  }

  Future<void> openCashPayment(Map<String, Object?> ride) async {
    final id = int.tryParse('${ride['id']}');
    if (id == null) return;
    await Get.to<void>(() => DriverPaymentView(
          ride: ride,
          repository: _repository,
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
              .whereType<Map>()
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
        'from': DateTime(from.year, from.month, from.day).toUtc().toIso8601String(),
        'to': DateTime(to.year, to.month, to.day).toUtc().toIso8601String(),
        if (financialSearch.value.trim().isNotEmpty) 'query': financialSearch.value.trim(),
        if (financialType.value != null) 'entryType': financialType.value,
      });
      driverAccountBalance.value = _number(report['balance']);
      driverCommissionTotal.value = _number(report['totalCommission']);
      final items = report['transactions'];
      driverAccountTransactions.assignAll(items is List
          ? items.whereType<Map>().map((item) => Map<String, Object?>.from(item)).toList()
          : const <Map<String, Object?>>[]);
    } catch (exception) {
      Get.snackbar('تعذر تحميل حساب السائق', 'تحقق من الاتصال ثم أعد المحاولة.');
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
        ride['destinationLongitude'], 'وجهة الرحلة');
  }

  Future<void> _openNavigation(Map<String, Object?> ride, Object? latitude,
      Object? longitude, String title) async {
    final lat = double.tryParse('$latitude');
    final lng = double.tryParse('$longitude');
    if (lat == null || lng == null) {
      Get.snackbar('المسار غير متاح', 'لا توجد إحداثيات صالحة لفتح المسار.');
      return;
    }
    await Get.toNamed<void>(DriverRoutes.navigation,
        arguments: <String, Object?>{
          'originLatitude': _number(ride['driverLatitude']),
          'originLongitude': _number(ride['driverLongitude']),
          'destinationLatitude': lat,
          'destinationLongitude': lng,
          'title': title,
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
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 20,
        ),
      ).listen(
        (position) => unawaited(_publishLocation(position)),
        onError: (_) {},
      );
    } catch (_) {
      // The driver can still retry explicitly with the location button.
    }
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
      }
      return false;
    }
    return true;
  }

  Future<void> _publishLocation(
    Position position, {
    bool showMessage = false,
    bool force = false,
  }) async {
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
        DateTime.now().difference(lastUpdate) < const Duration(seconds: 15) &&
        movedMeters < 20) {
      return;
    }

    _locationUpdateInFlight = true;
    try {
      await _repository.updateLocation(
        driverId: driverId,
        latitude: position.latitude,
        longitude: position.longitude,
      );
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
    final ride = rides.where((item) => '${item['id']}' == '$rideId').firstOrNull;
    if (ride == null) return true;
    final status = int.tryParse('${ride['status']}');
    return status != 6 && status != 7 &&
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
    Get.dialog<void>(AlertDialog(
      title: Text('الإشعارات ($unreadNotifications)'),
      content: SizedBox(
        width: double.maxFinite,
        child: notifications.isEmpty
            ? const Text('لا توجد إشعارات.')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: notifications.length,
                itemBuilder: (_, index) {
                  final item = notifications[index];
                  final cancellationId = cancellationRequestId(item);
                  final cashPaymentId = cashPaymentRequestId(item);
                  final rideId = notificationRideId(item);
                  final cashActionable =
                      cashPaymentId != null &&
                      _cashNotificationActionable(item, rideId);
                  final cancellationActionable =
                      cancellationId != null &&
                      item['isRead'] != true &&
                      _cancellationNotificationActionable(rideId);
                  return ListTile(
                    leading: Icon(
                      item['isRead'] == true ||
                              (cashPaymentId != null && !cashActionable)
                          ? Icons.notifications_none
                          : Icons.notifications_active,
                    ),
                    title: Text('${item['title'] ?? ''}'),
                    subtitle: Text('${item['body'] ?? ''}'),
                    trailing: cancellationId != null
                        ? const Icon(Icons.gavel_outlined)
                        : cashPaymentId != null
                            ? Icon(Icons.payments_outlined,
                                color: cashActionable ? null : Colors.grey)
                            : null,
                    onTap: cancellationActionable
                        ? () => _showCancellationDecision(cancellationId)
                        : cashActionable
                            ? () =>
                                _showCashPaymentDecision(cashPaymentId!, rideId)
                            : null,
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back<void>(),
          child: const Text('إغلاق'),
        ),
      ],
    ));
  }

  bool _cancellationNotificationActionable(int? rideId) {
    if (rideId == null) return true;
    final ride = rides.where((item) => '${item['id']}' == '$rideId').firstOrNull;
    if (ride == null) return true;
    final status = int.tryParse('${ride['status']}');
    return status == 8;
  }

  void _showCashPaymentDecision(int requestId, int? rideId) {
    if (Get.isDialogOpen ?? false) Get.back<void>();
    Get.dialog<void>(
      AlertDialog(
        title: const Text('تأكيد دفع نقدي'),
        content: const Text(
            'هل استلمت المبلغ النقدي من العميل؟ عند التأكيد افتح الرحلة وسجل التحصيل بالمبلغ الفعلي.'),
        actions: <Widget>[
          TextButton(
              onPressed: () =>
                  decideCashPaymentRequest(requestId, false, rideId),
              child: const Text('لم أستلم المبلغ')),
          FilledButton(
              onPressed: () =>
                  decideCashPaymentRequest(requestId, true, rideId),
              child: const Text('نعم، استلمته')),
        ],
      ),
      barrierDismissible: false,
    );
  }

  void _showCancellationDecision(int requestId) {
    if (Get.isDialogOpen ?? false) Get.back<void>();
    Get.dialog<void>(
      AlertDialog(
        title: const Text('طلب إلغاء الرحلة'),
        content: const Text(
            'اختر القرار المناسب. القبول أو الإحالة ينقلان الطلب إلى الإدارة؛ الرفض وحده يسمح للعميل بإعادة الطلب.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => decideCancellation(requestId, 'reject'),
              child: const Text('رفض')),
          OutlinedButton(
              onPressed: () => decideCancellation(requestId, 'refer'),
              child: const Text('رفض وإحالة للإدارة')),
          FilledButton(
              onPressed: () => decideCancellation(requestId, 'accept'),
              child: const Text('قبول')),
        ],
      ),
      barrierDismissible: false,
    );
  }

  @override
  void onClose() {
    _ridesPollingTimer?.cancel();
    _paymentPollingTimer?.cancel();
    _locationSubscription?.cancel();
    super.onClose();
  }
}
