import 'dart:async';
import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:yemen_drive_driver/core/services/driver_location_tracker.dart';

class _Gps extends GeolocatorPlatform {
  LocationPermission permission = LocationPermission.whileInUse;
  bool enabled = true;
  bool failRead = false;
  int reads = 0;
  int requests = 0;
  int streams = 0;
  final positions = StreamController<Position>.broadcast();
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
    return positions.stream;
  }

  @override
  Future<Position> getCurrentPosition(
      {LocationSettings? locationSettings}) async {
    reads++;
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
}
