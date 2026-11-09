import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    as maps;

import '../lib/core/network/api_client.dart';
import '../lib/core/network/api_models.dart';
import '../lib/core/realtime/tracking_hub_service.dart';
import '../lib/core/services/auth_session_service.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/features/driver/controllers/driver_controller.dart';
import '../lib/features/driver/models/driver_models.dart';
import '../lib/features/driver/repositories/driver_repository.dart';
import '../lib/features/driver/views/driver_navigation_view.dart';
import '../lib/shared/widgets/app_google_map.dart';

const _ride = <String, Object?>{
  'id': 7,
  'driverId': 42,
  'status': 4,
  'pickupLatitude': 15.36,
  'pickupLongitude': 44.19,
  'destinationLatitude': 15.4,
  'destinationLongitude': 44.22,
  'destinationAvailable': true,
  'routeVersion': 0,
  'paymentMethodCode': 'cash',
  'passengerBoardedAtUtc': 'confirmed',
};

class _Repository implements DriverRepository {
  Map<String, Object?> latest = Map.of(_ride);
  @override
  Future<DriverSnapshot> load(int? userId) async =>
      DriverSnapshot(profile: const {'userId': 42}, rides: [Map.of(latest)]);
  @override
  Future<List<Map<String, Object?>>> notifications() async => [];
  @override
  Future<Map<String, Object?>> getRide(int rideId) async => Map.of(latest);
  @override
  Future<void> updateRideStatus(
      {required int rideId,
      required int status,
      bool? customerPaymentEnabled,
      bool confirmPassengerBoarding = false}) async {
    latest = {...latest, 'status': status};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Hub extends TrackingHubService {
  _Hub() : super(SecureStorageService());
  final sent = <Map<String, Object?>>[];
  bool accepts = true;
  Completer<bool>? pending;
  @override
  Future<void> setUserEventListening(Object owner, bool listen) async {}
  @override
  Future<void> setRideSubscriptions(Iterable<int> rideIds) async {}
  @override
  Future<bool> publishDriverLocation(Map<String, Object?> payload) async {
    sent.add(payload);
    final wait = pending;
    pending = null;
    if (wait != null) return wait.future;
    return accepts;
  }
}

class _Gps extends GeolocatorPlatform {
  final positions = StreamController<Position>.broadcast();
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Stream<ServiceStatus> getServiceStatusStream() => const Stream.empty();
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      positions.stream;
  @override
  Future<Position> getCurrentPosition(
          {LocationSettings? locationSettings}) async =>
      // These controller tests supply actual fixes through the stream. Native
      // fix failure and provider replacement are covered by the tracker tests.
      Completer<Position>().future;
}

Position _fix(double latitude,
        {double accuracy = 10,
        DateTime? timestamp,
        double heading = 90,
        double speed = 4}) =>
    Position(
        latitude: latitude,
        longitude: 44.19,
        timestamp: timestamp ?? DateTime.now(),
        accuracy: accuracy,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: heading,
        headingAccuracy: 1,
        speed: speed,
        speedAccuracy: 1);

class _MapPlatform extends maps.GoogleMapsFlutterPlatform {
  @override
  Widget buildViewWithConfiguration(
          int creationId, ValueChanged<int> onPlatformViewCreated,
          {required maps.MapWidgetConfiguration widgetConfiguration,
          maps.MapConfiguration mapConfiguration =
              const maps.MapConfiguration(),
          maps.MapObjects mapObjects = const maps.MapObjects()}) =>
      const SizedBox();
}

class _Api extends ApiClient {
  _Api() : super(SecureStorageService());
  @override
  Future<ApiResult<T>> execute<T>(
          {required String model,
          required String operation,
          Object? data,
          T Function(Object?)? parse}) async =>
      ApiFailure<T>(
          const ApiProblemDetails(title: 'offline route', status: 503));
}

class _NavigationController extends DriverController {
  _NavigationController(super.repository, super.session);
  final destinations = <bool>[];
  @override
  void onReady() {}
  @override
  Future<void> openPickupNavigation(Map<String, Object?> ride) async =>
      destinations.add(false);
  @override
  Future<void> openDestinationNavigation(Map<String, Object?> ride) async =>
      destinations.add(true);
}

AuthSessionService _session() {
  final storage = SecureStorageService();
  return AuthSessionService(storage, ApiClient(storage))
    ..currentUserId.value = 42
    ..isAuthenticated.value = true;
}

void main() {
  tearDown(Get.reset);
  testWidgets(
      'local GPS keeps moving during failed uploads and approximate fixes are not published',
      (tester) async {
    final original = GeolocatorPlatform.instance;
    final gps = _Gps();
    GeolocatorPlatform.instance = gps;
    addTearDown(() => GeolocatorPlatform.instance = original);
    final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
    final controller = Get.put(DriverController(_Repository(), _session()));
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    await tester.pump();
    final first = _fix(15.36, accuracy: 150);
    gps.positions.add(first);
    await tester.pump();
    expect(controller.currentPosition.value, same(first));
    expect(hub.sent, isEmpty);
    hub.accepts = false;
    final next = _fix(15.361);
    gps.positions.add(next);
    await tester.pump();
    expect(controller.currentPosition.value, same(next));
    expect(hub.sent.single['rideId'], 7);
    expect(controller.lastLocationSentAt.value, isNull);
    final stale = _fix(15.0,
        timestamp: next.timestamp.subtract(const Duration(seconds: 1)));
    gps.positions.add(stale);
    await tester.pump();
    expect(controller.currentPosition.value, same(next));
    Get.delete<DriverController>();
    await tester.pump();
    await gps.positions.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'failed GPS retries only the latest real sample without another GPS event',
      (tester) async {
    final original = GeolocatorPlatform.instance;
    final gps = _Gps();
    GeolocatorPlatform.instance = gps;
    addTearDown(() => GeolocatorPlatform.instance = original);
    final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
    hub.accepts = false;
    final controller = Get.put(DriverController(_Repository(), _session()));
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    await tester.pump();
    gps.positions.add(_fix(15.36,
        timestamp: DateTime.now().subtract(const Duration(seconds: 1))));
    await tester.pump();
    final latest = _fix(15.361, heading: double.nan, speed: -1);
    gps.positions.add(latest);
    await tester.pump();
    expect(hub.sent, hasLength(1));
    expect(controller.currentPosition.value, same(latest));
    hub.accepts = true;
    await tester.pump(const Duration(seconds: 3));
    expect(hub.sent, hasLength(2));
    expect(hub.sent.last, containsPair('latitude', latest.latitude));
    expect(hub.sent.last['observedAtUtc'],
        latest.timestamp.toUtc().toIso8601String());
    expect(hub.sent.last['bearing'], isNull);
    expect(hub.sent.last['speed'], isNull);
    expect(controller.lastLocationSentAt.value, isNotNull);
    await tester.pump(const Duration(seconds: 3));
    expect(hub.sent, hasLength(2));
    Get.delete<DriverController>();
    await tester.pump();
    await gps.positions.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('slow uploads coalesce GPS without freezing local movement',
      (tester) async {
    final original = GeolocatorPlatform.instance;
    final gps = _Gps();
    GeolocatorPlatform.instance = gps;
    addTearDown(() => GeolocatorPlatform.instance = original);
    final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
    final pending = Completer<bool>();
    hub.pending = pending;
    final controller = Get.put(DriverController(_Repository(), _session()));
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    await tester.pump();
    final now = DateTime.now();
    gps.positions
        .add(_fix(15.36, timestamp: now.subtract(const Duration(seconds: 2))));
    await tester.pump();
    gps.positions
        .add(_fix(15.361, timestamp: now.subtract(const Duration(seconds: 1))));
    final latest = _fix(15.362, timestamp: now);
    gps.positions.add(latest);
    await tester.pump();
    expect(controller.currentPosition.value, same(latest));
    expect(hub.sent, hasLength(1));
    pending.complete(true);
    await tester.pump();
    expect(hub.sent.map((p) => p['latitude']), [15.36, 15.362]);
    Get.delete<DriverController>();
    await tester.pump();
    await gps.positions.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed sample cannot be reassigned after a ride ends',
      (tester) async {
    final original = GeolocatorPlatform.instance;
    final gps = _Gps();
    GeolocatorPlatform.instance = gps;
    addTearDown(() => GeolocatorPlatform.instance = original);
    final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
    hub.accepts = false;
    final repository = _Repository();
    final controller = Get.put(DriverController(repository, _session()));
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    await tester.pump();
    gps.positions.add(_fix(15.36));
    await tester.pump();
    repository.latest = {..._ride, 'status': 6};
    await controller.refreshRide(7);
    hub.accepts = true;
    await tester.pump(const Duration(seconds: 3));
    expect(hub.sent, hasLength(1));
    final idle = _fix(15.361);
    gps.positions.add(idle);
    await tester.pump();
    expect(hub.sent, hasLength(2));
    expect(hub.sent.last['rideId'], isNull);
    expect(hub.sent.last['latitude'], idle.latitude);
    Get.delete<DriverController>();
    await tester.pump();
    await gps.positions.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a late upload acknowledgement cannot update another account',
      (tester) async {
    final original = GeolocatorPlatform.instance;
    final gps = _Gps();
    GeolocatorPlatform.instance = gps;
    addTearDown(() => GeolocatorPlatform.instance = original);
    final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
    final pending = Completer<bool>();
    hub.pending = pending;
    final session = _session();
    final controller = Get.put(DriverController(_Repository(), session));
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    await tester.pump();
    gps.positions.add(_fix(15.36));
    await tester.pump();
    session.currentUserId.value = 99;
    pending.complete(true);
    await tester.pump();
    expect(controller.lastLocationSentAt.value, isNull);
    expect(hub.sent, hasLength(1));
    Get.delete<DriverController>();
    await tester.pump();
    await gps.positions.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'successful heading and trip start open their respective live maps',
      (tester) async {
    final repository = _Repository();
    final controller =
        Get.put<DriverController>(_NavigationController(repository, _session()))
            as _NavigationController;
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    await controller.updateStatus(_ride, 4, 'heading');
    await tester.pump();
    expect(controller.destinations, [false]);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await controller.updateStatus(_ride, 5, 'started');
    await tester.pump();
    expect(controller.destinations, [false, true]);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'navigation waits for a real driver point then changes marker and target when trip starts',
      (tester) async {
    final previousMaps = maps.GoogleMapsFlutterPlatform.instance;
    maps.GoogleMapsFlutterPlatform.instance = _MapPlatform();
    addTearDown(() => maps.GoogleMapsFlutterPlatform.instance = previousMaps);
    final repository = _Repository();
    final controller = Get.put<DriverController>(
        _NavigationController(repository, _session()));
    controller.rides.assignAll([Map.of(_ride)]);
    controller.passengerLocationsByRideId[7] = PassengerLocationUpdate(
        latitude: 15.365, longitude: 44.19, observedAtUtc: DateTime.now());
    Get.put<ApiClient>(_Api());
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    unawaited(Get.to<void>(() => const DriverNavigationView(), arguments: {
      'rideId': 7,
      'destinationLatitude': 15.36,
      'destinationLongitude': 44.19,
      'title': 'الطريق إلى الراكب',
      'followsDestination': false,
    }));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    AppGoogleMap map() =>
        tester.widget<AppGoogleMap>(find.byType(AppGoogleMap));
    expect(map().markers.where((m) => m.markerId.value == 'driver'), isEmpty);
    expect(map().initialTarget, const LatLng(15.36, 44.19));
    expect(map().myLocationEnabled, isFalse,
        reason: 'The custom car replaces the overlapping native GPS dot.');
    expect(map().smoothFollow, isTrue);
    expect(map().pauseOnUserInteraction, isTrue);
    expect(map().markers.any((m) => m.markerId.value == 'passenger-7'), isTrue);
    final firstTime = DateTime.now();
    controller.currentPosition.value =
        _fix(15.361, heading: 350, timestamp: firstTime);
    await tester.pump();
    expect(
        map().markers.singleWhere((m) => m.markerId.value == 'driver').position,
        const LatLng(15.361, 44.19));
    expect(map().followTarget, const LatLng(15.361, 44.19));
    controller.currentPosition.value = _fix(15.362,
        heading: 10, timestamp: firstTime.add(const Duration(seconds: 1)));
    await tester.pump();
    final unchangedPanel = tester.widget<Text>(find.textContaining(' كم ·'));
    await tester.pump(const Duration(milliseconds: 500));
    final midway =
        map().markers.singleWhere((m) => m.markerId.value == 'driver');
    expect(
        tester.widget<Text>(find.textContaining(' كم ·')), same(unchangedPanel),
        reason: 'GPS interpolation updates only the map, not the trip panels.');
    expect(midway.position.latitude, closeTo(15.3615, .00001));
    expect(map().followTarget, midway.position,
        reason: 'Camera follows the displayed marker rather than the raw fix.');
    expect(midway.rotation < 2 || midway.rotation > 358, isTrue,
        reason: 'Heading crosses north by the shortest arc.');
    await tester.pump(const Duration(milliseconds: 500));
    expect(
        map().markers.singleWhere((m) => m.markerId.value == 'driver').position,
        const LatLng(15.362, 44.19));
    await tester.pump(const Duration(seconds: 2));
    expect(
        map().markers.singleWhere((m) => m.markerId.value == 'driver').position,
        const LatLng(15.362, 44.19),
        reason: 'No motion is extrapolated after the last fix.');
    map().onUserInteraction!();
    await tester.pump();
    expect(find.byTooltip('متابعة موقعك'), findsOneWidget);
    final previousFollow = map().followRequestId;
    await tester.tap(find.byKey(const ValueKey('driver-recenter')));
    await tester.pump();
    expect(map().followRequestId, previousFollow + 1);
    expect(find.byTooltip('توسيط موقعك'), findsOneWidget);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    final approach =
        map().markers.singleWhere((m) => m.markerId.value == 'driver').icon;
    repository.latest = {
      ..._ride,
      'status': 5,
      'startedAtUtc': DateTime.now().toIso8601String()
    };
    await controller.refreshRide(7);
    await tester.pump();
    expect(
        map().markers.singleWhere((m) => m.markerId.value == 'target').position,
        const LatLng(15.4, 44.22));
    final driver =
        map().markers.singleWhere((m) => m.markerId.value == 'driver');
    expect(driver.icon, isNot(same(approach)));
    expect(driver.infoWindow.title, contains('الرحلة جارية'));
    expect(map().markers.any((m) => m.markerId.value == 'passenger-7'), isFalse,
        reason: 'An onboard rider must not appear as another vehicle marker.');
    expect(find.text('تتبع الرحلة إلى الوجهة'), findsOneWidget);
    Get.back<void>();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
