import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_models.dart';
import '../../../core/realtime/tracking_hub_service.dart';
import '../controllers/driver_controller.dart';
import 'driver_ride_actions.dart';
import '../../../shared/widgets/ride_financial_follow_up.dart';

class DriverArrivalPanel extends StatefulWidget {
  const DriverArrivalPanel(
      {required this.rideId,
      this.actions = const [],
      this.communicationActions = const [],
      super.key});
  final int rideId;
  final List<Widget> actions;
  final List<Widget> communicationActions;
  @override
  State<DriverArrivalPanel> createState() => _DriverArrivalPanelState();
}

class _DriverArrivalPanelState extends State<DriverArrivalPanel>
    with WidgetsBindingObserver {
  Map<String, Object?>? _state;
  Map<String, Object?>? _pickup;
  Timer? _timer;
  bool _busy = false;
  String? _error;
  StreamSubscription<TrackingHubEvent>? _events;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load('get'));
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_busy) unawaited(_load('get'));
    });
    if (Get.isRegistered<TrackingHubService>())
      _events = Get.find<TrackingHubService>().events.listen((event) {
        if (event.name == 'rideArrivalUpdated' &&
            '${event.payload['rideId']}' == '${widget.rideId}')
          unawaited(_load('get'));
      });
  }

  Future<void> _load(String operation) async {
    if (!Get.isRegistered<ApiClient>()) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await Get.find<ApiClient>().execute<Object?>(
          model: 'RideArrivalModel',
          operation: operation,
          data: {'rideId': widget.rideId});
      if (result is! ApiSuccess || result.data is! Map)
        throw const FormatException('تعذر إرسال تنبيه الوصول.');
      final pickup = await Get.find<ApiClient>().execute<Object?>(
          model: 'RidePickupModel',
          operation: 'get',
          data: {'rideId': widget.rideId});
      if (pickup is ApiFailure)
        throw FormatException(pickup.problem.detail ?? pickup.problem.title);
      if (mounted)
        setState(() {
          _state = Map<String, Object?>.from(result.data as Map);
          _pickup =
              Map<String, Object?>.from((pickup as ApiSuccess).data as Map);
          _error = null;
        });
    } on Object {
      if (mounted)
        setState(
            () => _error = 'تعذر تحديث التنبيه. تحقق من الاتصال وحاول مجدداً.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load('get'));
  }

  Future<void> _contact() async {
    final outcome = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
              title: Text(operationalText(
                  'نتيجة تواصل فعلي مع الراكب', 'Actual rider contact result')),
              children: [
                for (final option in [
                  operationalText('اتصلت ولم يجب', 'Called with no answer'),
                  operationalText('أبلغته بوصولي وينتظر الصعود',
                      'Reached rider and informed them of arrival'),
                  operationalText('تواصلت وتعذر عليه الحضور',
                      'Reached rider; unable to attend')
                ])
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, option),
                      child: Text(option)),
              ],
            ));
    if (outcome == null || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final response = await Get.find<ApiClient>().execute<Object?>(
          model: 'RidePickupModel',
          operation: 'contact',
          data: {'rideId': widget.rideId, 'outcome': outcome});
      if (response is ApiFailure)
        throw FormatException(
            response.problem.detail ?? response.problem.title);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load('get');
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('بانتظار صعود الراكب', style: TextStyle(fontSize: 12)),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          ...widget.communicationActions,
          const SizedBox(width: 6),
          IconButton.outlined(
            key: const ValueKey('send-rider-arrival-alert'),
            tooltip: 'تنبيه الراكب',
            iconSize: 18,
            onPressed: _busy ? null : () => _load('ring'),
            icon: const Icon(Icons.notifications_active_outlined),
          ),
          const SizedBox(width: 6),
          IconButton.outlined(
            key: const ValueKey('record-rider-contact'),
            tooltip: 'نتيجة التواصل',
            iconSize: 18,
            onPressed:
                _busy || _pickup == null || _error != null ? null : _contact,
            icon: const Icon(Icons.phone_in_talk_outlined),
          ),
        ]),
        if (_state?['acknowledged'] == true)
          const Text('أكد الراكب استلام إشعار الوصول.',
              style: TextStyle(fontSize: 12)),
        if (_state?['riderOnline'] == false)
          const Text('الراكب غير متصل حالياً؛ يمكنك الاتصال به.',
              style: TextStyle(fontSize: 12)),
        if (_pickup != null) ...[
          Text(
              _pickup!['pickupGraceMinutes'] == null
                  ? operationalText(
                      'مهلة الحضور غير معتمدة؛ الإلغاء يخضع للمراجعة.',
                      'No approved grace period; cancellation requires review.')
                  : operationalText(
                      'مهلة الحضور: ${_pickup!['pickupGraceMinutes']} دقيقة.',
                      'Pickup grace: ${_pickup!['pickupGraceMinutes']} minutes.'),
              style: const TextStyle(fontSize: 12)),
          if ((_pickup!['contacts'] as List? ?? []).isNotEmpty)
            ExpansionTile(
              title:
                  const Text('محاولات التواصل', style: TextStyle(fontSize: 12)),
              children: [
                for (final contact in (_pickup!['contacts'] as List? ?? []))
                  Text('${contact['outcome']}')
              ],
            ),
        ],
        if (_error != null)
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 8),
        DriverRideActions(actions: [
          ...widget.actions,
          if (_pickup?['noShowEligible'] == true)
            DriverRideAction(
                outlined: true,
                onPressed: _busy ||
                        _error != null ||
                        !Get.isRegistered<DriverController>()
                    ? null
                    : () => Get.find<DriverController>().requestCancellation(
                        {'id': widget.rideId, 'status': 9},
                        initialReason: operationalText(
                            'لم يحضر الراكب بعد المهلة المعتمدة ومحاولة التواصل',
                            'Rider did not attend after approved grace and contact attempt')),
                icon: const Icon(Icons.person_off_outlined),
                label: const Text('عدم حضور الراكب')),
        ]),
      ]);
  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _events?.cancel();
    super.dispose();
  }
}
