import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/auth_session_service.dart';
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
  Timer? _ridesPollingTimer;
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
      Get.snackbar('تعذر التحديث', exception.toString());
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

  Future<void> openPickupNavigation(Map<String, Object?> ride) =>
      _openNavigation(ride['pickupLatitude'], ride['pickupLongitude']);

  Future<void> openDestinationNavigation(Map<String, Object?> ride) async {
    if (ride['destinationAvailable'] != true) {
      Get.snackbar('الوجهة محمية', 'تظهر إحداثيات الوجهة بعد قبول العرض فقط.');
      return;
    }
    await _openNavigation(
        ride['destinationLatitude'], ride['destinationLongitude']);
  }

  Future<void> _openNavigation(Object? latitude, Object? longitude) async {
    final lat = double.tryParse('$latitude');
    final lng = double.tryParse('$longitude');
    if (lat == null || lng == null) {
      Get.snackbar('المسار غير متاح', 'لا توجد إحداثيات صالحة لفتح المسار.');
      return;
    }
    final uri = Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'destination': '$lat,$lng',
      'travelmode': 'driving',
    });
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      Get.snackbar('تعذر فتح الخريطة', 'لم يتمكن الجهاز من فتح تطبيق الخرائط.');
    }
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
                  return ListTile(
                    leading: Icon(item['isRead'] == true
                        ? Icons.notifications_none
                        : Icons.notifications_active),
                    title: Text('${item['title'] ?? ''}'),
                    subtitle: Text('${item['body'] ?? ''}'),
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

  @override
  void onClose() {
    _ridesPollingTimer?.cancel();
    _locationSubscription?.cancel();
    super.onClose();
  }
}
