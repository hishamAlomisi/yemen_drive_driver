import 'dart:async';

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
  int? _approvalId;
  int? _approvalStatus;
  Timer? _approvalPolling;

  @override
  void initState() {
    super.initState();
    _cash = TextEditingController(text: _totalDue.toStringAsFixed(0));
    _cash.addListener(_onCashChanged);
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
  double get _cashReceived =>
      double.tryParse(_cash.text.trim()) ?? _totalDue;
  double get _customerWalletExcess =>
      (_cashReceived - _totalDue).clamp(0, double.infinity);
  double get _expectedDriverDebt =>
      _platformReceivable + _customerWalletExcess;
  double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;

  void _onCashChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _approvalPolling?.cancel();
    _cash.removeListener(_onCashChanged);
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
    if (_approvalStatus == 0) return;
    setState(() => _saving = true);
    try {
      final result = await widget.repository.registerCashPayment(
        rideId: rideId,
        cashReceived: amount,
      );
      if (mounted) {
        if (result['requiresCustomerApproval'] == true) {
          _approvalId = int.tryParse('${result['approvalId']}');
          _approvalStatus = 0;
          _startApprovalPolling();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'أُرسل طلب موافقة للعميل على خصم الفرق من محفظته. انتظر القرار ثم أعد تسجيل المبلغ نفسه.')));
          return;
        }
        if (result['rejected'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'رُفض التحصيل: رصيد محفظة العميل لا يكفي لتغطية الفرق.')));
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تسجيل التحصيل النقدي. اضغط «إنهاء الرحلة» بعد التحقق من اكتمال العملية.')),
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

  void _startApprovalPolling() {
    _approvalPolling?.cancel();
    _approvalPolling = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _refreshApproval(),
    );
    unawaited(_refreshApproval());
  }

  Future<void> _refreshApproval() async {
    final approvalId = _approvalId;
    if (approvalId == null || !mounted) return;
    try {
      final approval =
          await widget.repository.getCashCollectionApproval(approvalId);
      final status = int.tryParse('${approval['status']}');
      if (!mounted || status == null) return;
      if (status != _approvalStatus) {
        setState(() => _approvalStatus = status);
        if (status != 0) {
          _approvalPolling?.cancel();
          final message = switch (status) {
            1 => 'وافق العميل. أعد تسجيل المبلغ نفسه لإكمال التحصيل.',
            2 => 'رفض العميل تغطية الفرق من محفظته. لم تسجل الدفعة.',
            3 => 'لم يعد رصيد محفظة العميل كافياً. لم تسجل الدفعة.',
            _ => 'تغيرت حالة طلب الموافقة. تحقق من إشعاراتك.',
          };
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        }
      }
    } catch (_) {
      // Keep the pending state visible. The notification screen remains the
      // fallback if the device temporarily loses connectivity.
    }
  }

  String? get _approvalMessage => switch (_approvalStatus) {
        0 => 'بانتظار موافقة العميل على خصم فرق الرحلة من محفظته…',
        1 => 'وافق العميل. أعد تسجيل المبلغ نفسه لإكمال التحصيل.',
        2 => 'رفض العميل تغطية الفرق؛ لن تسجل الدفعة.',
        3 => 'رصيد محفظة العميل لم يعد كافياً؛ لن تسجل الدفعة.',
        _ => null,
      };

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
                'التزامك للمنصة: ${_platformReceivable.toStringAsFixed(0)} ر.ي'),
            if (_customerWalletExcess > 0)
              Text(
                'الزيادة لمحفظة العميل: ${_customerWalletExcess.toStringAsFixed(0)} ر.ي',
                style: const TextStyle(color: Colors.deepOrange),
              ),
            Text(
              'إجمالي مديونيتك بعد التحصيل: ${_expectedDriverDebt.toStringAsFixed(0)} ر.ي',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
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
            if (_approvalMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _approvalStatus == 1
                      ? Colors.green.withValues(alpha: .10)
                      : _approvalStatus == 0
                          ? Colors.amber.withValues(alpha: .14)
                          : Colors.red.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _approvalMessage!,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              onPressed: _saving || _approvalStatus == 0 ? null : _submit,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.payments_outlined),
              label: Text(_approvalStatus == 1
                  ? 'إعادة تسجيل التحصيل بعد الموافقة'
                  : 'تسجيل التحصيل فقط'),
            ),
            const SizedBox(height: 12),
            const Text(
              'إذا كان المبلغ أكبر من الإجمالي، يضاف الفرق إلى محفظة العميل وتصبح قيمته التزاماً عليك. وإذا كان أقل، يُرسل طلب موافقة للعميل لتغطية الفرق من محفظته. لا يُخصم شيء ولا تُسجل الدفعة حتى يوافق العميل، ثم أعد تسجيل المبلغ نفسه. إذا لم يكف الرصيد أو رُفض الطلب فلن يكتمل التحصيل.',
              textAlign: TextAlign.start,
            ),
          ],
        ),
      );
}
