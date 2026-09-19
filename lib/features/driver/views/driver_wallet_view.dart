import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/driver_controller.dart';

class DriverWalletView extends GetView<DriverController> {
  const DriverWalletView({super.key});

  @override
  Widget build(BuildContext context) {
    if (!controller.isWalletLoaded.value && !controller.isWalletLoading.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.loadWallet());
    }
    return Scaffold(
      appBar: AppBar(title: const Text('محفظتي والعمليات المالية')),
      body: Obx(() {
        final transactions = controller.walletTransactions;
        final spent = transactions.where((item) => item['type'] == 1).fold<double>(0, (sum, item) => sum + _number(item['amount']));
        return RefreshIndicator(
          onRefresh: controller.loadWallet,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('الرصيد المتاح'),
                    const SizedBox(height: 8),
                    Text('${controller.walletBalance.value.toStringAsFixed(0)} ر.ي', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 5),
                    Text('إجمالي الخصومات: ${spent.toStringAsFixed(0)} ر.ي'),
                  ]),
                ),
              ),
              const SizedBox(height: 20),
              Text('العمليات', style: Theme.of(context).textTheme.titleLarge),
              if (controller.isWalletLoading.value && transactions.isEmpty)
                const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
              else if (transactions.isEmpty)
                const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('لا توجد حركات مالية بعد.')))
              else
                ...transactions.map((item) {
                  final credit = item['type'] == 0 || item['type'] == 4;
                  final amount = _number(item['amount']);
                  return Card(child: ListTile(
                    leading: CircleAvatar(child: Icon(credit ? Icons.south_west_rounded : Icons.north_east_rounded, color: credit ? Colors.green : Colors.red)),
                    title: Text('${item['description'] ?? 'عملية مالية'}'),
                    subtitle: Text('${item['createdAtUtc'] ?? ''}'),
                    trailing: Text('${credit ? '+' : '-'}${amount.toStringAsFixed(0)} ر.ي', style: TextStyle(color: credit ? Colors.green : Colors.red, fontWeight: FontWeight.bold)),
                  ));
                }),
            ],
          ),
        );
      }),
    );
  }

  double _number(Object? value) => value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;
}
