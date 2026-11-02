import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/realtime/tracking_hub_service.dart';
import 'package:yemen_drive_driver/core/services/auth_session_service.dart';
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
  @override
  Future<DriverSnapshot> load(int? userId) async {
    reads++;
    return DriverSnapshot(
        profile: const {'userId': 42}, rides: List.of(latest));
  }

  @override
  Future<List<Map<String, Object?>>> notifications() async => [];
  @override
  Future<Map<String, Object?>> getRide(int rideId) async =>
      latest.singleWhere((r) => r['id'] == rideId);
  @override
  Future<bool> isRequestAvailable(int rideId) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Hub extends TrackingHubService {
  _Hub() : super(SecureStorageService());
  final messages = StreamController<TrackingHubEvent>.broadcast();
  @override
  Stream<TrackingHubEvent> get events => messages.stream;
  @override
  Future<void> setUserEventListening(Object owner, bool listen) async {}
  @override
  Future<void> setRideSubscriptions(Iterable<int> rideIds) async {}
}

void main() {
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
    await tester.pump();
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
}
