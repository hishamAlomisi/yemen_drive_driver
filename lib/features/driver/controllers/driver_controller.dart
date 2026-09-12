import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

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
  bool _refreshInFlight = false;

  int? get currentUserId => _session.currentUserId.value;

  @override
  void onReady() {
    super.onReady();
    unawaited(_startRidesPolling());
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

  Future<void> updateLocation() async {
    final id = _session.currentUserId.value;
    if (id == null) return;
    try {
      await _repository.updateLocation(
          driverId: id, latitude: 15.3694, longitude: 44.1910);
      Get.snackbar('الموقع', 'تم إرسال الموقع التجريبي');
    } catch (exception) {
      Get.snackbar('تعذر تحديث الموقع', exception.toString());
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
      actions: [TextButton(onPressed: Get.back, child: const Text('إغلاق'))],
    ));
  }

  @override
  void onClose() {
    _ridesPollingTimer?.cancel();
    super.onClose();
  }
}
