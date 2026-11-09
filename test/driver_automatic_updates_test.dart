import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/realtime/tracking_hub_service.dart';
import 'package:yemen_drive_driver/core/services/auth_session_service.dart';
import 'package:yemen_drive_driver/core/services/startup_connection_service.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';
import 'package:yemen_drive_driver/features/driver/controllers/driver_controller.dart';
import 'package:yemen_drive_driver/features/driver/models/driver_models.dart';
import 'package:yemen_drive_driver/features/driver/repositories/driver_repository.dart';

class _Gps extends GeolocatorPlatform {
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Stream<ServiceStatus> getServiceStatusStream() => const Stream.empty();
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      const Stream.empty();
  @override
  Future<Position> getCurrentPosition(
          {LocationSettings? locationSettings}) async =>
      throw TimeoutException('GPS unrelated to this test');
}

class _Repository implements DriverRepository {
  final latest = <Map<String, Object?>>[];
  int reads = 0;
  int writes = 0;
  int detailReads = 0;
  Completer<DriverSnapshot>? nextLoad;
  @override
  Future<void> updateRideStatus(
      {required int rideId,
      required int status,
      bool? customerPaymentEnabled,
      bool confirmPassengerBoarding = false}) async {
    writes++;
  }

  @override
  Future<DriverSnapshot> load(int? userId) async {
    reads++;
    final pending = nextLoad;
    nextLoad = null;
    if (pending != null) return pending.future;
    return DriverSnapshot(
        profile: const {'userId': 42}, rides: List.of(latest));
  }

  @override
  Future<List<Map<String, Object?>>> notifications() async => [];
  @override
  Future<Map<String, Object?>> getRide(int rideId) async {
    detailReads++;
    return latest.singleWhere((r) => r['id'] == rideId);
  }

  @override
  Future<bool> isRequestAvailable(int rideId) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Hub extends TrackingHubService {
  _Hub() : super(SecureStorageService());
  final messages = StreamController<TrackingHubEvent>.broadcast();
  int apiRecoveries = 0;
  @override
  Future<void> reconnectAfterApiRecovery() async {
    apiRecoveries++;
  }

  @override
  Stream<TrackingHubEvent> get events => messages.stream;
  @override
  Future<void> setUserEventListening(Object owner, bool listen) async {}
  @override
  Future<void> setRideSubscriptions(Iterable<int> rideIds) async {}
}

class _RecoveryConnection extends StartupConnectionService {
  final recoveryEvents = StreamController<void>.broadcast();
  @override
  Stream<void> get recovered => recoveryEvents.stream;
  void recover() {
    runtimeUnavailable.value = false;
    isVerified = true;
    recoveryEvents.add(null);
  }

