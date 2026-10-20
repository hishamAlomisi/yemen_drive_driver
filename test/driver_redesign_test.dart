import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:yemen_drive_driver/app/theme/app_theme.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/realtime/tracking_hub_service.dart';
import 'package:yemen_drive_driver/core/services/auth_session_service.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';
import 'package:yemen_drive_driver/features/driver/controllers/driver_controller.dart';
import 'package:yemen_drive_driver/features/driver/controllers/driver_login_controller.dart';
import 'package:yemen_drive_driver/features/driver/driver_routes.dart';
import 'package:yemen_drive_driver/features/driver/repositories/driver_repository.dart';
import 'package:yemen_drive_driver/features/driver/views/driver_history_view.dart';
import 'package:yemen_drive_driver/features/driver/views/driver_home_view.dart';
import 'package:yemen_drive_driver/features/driver/views/driver_login_view.dart';
import 'package:yemen_drive_driver/features/driver/views/driver_payment_view.dart';
import 'package:yemen_drive_driver/features/driver/views/driver_wallet_view.dart';
import 'package:yemen_drive_driver/features/driver/widgets/driver_ride_card.dart';

// Fixtures exist only in tests; the shipped app always uses the real services.
class _Repository implements DriverRepository {
  @override
  Future<Map<String, Object?>> getRideForPayment(int rideId) async => {
        'id': rideId,
        'customerPrice': 2500,
        'serviceFee': 100,
        'totalAmount': 2600,
        'driverCommissionAmount': 250,
        'platformShare': 350,
        'driverShare': 2250,
        'waitingFee': 0,
        'waitingIsOpen': false,
        'routeChangeFees': 0,
        'routeVersion': 0,
      };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Driver extends DriverController {
  _Driver(super.repository, super.session);
  int offers = 0;
  int refreshes = 0;
  int? nextStatus;
  @override
  void onReady() {}
  @override
  Future<void> load({bool showLoading = true}) async {
    refreshes++;
  }

  @override
  Future<void> markRequestViewed(Map<String, Object?> ride) async {}
  @override
  Future<void> sendOffer(Map<String, Object?> ride) async {
    offers++;
  }

  @override
  Future<void> updateStatus(
    Map<String, Object?> ride,
    int status,
    String label,
  ) async {
    nextStatus = status;
  }

  @override
  Future<void> loadWallet() async {}
  @override
  Future<void> loadDriverAccount() async {}
}

class _Login extends DriverLoginController {
  _Login(super.repository, super.session);
  int submissions = 0;
  int verifications = 0;
  @override
  Future<void> submit() async {
    submissions++;
  }

