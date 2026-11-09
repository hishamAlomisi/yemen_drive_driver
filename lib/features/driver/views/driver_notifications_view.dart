import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../shared/widgets/ride_route_change_panel.dart';
import '../../../shared/widgets/ride_waiting_panel.dart';
import '../controllers/driver_controller.dart';
import '../driver_routes.dart';

class DriverNotificationsView extends GetView<DriverController> {
  const DriverNotificationsView({super.key});

  void _returnHome() {
    // Keep the route that owns the live driver controller while leaving
    // notifications. Replacing the whole stack can dispose that controller.
    var foundHome = false;
    Get.until((route) {
      foundHome = route.settings.name == DriverRoutes.home;
      return foundHome || route.isFirst;
    });
    if (!foundHome) Get.toNamed<void>(DriverRoutes.home);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _returnHome();
        },
        child: Scaffold(
          appBar: AppBar(
              title: const Text('الإشعارات'),
              leading: BackButton(onPressed: _returnHome)),
          body: Obx(() => RefreshIndicator(
                onRefresh: () => controller.load(showLoading: false),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (controller.notifications.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('لا توجد إشعارات.')),
                    for (final item in controller.notifications)
                      _NotificationCard(key: ValueKey(item['id']), item: item),
                  ],
                ),
              )),
        ),
      );
}

class _NotificationCard extends StatefulWidget {
  const _NotificationCard({required this.item, super.key});
  final Map<String, Object?> item;
  @override
  State<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<_NotificationCard> {
  DriverController get controller => Get.find<DriverController>();
  Future<Map<String, Object?>>? _cancellation;
  int _refundMethod = 2;
  bool _busy = false;
  bool _showRoute = false;
  bool _showWaiting = false;
  Map<String, dynamic> get data {
    try {
      final value = jsonDecode('${widget.item['dataJson'] ?? '{}'}');
      return value is Map ? Map<String, dynamic>.from(value) : {};
    } on Object {
      return {};
    }
  }

  @override
  void initState() {
    super.initState();
    _reloadCancellation();
  }

  void _reloadCancellation() {
    final id = controller.cancellationRequestId(widget.item);
    _cancellation = id == null ? null : controller.getCancellationRequest(id);
  }

  @override
  void didUpdateWidget(covariant _NotificationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_busy) _reloadCancellation();
  }

