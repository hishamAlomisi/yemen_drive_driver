import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Reports a view only when an open request is visible in the foreground.
/// Merely receiving/loading a request is not a view.
class RequestViewTracker extends StatefulWidget {
  const RequestViewTracker(
      {required this.report, required this.child, super.key});
  final Future<void> Function() report;
  final Widget child;
  @override
  State<RequestViewTracker> createState() => _RequestViewTrackerState();
}

class _RequestViewTrackerState extends State<RequestViewTracker>
    with WidgetsBindingObserver {
  ScrollPosition? _position;
  bool _sent = false;
  bool _inFlight = false;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (_position != position) {
      _position?.removeListener(_scheduleCheck);
      _position = position;
      _position?.addListener(_scheduleCheck);
    }
    _scheduleCheck();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleCheck();
  }

  void _scheduleCheck() {
    if (!mounted || _sent || _inFlight || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          _sent ||
          _inFlight ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
          ModalRoute.of(context)?.isCurrent != true) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final bounds = box.localToGlobal(Offset.zero) & box.size;
      final scrollBox =
          Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
      final viewport = scrollBox != null && scrollBox.hasSize
          ? scrollBox.localToGlobal(Offset.zero) & scrollBox.size
          : Offset.zero & MediaQuery.sizeOf(context);
      final visible = bounds.intersect(viewport);
      if (visible.width <= 0 ||
          visible.height < math.min(100, bounds.height * .35)) return;
      unawaited(_report());
    });
  }

  Future<void> _report() async {
    _inFlight = true;
    try {
      await widget.report();
      _sent = true;
    } catch (_) {
      /* Retry on the next visible foreground/scroll event. */
    } finally {
      _inFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position?.removeListener(_scheduleCheck);
    super.dispose();
  }
}
