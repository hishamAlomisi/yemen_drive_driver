import 'dart:async';

import 'package:flutter/foundation.dart';
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
    GeolocatorPlatform? geolocator,
  }) : _geolocator = geolocator ?? GeolocatorPlatform.instance;

  final Future<void> Function(Position) onPosition;
  final void Function(DriverLocationStatus) onStatus;
  final Future<void> Function(DriverLocationStatus) onAccessRequired;
  final GeolocatorPlatform _geolocator;
  StreamSubscription<Position>? _positions;
  StreamSubscription<ServiceStatus>? _services;
  Timer? _timer;
  Future<void>? _refreshTask;
  bool _stopped = false;
  bool _started = false;

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
      unawaited(refresh());
    });
    await refresh(prompt: true);
  }

  Future<void> refresh({bool prompt = false}) {
    if (_stopped) return Future<void>.value();
    final pending = _refreshTask;
    if (pending != null) return pending;
    final task = _refresh(prompt);
    _refreshTask = task;
    return task.whenComplete(() {
      if (identical(_refreshTask, task)) _refreshTask = null;
    });
  }

  Future<void> _refresh(bool prompt) async {
    try {
      var permission = await _geolocator.checkPermission();
      if (permission == LocationPermission.denied && prompt) {
        permission = await _geolocator.requestPermission();
      }
      if (_stopped) return;
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
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
        await _positions?.cancel();
        _positions = null;
        if (_stopped) return;
        onStatus(DriverLocationStatus.serviceDisabled);
        if (prompt)
          await onAccessRequired(DriverLocationStatus.serviceDisabled);
        return;
      }
      if (_stopped) return;
      // Subscribe before requesting the first fix: a timeout must never prevent
      // subsequent GPS fixes or the Android foreground service from running.
      if (_positions == null) {
        onStatus(DriverLocationStatus.locating);
        _positions = _geolocator
            .getPositionStream(
          locationSettings: _streamSettings(),
        )
            .listen((position) => unawaited(_deliver(position)),
                onError: (Object _) {
          unawaited(_positions?.cancel());
          _positions = null;
          if (!_stopped) onStatus(DriverLocationStatus.unavailable);
        });
      }
      try {
        final position = await _geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 12),
          ),
        );
        await _deliver(position);
      } on Object {
        // The stream stays active and the next periodic read retries the fix.
      }
    } on Object {
      if (!_stopped) onStatus(DriverLocationStatus.unavailable);
    }
  }

  Future<void> _deliver(Position position) async {
    if (_stopped) return;
    final age = DateTime.now().toUtc().difference(position.timestamp.toUtc());
    if (age > const Duration(seconds: 30) || age < const Duration(seconds: -5))
      return;
    onStatus(DriverLocationStatus.tracking);
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
        intervalDuration: const Duration(seconds: 3),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'تتبع موقع سائق يمن درايف',
          notificationText: 'موقعك يتحدث تلقائياً أثناء تشغيل تطبيق السائق.',
          notificationChannelName: 'تتبع موقع السائق',
          notificationIcon: AndroidResource(name: 'ic_stat_yemendrive'),
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
