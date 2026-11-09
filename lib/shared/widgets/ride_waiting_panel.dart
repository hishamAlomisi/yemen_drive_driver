import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_models.dart';
import '../../core/realtime/realtime_state_binding.dart';
import '../models/ride_waiting_snapshot.dart';

/// Driver-controlled waiting. Local time animates the server's last snapshot.
class RideWaitingPanel extends StatefulWidget {
  const RideWaitingPanel({
    required this.rideId,
    this.isDriver = false,
    this.onChanged,
    super.key,
  });
  final int rideId;
  final bool isDriver;
  final VoidCallback? onChanged;

  @override
  State<RideWaitingPanel> createState() => _RideWaitingPanelState();
}

class _RideWaitingPanelState extends State<RideWaitingPanel>
    with WidgetsBindingObserver {
  Map<String, Object?>? _data;
  Timer? _timer;
  RealtimeStateBinding? _stateBinding;
  final _elapsed = Stopwatch();
  bool _loading = false;
  bool _busy = false;
  bool _paused = false;
  String? _error;
  String? _requestKey;
  int _ticks = 0;
  int _revision = 0;
  int _refreshId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stateBinding = RealtimeStateBinding(
        owner: this,
        resources: const {'ride'},
        accepts: (change) =>
            change.resource == 'ride' && change.resourceId == widget.rideId,
        refresh: () => _refresh(requireSuccess: true));
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _paused || !TickerMode.valuesOf(context).enabled) return;
      if (++_ticks % 5 == 0 && _stateBinding?.synchronized != true) {
        unawaited(_refresh());
      }
      if (_session['isOpen'] == true) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant RideWaitingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rideId == widget.rideId) return;
    ++_revision;
    ++_refreshId;
    _loading = false;
    _busy = false;
    _data = null;
    _error = null;
    _requestKey = null;
    _elapsed.reset();
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (!_paused) unawaited(_refresh());
  }

  Map<String, Object?> get _session => _map(_data?['session']);
  bool get _stale =>
      _error != null ||
      (_elapsed.elapsed.inSeconds >= 15 && _stateBinding?.synchronized != true);
  static Map<String, Object?> _map(Object? raw) =>
      raw is Map ? Map<String, Object?>.from(raw) : {};
  static double _number(Object? raw) => RideWaitingSnapshot.number(raw);

  Future<Map<String, Object?>> _call(String operation) async {
    final result = await Get.find<ApiClient>().execute<Object?>(
      model: 'RideWaitingModel',
      operation: operation,
      data: {
        'rideId': widget.rideId,
        if (operation != 'get' && operation != 'start')
          'sessionId': _session['id'],
        if (operation == 'start' || operation == 'request_resume')
          'requestKey': _requestKey,
        if (operation == 'accept_resume' || operation == 'reject_resume')
          'resumeRequestKey': RideWaitingSnapshot(_data!).resumeRequestKey,
      },
    );
    if (result is ApiFailure) {
      throw FormatException(result.problem.detail ?? result.problem.title);
    }
    final data = _map((result as ApiSuccess).data);
    RideWaitingSnapshot(data);
    return data;
  }

  void _apply(Map<String, Object?> value) {
    final oldSessionId = _session['id'];
    final old =
        '${_session['id']}-${_session['isOpen']}-${_session['startedAtUtc']}-${_data?['settledWaitingFee']}-${_session['resumeRequest']}';
    setState(() {
      _data = value;
      _error = null;
      _elapsed
        ..reset()
        ..start();
    });
    final next =
        '${_session['id']}-${_session['isOpen']}-${_session['startedAtUtc']}-${_data?['settledWaitingFee']}-${_session['resumeRequest']}';
    if (_session['id'] != oldSessionId) _requestKey = null;
    if (old != next) widget.onChanged?.call();
  }

  Future<void> _refresh({bool requireSuccess = false}) async {
    if (_loading || _busy) {
      if (requireSuccess) throw StateError('Waiting refresh is in progress');
      return;
    }
    _loading = true;
    final revision = _revision;
    final refreshId = ++_refreshId;
    final epoch = _stateBinding?.epoch;
    try {
      final value = await _call('get');
      if (epoch != null) _stateBinding?.verify(epoch);
      if (mounted && revision == _revision) _apply(value);
    } catch (error) {
      if (mounted &&
          revision == _revision &&
          error is! StateSnapshotSuperseded) {
        setState(() => _error = 'تعذرت مزامنة الانتظار. أعد المحاولة.');
      }
      if (requireSuccess) rethrow;
    } finally {
      if (refreshId == _refreshId) _loading = false;
    }
  }

  Future<void> _action(String operation) async {
    if (_busy || _data == null) return;
    final snapshot = RideWaitingSnapshot(_data!);
    final allowed = switch (operation) {
      'start' => widget.isDriver && snapshot.canStart && !snapshot.isOpen,
      'resume' => widget.isDriver && snapshot.canResume && snapshot.isActive,
      'accept_resume' || 'reject_resume' => widget.isDriver &&
          snapshot.canDecideResume &&
          snapshot.resumeRequestPending,
      'request_resume' =>
        !widget.isDriver && snapshot.canRequestResume && snapshot.isActive,
      _ => false,
    };
    if (!allowed) return;
    if (operation != 'resume' && _stale) {
      unawaited(_refresh());
      return;
    }
    if (operation == 'start' || operation == 'request_resume') {
      final random = math.Random.secure();
      final hex = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      _requestKey ??=
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    }
    final revision = ++_revision;
    setState(() => _busy = true);
    try {
      final data = await _call(operation);
      if (!mounted || revision != _revision) return;
      _apply(data);
      if (operation == 'start' || operation == 'request_resume') {
        _requestKey = null;
      }
    } catch (error) {
      if (mounted && revision == _revision) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException
                  ? error.message
                  : 'تعذر تنفيذ الطلب. حدّث الحالة وحاول مجددًا.',
            ),
          ),
        );
      }
    } finally {
      if (mounted && revision == _revision) {
        setState(() => _busy = false);
        unawaited(_refresh());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_data == null) {
      return _error == null
          ? const SizedBox.shrink()
          : TextButton(onPressed: _refresh, child: Text(_error!));
    }
    final snapshot = RideWaitingSnapshot(_data!);
    final session = _session;
    final open = snapshot.isOpen;
    final active = snapshot.isActive;
    if (!open && !snapshot.canStart && _number(_data?['waitingFee']) == 0) {
      return const SizedBox.shrink();
    }
    final seconds = snapshot.elapsedSeconds(_elapsed.elapsed);
    final freeSeconds = (_number(session['freeMinutes']) * 60).toInt();
    final waitingFee = snapshot.waitingFee(_elapsed.elapsed);
    final total = snapshot.totalAmount(_elapsed.elapsed);
    final stale = _stale;
    final busy = _busy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              active ? 'الرحلة متوقفة' : 'التوقف والانتظار أثناء الرحلة',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (active) ...[
              Text(
                '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                textDirection: TextDirection.ltr,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(
                seconds < freeSeconds
                    ? 'المتبقي مجانًا: ${(freeSeconds - seconds + 59) ~/ 60} دقيقة'
                    : 'بدأ احتساب رسوم الانتظار',
              ),
            ],
            Text(
              'المهلة المجانية: ${_data?['waitingFreeMinutes'] ?? 0} دقيقة لكل توقف · ${_data?['waitingPricePerMinute'] ?? 0} ر.ي للدقيقة · سقف الرحلة ${_data?['waitingMaxFee'] ?? 0} ر.ي',
            ),
            if (snapshot.resumeRequestPending)
              Text(widget.isDriver
                  ? 'طلب الراكب استئناف الرحلة. يمكنك قبول طلبه أو استئناف الرحلة مباشرةً.'
                  : 'أُرسل طلب الاستئناف إلى السائق. يستمر الانتظار حتى الاستئناف.'),
            Text(
              'أجرة الرحلة ${_number(_data?['baseFare']).toStringAsFixed(0)} + الخدمة ${_number(_data?['serviceFee']).toStringAsFixed(0)} + الانتظار ${waitingFee.toStringAsFixed(0)} ر.ي',
            ),
            Text('الإجمالي الحالي: ${total.toStringAsFixed(0)} ر.ي'),
            if (!open && session['endReason'] != null)
              Text(
                switch (session['endReason']) {
                  'connection_lost' => 'أُوقف الانتظار لانقطاع تحديث الموقع.',
                  'vehicle_moving' => 'أُوقف الانتظار بعد تأكد حركة السيارة.',
                  'fee_cap' => 'وصل الانتظار إلى سقف الرسوم.',
                  _ => 'انتهى التوقف.'
                },
              ),
            if (stale)
              TextButton(
                onPressed: _refresh,
                child: const Text('بانتظار المزامنة — تحديث الحالة'),
              ),
            if (_busy) const LinearProgressIndicator(),
            if (widget.isDriver && snapshot.canStart && !open)
              OutlinedButton.icon(
                onPressed: busy || stale ? null : () => _action('start'),
                icon: const Icon(Icons.timer_outlined),
                label: const Text('بدء التوقف'),
              ),
            if (widget.isDriver &&
                snapshot.canDecideResume &&
                snapshot.resumeRequestPending)
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed:
                        busy || stale ? null : () => _action('accept_resume'),
                    child: const Text('قبول طلب الاستئناف'),
                  ),
                  TextButton(
                    onPressed:
                        busy || stale ? null : () => _action('reject_resume'),
                    child: const Text('رفض طلب الاستئناف'),
                  ),
                ],
              ),
            if (active && widget.isDriver && snapshot.canResume)
              FilledButton(
                onPressed: busy ? null : () => _action('resume'),
                child: const Text('استئناف الرحلة وإيقاف الانتظار'),
              ),
            if (active && !widget.isDriver && snapshot.canRequestResume)
              OutlinedButton(
                onPressed:
                    busy || stale ? null : () => _action('request_resume'),
                child: const Text('طلب استئناف الرحلة'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stateBinding?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _elapsed.stop();
    super.dispose();
  }
}
