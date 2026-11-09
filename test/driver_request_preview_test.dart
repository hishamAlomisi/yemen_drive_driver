import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    as maps;

import '../lib/core/network/api_client.dart';
import '../lib/core/services/auth_session_service.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/features/driver/controllers/driver_controller.dart';
import '../lib/features/driver/models/driver_request_route.dart';
import '../lib/features/driver/models/driver_models.dart';
import '../lib/features/driver/repositories/driver_repository.dart';
import '../lib/features/driver/repositories/route_repository.dart';
import '../lib/features/driver/views/driver_request_route_view.dart';
import '../lib/features/driver/widgets/driver_ride_card.dart';
import '../lib/shared/widgets/app_google_map.dart';

const _pickup = LatLng(15.36, 44.19);
const _destination = LatLng(15.4, 44.22);
const _origin = LatLng(15.35, 44.18);
const _request = <String, Object?>{
  'id': 91,
  'status': 1,
  'driverId': null,
  'pickupDisplayName': 'الانطلاق',
  'pickupLatitude': 15.36,
  'pickupLongitude': 44.19,
  'destinationDisplayName': 'الوجهة',
  'destinationLatitude': 15.4,
  'destinationLongitude': 44.22,
  'destinationAvailable': true,
  'customerPrice': 1000,
};

class _Routes implements RouteRepository {
  final calls = <({LatLng origin, LatLng destination})>[];
  bool fail = false;
  @override
  Future<DrivingRoute> getDrivingRoute({
    required LatLng origin,
    required LatLng destination,
    bool includeSteps = false,
  }) async {
    calls.add((origin: origin, destination: destination));
    if (fail) throw StateError('offline');
    return DrivingRoute(
      points: [origin, destination],
      distanceMeters: origin == _pickup ? 7200 : 1600,
      durationSeconds: origin == _pickup ? 780 : 240,
    );
  }
}

