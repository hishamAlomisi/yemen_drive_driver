import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class AppGoogleMap extends StatefulWidget {
  const AppGoogleMap({
    this.width,
    this.height,
    this.initialTarget = const LatLng(15.3694, 44.1910),
    this.initialZoom = 14,
    this.followTarget,
    this.smoothFollow = false,
    this.pauseOnUserInteraction = false,
    this.followRequestId = 0,
    this.onUserInteraction,
    this.markers = const <Marker>{},
    this.polylines = const <Polyline>{},
    this.myLocationEnabled = false,
    this.zoomControlsEnabled = false,
    this.compassEnabled = true,
    this.onMapCreated,
    this.onCameraMove,
    this.onCameraIdle,
    this.onTap,
    this.lightStyle,
    this.darkStyle,
    super.key,
  });

  final double? width;
  final double? height;
  final LatLng initialTarget;
  final double initialZoom;
  final LatLng? followTarget;

  /// The caller already interpolates its marker; native animation would lag it.
  final bool smoothFollow;

  /// Tracking yields camera ownership to a pan or pinch until explicitly reset.
  final bool pauseOnUserInteraction;
  final int followRequestId;
  final VoidCallback? onUserInteraction;
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final bool myLocationEnabled;
  final bool zoomControlsEnabled;
  final bool compassEnabled;
  final MapCreatedCallback? onMapCreated;
  final CameraPositionCallback? onCameraMove;
  final VoidCallback? onCameraIdle;
  final ArgumentCallback<LatLng>? onTap;
  final String? lightStyle;
  final String? darkStyle;

  @override
  State<AppGoogleMap> createState() => _AppGoogleMapState();
}

class _AppGoogleMapState extends State<AppGoogleMap>
    with WidgetsBindingObserver {
  bool _isLoading = true;
  GoogleMapController? _controller;
  LatLng? _pendingFollowTarget;
  Timer? _followTimer;
  bool _cameraUpdateInFlight = false;
  final _cameraClock = Stopwatch()..start();
  Duration? _lastCameraUpdateAt;
  final Map<int, Offset> _pointers = {};
  bool _userOwnsCamera = false;
  bool _foreground = true;
  bool _tickerEnabled = true;
  bool get _mayFollow =>
      _foreground &&
      _tickerEnabled &&
      (!widget.pauseOnUserInteraction ||
          (!_userOwnsCamera && _pointers.isEmpty));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasEnabled = _mayFollow;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncCameraAvailability(wasEnabled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasEnabled = _mayFollow;
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _pointers.clear();
    _syncCameraAvailability(wasEnabled);
  }

  void _syncCameraAvailability(bool wasEnabled) {
    if (!_mayFollow) {
      _cancelPendingFollow();
    } else if (!wasEnabled && widget.followTarget != null) {
      _queueCameraFollow(widget.followTarget!);
    }
  }

  void _cancelPendingFollow() {
    _followTimer?.cancel();
    _followTimer = null;
    _pendingFollowTarget = null;
  }

  void _takeCameraOwnership() {
    if (!widget.pauseOnUserInteraction || _userOwnsCamera) return;
    _userOwnsCamera = true;
    _cancelPendingFollow();
    widget.onUserInteraction?.call();
  }

  void _pointerDown(PointerDownEvent event) {
    if (!widget.pauseOnUserInteraction) return;
    _pointers[event.pointer] = event.localPosition;
    _cancelPendingFollow();
    if (_pointers.length > 1) _takeCameraOwnership();
  }

  void _pointerMove(PointerMoveEvent event) {
    final origin = _pointers[event.pointer];
    if (origin != null && (event.localPosition - origin).distance >= 8) {
      _takeCameraOwnership();
    }
  }

  void _pointerEnd(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_mayFollow && widget.followTarget != null) {
      _queueCameraFollow(widget.followTarget!);
    }
  }

  @override
  void didUpdateWidget(covariant AppGoogleMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasEnabled = _mayFollow;
    // An inherited visibility change may arrive in the same update as GPS,
    // before didChangeDependencies runs. Never dispatch with the old value.
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    if (!_mayFollow) _cancelPendingFollow();
    final target = widget.followTarget;
    final requested = widget.followRequestId != oldWidget.followRequestId;
    if (requested) {
      _userOwnsCamera = false;
      _cancelPendingFollow();
      _lastCameraUpdateAt = null;
    }
    if (target == null) _cancelPendingFollow();
    if (target != null &&
        (requested ||
            target != oldWidget.followTarget ||
            (!wasEnabled && _mayFollow))) {
      _queueCameraFollow(target);
    }
  }

  void _queueCameraFollow(LatLng target) {
    if (!_mayFollow) return;
    _pendingFollowTarget = target;
    if (_controller == null || _cameraUpdateInFlight || _followTimer != null) {
      return;
    }
    final elapsed = _lastCameraUpdateAt == null
        ? const Duration(seconds: 1)
        : _cameraClock.elapsed - _lastCameraUpdateAt!;
    final delay = const Duration(milliseconds: 50) - elapsed;
    if (delay.isNegative || delay == Duration.zero) {
      unawaited(_flushCameraFollow());
    } else {
      _followTimer = Timer(delay, () {
        _followTimer = null;
        unawaited(_flushCameraFollow());
      });
    }
  }

  Future<void> _flushCameraFollow() async {
    final controller = _controller;
    final target = _pendingFollowTarget;
    if (!mounted || !_mayFollow || controller == null || target == null) return;
    _pendingFollowTarget = null;
    _cameraUpdateInFlight = true;
    _lastCameraUpdateAt = _cameraClock.elapsed;
    try {
      final update = CameraUpdate.newLatLng(target);
      if (widget.smoothFollow) {
        await controller.moveCamera(update);
      } else {
        await controller.animateCamera(update);
      }
    } on Object {
      // Disposal or a transient native-map failure must not stop GPS updates.
    } finally {
      _cameraUpdateInFlight = false;
      if (mounted && _pendingFollowTarget != null) {
        _queueCameraFollow(_pendingFollowTarget!);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Listener(
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerEnd,
            onPointerCancel: _pointerEnd,
            onPointerSignal: (_) => _takeCameraOwnership(),
            onPointerPanZoomStart: (_) => _takeCameraOwnership(),
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: widget.initialTarget,
                zoom: widget.initialZoom,
              ),
              markers: widget.markers,
              polylines: widget.polylines,
              myLocationEnabled: widget.myLocationEnabled,
              myLocationButtonEnabled: widget.myLocationEnabled,
              zoomControlsEnabled: widget.zoomControlsEnabled,
              compassEnabled: widget.compassEnabled,
              style: isDark ? widget.darkStyle : widget.lightStyle,
              onMapCreated: (controller) {
                _controller = controller;
                final followTarget = widget.followTarget;
                if (followTarget != null &&
                    followTarget != widget.initialTarget) {
                  _queueCameraFollow(followTarget);
                }
                widget.onMapCreated?.call(controller);
                if (mounted) setState(() => _isLoading = false);
              },
              onCameraMove: widget.onCameraMove,
              onCameraIdle: widget.onCameraIdle,
              onTap: widget.onTap,
            ),
          ),
          if (_isLoading)
            IgnorePointer(
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor.withValues(
                      alpha: .82,
                    ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      CircularProgressIndicator(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 10),
                      Text('map_loading'.tr),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelPendingFollow();
    _controller?.dispose();
    super.dispose();
  }
}
