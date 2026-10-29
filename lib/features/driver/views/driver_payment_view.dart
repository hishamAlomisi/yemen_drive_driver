import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_models.dart';
import '../../../core/realtime/tracking_hub_service.dart';
import '../models/driver_ride_payment_state.dart';
import '../repositories/driver_repository.dart';
import '../widgets/driver_design.dart';

class DriverPaymentView extends StatefulWidget {
  const DriverPaymentView({
    required this.ride,
    required this.repository,
    required this.hub,
    super.key,
  });
  final Map<String, Object?> ride;
  final DriverRepository repository;
  final TrackingHubService hub;

  @override
  State<DriverPaymentView> createState() => _DriverPaymentViewState();
}

class _DriverPaymentViewState extends State<DriverPaymentView>
    with WidgetsBindingObserver {
  late final TextEditingController _cash;
  late Map<String, Object?> _ride;
  bool _refreshingFare = false;
  String? _fareError;
  bool _saving = false;
  int? _approvalId;
  int? _approvalStatus;
  bool _approvalRefreshInFlight = false;
  bool _approvalRefreshRequested = false;
  StreamSubscription<TrackingHubEvent>? _hubEventSubscription;
  StreamSubscription<void>? _hubConnectionSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ride = Map<String, Object?>.from(widget.ride);
    _cash = TextEditingController(text: _totalDue.toStringAsFixed(0));
    _cash.addListener(_onCashChanged);
    _hubEventSubscription = widget.hub.events.listen(_handleHubEvent);
    _hubConnectionSubscription = widget.hub.connectionRestored.listen((_) {
      unawaited(_refreshApproval());
      unawaited(_refreshFare());
    });
    unawaited(_refreshFare());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshFare());
  }

  double get _fare => _number(_ride['customerPrice']);
  double get _serviceFee => _number(_ride['serviceFee']);
  double get _waitingFee => _number(_ride['waitingFee']);
  double get _routeChangeFees => _number(_ride['routeChangeFees']);
  double get _totalDue {
    final stored = _number(_ride['totalAmount']);
    return stored > 0 ? stored : _fare + _serviceFee + _waitingFee;
  }

  double get _commission => _number(_ride['driverCommissionAmount']);
  double get _platformReceivable {
    final stored = _number(_ride['platformShare']);
    return stored > 0 ? stored : _serviceFee + _commission;
  }

  double get _driverNet => _number(_ride['driverShare']) > 0
      ? _number(_ride['driverShare'])
      : _fare + _waitingFee - _commission;
  double get _cashReceived => double.tryParse(_cash.text.trim()) ?? _totalDue;
  double get _customerWalletExcess =>
      (_cashReceived - _totalDue).clamp(0, double.infinity);
  double get _expectedDriverDebt => _platformReceivable + _customerWalletExcess;
  double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;
  bool get _waitingIsOpen => _ride['waitingIsOpen'] == true;
  bool get _paymentCompleted => _ride['paymentCompleted'] == true;
  bool get _walletPaymentPending => _ride['walletPaymentPending'] == true;
  bool get _collectionBlocked => _paymentCompleted || _walletPaymentPending;
  String get _paymentStateMessage => _paymentCompleted
      ? '${DriverRidePaymentState(_ride).paidMessage}. لا يمكن تحصيله مرة أخرى.'
      : 'توجد عملية دفع بالمحفظة قيد التنفيذ أو التحقق. انتظر تأكيد نتيجتها قبل التحصيل.';

  Future<bool> _refreshFare() async {
    if (_refreshingFare || !mounted) return false;
    final rideId = int.tryParse('${_ride['id']}');
    if (rideId == null) return false;
    setState(() => _refreshingFare = true);
    try {
      final latest = await widget.repository.getRideForPayment(rideId);
      if (!mounted) return false;
      final previousTotal = _totalDue;
      final previousWaiting = _waitingFee;
      final previousRouteVersion = _ride['routeVersion'];
      final usedSuggestedAmount =
          _cash.text == previousTotal.toStringAsFixed(0);
      setState(() {
        _ride = latest;
        _fareError = null;
        if (usedSuggestedAmount) _cash.text = _totalDue.toStringAsFixed(0);
      });
      return previousTotal == _totalDue &&
          previousWaiting == _waitingFee &&
          previousRouteVersion == _ride['routeVersion'];
    } catch (_) {
      if (mounted) {
        setState(() =>
            _fareError = 'تعذر تأكيد الأجرة. أعد التحديث قبل تسجيل التحصيل.');
      }
      return false;
    } finally {
      if (mounted) setState(() => _refreshingFare = false);
    }
  }

  void _onCashChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hubEventSubscription?.cancel();
    _hubConnectionSubscription?.cancel();
    _cash.removeListener(_onCashChanged);
    _cash.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || _refreshingFare) return;
    final rideId = int.tryParse('${widget.ride['id']}');
    final amount = num.tryParse(_cash.text.trim());
    if (rideId == null || amount == null || !amount.isFinite || amount < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل المبلغ النقدي الصحيح.')),
      );
      return;
    }
    if (_approvalStatus == 0) return;
    setState(() => _saving = true);
    try {
      final unchanged = await _refreshFare();
      if (!mounted || _fareError != null) return;
      if (_collectionBlocked) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_paymentStateMessage)));
        return;
      }
      if (_waitingIsOpen) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('استأنف الرحلة وأوقف الانتظار قبل التحصيل.')));
        return;
      }
      if (!unchanged) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'تم تحديث الرحلة أو الأجرة. راجع الوجهة والإجمالي ثم أعد تسجيل التحصيل.')));
        return;
      }
      final result = await widget.repository.registerCashPayment(
        rideId: rideId,
        cashReceived: amount,
      );
      if (mounted) {
        if (result['requiresCustomerApproval'] == true) {
          _approvalId = int.tryParse('${result['approvalId']}');
          _approvalStatus = 0;
          unawaited(_refreshApproval());
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
          const SnackBar(
              content: Text(
                  'تم تسجيل التحصيل النقدي. اضغط «إنهاء الرحلة» بعد التحقق من اكتمال العملية.')),
        );
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(error is ApiProblemDetails
                  ? error.detail ?? error.title
                  : 'تعذر تسجيل الدفع: $error')),
        );
        unawaited(_refreshFare());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _handleHubEvent(TrackingHubEvent event) {
    if (event.name == 'rideStatusUpdated' || event.name == 'paymentUpdated') {
      if ('${event.payload['rideId'] ?? event.payload['id']}' ==
          '${_ride['id']}') {
        unawaited(_refreshFare());
      }
      return;
    }
    if (event.name != 'cashApprovalUpdated') return;
    final rideId = int.tryParse('${widget.ride['id']}');
    final eventRideId = int.tryParse('${event.payload['rideId']}');
    final approvalId = _approvalId;
    final eventApprovalId =
        int.tryParse('${event.payload['cashCollectionApprovalId']}');
    if (rideId == null ||
        eventRideId != rideId ||
        approvalId == null ||
        eventApprovalId != approvalId) {
      return;
    }
    unawaited(_refreshApproval());
  }

  Future<void> _refreshApproval() async {
    final approvalId = _approvalId;
    if (approvalId == null || !mounted) return;
    if (_approvalRefreshInFlight) {
      _approvalRefreshRequested = true;
      return;
    }
    _approvalRefreshInFlight = true;
    try {
      final approval =
          await widget.repository.getCashCollectionApproval(approvalId);
      final status = int.tryParse('${approval['status']}');
      if (!mounted || status == null) return;
      if (status != _approvalStatus) {
        setState(() => _approvalStatus = status);
        if (status != 0) {
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
    } finally {
      _approvalRefreshInFlight = false;
      if (_approvalRefreshRequested && mounted) {
        _approvalRefreshRequested = false;
        unawaited(_refreshApproval());
      }
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
        appBar: AppBar(
            title:
                Text(_paymentCompleted ? 'حالة الدفع' : 'تحصيل الدفع النقدي')),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (_paymentCompleted) ...[
                      DriverHero(
                        eyebrow: 'رحلة #${_ride['id']}',
                        title: DriverRidePaymentState(_ride).paidMessage,
                        subtitle:
                            'المبلغ المدفوع: ${_totalDue.toStringAsFixed(0)} ر.ي',
                        trailing: const Icon(Icons.check_circle_outline,
                            color: copper),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                          'اكتمل الدفع. يمكنك إنهاء الرحلة عند اكتمالها.'),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('العودة إلى الرحلة'),
                      ),
                    ] else ...[
                      DriverHero(
                        eyebrow: 'تحصيل رحلة #${_ride['id']}',
                        title: '${_totalDue.toStringAsFixed(0)} ر.ي',
                        subtitle: 'إجمالي المبلغ المطلوب من العميل',
                        trailing:
                            const Icon(Icons.payments_outlined, color: copper),
                      ),
                      const SizedBox(height: 24),
                      Text('تفاصيل التحصيل',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 16),
                      if (_ride['destinationDisplayName'] != null ||
                          _ride['destinationAddress'] != null)
                        Text(
                            'الوجهة الحالية: ${_ride['destinationDisplayName'] ?? _ride['destinationAddress']}'),
                      Text('أجرة الرحلة: ${_fare.toStringAsFixed(0)} ر.ي'),
                      if (_routeChangeFees > 0)
                        Text(
                            'منها رسوم تغيير الوجهة: ${_routeChangeFees.toStringAsFixed(0)} ر.ي'),
                      Text(
                          'رسوم الانتظار: ${_waitingFee.toStringAsFixed(0)} ر.ي'),
                      Text(
                          'رسم الخدمة من العميل: ${_serviceFee.toStringAsFixed(0)} ر.ي'),
                      Text(
                          'إجمالي المطلوب تحصيله: ${_totalDue.toStringAsFixed(0)} ر.ي',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const Divider(height: 28),
                      Text(
                          'عمولتك للمنصة: ${_commission.toStringAsFixed(0)} ر.ي'),
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
                      Text(
                          'صافي مستحقك من الأجرة: ${_driverNet.toStringAsFixed(0)} ر.ي',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _cash,
                        enabled: !_saving && !_collectionBlocked,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'المبلغ المقبوض من العميل',
                          suffixText: 'ر.ي',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_refreshingFare) const LinearProgressIndicator(),
                      if (_collectionBlocked) Text(_paymentStateMessage),
                      if (_waitingIsOpen)
                        const Text(
                            'يوجد طلب انتظار أو توقف مفتوح. استأنف الرحلة أو اسحب الطلب من شاشة الرحلة قبل التحصيل.'),
                      if (_fareError != null) Text(_fareError!),
                      TextButton.icon(
                        onPressed:
                            _saving || _refreshingFare ? null : _refreshFare,
                        icon: const Icon(Icons.refresh),
                        label: const Text('تحديث الأجرة وحالة الانتظار'),
                      ),
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
                        onPressed: _saving ||
                                _refreshingFare ||
                                _fareError != null ||
                                _waitingIsOpen ||
                                _collectionBlocked ||
                                _approvalStatus == 0
                            ? null
                            : _submit,
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
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
                  ],
                ))),
      );
}
