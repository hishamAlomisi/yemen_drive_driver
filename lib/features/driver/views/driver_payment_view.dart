import 'package:flutter/material.dart';

import '../repositories/driver_repository.dart';

class DriverPaymentView extends StatefulWidget {
  const DriverPaymentView({required this.ride, required this.repository, super.key});
  final Map<String, Object?> ride;
  final DriverRepository repository;

  @override
  State<DriverPaymentView> createState() => _DriverPaymentViewState();
}

class _DriverPaymentViewState extends State<DriverPaymentView> {
  late final TextEditingController _cash;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _cash = TextEditingController(text: '${widget.ride['customerPrice'] ?? ''}');
  }

  @override
  void dispose() {
    _cash.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final rideId = int.tryParse('${widget.ride['id']}');
    final amount = num.tryParse(_cash.text.trim());
    if (rideId == null || amount == null || amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل المبلغ النقدي الصحيح.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.repository.registerCashPayment(
        rideId: rideId,
        cashReceived: amount,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تسجيل الدفع وإكمال الرحلة.')),
        );
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تسجيل الدفع: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('تحصيل الدفع النقدي')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('رحلة #${widget.ride['id']}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text('الأجرة المتفق عليها: ${widget.ride['customerPrice'] ?? '-'} ر.ي'),
            const SizedBox(height: 20),
            TextField(
              controller: _cash,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'المبلغ المقبوض من العميل',
                suffixText: 'ر.ي',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : _submit,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.payments_outlined),
              label: const Text('تسجيل الدفع وإنهاء الرحلة'),
            ),
            const SizedBox(height: 12),
            const Text(
              'إذا كان المبلغ أكبر من الأجرة، يضاف الفرق إلى محفظة العميل. وإذا كان أقل، يخصم الفرق من محفظته عند توفر الرصيد؛ وإلا ترفض العملية.',
            ),
          ],
        ),
      );
}
