import 'dart:async';
import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:yemen_drive_driver/core/services/driver_location_tracker.dart';

class _Gps extends GeolocatorPlatform {
  LocationPermission permission = LocationPermission.whileInUse;
  bool enabled = true;
  bool failRead = false;
  int reads = 0;
  int requests = 0;
  int streams = 0;
  Completer<Position>? pendingFix;
  final streamSettings = <LocationSettings?>[];
  var positions = StreamController<Position>.broadcast();
  final services = StreamController<ServiceStatus>.broadcast();

  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return permission = LocationPermission.whileInUse;
  }

  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Stream<ServiceStatus> getServiceStatusStream() => services.stream;
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    streams++;
    streamSettings.add(locationSettings);
    return positions.stream;
  }

  @override
  Future<Position> getCurrentPosition(
      {LocationSettings? locationSettings}) async {
    reads++;
    if (pendingFix != null) return pendingFix!.future;
    if (failRead) throw TimeoutException('No initial GPS fix');
    return fix();
  }

  Future<void> close() async {
    await positions.close();
    await services.close();
  }
}

Position fix({DateTime? timestamp}) => Position(
      latitude: 15.36,
      longitude: 44.19,
      timestamp: timestamp ?? DateTime.now(),
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  late _Gps gps;
  late DriverLocationTracker tracker;
  late List<Position> delivered;
  late List<DriverLocationStatus> prompts;
  setUp(() {
    gps = _Gps();
    delivered = [];
    prompts = [];
    tracker = DriverLocationTracker(
      geolocator: gps,
      onPosition: (p) async => delivered.add(p),
      onStatus: (_) {},
      onAccessRequired: (status) async => prompts.add(status),
    );
  });
  tearDown(() async {
    await tracker.stop();
    await gps.close();
  });

  test('requests permission on launch and captures without a manual action',
      () async {
    gps.permission = LocationPermission.denied;
    await tracker.start();
    expect(gps.requests, 1);
    expect(delivered, hasLength(1));
    expect(gps.positions.hasListener, true);
  });
  test('a failed first fix keeps the stream and accepts the next device fix',
      () async {
    gps.failRead = true;
    await tracker.start();
    expect(gps.positions.hasListener, true);
    gps.positions.add(fix());
    await Future<void>.delayed(Duration.zero);
    expect(delivered, hasLength(1));
  });
  test(
      'disabled GPS prompts and starts automatically when the device enables it',
      () async {
    gps.enabled = false;
    await tracker.start();
    expect(prompts, [DriverLocationStatus.serviceDisabled]);
    expect(gps.streams, 0);
    gps.enabled = true;
    gps.services.add(ServiceStatus.enabled);
    await Future<void>.delayed(Duration.zero);
    expect(delivered, hasLength(1));
    expect(gps.positions.hasListener, true);
  });
  test(
      'permanent denial opens settings once and recovers after a permission change',
      () async {
    gps.permission = LocationPermission.deniedForever;
    await tracker.start();
    await tracker.refresh();
    expect(gps.requests, 0);
    expect(prompts, [DriverLocationStatus.permissionDeniedForever]);
    gps.permission = LocationPermission.whileInUse;
    await tracker.refresh();
    expect(delivered, hasLength(1));
  });
  test(
      'stationary drivers get periodic fresh fixes and stopping cancels updates',
      () {
    fakeAsync((clock) {
      final periodicGps = _Gps();
      final periodicTracker = DriverLocationTracker(
        geolocator: periodicGps,
        onPosition: (p) async => delivered.add(p),
        onStatus: (_) {},
        onAccessRequired: (status) async => prompts.add(status),
      );
      unawaited(periodicTracker.start());
      clock.flushMicrotasks();
      final before = periodicGps.reads;
      clock.elapse(const Duration(seconds: 10));
      clock.flushMicrotasks();
      expect(periodicGps.reads, greaterThan(before));
      unawaited(periodicTracker.stop());
      clock.flushMicrotasks();
      final stoppedAt = periodicGps.reads;
      clock.elapse(const Duration(seconds: 30));
      clock.flushMicrotasks();
      expect(periodicGps.reads, stoppedAt);
      expect(periodicGps.positions.hasListener, false);
      unawaited(periodicGps.close());
      clock.flushMicrotasks();
    });
  });
  test('stale GPS cannot be replayed as a current location', () async {
    gps.failRead = true;
    await tracker.start();
    gps.positions.add(
        fix(timestamp: DateTime.now().subtract(const Duration(minutes: 1))));
    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);
  });

  test(
      'a pending fix does not delay revoking access or publish after GPS is disabled',
      () async {
    gps.pendingFix = Completer<Position>();
    final starting = tracker.start();
    await Future<void>.delayed(Duration.zero);
    expect(gps.positions.hasListener, isTrue);
    gps.enabled = false;
    await tracker.refresh(forceFix: false);
    expect(gps.positions.hasListener, isFalse);
    gps.pendingFix!.complete(fix());
    await starting;
    expect(delivered, isEmpty);
  });

  test('an upload does not delay a new permission check', () async {
    await tracker.stop();
    final uploading = Completer<void>();
    final release = Completer<void>();
    tracker = DriverLocationTracker(
        geolocator: gps,
        onPosition: (_) async {
          uploading.complete();
          await release.future;
        },
        onStatus: (_) {},
        onAccessRequired: (_) async {});
    final starting = tracker.start();
    await uploading.future;
    gps.permission = LocationPermission.deniedForever;
    await tracker.refresh(forceFix: false);
    expect(gps.positions.hasListener, isFalse);
    release.complete();
    await starting;
  });

  test('duplicate and out-of-order native samples cannot refresh tracking',
      () async {
    gps.failRead = true;
    await tracker.start();
    final current = fix();
    gps.positions.add(current);
    gps.positions.add(current);
    gps.positions.add(
        fix(timestamp: current.timestamp.subtract(const Duration(seconds: 1))));
    await Future<void>.delayed(Duration.zero);
    expect(delivered, [current]);
  });

  test(
      'a failing Android stream automatically restarts with the location manager',
      () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    fakeAsync((clock) {
      unawaited(tracker.start());
      clock.flushMicrotasks();
      expect(
          (gps.streamSettings.single as AndroidSettings).forceLocationManager,
          isFalse);
      gps.positions.addError(StateError('Fused provider failed'));
      clock.flushMicrotasks();
      expect(gps.positions.hasListener, isFalse);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(gps.positions.hasListener, isTrue);
      expect((gps.streamSettings.last as AndroidSettings).forceLocationManager,
          isTrue);
      unawaited(tracker.stop());
      clock.flushMicrotasks();
    });
  });

  test('a completed native stream is subscribed again on the next refresh',
      () async {
    await tracker.start();
    final old = gps.positions;
    gps.positions = StreamController<Position>.broadcast();
    await old.close();
    await tracker.refresh();
    expect(gps.streams, 2);
    expect(gps.positions.hasListener, isTrue);
    final next = fix(
        timestamp:
            delivered.last.timestamp.add(const Duration(milliseconds: 1)));
    gps.positions.add(next);
    await Future<void>.delayed(Duration.zero);
    expect(delivered.last, same(next));
  });

  test(
      'opening a map accelerates the GPS stream while first-fix upload is slow',
      () async {
    await tracker.stop();
    final uploadStarted = Completer<void>();
    final releaseUpload = Completer<void>();
    tracker = DriverLocationTracker(
        adaptive: true,
        geolocator: gps,
        onPosition: (_) async {
          if (!uploadStarted.isCompleted) uploadStarted.complete();
          await releaseUpload.future;
        },
        onStatus: (_) {},
        onAccessRequired: (_) async {});
    final starting = tracker.start();
    await uploadStarted.future;
    expect(gps.streams, 1);
    await tracker.setActivity(
        activeRide: true, viewed: true, moving: true, available: true);
    expect(gps.streams, 2);
    expect(gps.positions.hasListener, true);
    expect(tracker.requestedInterval, const Duration(seconds: 1));
    releaseUpload.complete();
    await starting;
  });

  test(
      'adaptive mode does not request a redundant periodic fix while samples arrive',
      () {
    fakeAsync((clock) {
      final adaptiveGps = _Gps();
      final adaptiveTracker = DriverLocationTracker(
          adaptive: true,
          geolocator: adaptiveGps,
          onPosition: (_) async {},
          onStatus: (_) {},
          onAccessRequired: (_) async {});
      unawaited(adaptiveTracker.start());
      clock.flushMicrotasks();
      expect(adaptiveGps.reads, 1);
      adaptiveGps.positions.add(fix());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 10));
      clock.flushMicrotasks();
      expect(adaptiveGps.reads, 1);
      unawaited(adaptiveTracker.stop());
      clock.flushMicrotasks();
      unawaited(adaptiveGps.close());
      clock.flushMicrotasks();
    });
  });
}
