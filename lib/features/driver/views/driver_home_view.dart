import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../shared/widgets/app_brand_icon.dart';
import '../controllers/driver_controller.dart';
import '../widgets/driver_design.dart';
import '../widgets/driver_ride_card.dart';
import '../widgets/request_view_tracker.dart';

class DriverHomeView extends StatefulWidget {
  const DriverHomeView({super.key});
  @override
  State<DriverHomeView> createState() => _DriverHomeViewState();
}

class _DriverHomeViewState extends State<DriverHomeView> {
  DriverController get controller => Get.find<DriverController>();
  int _filter = 0;
  bool _open(Map<String, Object?> ride) =>
      ride['driverId'] == null &&
      ('${ride['status']}' == '1' || '${ride['status']}' == '2');
  bool _mine(Map<String, Object?> ride) =>
      controller.currentUserId != null &&
      '${ride['driverId']}' == '${controller.currentUserId}';

  @override
  Widget build(BuildContext context) => Scaffold(
        bottomNavigationBar: const DriverBottomBar(index: 0),
        body: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Obx(() {
                final rides = controller.rides
                    .where(
                      (r) =>
                          _filter == 0 || (_filter == 1 ? _open(r) : _mine(r)),
                    )
                    .toList();
                final openCount = controller.rides.where(_open).length;
                final assigned = controller.rides
                    .where(_mine)
                    .where(
                      (r) =>
                          [3, 4, 5, 8].contains(int.tryParse('${r['status']}')),
                    )
                    .length;
                return RefreshIndicator(
                  onRefresh: controller.load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'أهلًا بك، شريك الطريق',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                Text(
                                  '${controller.profile.value?['displayName'] ?? 'كابتن يمن درايف'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ],
                            ),
                          ),
                          IconButton.filledTonal(
                            tooltip: 'الإشعارات',
                            onPressed: controller.showNotifications,
                            icon: Badge(
                              isLabelVisible:
                                  controller.unreadNotifications > 0,
                              label: Text(
                                '${controller.unreadNotifications}',
                              ),
                              child: const Icon(
                                Icons.notifications_none_rounded,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => showDriverProfile(context),
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: forest,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: const Icon(
                                Icons.person_outline_rounded,
                                color: copper,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      DriverHero(
                        compact: true,
                        eyebrow:
                            '${controller.profile.value?['serviceNameAr'] ?? 'يمن درايف للسائق'}',
                        title: 'رحلتك القادمة تبدأ هنا.',
                        subtitle: 'اختر طلبك، قدّم عرضك، وانطلق بثقة.',
                        trailing: const AppBrandIcon(size: 32),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          _metric(
                            context,
                            '$openCount',
                            'طلبات متاحة',
                            Icons.radar_rounded,
                          ),
                          const SizedBox(width: 12),
                          _metric(
                            context,
                            '$assigned',
                            'رحلات جارية',
                            Icons.route_rounded,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Material(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          onTap: controller.updateLocation,
                          borderRadius: BorderRadius.circular(18),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.my_location_rounded,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    controller.currentPosition.value == null
                                        ? 'حدّث موقعك لرحلات أقرب إليك'
                                        : 'موقعك محدّث · اضغط للتحديث',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_left_rounded,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 26),
                      Row(
                        children: [
                          Text(
                            'على طريقك',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'تحديث الطلبات',
                            onPressed: controller.load,
                            icon: const Icon(
                              Icons.refresh_rounded,
                              size: 21,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: List.generate(
                          3,
                          (i) => Expanded(
                            child: Padding(
                              padding: EdgeInsetsDirectional.only(
                                end: i == 2 ? 0 : 8,
                              ),
                              child: ChoiceChip(
                                showCheckmark: false,
                                selected: _filter == i,
                                onSelected: (_) => setState(
                                  () => _filter = i,
                                ),
                                label: Center(
                                  child: Text(
                                    [
                                      'الكل',
                                      'المتاحة',
                                      'المسندة لي',
                                    ][i],
                                  ),
                                ),
                                selectedColor:
                                    Theme.of(context).colorScheme.primary,
                                labelStyle: TextStyle(
                                  fontFamily: 'BeINArabic',
                                  fontSize: 12,
                                  color: _filter == i
                                      ? Theme.of(context).colorScheme.onPrimary
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      if (controller.isLoading.value)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      if (controller.error.value != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    controller.error.value!,
                                    style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: controller.load,
                                    child: const Text(
                                      'إعادة المحاولة',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (rides.isEmpty &&
                          !controller.isLoading.value &&
                          controller.error.value == null)
                        const DriverEmptyState(
                          title: 'الطريق ينتظر رحلتك القادمة',
                          message:
                              'ستظهر الطلبات المناسبة هنا عند توفرها.\nيمكنك سحب الشاشة لتحديث القائمة.',
                        ),
                      ...rides.map(
                        (ride) => _open(ride)
                            ? RequestViewTracker(
                                key: ValueKey(
                                  'view-${ride['id']}-${ride['customerPrice']}-${ride['updatedAtUtc']}',
                                ),
                                report: () =>
                                    controller.markRequestViewed(ride),
                                child: DriverRideCard(ride: ride),
                              )
                            : DriverRideCard(ride: ride),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ),
      );

  Widget _metric(
    BuildContext context,
    String value,
    String label,
    IconData icon,
  ) =>
      Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      Text(
                        label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Icon(
                  icon,
                  color: Theme.of(context).colorScheme.secondary,
                  size: 27,
                ),
              ],
            ),
          ),
        ),
      );
}
