import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:geolocator/geolocator.dart';

enum DriverLocationStatus {
  locating,
  tracking,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  unavailable,
}

/// Keeps GPS alive independently of the initial fix and recovers after settings
/// changes. Only fresh device samples are passed to the authenticated publisher.
class DriverLocationTracker {
  DriverLocationTracker({
    required this.onPosition,
    required this.onStatus,
    required this.onAccessRequired,
    this.adaptive = false,
    GeolocatorPlatform? geolocator,
  }) : _geolocator = geolocator ?? GeolocatorPlatform.instance;

  final Future<void> Function(Position) onPosition;
  final void Function(DriverLocationStatus) onStatus;
  final Future<void> Function(DriverLocationStatus) onAccessRequired;
  final GeolocatorPlatform _geolocator;
  final bool adaptive;
  Duration _interval = const Duration(seconds: 3);
  final Stopwatch _sinceSample = Stopwatch()..start();
  Duration get requestedInterval => _interval;
  StreamSubscription<Position>? _positions;
  StreamSubscription<ServiceStatus>? _services;
  Timer? _timer;
  Timer? _streamRetry;
  Future<void>? _refreshTask;
  Future<void>? _fixTask;
  DateTime? _lastDeliveredAt;
  bool _forceLocationManager = false;
  bool _stopped = false;
  bool _started = false;
  bool _hasLocationAccess = false;
  Future<void>? _activityTask;

