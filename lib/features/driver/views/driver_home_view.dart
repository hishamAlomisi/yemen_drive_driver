import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/driver_controller.dart';
import '../driver_routes.dart';
import 'driver_chat_view.dart';

class DriverHomeView extends GetView<DriverController> {
  const DriverHomeView({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('لوحة السائق'), actions: [
        Obx(() => IconButton(
              onPressed: controller.showNotifications,
              icon: Badge(
                isLabelVisible: controller.unreadNotifications > 0,
                label: Text('${controller.unreadNotifications}'),
                child: const Icon(Icons.notifications_outlined),
              ),
            )),
        IconButton(onPressed: controller.load, icon: const Icon(Icons.refresh)),
        IconButton(
            onPressed: () => Get.toNamed<void>(DriverRoutes.history),
            icon: const Icon(Icons.history)),
        IconButton(
            onPressed: controller.signOut, icon: const Icon(Icons.logout))
      ]),
      body: Obx(() => controller.isLoading.value && controller.rides.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : controller.error.value != null && controller.rides.isEmpty
              ? Center(child: Text(controller.error.value!))
              : RefreshIndicator(
                  onRefresh: controller.load,
                  child: ListView(padding: const EdgeInsets.all(16), children: [
                    _profile(context),
                    const SizedBox(height: 12),
                    Row(children: [
                      _stat(context, 'الرحلات المفتوحة', _openCount,
                          Icons.search),
                      const SizedBox(width: 12),
                      _stat(context, 'رحلاتي', _assignedCount,
                          Icons.assignment_turned_in)
                    ]),
                    const SizedBox(height: 20),
                    Text('الرحلات',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    ...controller.rides.map((ride) => _rideCard(context, ride))
                  ]))),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: controller.updateLocation,
          icon: const Icon(Icons.my_location),
          label: const Text('تحديث موقعي')));
  int get _openCount => controller.rides
      .where((ride) =>
          ride['driverId'] == null &&
          (ride['status'] == 1 || ride['status'] == 2))
      .length;
  int get _assignedCount => controller.rides
      .where((ride) =>
          ride['driverId']?.toString() == controller.currentUserId?.toString())
      .length;
  Widget _profile(BuildContext context) => Card(
      child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.local_taxi)),
          title: Text(
              controller.profile.value?['displayName']?.toString() ?? 'السائق'),
          subtitle: Text(
              controller.profile.value?['serviceNameAr']?.toString() ??
                  'ملف السائق')));
  Widget _stat(BuildContext context, String label, int value, IconData icon) =>
      Expanded(
          child: Card(
              child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(children: [
                    Icon(icon, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 6),
                    Text('$value',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    Text(label)
                  ]))));
  Widget _rideCard(BuildContext context, Map<String, Object?> ride) {
    final assigned =
        ride['driverId']?.toString() == controller.currentUserId?.toString();
    final state = int.tryParse('${ride['status']}') ?? 0;
    const labels = {
      0: 'مسودة',
      1: 'تبحث عن سائق',
      2: 'مفاوضة',
      3: 'تم التعيين',
      4: 'في الطريق',
      5: 'بدأت',
      6: 'مكتملة',
      7: 'ملغاة'
    };
    return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text('رحلة #${ride['id']}',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold))),
                    Chip(label: Text(labels[state] ?? 'غير معروف'))
                  ]),
                  Text(
                      '${ride['pickupAddress'] ?? '-'}  ←  ${ride['destinationAddress'] ?? '-'}'),
                  const SizedBox(height: 5),
                  Text('السعر: ${ride['customerPrice'] ?? '-'} ر.ي'),
                  if (ride['driverOfferAmount'] != null) ...[
                    const SizedBox(height: 4),
                    Text('عرضك الحالي: ${ride['driverOfferAmount']} ر.ي',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600)),
                  ],
                  const SizedBox(height: 10),
                  if (!assigned &&
                      ride['driverId'] == null &&
                      (state == 1 || state == 2))
                    FilledButton.icon(
                        onPressed: () => controller.sendOffer(ride),
                        icon: const Icon(Icons.local_offer_outlined),
                        label: Text(ride['driverOfferAmount'] != null
                            ? 'تعديل العرض'
                            : 'إرسال عرض')),
                  if (assigned && state == 3)
                    FilledButton.icon(
                        onPressed: () =>
                            controller.updateStatus(ride, 4, 'في الطريق'),
                        icon: const Icon(Icons.directions_car),
                        label: const Text('بدء التوجه')),
                  if (assigned && state == 4)
                    FilledButton.icon(
                        onPressed: () =>
                            controller.updateStatus(ride, 5, 'بدأت الرحلة'),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('بدء الرحلة')),
                  if (assigned && state == 5)
                    ...[
                      FilledButton.icon(
                          onPressed: () => controller.openCashPayment(ride),
                          icon: const Icon(Icons.payments_outlined),
                          label: const Text('تحصيل الدفع')),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                          onPressed: () => Get.to<void>(() => DriverChatView(
                              rideId: '${ride['id']}')),
                          icon: const Icon(Icons.chat_bubble_outline),
                          label: const Text('محادثة العميل')),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () => _callCustomer(ride['customerPhone']),
                        icon: const Icon(Icons.phone_outlined),
                        label: const Text('اتصال بالعميل'),
                      )
                    ],
                  if (assigned && state == 4)
                    OutlinedButton.icon(
                        onPressed: () => Get.to<void>(() => DriverChatView(
                            rideId: '${ride['id']}')),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: const Text('محادثة العميل')),
                  if (assigned && (state == 3 || state == 4 || state == 5))
                    OutlinedButton.icon(
                      onPressed: () => _callCustomer(ride['customerPhone']),
                      icon: const Icon(Icons.phone_outlined),
                      label: const Text('اتصال بالعميل'),
                    )
                ])));
  }

  Future<void> _callCustomer(Object? phone) async {
    final value = phone?.toString().trim();
    if (value == null || value.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: value);
    if (!await launchUrl(uri)) {
      Get.snackbar('تعذر الاتصال', 'لم يتمكن الجهاز من فتح تطبيق الهاتف.');
    }
  }
}
