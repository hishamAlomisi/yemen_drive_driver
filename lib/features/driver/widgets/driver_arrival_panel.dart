import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_models.dart';
import '../../../core/realtime/tracking_hub_service.dart';

class DriverArrivalPanel extends StatefulWidget {
  const DriverArrivalPanel({required this.rideId, super.key});
  final int rideId;
  @override
  State<DriverArrivalPanel> createState() => _DriverArrivalPanelState();
}
class _DriverArrivalPanelState extends State<DriverArrivalPanel> {
  Map<String, Object?>? _state;
  bool _busy = false;
  String? _error;
  StreamSubscription<TrackingHubEvent>? _events;
  @override
  void initState() {
    super.initState(); unawaited(_load('get'));
    if (Get.isRegistered<TrackingHubService>()) _events = Get.find<TrackingHubService>().events.listen((event) {
      if (event.name == 'rideArrivalUpdated' && '${event.payload['rideId']}' == '${widget.rideId}') unawaited(_load('get'));
    });
  }
  Future<void> _load(String operation) async {
    if (!Get.isRegistered<ApiClient>()) return;
    if (operation == 'ring') setState(() => _busy = true);
    try {
      final result = await Get.find<ApiClient>().execute<Object?>(model: 'RideArrivalModel', operation: operation, data: {'rideId': widget.rideId});
      if (result is! ApiSuccess || result.data is! Map) throw const FormatException('تعذر إرسال تنبيه الوصول.');
      if (mounted) setState(() { _state = Map<String, Object?>.from(result.data as Map); _error = null; });
    } on Object {
      if (mounted) setState(() => _error = 'تعذر تحديث التنبيه. تحقق من الاتصال وحاول مجدداً.');
    } finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (_state?['acknowledged'] == true) const Text('أكد الراكب استلام إشعار الوصول.'),
    if (_state?['riderOnline'] == false) const Text('الراكب غير متصل بالتطبيق حالياً. يمكنك الاتصال به مباشرة.'),
    if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    OutlinedButton.icon(key: const ValueKey('send-rider-arrival-alert'), onPressed: _busy ? null : () => _load('ring'),
      icon: const Icon(Icons.notifications_active_outlined), label: const Text('إرسال تنبيه صوتي إلى الراكب')),
  ]);
  @override
  void dispose() { _events?.cancel(); super.dispose(); }
}
