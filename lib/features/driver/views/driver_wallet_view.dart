import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/driver_controller.dart';

class DriverWalletView extends GetView<DriverController> {
  const DriverWalletView({super.key});

  @override
  Widget build(BuildContext context) {
    if (!controller.isWalletLoaded.value && !controller.isWalletLoading.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.loadWallet();
        controller.loadDriverAccount();
      });
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الحسابات والعمليات المالية'),
          actions: [
            Obx(() => IconButton(
                  tooltip: controller.financialFiltersVisible.value ? 'إخفاء الفلترة' : 'إظهار الفلترة',
                  icon: Icon(controller.financialFiltersVisible.value ? Icons.filter_alt : Icons.filter_alt_outlined),
                  onPressed: () => controller.financialFiltersVisible.toggle(),
                )),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'المحفظة'), Tab(text: 'حساب السائق')]),
        ),
        body: TabBarView(children: [_WalletTab(controller), _DriverAccountTab(controller)]),
      ),
    );
  }
}

class _WalletTab extends StatelessWidget {
  const _WalletTab(this.controller);
  final DriverController controller;

  @override
  Widget build(BuildContext context) => Obx(() {
        final transactions = controller.walletTransactions.where((item) {
          final date = DateTime.tryParse('${item['createdAtUtc'] ?? ''}')?.toLocal();
          final query = controller.financialSearch.value.trim().toLowerCase();
          final type = controller.financialType.value;
          return (date == null || _inDateRange(date, controller)) &&
              (query.isEmpty || '${item['description'] ?? ''}'.toLowerCase().contains(query)) &&
              (type == null || '${item['type']}' == '$type');
        }).toList();
        // The wallet balance and its total spending are account totals; the
        // active filters apply only to the list shown below.
        final spent = controller.walletTransactions.where((item) => item['type'] == 1).fold<double>(0, (sum, item) => sum + _number(item['amount']));
        return RefreshIndicator(
          onRefresh: controller.loadWallet,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            _BalanceCard(title: 'الرصيد المتاح', value: controller.walletBalance.value, subtitle: 'إجمالي المصروفات: ${spent.toStringAsFixed(0)} ر.ي', icon: Icons.account_balance_wallet_rounded),
            const SizedBox(height: 12),
            if (controller.financialFiltersVisible.value) _FinancialFilters(controller),
            const SizedBox(height: 16),
            const Text('حركة المحفظة', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _TransactionList(items: transactions, loading: controller.isWalletLoading.value),
          ]),
        );
      });
}

class _DriverAccountTab extends StatelessWidget {
  const _DriverAccountTab(this.controller);
  final DriverController controller;

  @override
  Widget build(BuildContext context) => Obx(() => RefreshIndicator(
        onRefresh: controller.loadDriverAccount,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            Expanded(child: _DriverBalanceCard(value: controller.driverAccountBalance.value)),
            const SizedBox(width: 10),
            Expanded(child: _BalanceCard(title: 'إجمالي النسبة', value: controller.driverCommissionTotal.value, subtitle: 'عمولات السائق', icon: Icons.percent_rounded)),
          ]),
          const SizedBox(height: 12),
          if (controller.financialFiltersVisible.value) _FinancialFilters(controller, onChanged: controller.loadDriverAccount),
          const SizedBox(height: 16),
          const Text('حركة حساب السائق', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _TransactionList(items: controller.driverAccountTransactions, loading: controller.isDriverAccountLoading.value, account: true),
        ]),
      ));
}

