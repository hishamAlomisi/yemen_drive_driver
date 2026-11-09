import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:yemen_drive_driver/app/theme/app_theme.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/network/api_models.dart';
import 'package:yemen_drive_driver/core/services/auth_session_service.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';
import 'package:yemen_drive_driver/features/driver/controllers/driver_controller.dart';
import 'package:yemen_drive_driver/features/driver/driver_routes.dart';

class _Storage extends SecureStorageService {
  @override
  Future<void> clear() async {}
}

class _Gps extends GeolocatorPlatform {
  final positions = StreamController<Position>.broadcast();
  int subscriptions = 0;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Stream<ServiceStatus> getServiceStatusStream() => const Stream.empty();
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    subscriptions++;
    return positions.stream;
  }

  @override
  Future<Position> getCurrentPosition(
          {LocationSettings? locationSettings}) async =>
      _fix(15.36);
}

Position _fix(double latitude) => Position(
      latitude: latitude,
      longitude: 44.19,
      timestamp: DateTime.now(),
      // An approximate fix is shown locally and never sent as a financial sample.
      accuracy: 100,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

Map<String, Object?> _completedRide(int id) => {
      'id': id,
      'driverId': 42,
      'status': 6,
      'pickupDisplayName': 'انطلاق $id',
      'destinationDisplayName': 'وجهة $id',
      'paymentCompleted': true,
      'totalAmount': 1000,
    };

class _Api extends ApiClient {
  _Api(super.storage);
  final rides = <Map<String, Object?>>[_completedRide(105)];
  int rideReads = 0;
  int profileReads = 0;

  @override
  Future<ApiResult<T>> execute<T>({
    required String model,
    required String operation,
    Object? data,
    T Function(Object?)? parse,
  }) async {
    if (model == 'DriverModel') profileReads++;
    if (model == 'RideModel') rideReads++;
    final Object payload = switch (model) {
      'DriverModel' => <Object?>[
          <String, Object?>{
            'userId': 42,
            'displayName': 'السائق الاختباري',
            'isApproved': true,
            'isAvailable': true,
            'acceptsNewRequests': true,
            'approvedPassengerSeats': 4,
          },
        ],
      'RideModel' when operation == 'get' => <String, Object?>{
          'ride': rides.first,
          'paymentCompleted': true,
        },
      'RideModel' => List<Map<String, Object?>>.of(rides),
      'NotificationModel' => <Object?>[],
      'WalletModel' || 'DriverFinancialReportModel' => <String, Object?>{
          'balance': 0,
          'transactions': <Object?>[],
        },
      _ => <String, Object?>{},
    };
    return ApiSuccess<T>(parse == null ? payload as T : parse(payload));
  }
}

void main() {
  late GeolocatorPlatform originalGps;
  late _Gps gps;
  late _Api api;
  late AuthSessionService session;

  setUp(() {
    Get.testMode = true;
    originalGps = GeolocatorPlatform.instance;
    gps = _Gps();
    GeolocatorPlatform.instance = gps;
    final storage = _Storage();
    api = _Api(storage);
    session = AuthSessionService(storage, api)
      ..isAuthenticated.value = true
      ..currentUserId.value = 42;
    Get.put<ApiClient>(api, permanent: true);
    Get.put<AuthSessionService>(session, permanent: true);
  });

  tearDown(() async {
    Get.reset();
    GeolocatorPlatform.instance = originalGps;
    await gps.positions.close();
  });

  Future<void> settleNavigation(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<DriverController> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fonts = FontLoader('BeINArabic')
      ..addFont(rootBundle.load('assets/fonts/bein_ar_regular.ttf'));
    await fonts.load();
    // Use shipped routes and bindings: registering a test controller directly
    // would skip the route ownership bug this regression is intended to catch.
    await tester.pumpWidget(GetMaterialApp(
      initialRoute: DriverRoutes.home,
      getPages: driverPages,
      theme: AppTheme.light,
      locale: const Locale('ar', 'SA'),
      supportedLocales: const [Locale('ar', 'SA')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      transitionDuration: Duration.zero,
    ));
    await settleNavigation(tester);
    final controller = Get.find<DriverController>();
    expect(controller.profile.value?['displayName'], 'السائق الاختباري');
    expect(controller.rides.single['status'], 6);
    expect(controller.currentPosition.value?.latitude, 15.36);
    expect(gps.subscriptions, 1);
    return controller;
  }

  Future<void> expectStillActive(
      WidgetTester tester, DriverController original) async {
    final current = Get.find<DriverController>();
    expect(identical(original, current), isTrue);
    expect(current.isClosed, isFalse);
    expect(current.currentUserId, 42);
    expect(current.profile.value?['acceptsNewRequests'], isTrue);
    expect(current.rides.single['id'], 105);
    final readsBefore = api.rideReads;
    api.rides.add(_completedRide(106));
    await current.load(showLoading: false);
    await tester.pump();
    expect(api.rideReads, greaterThan(readsBefore));
    expect(current.rides.map((ride) => ride['id']), [105, 106]);
    gps.positions.add(_fix(15.37));
    await tester.pump();
    expect(current.currentPosition.value?.latitude, 15.37);
    expect(gps.subscriptions, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await Get.delete<DriverController>(force: true);
    await tester.pump();
  }

  testWidgets('actual bindings keep completed trips and GPS across bottom tabs',
      (tester) async {
    final original = await mount(tester);
    for (final label in ['رحلاتي', 'المحفظة', 'الرئيسية']) {
      await tester.tap(find.text(label).last);
      await settleNavigation(tester);
      expect(identical(original, Get.find<DriverController>()), isTrue);
      expect(original.isClosed, isFalse);
    }
    await expectStillActive(tester, original);
  });

  for (final openFromHistory in [false, true]) {
    testWidgets(
        'push from ${openFromHistory ? 'history' : 'home'} keeps the live driver after completion',
        (tester) async {
      final original = await mount(tester);
      if (openFromHistory) {
        await tester.tap(find.text('رحلاتي').last);
        await settleNavigation(tester);
        expect(find.text('1 رحلة مكتملة'), findsOneWidget);
      }
      session.openNotificationFromPush({
        'action': 'open_notifications',
        'rideId': '105',
      });
      await settleNavigation(tester);
      await expectStillActive(tester, original);
    });
  }

  testWidgets('returning from notifications keeps the route owning the driver',
      (tester) async {
    final original = await mount(tester);
    original.showNotifications();
    await settleNavigation(tester);
    expect(find.text('لا توجد إشعارات.'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await settleNavigation(tester);
    expect(Get.currentRoute, DriverRoutes.home);
    await expectStillActive(tester, original);
  });

  testWidgets('wallet push keeps the live driver and completed history',
      (tester) async {
    final original = await mount(tester);
    session.openNotificationFromPush({
      'action': 'open_wallet',
      'walletTransactionId': '7',
    });
    await settleNavigation(tester);
    expect(Get.currentRoute, DriverRoutes.wallet);
    await expectStillActive(tester, original);
  });

  testWidgets('system Back from notifications preserves the live driver',
      (tester) async {
    final original = await mount(tester);
    original.showNotifications();
    await settleNavigation(tester);
    await tester.binding.handlePopRoute();
    await settleNavigation(tester);
    expect(Get.currentRoute, DriverRoutes.home);
    await expectStillActive(tester, original);
  });

  testWidgets(
      'queued push is handled after the driver binding creates its owner',
      (tester) async {
    session.openNotificationFromPush({
      'action': 'open_notifications',
      'rideId': '105',
    });
    expect(session.hasPendingNotificationOpen, isTrue);
    final original = await mount(tester);
    expect(session.hasPendingNotificationOpen, isFalse);
    expect(original.focusedRideId.value, 105);
    await expectStillActive(tester, original);
  });

  for (final afterPush in [false, true]) {
    testWidgets(
        'sign-out closes the driver and stops GPS ${afterPush ? 'after a push' : 'without a push'}',
        (tester) async {
      final original = await mount(tester);
      if (afterPush) {
        session.openNotificationFromPush({
          'action': 'open_notifications',
          'rideId': '105',
        });
        await settleNavigation(tester);
      }
      expect(identical(original, Get.find<DriverController>()), isTrue);
      await session.signOut(revokeServerSession: false);
      await settleNavigation(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(original.isClosed, isTrue);
      expect(session.isAuthenticated.value, isFalse);
      expect(session.currentUserId.value, isNull);
      expect(session.onNotificationOpened, isNull);
      expect(gps.positions.hasListener, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