class _Repository implements DriverRepository {
  final items = <Map<String, Object?>>[];
  @override
  Future<List<Map<String, Object?>>> notifications() async => items;
  @override
  Future<DriverSnapshot> load(int? userId) async =>
      const DriverSnapshot(profile: null, rides: [_request]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Driver extends DriverController {
  _Driver(
      DriverRepository repository, AuthSessionService session, _Routes routes)
      : super(repository, session, routes: routes);
  int offers = 0;
  @override
  void onReady() {}
  @override
  Future<void> sendOffer(Map<String, Object?> ride) async => offers++;
}

class _MapPlatform extends maps.GoogleMapsFlutterPlatform {
  @override
  Widget buildViewWithConfiguration(
    int creationId,
    ValueChanged<int> onPlatformViewCreated, {
    required maps.MapWidgetConfiguration widgetConfiguration,
    maps.MapConfiguration mapConfiguration = const maps.MapConfiguration(),
    maps.MapObjects mapObjects = const maps.MapObjects(),
  }) =>
      const SizedBox();
}

Position _fix({DateTime? timestamp, double accuracy = 10}) => Position(
      latitude: _origin.latitude,
      longitude: _origin.longitude,
      timestamp: timestamp ?? DateTime.now(),
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  late _Routes routes;
  late _Driver driver;
  late _Repository repository;
  setUp(() {
    Get.testMode = true;
    routes = _Routes();
    final storage = SecureStorageService();
    final session = AuthSessionService(storage, ApiClient(storage))
      ..currentUserId.value = 42;
    repository = _Repository();
    driver = Get.put<DriverController>(_Driver(repository, session, routes))
        as _Driver;
    final original = maps.GoogleMapsFlutterPlatform.instance;
    maps.GoogleMapsFlutterPlatform.instance = _MapPlatform();
    addTearDown(() => maps.GoogleMapsFlutterPlatform.instance = original);
  });
  tearDown(Get.reset);

  Future<void> mount(WidgetTester tester, Map<String, Object?> ride) async {
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(child: DriverRideCard(ride: ride))),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('pending request previews both road legs before any offer',
      (tester) async {
    driver.currentPosition.value = _fix();
    await mount(tester, _request);
    expect(find.text('عرض مسار الرحلة'), findsOneWidget);
    expect(find.text('من الانطلاق إلى الوجهة: 7.2 كم بالطريق'), findsOneWidget);
    expect(find.text('من موقعك إلى الانطلاق: 1.6 كم بالطريق'), findsOneWidget);
    expect(
        routes.calls, contains((origin: _pickup, destination: _destination)));
    expect(routes.calls, contains((origin: _origin, destination: _pickup)));
    expect(driver.offers, 0);
    await tester.tap(find.text('عرض مسار الرحلة'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(DriverRequestRouteView), findsOneWidget);
    final map = tester.widget<AppGoogleMap>(find.byType(AppGoogleMap));
    expect(map.polylines, hasLength(2));
    expect(
        map.polylines
            .singleWhere((p) => p.polylineId.value == 'request-trip')
            .points,
        [_pickup, _destination]);
    expect(routes.calls, hasLength(2),
        reason: 'Preview shares cached card routes.');
    expect(driver.offers, 0);
    await tester.tap(find.text('العودة إلى الطلب وتقديم العرض'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('إرسال عرض'));
    await tester.pump();
    expect(driver.offers, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('trip preview works without driver GPS or submitted offer',
      (tester) async {
    await mount(tester, {..._request, 'status': 2});
    expect(find.textContaining('بانتظار موقعك الحالي'), findsOneWidget);
    expect(routes.calls, [(origin: _pickup, destination: _destination)]);
    await tester.tap(find.text('عرض مسار الرحلة'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final map = tester.widget<AppGoogleMap>(find.byType(AppGoogleMap));
    expect(map.polylines.single.points, [_pickup, _destination]);
    expect(map.markers, hasLength(2));
    expect(driver.offers, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('route failures leave offers available and retry explicitly',
      (tester) async {
    routes.fail = true;
    await mount(tester, _request);
    expect(find.textContaining('المسافة غير متاحة'), findsOneWidget);
    await tester.tap(find.text('إرسال عرض'));
    await tester.pump(const Duration(seconds: 30));
    expect(driver.offers, 1);
    expect(routes.calls, hasLength(1));
    routes.fail = false;
    await tester.tap(find.byTooltip('إعادة حساب المسافة'));
    await tester.pump();
    await tester.pump();
    expect(routes.calls, hasLength(2));
    expect(find.text('من الانطلاق إلى الوجهة: 7.2 كم بالطريق'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('missing destination is labelled without requesting a fake route',
      (tester) async {
    await mount(tester, {..._request, 'destinationLatitude': null});
    expect(find.textContaining('إحداثيات المسار غير متاحة'), findsOneWidget);
    expect(routes.calls, isEmpty);
    await tester.tap(find.text('إرسال عرض'));
    await tester.pump();
    expect(driver.offers, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed preview never substitutes a straight line for a road',
      (tester) async {
    routes.fail = true;
    await mount(tester, _request);
    await tester.tap(find.text('عرض مسار الرحلة'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final map = tester.widget<AppGoogleMap>(find.byType(AppGoogleMap));
    expect(map.polylines, isEmpty);
    expect(find.textContaining('تعذر تحميل مسار الطريق'), findsOneWidget);
    expect(routes.calls, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('route report raises one in-app alert across repeated refreshes',
      (tester) async {
    await mount(tester, _request);
    repository.items.add({
      'id': 7,
      'title': 'بلاغ انحراف عن مسار الرحلة',
      'body': 'أرسل الراكب بلاغاً عن انحراف بمسافة 28 متر باتجاه الشرق',
      'isRead': false,
      'dataJson': '{"action":"route_deviation_reported","rideId":91}',
    });
    await driver.load(showLoading: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('بلاغ انحراف عن مسار الرحلة'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('بلاغ انحراف عن مسار الرحلة'), findsNothing);
    await driver.load(showLoading: false);
    await tester.pump();
    expect(find.text('بلاغ انحراف عن مسار الرحلة'), findsNothing);
    expect(driver.notifications.single['isRead'], false);
    await tester.pumpWidget(const SizedBox());
  });

  test('current-position distance rejects stale, inaccurate and invalid fixes',
      () {
    final now = DateTime.utc(2026, 11, 5, 12);
    expect(currentRequestOrigin(_fix(timestamp: now), now: now), _origin);
    expect(currentRequestOrigin(_fix(timestamp: now, accuracy: 100), now: now),
        isNull);
    expect(
        currentRequestOrigin(
            _fix(timestamp: now.subtract(const Duration(seconds: 31))),
            now: now),
        isNull);
    expect(requestCoordinates(double.nan, 44), isNull);
    expect(requestCoordinates(91, 44), isNull);
  });

  test('cached failure does not silently retry on card or preview rebuild',
      () async {
    routes.fail = true;
    final cache = DriverRequestRouteCache(() => routes);
    await expectLater(cache.route(_pickup, _destination), throwsStateError);
    await expectLater(cache.route(_pickup, _destination), throwsStateError);
    expect(routes.calls, hasLength(1));
    routes.fail = false;
    expect(
        (await cache.route(_pickup, _destination, retry: true)).distanceMeters,
        7200);
    expect(routes.calls, hasLength(2));
  });
}
