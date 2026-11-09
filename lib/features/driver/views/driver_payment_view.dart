import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/network/api_models.dart';
import '../../../core/realtime/tracking_hub_service.dart';
import '../../../shared/widgets/ride_financial_follow_up.dart';
import '../models/driver_ride_payment_state.dart';
import '../repositories/driver_repository.dart';

class DriverPaymentView extends StatefulWidget {
  const DriverPaymentView(
      {required this.ride,
      required this.repository,
      required this.hub,
      super.key});
  final Map<String, Object?> ride;
  final DriverRepository repository;
  final TrackingHubService hub;
  @override
  State<DriverPaymentView> createState() => _DriverPaymentViewState();
}

class _DriverPaymentViewState extends State<DriverPaymentView>
    with WidgetsBindingObserver {
  late Map<String, Object?> _ride;
  late final TextEditingController _cash;
  bool _busy = false;
  bool _refreshing = false;
  Future<bool>? _refreshTask;
  bool _refreshQueued = false;
  bool _confirming = false;
  String? _error;
  StreamSubscription<TrackingHubEvent>? _events;
  StreamSubscription<void>? _connections;
  Timer? _timer;
  double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
  Map<Object?, Object?> get _finance =>
      _ride['finance'] is Map<Object?, Object?>
          ? _ride['finance']! as Map<Object?, Object?>
          : {};
  double get _due => _number(_finance['amountDue'] ?? _ride['totalAmount']);
  double get _outstanding =>
      _number(_finance['outstandingAmount'] ?? _ride['outstandingAmount']);
  double get _received => double.tryParse(_cash.text.trim()) ?? 0;
  double get _excess => (_received - _outstanding).clamp(0, double.infinity);
  DriverRidePaymentState get _state => DriverRidePaymentState(_ride);
  bool get _blocked =>
      _state.completed ||
      _state.pending ||
      !_state.cashSelected ||
      _ride['waitingIsOpen'] == true ||
      _finance['amountUnderReview'] == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ride = Map<String, Object?>.from(widget.ride);
    _cash = TextEditingController(text: _outstanding.toStringAsFixed(0))
      ..addListener(_cashChanged);
    widget.hub.stateChanges.register(this, (changes) async {
      if (!changes.any((change) =>
          change.resource == 'ride' &&
          '${change.resourceId}' == '${_ride['id']}')) return;
      await _refresh();
      if (_error != null) throw StateError(_error!);
    });
    _events = widget.hub.events.listen((event) {
      if (widget.hub.supportsStateRecovery.value) return;
      if (const {
            'paymentUpdated',
            'cashApprovalUpdated',
            'rideStatusUpdated',
            'rideArrivalUpdated',
            'rideCancellationUpdated'
          }.contains(event.name) &&
          '${event.payload['rideId'] ?? event.payload['id']}' ==
              '${_ride['id']}') unawaited(_refresh());
    });
    _connections = widget.hub.connectionRestored.listen((_) => _refresh());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_busy) unawaited(_refresh());
    });
    unawaited(_refresh());
  }

  void _cashChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<bool> _refresh() {
    if (_refreshTask != null) {
      _refreshQueued = true;
      return _refreshTask!;
    }
    late final Future<bool> task;
    task = _refreshSnapshot().whenComplete(() {
      if (identical(_refreshTask, task)) _refreshTask = null;
    });
    _refreshTask = task;
    return task;
  }

  Future<bool> _refreshSnapshot() async {
    if (!mounted) return false;
    setState(() => _refreshing = true);
    var unchanged = true;
    try {
      do {
        _refreshQueued = false;
        final old = _outstanding;
        final oldVersion = _ride['routeVersion'];
        final epoch = widget.hub.stateChanges.epochForResources(const {'ride'});
        final suggested = _cash.text == old.toStringAsFixed(0);
        final latest = await widget.repository
            .getRideForPayment(int.parse('${_ride['id']}'));
        if (!mounted) return false;
        if (epoch != widget.hub.stateChanges.epochForResources(const {'ride'})) {
          _refreshQueued = true;
          continue;
        }
        setState(() {
          _ride = latest;
          _error = null;
          if (suggested) _cash.text = _outstanding.toStringAsFixed(0);
        });
        unchanged = unchanged &&
            old == _outstanding &&
            oldVersion == _ride['routeVersion'];
      } while (_refreshQueued && mounted);
      return unchanged;
    } catch (_) {
      if (mounted)
        setState(() => _error = operationalText(
            'تعذر تأكيد الأجرة. أعد التحديث قبل تسجيل التحصيل.',
            'Could not verify the fare. Refresh before recording cash.'));
      return false;
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || _refreshing) return;
    final amount = num.tryParse(_cash.text.trim());
    if (amount == null || !amount.isFinite || amount <= 0) {
      setState(() => _error = operationalText(
          'أدخل قيمة النقد الذي استلمته فعلياً.',
          'Enter the cash you actually received.'));
      return;
    }
    setState(() => _busy = true);
    try {
      final unchanged = await _refresh();
      if (!mounted || _error != null) return;
      if (!unchanged || _blocked) {
        setState(() => _error = operationalText(
            'تغيرت حالة الدفع أو الأجرة. راجع الفاتورة الحالية قبل التحصيل.',
            'The fare or payment changed. Review the current invoice before collecting.'));
        return;
      }
      setState(() => _confirming = true);
      final confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(operationalText(
                    'تسجيل النقد المقبوض', 'Record cash received')),
                content: Text(operationalText(
                    'المقبوض فعلياً: $amount ر.ي.\nالمتبقي بعده: ${(_outstanding - amount).clamp(0, double.infinity).toStringAsFixed(0)} ر.ي.'
                        '${_excess > 0 ? '\nالباقي للعميل: ${_excess.toStringAsFixed(0)} ر.ي. الأصل إعادته نقداً؛ المحفظة تتطلب اختياره.' : ''}\nيُسجل هذا القبض مرة واحدة. إنهاء النقل مستقل عن سداد المتبقي.',
                    'Cash received: $amount YER.\nRemaining: ${(_outstanding - amount).clamp(0, double.infinity).toStringAsFixed(0)} YER.'
                        '${_excess > 0 ? '\nRider change: ${_excess.toStringAsFixed(0)} YER. Return it physically; wallet credit requires their choice.' : ''}\nThis receipt is recorded once. Transport completion is independent of the balance.')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(operationalText('رجوع', 'Back'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(operationalText(
                          'استلمت النقد، سجله', 'Cash received; record it')))
                ],
              ));
      if (!mounted) return;
      setState(() => _confirming = false);
      if (confirm != true) return;
      final result = await widget.repository.registerCashPayment(
          rideId: int.parse('${_ride['id']}'), cashReceived: amount);
      if (!mounted) return;
      _cash.text = '';
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${result['message'] ?? operationalText('سُجل النقد الفعلي.', 'Actual cash recorded.')}')));
    } catch (error) {
      if (mounted)
        setState(() => _error = error is ApiProblemDetails
            ? error.detail ?? error.title
            : '$error');
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _confirming = false;
        });
    }
  }

  Widget _line(String title, Object? amount) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(child: Text(title)),
        Text(
            '${_number(amount).toStringAsFixed(0)} ${operationalText('ر.ي', 'YER')}')
      ]));
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text(operationalText(
              'حالة الدفع والتحصيل', 'Payment and collection'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text(operationalText('رحلة #${_ride['id']}', 'Ride #${_ride['id']}'),
            style: Theme.of(context).textTheme.headlineSmall),
        Text(_state.selectedMethodName),
        if (!_state.completed) Text(_state.collectionMessage),
        if (_state.completed) Text(_state.paidMessage),
        if (_ride['destinationDisplayName'] != null)
          Text(operationalText(
              'الوجهة الحالية: ${_ride['destinationDisplayName']}',
              'Current destination: ${_ride['destinationDisplayName']}')),
        if (_number(_ride['routeChangeFees']) > 0)
          Text(operationalText(
              'منها رسوم تغيير الوجهة: ${_number(_ride['routeChangeFees']).toStringAsFixed(0)} ر.ي',
              'Includes destination change fee: ${_number(_ride['routeChangeFees']).toStringAsFixed(0)} YER')),
        _line(operationalText('إجمالي المستحق', 'Total due'), _due),
        _line(operationalText('المقبوض المؤكد', 'Confirmed receipts'),
            _finance['paidAmount'] ?? _ride['paidAmount']),
        _line(operationalText('المسترد فعلياً', 'Actual refunds'),
            _finance['refundedAmount'] ?? _ride['refundedAmount']),
        _line(operationalText('المتبقي للسداد', 'Outstanding balance'),
            _outstanding),
        const Divider(),
        _line(operationalText('أجرة النقل', 'Transport fare'),
            _ride['customerPrice']),
        _line(operationalText('الانتظار المعتمد', 'Approved waiting'),
            _ride['waitingFee']),
        _line(
            operationalText('رسوم الخدمة', 'Service fee'), _ride['serviceFee']),
        _line(
            operationalText(
                'صافي مستحق السائق عن الخدمة', 'Driver net entitlement'),
            _ride['financialDriverEntitlement'] ?? _ride['driverShare']),
        Text(operationalText(
            'المستحق غير المحصل مستقل عن الرصيد القابل للسحب. لا يُسجل قبض أو خصم محفظة بمجرد اختيار طريقة الدفع.',
            'Uncollected entitlement is separate from withdrawable funds. Selecting a method does not record a receipt or wallet debit.')),
        const SizedBox(height: 16),
        if (_state.completed)
          Text(operationalText('تم السداد بالكامل.', 'Fully paid.'),
              style:
                  TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
        if (_state.pending)
          Text(operationalText(
              'محاولة المزود الأصلية لم تُحسم. التحصيل البديل يتطلب حسمها أولاً.',
              'The original provider attempt is unresolved. Verify it before collecting another payment.')),
        if (_finance['amountUnderReview'] == true)
          Text(operationalText(
              'تراجع الإدارة مبلغ الإلغاء والمسؤولية. لا يُحصّل كامل سعر الرحلة الأصلي قبل اعتماد التسوية.',
              'Administration is reviewing the cancellation amount and responsibility. Do not collect the original full fare before settlement is approved.')),
        if (!_state.cashSelected && !_state.completed)
          Text(operationalText(
              'يُكمل الراكب الدفع من تطبيقه، أو يغير الطريقة إلى النقد. يمكن إنهاء النقل بعد انتهائه فعلياً مع إبقاء المتبقي للمتابعة.',
              'The rider can pay in their app or choose cash. Transport can end when physically finished; outstanding money remains for follow-up.')),
        if (_state.cashSelected && !_state.completed) ...[
          TextField(
              controller: _cash,
              enabled: !_busy && !_blocked,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: operationalText(
                      'نقد جديد استلمته فعلياً', 'New cash actually received'),
                  suffixText: operationalText('ر.ي', 'YER'),
                  border: OutlineInputBorder())),
          if (_excess > 0)
            Text(operationalText(
                'الباقي الواجب إعادته: ${_excess.toStringAsFixed(0)} ر.ي. تُعرض خيارات استلامه للراكب.',
                'Change owed: ${_excess.toStringAsFixed(0)} YER. The rider chooses how to receive it.')),
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: _busy || _refreshing || _blocked || _error != null
                  ? null
                  : _submit,
              icon: const Icon(Icons.payments_outlined),
              label: Text(
                  operationalText('تسجيل التحصيل فقط', 'Record collection'))),
        ],
        if ((_busy && !_confirming) || _refreshing)
          const LinearProgressIndicator(),
        if (_error != null)
          Container(
              padding: const EdgeInsets.all(12),
              color: Colors.red.shade50,
              child:
                  Text(_error!, style: TextStyle(color: Colors.red.shade900))),
        TextButton.icon(
            onPressed: _busy || _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh),
            label: Text(operationalText(
                'تحديث الأجرة وحالة الانتظار', 'Refresh fare and waiting'))),
        OutlinedButton.icon(
            onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                    builder: (_) => RideFinancialFollowUp(
                        rideId: int.parse('${_ride['id']}'), isDriver: true))),
            icon: const Icon(Icons.receipt_long_outlined),
            label: Text(operationalText(
                'الفاتورة والباقي والاسترجاع', 'Invoice, change and refunds'))),
        Text(operationalText(
            'بعد وصول الراكب أو التوقف الآمن، يمكنك إنهاء النقل من شاشة الرحلة حتى لو بقي مبلغ أو مراجعة مالية.',
            'After arrival or a safe stop, end transport from the ride screen even if money or financial review remains.')),
      ]));
  @override
  void dispose() {
    widget.hub.stateChanges.unregister(this);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _events?.cancel();
    _connections?.cancel();
    _cash.removeListener(_cashChanged);
    _cash.dispose();
    super.dispose();
  }
}