class _FinancialFilters extends StatelessWidget {
  const _FinancialFilters(this.controller, {this.onChanged});
  final DriverController controller;
  final Future<void> Function()? onChanged;

  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
        TextField(textDirection: TextDirection.rtl, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'بحث في وصف العملية', border: OutlineInputBorder()), onChanged: (value) { controller.financialSearch.value = value; if (onChanged != null) onChanged!(); }),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _dateButton(context, 'من', controller.financialFrom.value, (date) { controller.setFinancialDateRange(date, controller.financialTo.value); if (onChanged != null) onChanged!(); })),
          const SizedBox(width: 8),
          Expanded(child: _dateButton(context, 'إلى', controller.financialTo.value, (date) { controller.setFinancialDateRange(controller.financialFrom.value, date); if (onChanged != null) onChanged!(); })),
        ]),
        const SizedBox(height: 10),
        DropdownButtonFormField<int?>(value: controller.financialType.value, decoration: const InputDecoration(labelText: 'نوع الحركة', border: OutlineInputBorder()), items: const [
          DropdownMenuItem<int?>(value: null, child: Text('كل العمليات')),
          DropdownMenuItem<int?>(value: 0, child: Text('رصيد افتتاحي / شحن')),
          DropdownMenuItem<int?>(value: 1, child: Text('تحصيل نقدي')),
          DropdownMenuItem<int?>(value: 2, child: Text('دفع من المحفظة')),
          DropdownMenuItem<int?>(value: 3, child: Text('إلغاء أو عكس')),
          DropdownMenuItem<int?>(value: 5, child: Text('تسوية مديونية')),
        ], onChanged: (value) { controller.financialType.value = value; if (onChanged != null) onChanged!(); }),
      ])));

  Widget _dateButton(BuildContext context, String label, DateTime value, ValueChanged<DateTime> onPicked) => OutlinedButton.icon(
        icon: const Icon(Icons.calendar_today_outlined, size: 17), label: Text('$label: ${value.day}/${value.month}/${value.year}'),
        onPressed: () async { final selected = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365)), initialDate: value); if (selected != null) onPicked(selected); },
      );
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.title, required this.value, required this.subtitle, required this.icon});
  final String title;
  final double value;
  final String subtitle;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Card(color: Theme.of(context).colorScheme.primaryContainer, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon), const SizedBox(height: 8), Text(title), Text('${value.toStringAsFixed(0)} ر.ي', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)), Text(subtitle)])));
}

class _DriverBalanceCard extends StatelessWidget {
  const _DriverBalanceCard({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final isOwedByDriver = value > 0;
    final isOwedToDriver = value < 0;
    final color = isOwedByDriver
        ? Colors.red.shade700
        : isOwedToDriver
            ? Colors.green.shade700
            : Theme.of(context).colorScheme.onSurface;
    final label = isOwedByDriver
        ? 'عليه للمنصة'
        : isOwedToDriver
            ? 'له عند المنصة'
            : 'لا يوجد رصيد مستحق';
    return Card(
      color: color.withValues(alpha: .10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.account_balance_rounded, color: color),
          const SizedBox(height: 8),
          const Text('إجمالي الرصيد'),
          Text(
            '${isOwedByDriver ? '-' : ''}${value.abs().toStringAsFixed(0)} ر.ي',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: color),
          ),
          Text(label, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ]),
      ),
    );
  }
}

class _TransactionList extends StatelessWidget {
  const _TransactionList({required this.items, required this.loading, this.account = false});
  final List<Map<String, Object?>> items;
  final bool loading;
  final bool account;
  @override
  Widget build(BuildContext context) {
    if (loading && items.isEmpty) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()));
    if (items.isEmpty) return const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('لا توجد حركات مالية في الفترة المحددة.')));
    return Column(children: items.map((item) {
      final debit = _number(item['debit']);
      final credit = _number(item['credit']);
      final amount = account ? (debit - credit) : _number(item['amount']);
      final positive = amount >= 0;
      final title = '${item['description'] ?? item['accountName'] ?? 'عملية مالية'}';
      final date = DateTime.tryParse('${item['occurredAtUtc'] ?? item['createdAtUtc'] ?? ''}')?.toLocal();
      return Card(child: ListTile(leading: CircleAvatar(child: Icon(positive ? Icons.south_west_rounded : Icons.north_east_rounded, color: positive ? Colors.green : Colors.red)), title: Text(title), subtitle: Text(date == null ? '' : '${date.day}/${date.month}/${date.year}'), trailing: Text('${positive ? '+' : ''}${amount.toStringAsFixed(0)} ر.ي', style: TextStyle(color: positive ? Colors.green : Colors.red, fontWeight: FontWeight.bold))));
    }).toList());
  }
}

bool _inDateRange(DateTime date, DriverController controller) {
  final day = DateTime(date.year, date.month, date.day);
  final from = DateTime(controller.financialFrom.value.year, controller.financialFrom.value.month, controller.financialFrom.value.day);
  final to = DateTime(controller.financialTo.value.year, controller.financialTo.value.month, controller.financialTo.value.day);
  return !day.isBefore(from) && !day.isAfter(to);
}

double _number(Object? value) => value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;
