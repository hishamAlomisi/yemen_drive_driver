import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/driver_controller.dart';
import '../widgets/driver_design.dart';
import '../widgets/driver_ride_card.dart';

class DriverHistoryView extends GetView<DriverController> {
  const DriverHistoryView({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          titleSpacing: 24,
          title: const Text('سجل الرحلات'),
          actions: [
            IconButton(
              tooltip: 'تحديث الرحلات',
              onPressed: controller.load,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 12),
          ],
        ),
        bottomNavigationBar: const DriverBottomBar(index: 1),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Obx(() {
              final history = controller.rides
                  .where(
                    (ride) =>
                        controller.currentUserId != null &&
                        '${ride['driverId']}' ==
                            '${controller.currentUserId}' &&
                        ['6', '7'].contains('${ride['status']}'),
                  )
                  .toList();
              final completed =
                  history.where((ride) => '${ride['status']}' == '6').length;
              return RefreshIndicator(
                onRefresh: controller.load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                  children: [
                    DriverHero(
                      eyebrow: 'كل طريق يترك حكاية',
                      title: '$completed رحلة مكتملة',
                      subtitle: 'سجل رحلاتك المكتملة والملغاة في مكان واحد.',
                    ),
                    const SizedBox(height: 26),
                    Text(
                      'رحلاتك السابقة',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    if (controller.isLoading.value)
                      const LinearProgressIndicator(),
                    if (controller.error.value != null)
                      Text(
                        controller.error.value!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (history.isEmpty && !controller.isLoading.value)
                      const DriverEmptyState(
                        title: 'أول حكاية تبدأ برحلة',
                        message: 'بعد إتمام رحلاتك ستجد تفاصيلها هنا.',
                      ),
                    ...history.map((ride) => DriverRideCard(ride: ride)),
                  ],
                ),
              );
            }),
          ),
        ),
      );
}