  @override
  void onClose() {
    unawaited(recoveryEvents.close());
    super.onClose();
  }
}

void main() {
  testWidgets(
      'API recovery refreshes the active ride and Hub without repeating user commands',
      (tester) async {
    Get.testMode = true;
    final originalGps = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = _Gps();
    final connection = Get.put<StartupConnectionService>(_RecoveryConnection())
        as _RecoveryConnection;
    final repository = _Repository()
      ..latest.add({'id': 7, 'status': 4, 'driverId': 42});
    final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
    final storage = SecureStorageService();
    final session = AuthSessionService(storage, ApiClient(storage))
      ..currentUserId.value = 42
      ..isAuthenticated.value = true;
    final controller = Get.put(DriverController(repository, session));
    try {
      await tester.pumpWidget(const GetMaterialApp(home: SizedBox()));
      await tester.pump();
      await tester.pump();
      expect(controller.rides.single['status'], 4);
      final readsBefore = repository.reads;
      connection.runtimeUnavailable.value = true;
      repository.latest[0] = {'id': 7, 'status': 5, 'driverId': 42};
      expect(controller.rides.single['status'], 4);
      connection.recover();
      await tester.pump();
      await tester.pump();
      expect(repository.reads, greaterThan(readsBefore));
      expect(controller.rides.single['status'], 5);
      expect(session.currentUserId.value, 42);
      expect(session.isAuthenticated.value, true);
      expect(hub.apiRecoveries, 1);
      expect(repository.writes, 0);
    } finally {
      Get.delete<DriverController>();
      await tester.pumpWidget(const SizedBox());
      Get.reset();
      await hub.messages.close();
      GeolocatorPlatform.instance = originalGps;
    }
  });

  testWidgets(
      'requests appear on periodic sync; arrival events refresh the assigned ride; closing stops sync',
      (tester) async {
    Get.testMode = true;
    final originalGps = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = _Gps();
    final repository = _Repository();
    final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
    final storage = SecureStorageService();
    final session = AuthSessionService(storage, ApiClient(storage));
    session.currentUserId.value = 42;
    session.isAuthenticated.value = true;
    final controller =
        Get.put<DriverController>(DriverController(repository, session));
    await tester.pumpWidget(const GetMaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pump();
    expect(controller.rides, isEmpty);
    repository.latest.add({'id': 7, 'status': 1, 'driverId': null});
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(controller.rides.single['id'], 7);
    repository.latest[0] = {
      'id': 7,
      'status': 9,
      'driverId': 42,
      'passengerBoardedAtUtc': 'confirmed'
    };
    hub.messages
        .add(const TrackingHubEvent('rideArrivalUpdated', {'rideId': 7}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(controller.rides.single['passengerBoardedAtUtc'], 'confirmed');
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    final pausedAt = repository.reads;
    await tester.pump(const Duration(seconds: 30));
    expect(repository.reads, pausedAt);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(repository.reads, greaterThan(pausedAt));
    Get.delete<DriverController>();
    await tester.pump();
    final stoppedAt = repository.reads;
    await tester.pump(const Duration(seconds: 30));
    expect(repository.reads, stoppedAt);
    await hub.messages.close();
    await tester.pumpWidget(const SizedBox());
    Get.reset();
    GeolocatorPlatform.instance = originalGps;
  });

  testWidgets(
      'slow snapshot never blocks passenger GPS or multiplies state reads',
      (tester) async {
    Get.testMode = true;
    final originalGps = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = _Gps();
    final repository = _Repository()
      ..latest.add({'id': 7, 'status': 4, 'driverId': 42, 'routeVersion': 1});
    final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
    final storage = SecureStorageService();
    final session = AuthSessionService(storage, ApiClient(storage))
      ..currentUserId.value = 42
      ..isAuthenticated.value = true;
    final controller = Get.put(DriverController(repository, session));
    try {
      await tester.pumpWidget(const GetMaterialApp(home: SizedBox()));
      await tester.pump();
      final pending = Completer<DriverSnapshot>();
      repository.nextLoad = pending;
      final loading = controller.load(showLoading: false);
      await tester.pump();
      final observed = DateTime.now().toUtc();
      for (var i = 0; i < 100; i++) {
        hub.messages.add(TrackingHubEvent('passengerLocationUpdated', {
          'rideId': 7,
          'latitude': 15 + i / 100000,
          'longitude': 44,
          'observedAtUtc':
              observed.add(Duration(microseconds: i)).toIso8601String(),
        }));
        hub.messages.add(
            const TrackingHubEvent('rideRouteChangeUpdated', {'rideId': 7}));
      }
      await tester.pump();
      expect(controller.passengerLocationForRide(7)!.latitude, 15.00099);
      expect(repository.detailReads, 0);
      repository.latest[0] = {...repository.latest[0], 'routeVersion': 2};
      pending.complete(DriverSnapshot(profile: const {
        'userId': 42
      }, rides: [
        {'id': 7, 'status': 4, 'driverId': 42, 'routeVersion': 1}
      ]));
      await loading;
      await tester.pump(const Duration(milliseconds: 110));
      expect(repository.detailReads, 1);
      expect(controller.rides.single['routeVersion'], 2);
      expect(repository.writes, 0);
    } finally {
      Get.delete<DriverController>();
      await tester.pumpWidget(const SizedBox());
      Get.reset();
      await hub.messages.close();
      GeolocatorPlatform.instance = originalGps;
    }
  });

  testWidgets('automatic fallback waits during outage or verified durable sync',
      (tester) async {
    Get.testMode = true;
    final originalGps = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = _Gps();
    final connection = Get.put<StartupConnectionService>(_RecoveryConnection());
    final repository = _Repository();
    final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
    final storage = SecureStorageService();
    final session = AuthSessionService(storage, ApiClient(storage))
      ..currentUserId.value = 42
      ..isAuthenticated.value = true;
    final controller = Get.put(DriverController(repository, session));
    try {
      await tester.pumpWidget(const GetMaterialApp(home: SizedBox()));
      await tester.pump();
      final initialReads = repository.reads;
      connection.runtimeUnavailable.value = true;
      await tester.pump(const Duration(seconds: 30));
      expect(repository.reads, initialReads);
      connection.runtimeUnavailable.value = false;
      expect(hub.stateChanges.covers(controller), isTrue);
      hub.supportsStateRecovery.value = true;
      hub.isStateSynchronized.value = true;
      await tester.pump(const Duration(seconds: 30));
      expect(repository.reads, initialReads);
      hub.isStateSynchronized.value = false;
      await tester.pump(const Duration(seconds: 15));
      expect(repository.reads, greaterThan(initialReads));
    } finally {
      Get.delete<DriverController>();
      await tester.pumpWidget(const SizedBox());
      Get.reset();
      await hub.messages.close();
      GeolocatorPlatform.instance = originalGps;
    }
  });
}
