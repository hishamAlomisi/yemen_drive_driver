import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';
import '../controllers/driver_controller.dart';
import '../views/driver_chat_view.dart';
import 'driver_design.dart';
import '../../../shared/widgets/ride_waiting_panel.dart';
import '../../../shared/widgets/ride_route_change_panel.dart';

class DriverRideCard extends GetView<DriverController> {
  const DriverRideCard({required this.ride, super.key});
  final Map<String, Object?> ride;
  @override
  Widget build(BuildContext context) {
    final assigned =
        ride['driverId']?.toString() == controller.currentUserId?.toString();
    final state = int.tryParse('${ride['status']}') ?? 0;
    final offerStatus = int.tryParse('${ride['driverOfferStatus']}');
    final canSendOrEditOffer = !assigned &&
        ride['driverId'] == null &&
        (state == 1 || state == 2) &&
        (offerStatus == null ||
            offerStatus == 0 ||
            offerStatus == 2 ||
            offerStatus == 3);
    const labels = {
      0: 'مسودة',
      1: 'تبحث عن سائق',
      2: 'مفاوضة',
      3: 'تم التعيين',
      4: 'في الطريق',
      5: 'بدأت',
      6: 'مكتملة',
      7: 'ملغاة',
      8: 'طلب إلغاء قيد المراجعة',
      9: 'وصل السائق إلى نقطة الانطلاق',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: .07),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.local_taxi_outlined,
                    color: Theme.of(context).colorScheme.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'رحلة #${ride['id']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Chip(label: Text(labels[state] ?? 'غير معروف')),
                ),
              ],
            ),
            const SizedBox(height: 20),
            RideRoute(ride: ride),
            if (ride['pickupDistanceMeters'] != null) ...[
              const SizedBox(height: 4),
              Text(
                'يبعد عنك ${_distanceText(ride['pickupDistanceMeters'])}',
              ),
            ],
            const Divider(height: 30),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    assigned ? 'أجرة الرحلة' : 'السعر المقترح',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Flexible(
                  child: Text(
                    '${ride['customerPrice'] ?? '—'}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(width: 5),
                Text('ر.ي', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            if (assigned && state == 5 && ride['totalAmount'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('الإجمالي الحالي: ${ride['totalAmount']} ر.ي'),
              ),
            if (!assigned && ride['minCustomerPrice'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    'نطاق التفاوض: ${ride['minCustomerPrice']} – ${ride['maxCustomerPrice']} ر.ي'),
              ),
            if (assigned && state == 5) ...[
              const SizedBox(height: 16),
              RideWaitingPanel(
                key: ValueKey('waiting-${ride['id']}'),
                rideId: int.parse('${ride['id']}'),
                isDriver: true,
                onChanged: () => controller.load(showLoading: false),
              ),
              RideRouteChangePanel(
                key: ValueKey('route-change-${ride['id']}'),
                rideId: int.parse('${ride['id']}'),
                isDriver: true,
                selectDestination: () async => null,
                onRouteChanged: () =>
                    controller.refreshRide(int.parse('${ride['id']}')),
              ),
            ],
            if (ride['moreThanFourPassengers'] == true)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'خيارات الركوب: أكثر من 4 ركاب',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            if ((ride['passengerNotes']?.toString() ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('ملاحظات الراكب: ${ride['passengerNotes']}'),
              ),
            if (ride['driverOfferAmount'] != null) ...[
              const SizedBox(height: 4),
              Text(
                offerStatus == 2
                    ? 'تم رفض عرضك: ${ride['driverOfferAmount']} ر.ي'
                    : offerStatus == 3
                        ? 'انتهت صلاحية عرضك: ${ride['driverOfferAmount']} ر.ي'
                        : 'عرضك الحالي: ${ride['driverOfferAmount']} ر.ي',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 10),
            if (canSendOrEditOffer)
              FilledButton.icon(
                onPressed: () => controller.sendOffer(ride),
                icon: const Icon(Icons.local_offer_outlined),
                label: Text(
                  (offerStatus == 2 || offerStatus == 3)
                      ? 'إرسال عرض جديد'
                      : ride['driverOfferAmount'] != null
                          ? 'تعديل العرض'
                          : 'إرسال عرض',
                ),
              ),
            if (!assigned && ride['pickupLatitude'] != null)
              OutlinedButton.icon(
                onPressed: () => controller.openPickupNavigation(ride),
                icon: const Icon(Icons.navigation_outlined),
                label: const Text('فتح مسار إلى نقطة الانطلاق'),
              ),
            if (assigned && state == 3)
              FilledButton.icon(
                onPressed: () => controller.updateStatus(ride, 4, 'في الطريق'),
                icon: const Icon(Icons.directions_car),
                label: const Text('بدء التوجه'),
              ),
            if (assigned && ride['destinationAvailable'] == true)
              OutlinedButton.icon(
                onPressed: () => controller.openDestinationNavigation(ride),
                icon: const Icon(Icons.route_outlined),
                label: const Text('فتح مسار الوجهة'),
              ),
            if (assigned && state == 4)
              FilledButton.icon(
                onPressed: () => controller.updateStatus(ride, 9, 'وصلت إلى نقطة الانطلاق'),
                icon: const Icon(Icons.place_outlined),
                label: const Text('تأكيد الوصول إلى الراكب'),
              ),
            if (assigned && state == 9)
              FilledButton.icon(
                onPressed: () =>
                    controller.updateStatus(ride, 5, 'بدأت الرحلة'),
                icon: const Icon(Icons.play_arrow),
                label: const Text('بدء الرحلة'),
              ),
            if (assigned && state == 5) ...[
              FilledButton.icon(
                onPressed: ride['paymentCompleted'] == true
                    ? null
                    : () => controller.openCashPayment(ride),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('تحصيل الدفع'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: ride['paymentCompleted'] == true
                    ? null
                    : () => controller.enableCustomerPayment(ride),
                icon: const Icon(Icons.credit_score_outlined),
                label: const Text('تمكين طرق الدفع للعميل'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => controller.updateStatus(ride, 6, 'مكتملة'),
                icon: const Icon(Icons.flag_rounded),
                label: const Text('إنهاء الرحلة'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Get.to<void>(
                  () => DriverChatView(rideId: '${ride['id']}'),
                ),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('محادثة العميل'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _callCustomer(ride['customerPhone']),
                icon: const Icon(Icons.phone_outlined),
                label: const Text('اتصال بالعميل'),
              ),
            ],
            if (assigned && state == 6 && ride['cashPaymentRequestStatus'] == 1)
              OutlinedButton.icon(
                onPressed: () => controller.openCashPayment(ride),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('تسجيل تحصيل نقدي بطلب العميل'),
              ),
            if (assigned && (state == 4 || state == 9))
              OutlinedButton.icon(
                onPressed: () => Get.to<void>(
                  () => DriverChatView(rideId: '${ride['id']}'),
                ),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('محادثة العميل'),
              ),
            if (assigned && (state == 3 || state == 4 || state == 9))
              OutlinedButton.icon(
                onPressed: () => _callCustomer(ride['customerPhone']),
                icon: const Icon(Icons.phone_outlined),
                label: const Text('اتصال بالعميل'),
              ),
            if (assigned && {3, 4, 5, 9}.contains(state))
              OutlinedButton.icon(
                onPressed: () => controller.requestCancellation(ride),
                icon: const Icon(Icons.cancel_outlined),
                label: Text(state == 5 ? 'طلب إلغاء الرحلة' : 'إلغاء الرحلة'),
              ),
          ],
        ),
      ),
    );
  }

  String _distanceText(Object? value) {
    final meters = double.tryParse('$value');
    if (meters == null) return '-';
    if (meters < 1000) return '${meters.round()} م';
    return '${(meters / 1000).toStringAsFixed(1)} كم';
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
