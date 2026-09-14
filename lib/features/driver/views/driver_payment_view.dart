import 'package:flutter/material.dart';

import '../repositories/driver_repository.dart';

class DriverPaymentView extends StatefulWidget {
  const DriverPaymentView(
      {required this.ride, required this.repository, super.key});
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
    _cash = TextEditingController(text: _totalDue.toStringAsFixed(0));
  }

  double get _fare => _number(widget.ride['customerPrice']);
  double get _serviceFee => _number(widget.ride['serviceFee']);
  double get _totalDue {
    final stored = _number(widget.ride['totalAmount']);
    return stored > 0 ? stored : _fare + _serviceFee;
  }

  double get _commission => _number(widget.ride['driverCommissionAmount']);
  double get _platformReceivable {
    final stored = _number(widget.ride['platformShare']);
    return stored > 0 ? stored : _serviceFee + _commission;
  }

  double get _driverNet => _number(widget.ride['driverShare']) > 0
      ? _number(widget.ride['driverShare'])
      : _fare - _commission;
  double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;

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
      final result = await widget.repository.registerCashPayment(
        rideId: rideId,
        cashReceived: amount,
      );
      if (mounted) {
        if (result['requiresCustomerApproval'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أُرسل طلب موافقة للعميل على خصم الفرق من محفظته. انتظر القرار ثم أعد تسجيل المبلغ نفسه.')));
          Navigator.of(context).pop();
          return;
        }
        if (result['rejected'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('رُفض التحصيل: رصيد محفظة العميل لا يكفي لتغطية الفرق.')));
          return;
        }
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
            Text('رحلة #${widget.ride['id']}',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text('أجرة الرحلة: ${_fare.toStringAsFixed(0)} ر.ي'),
            Text('رسم الخدمة من العميل: ${_serviceFee.toStringAsFixed(0)} ر.ي'),
            Text('إجمالي المطلوب تحصيله: ${_totalDue.toStringAsFixed(0)} ر.ي',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Divider(height: 28),
            Text('عمولتك للمنصة: ${_commission.toStringAsFixed(0)} ر.ي'),
            Text(
                'رسم الخدمة المستحق للمنصة: ${_serviceFee.toStringAsFixed(0)} ر.ي'),
            Text(
                'مديونيتك بعد التحصيل النقدي: ${_platformReceivable.toStringAsFixed(0)} ر.ي'),
            Text('صافي مستحقك من الأجرة: ${_driverNet.toStringAsFixed(0)} ر.ي',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            TextField(
              controller: _cash,
              enabled: !_saving,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
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
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.payments_outlined),
              label: const Text('تسجيل الدفع وإنهاء الرحلة'),
            ),
            const SizedBox(height: 12),
            const Text(
              'إذا كان المبلغ أكبر من الإجمالي، يضاف الفرق إلى محفظة العميل. وإذا كان أقل، يخصم الفرق من محفظته عند توفر الرصيد؛ وإلا ترفض العملية. يظهر أعلاه الدين المسجل للمنصة ولا يخصم مباشرة من محفظتك.',
            ),
          ],
        ),
      );
}
