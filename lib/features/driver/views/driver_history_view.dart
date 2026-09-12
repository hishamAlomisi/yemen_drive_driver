import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/driver_controller.dart';

class DriverHistoryView extends GetView<DriverController> {
  const DriverHistoryView({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('سجل الرحلات')),
        body: Obx(() {
          final history = controller.rides.where((ride) {
            final status = int.tryParse('${ride['status']}') ?? 0;
            final mine = '${ride['driverId']}' == '${controller.currentUserId}';
            return mine && (status == 6 || status == 7);
          }).toList();
          if (history.isEmpty) {
            return const Center(child: Text('لا توجد رحلات سابقة.'));
          }
          return RefreshIndicator(
            onRefresh: controller.load,
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: history.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, index) {
                final ride = history[index];
                final completed = '${ride['status']}' == '6';
                return Card(
                  child: ListTile(
                    leading: Icon(completed ? Icons.check_circle : Icons.cancel),
                    title: Text('رحلة #${ride['id']}'),
                    subtitle: Text(
                      '${ride['pickupAddress'] ?? '-'} ← ${ride['destinationAddress'] ?? '-'}\n'
                      '${ride['customerPrice'] ?? '-'} ر.ي',
                    ),
                    isThreeLine: true,
                    trailing: Text(completed ? 'مكتملة' : 'ملغاة'),
                  ),
                );
              },
            ),
          );
        }),
      );
}