  Future<void> _decide(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _reloadCancellation();
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final cancellationId = controller.cancellationRequestId(item);
    final cashId = controller.cashPaymentRequestId(item);
    final rideId = controller.notificationRideId(item);
    final routeId = int.tryParse('${data['routeChangeId']}');
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
            color: item['isRead'] == true
                ? Theme.of(context).colorScheme.outlineVariant
                : Theme.of(context).colorScheme.primary,
            width: 1.5),
      ),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${item['title'] ?? ''}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('${item['body'] ?? ''}'),
              if (_cancellation != null)
                FutureBuilder<Map<String, Object?>>(
                  future: _cancellation,
                  builder: (context, snapshot) {
                    if (snapshot.hasError)
                      return TextButton(
                          onPressed: () => setState(() => _cancellation =
                              controller
                                  .getCancellationRequest(cancellationId!)),
                          child: const Text('إعادة تحميل حالة الطلب'));
                    final request = snapshot.data;
                    if (request == null) return const LinearProgressIndicator();
                    if (request['canChooseRefundMethod'] == true) {
                      final quote = request['refundQuote'] as Map? ?? {};
                      return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                                'اكتملت الموافقات؛ اختر طريقة إعادة المبلغ'),
                            Text(
                                'المبلغ المدفوع: ${quote['paidAmount']} ريال يمني'),
                            Text(
                                'الجزء المقطوع: ${quote['travelledFare']} · رسوم الرحلة: ${quote['serviceFee']} · رسوم الإلغاء: ${quote['cancellationFee']}'),
                            Text(
                                'إجمالي الخصم: ${quote['totalDeductions']} · صافي الاسترداد: ${quote['refundAmount']} ريال يمني'),
                            RadioListTile<int>(
                                value: 2,
                                groupValue: _refundMethod,
                                onChanged: _busy
                                    ? null
                                    : (value) =>
                                        setState(() => _refundMethod = value!),
                                title: const Text('إرجاع إلى محفظة الراكب')),
                            RadioListTile<int>(
                                value: 1,
                                groupValue: _refundMethod,
                                onChanged: _busy
                                    ? null
                                    : (value) =>
                                        setState(() => _refundMethod = value!),
                                title: const Text('إرجاع نقداً إلى الراكب')),
                            FilledButton(
                                key: const ValueKey(
                                    'confirm-cancellation-refund-method'),
                                onPressed: _busy
                                    ? null
                                    : () => _decide(() =>
                                        controller.chooseCancellationRefund(
                                            cancellationId!,
                                            _refundMethod,
                                            (request['refundChoiceRevision']
                                                    as num)
                                                .toInt())),
                                child: Text(_refundMethod == 2
                                    ? 'طلب موافقة الراكب على المحفظة'
                                    : 'أؤكد أنني أعدت صافي المبلغ نقداً')),
                          ]);
                    }
                    if (request['canDecide'] != true)
                      return Text(request['refundConsentPending'] == true
                          ? 'بانتظار موافقة الراكب على الاسترداد إلى المحفظة.'
                          : 'لا يوجد قرار مطلوب لهذا الطلب.');
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('السبب: ${request['reason'] ?? ''}'),
                          if (request['refundQuote'] is Map &&
                              (request['refundQuote']
                                      as Map)['paymentCompleted'] ==
                                  true) ...[
                            const SizedBox(height: 8),
                            Text(
                                'المبلغ المدفوع: ${(request['refundQuote'] as Map)['paidAmount']} ريال يمني'),
                            Text(
                                'إجمالي الخصم: ${(request['refundQuote'] as Map)['totalDeductions'] ?? 'تقدّره الإدارة'}'),
                            Text(
                                'المبلغ المسترد: ${(request['refundQuote'] as Map)['refundAmount'] ?? 'تقدّره الإدارة'}'),
                            const Text(
                                'بعد موافقتك، تراجع الإدارة الاسترداد إلى محفظة الراكب.'),
                          ],
                          Wrap(spacing: 8, children: [
                            FilledButton(
                                onPressed: _busy
                                    ? null
                                    : () => _decide(() =>
                                        controller.decideCancellation(
                                            cancellationId!, 'accept')),
                                child: const Text('موافقة')),
                            TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _decide(() =>
                                        controller.decideCancellation(
                                            cancellationId!, 'reject')),
                                child: const Text('رفض')),
                            TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _decide(() =>
                                        controller.decideCancellation(
                                            cancellationId!, 'refer')),
                                child: const Text('إحالة للإدارة')),
                          ]),
                        ]);
                  },
                ),
              if (cashId != null && controller.cashNotificationActionable(item))
                Wrap(spacing: 8, children: [
                  FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _decide(() => controller
                              .decideCashPaymentRequest(cashId, true, rideId)),
                      child: const Text('استلمت النقد')),
                  TextButton(
                      onPressed: _busy
                          ? null
                          : () => _decide(() => controller
                              .decideCashPaymentRequest(cashId, false, rideId)),
                      child: const Text('لم أستلم النقد')),
                ]),
              if (routeId != null && rideId != null) ...[
                TextButton(
                    onPressed: () => setState(() => _showRoute = !_showRoute),
                    child: const Text('مراجعة طلب تغيير المسار')),
                if (_showRoute)
                  RideRouteChangePanel(
                      rideId: rideId,
                      isDriver: true,
                      selectDestination: () async => null,
                      onRouteChanged: () async {
                        await controller.refreshRide(rideId);
                        await controller.load(showLoading: false);
                      }),
              ],
              if (data['action'] == 'review_waiting' && rideId != null) ...[
                TextButton(
                    onPressed: () =>
                        setState(() => _showWaiting = !_showWaiting),
                    child: const Text('متابعة التوقف والانتظار')),
                if (_showWaiting)
                  RideWaitingPanel(
                      rideId: rideId,
                      isDriver: true,
                      onChanged: () => controller.load(showLoading: false)),
              ],
              if (item['isRead'] != true &&
                  cancellationId == null &&
                  cashId == null)
                TextButton(
                    onPressed: () => controller.markNotificationRead(item),
                    child: const Text('تمت القراءة')),
              if (_busy) const LinearProgressIndicator(),
            ],
          )),
    );
  }
}