  @override
  Future<void> verifyOtp() async {
    verifications++;
  }
}

const sampleRide = <String, Object?>{
  'id': 2048,
  'driverId': null,
  'status': 1,
  'pickupDisplayName': 'شارع حدة، أمام مركز الكميم',
  'destinationDisplayName': 'شارع الزبيري، صنعاء',
  'pickupDistanceMeters': 850,
  'customerPrice': 2500,
};

void main() {
  late _Driver driver;
  late _Login login;
  late _Repository repository;
  late SecureStorageService storage;
  setUp(() {
    Get.testMode = true;
    storage = SecureStorageService();
    final session = AuthSessionService(storage, ApiClient(storage));
    session.currentUserId.value = 42;
    repository = _Repository();
    driver = _Driver(repository, session);
    driver.profile.value = {
      'displayName': 'أحمد الصنعاني',
      'serviceNameAr': 'نقل الركاب',
    };
    driver.rides.assignAll([
      sampleRide,
      {...sampleRide, 'id': 2049, 'driverId': 42, 'status': 4},
      {...sampleRide, 'id': 2012, 'driverId': 42, 'status': 6},
    ]);
    driver.isWalletLoaded.value = true;
    driver.walletBalance.value = 48500;
    final now = DateTime.now().toUtc().toIso8601String();
    driver.walletTransactions.assignAll([
      {
        'description': 'تسوية رحلة #2012',
        'amount': 2500,
        'type': 0,
        'createdAtUtc': now,
      },
      {
        'description': 'تحصيل نقدي · رحلة #2008',
        'amount': -1800,
        'type': 1,
        'createdAtUtc': now,
      },
      {
        'description': 'إضافة إلى المحفظة',
        'amount': 10000,
        'type': 0,
        'createdAtUtc': now,
      },
    ]);
    Get.put<DriverController>(driver);
    login = _Login(repository, session);
    Get.put<DriverLoginController>(login, permanent: true);
  });
  tearDown(() => Get.reset());

  Future<void> mount(
    WidgetTester tester,
    Widget screen, {
    double width = 390,
    double height = 1000,
    double scale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loader = FontLoader('BeINArabic')
      ..addFont(rootBundle.load('assets/fonts/bein_ar_regular.ttf'));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar', 'SA'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('ar', 'SA')],
        theme: dark ? AppTheme.dark : AppTheme.light,
        getPages: [
          GetPage<dynamic>(name: DriverRoutes.home, page: DriverHomeView.new),
          GetPage<dynamic>(
            name: DriverRoutes.wallet,
            page: DriverWalletView.new,
          ),
          GetPage<dynamic>(
            name: DriverRoutes.history,
            page: DriverHistoryView.new,
          ),
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(key: const ValueKey('preview'), child: screen),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> preview(WidgetTester tester, String name) async {
    if (const bool.fromEnvironment('UPDATE_PREVIEWS')) {
      await expectLater(
        find.byKey(const ValueKey('preview')),
        matchesGoldenFile('../docs/previews/$name.png'),
      );
    }
  }

  testWidgets(
      'login retains inputs, password visibility, remember and OTP actions',
      (tester) async {
    await mount(tester, const DriverLoginView());
    await preview(tester, 'login');
    await tester.enterText(
      find.byKey(const ValueKey('driver-phone')),
      '777123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey('driver-password')),
      'test-password',
    );
    await tester.tap(find.byTooltip('إظهار كلمة المرور'));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('driver-password')))
          .obscureText,
      false,
    );
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(login.rememberMe.value, true);
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    expect(login.submissions, 1);
    expect(login.phoneController.text, '777123456');
    login.challengeId.value = 'challenge';
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('driver-password')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('driver-otp')), '123456');
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    expect(login.verifications, 1);
    expect(login.otpController.text, '123456');
  });

  testWidgets('home filters requests without removing assigned rides',
      (tester) async {
    await mount(tester, const DriverHomeView(), height: 1000);
    await preview(tester, 'home');
    await tester.tap(find.text('المتاحة'));
    await tester.pumpAndSettle();
    expect(find.byType(DriverRideCard), findsOneWidget);
    expect(
      tester.widget<DriverRideCard>(find.byType(DriverRideCard)).ride['id'],
      2048,
    );
    await tester.tap(find.text('المسندة لي'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<DriverRideCard>(find.byType(DriverRideCard))
          .every((card) => card.ride['driverId'] == 42),
      true,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'rejected and expired offers can be sent again; assigned status actions survive',
      (tester) async {
    for (final status in [null, 0, 2, 3]) {
      await mount(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: DriverRideCard(
              ride: {
                ...sampleRide,
                'driverOfferStatus': status,
                'driverOfferAmount': 2200,
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
    }
    expect(driver.offers, 4);
    await mount(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: DriverRideCard(
            ride: {...sampleRide, 'driverId': 42, 'status': 3},
          ),
        ),
      ),
    );
    await tester.tap(find.text('بدء التوجه'));
    expect(driver.nextStatus, 4);
  });

  testWidgets(
      'wallet and history render and bottom navigation preserves the session',
      (tester) async {
    await mount(tester, const DriverWalletView());
    await preview(tester, 'wallet');
    expect(find.text('48500 ر.ي'), findsOneWidget);
    await tester.tap(find.text('رحلاتي'));
    await tester.pumpAndSettle();
    expect(find.text('سجل الرحلات'), findsOneWidget);
    await tester.tap(find.text('الرئيسية'));
    await tester.pumpAndSettle();
    expect(find.text('على طريقك'), findsOneWidget);
    expect(identical(Get.find<DriverController>(), driver), true);
    expect(driver.isClosed, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screens, keyboard and larger Arabic text stay scrollable',
      (tester) async {
    await mount(
      tester,
      const DriverLoginView(),
      width: 320,
      height: 640,
      scale: 1.35,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    expect(login.submissions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wallet filters and driver account fit narrow screens',
      (tester) async {
    await mount(
      tester,
      const DriverWalletView(),
      width: 320,
      height: 800,
      scale: 1.35,
    );
    driver.financialFiltersVisible.value = true;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('حساب السائق'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark theme and history render the shared ride details',
      (tester) async {
    await mount(tester, const DriverHomeView(), dark: true, height: 1000);
    await preview(tester, 'home-dark');
    await mount(tester, const DriverHistoryView());
    await preview(tester, 'history');
    expect(find.text('1 رحلة مكتملة'), findsOneWidget);
  });

  testWidgets(
      'cash payment displays the original fare breakdown and excess calculation',
      (tester) async {
    final hub = TrackingHubService(storage);
    await mount(
      tester,
      DriverPaymentView(
        ride: {
          ...sampleRide,
          'serviceFee': 100,
          'driverCommissionAmount': 250,
        },
        repository: repository,
        hub: hub,
      ),
    );
    await preview(tester, 'payment');
    expect(find.text('2600 ر.ي'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '3000');
    await tester.pumpAndSettle();
    expect(find.text('الزيادة لمحفظة العميل: 400 ر.ي'), findsOneWidget);
    expect(find.text('إجمالي مديونيتك بعد التحصيل: 750 ر.ي'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