  Future<void> start() async {
    if (_stopped || _started) return;
    _started = true;
    try {
      _services = _geolocator.getServiceStatusStream().listen((_) {
        unawaited(refresh());
      }, onError: (Object _) {});
    } on Object {
      // Periodic checks also recover platforms without service-status events.
    }
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(refresh(
          forceFix: !adaptive ||
              _sinceSample.elapsed >= const Duration(seconds: 15)));
    });
    await refresh(prompt: true);
  }

  Future<void> refresh({bool prompt = false, bool forceFix = true}) {
    if (_stopped) return Future<void>.value();
    final access = _refreshTask ??= _refreshAccess(prompt).whenComplete(() {
      _refreshTask = null;
    });
    return access.then((_) async {
      if (forceFix && _hasLocationAccess && !_stopped) await _requestFix();
    });
  }

  Future<void> setActivity(
      {required bool activeRide,
      required bool viewed,
      required bool moving,
      required bool available}) async {
    if (!adaptive || _stopped) return;
    final seconds = activeRide
        ? (viewed ? 1 : 3)
        : available
            ? (moving ? 3 : 15)
            : 30;
    final desired = Duration(seconds: seconds);
    if (_interval == desired) return;
    _interval = desired;
    await _restartStream();
    if (_started) unawaited(refresh(forceFix: false));
  }

  Future<void> _restartStream() {
    final active = _activityTask;
    if (active != null) return active;
    late final Future<void> task;
    task = (() async {
      final previous = _positions;
      _positions = null;
      await previous?.cancel();
      // Do not wait for a first-fix upload before restarting the platform stream.
      // A slow network must not leave the stream unsubscribed after demand changes.
      try {
        if (_started && _hasLocationAccess && !_stopped) _subscribe();
      } on Object {
        if (!_stopped) {
          onStatus(DriverLocationStatus.unavailable);
          _scheduleStreamRetry();
        }
      }
    })()
        .whenComplete(() {
      if (identical(_activityTask, task)) _activityTask = null;
    });
    _activityTask = task;
    return task;
  }

  Future<void> _refreshAccess(bool prompt) async {
    try {
      var permission = await _geolocator.checkPermission();
      if (permission == LocationPermission.denied && prompt) {
        permission = await _geolocator.requestPermission();
      }
      if (_stopped) return;
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _hasLocationAccess = false;
        await _positions?.cancel();
        _positions = null;
        final status = permission == LocationPermission.deniedForever
            ? DriverLocationStatus.permissionDeniedForever
            : DriverLocationStatus.permissionDenied;
        onStatus(status);
        if (prompt) await onAccessRequired(status);
        return;
      }
      if (!await _geolocator.isLocationServiceEnabled()) {
        _hasLocationAccess = false;
        await _positions?.cancel();
        _positions = null;
        if (_stopped) return;
        onStatus(DriverLocationStatus.serviceDisabled);
        if (prompt)
          await onAccessRequired(DriverLocationStatus.serviceDisabled);
        return;
      }
      if (_stopped) return;
      _hasLocationAccess = true;
      // Subscribe before requesting the first fix: a timeout must never prevent
      // subsequent GPS fixes or the Android foreground service from running.
      await _activityTask;
      if (_stopped || !_hasLocationAccess) return;
      if (_positions == null) {
        onStatus(DriverLocationStatus.locating);
        _subscribe();
      }
    } on Object {
      if (!_stopped) {
        onStatus(DriverLocationStatus.unavailable);
        _scheduleStreamRetry();
      }
    }
  }

  Future<void> _requestFix() {
    return _fixTask ??= (() async {
      final lastSample = _lastDeliveredAt;
      try {
        final settings =
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android
                ? AndroidSettings(
                    accuracy: LocationAccuracy.high,
                    forceLocationManager: _forceLocationManager,
                    timeLimit: const Duration(seconds: 12),
                  )
                : const LocationSettings(
                    accuracy: LocationAccuracy.high,
                    timeLimit: Duration(seconds: 12),
                  );
        final position =
            await _geolocator.getCurrentPosition(locationSettings: settings);
        // Network uploads must never hold the access check or next GPS fix open.
        unawaited(_deliver(position));
      } on Object {
        if (!_stopped &&
            _hasLocationAccess &&
            lastSample == _lastDeliveredAt &&
            !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.android &&
            !_forceLocationManager) {
          _forceLocationManager = true;
          await _restartStream();
        }
      }
    })()
        .whenComplete(() {
      _fixTask = null;
    });
  }

  void _scheduleStreamRetry() {
    if (_stopped || _streamRetry?.isActive == true) return;
    _streamRetry = Timer(const Duration(seconds: 1), () {
      if (!_stopped) unawaited(refresh(forceFix: false));
    });
  }

  void _subscribe() {
    if (_positions != null || _stopped) return;
    late final StreamSubscription<Position> subscription;
    subscription = _geolocator
        .getPositionStream(locationSettings: _streamSettings())
        .listen((position) {
      if (identical(_positions, subscription)) unawaited(_deliver(position));
    }, onError: (Object error) {
      if (!identical(_positions, subscription)) return;
      unawaited(subscription.cancel());
      _positions = null;
      if (!_stopped) {
        if (error is! PermissionDeniedException &&
            error is! LocationServiceDisabledException) {
          _forceLocationManager = true;
        }
        onStatus(DriverLocationStatus.unavailable);
        _scheduleStreamRetry();
      }
    }, onDone: () {
      if (!identical(_positions, subscription)) return;
      _positions = null;
      if (!_stopped) {
        onStatus(DriverLocationStatus.unavailable);
        _scheduleStreamRetry();
      }
    });
    _positions = subscription;
  }

  Future<void> _deliver(Position position) async {
    if (_stopped || !_hasLocationAccess) return;
    final age = DateTime.now().toUtc().difference(position.timestamp.toUtc());
    if (age > const Duration(seconds: 30) || age < const Duration(seconds: -5))
      return;
    if (!position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude.abs() > 90 ||
        position.longitude.abs() > 180 ||
        !position.accuracy.isFinite ||
        position.accuracy <= 0) return;
    if (_lastDeliveredAt != null &&
        !position.timestamp.isAfter(_lastDeliveredAt!)) return;
    _lastDeliveredAt = position.timestamp;
    onStatus(DriverLocationStatus.tracking);
    _sinceSample.reset();
    try {
      await onPosition(position);
    } on Object {
      // A failed upload must not close the GPS stream.
    }
  }

  LocationSettings _streamSettings() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: _interval,
        forceLocationManager: _forceLocationManager,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'تتبع موقع سائق يمن درايف',
          notificationText: 'موقعك يتحدث تلقائياً أثناء تشغيل تطبيق السائق.',
          notificationChannelName: 'تتبع موقع السائق',
          notificationIcon: AndroidResource(name: 'ic_stat_yemendrive'),
          color: Color(0xFF174C43),
          setOngoing: true,
          enableWakeLock: true,
        ),
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _streamRetry?.cancel();
    final services = _services;
    final positions = _positions;
    _services = null;
    _positions = null;
    await Future.wait<void>([
      if (services != null) services.cancel(),
      if (positions != null) positions.cancel(),
    ]);
  }
}
