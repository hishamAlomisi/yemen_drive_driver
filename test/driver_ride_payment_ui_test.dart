import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import '../lib/core/network/api_client.dart';
import '../lib/core/network/api_models.dart';
import '../lib/core/realtime/tracking_hub_service.dart';
import '../lib/core/services/auth_session_service.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/features/driver/controllers/driver_controller.dart';
import '../lib/features/driver/models/driver_models.dart';
import '../lib/features/driver/repositories/driver_repository.dart';
import '../lib/features/driver/widgets/driver_ride_card.dart';

const _ride = <String, Object?>{
  'id': 7,
  'driverId': 42,
  'status': 9,
  'paymentMethodCode': 'cash',
  'passengerBoardedAtUtc': '2026-11-01T10:00:00Z',
  'customerPrice': 1000,
  'totalAmount': 1100,
  'pickupDisplayName': 'حدة',
  'destinationDisplayName': 'التحرير',
};

class _Repository implements DriverRepository {
  Map<String, Object?> latest = {..._ride};
  int detailReads = 0;
  Completer<Map<String, Object?>>? nextDetail;
  final starts = <bool>[];

  @override
  Future<void> updateRideStatus(
      {required int rideId,
      required int status,
      bool? customerPaymentEnabled,
      bool confirmPassengerBoarding = false}) async {
    starts.add(confirmPassengerBoarding);
  }

  @override
  Future<Map<String, Object?>> getRide(int rideId) async {
    detailReads++;
    final held = nextDetail;
    nextDetail = null;
    if (held != null) return held.future;
    return Map.of(latest);
  }

  @override
  Future<DriverSnapshot> load(int? userId) async =>
      DriverSnapshot(profile: null, rides: [Map.of(latest)]);

  @override
  Future<List<Map<String, Object?>>> notifications() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PanelApi extends ApiClient {
  _PanelApi() : super(SecureStorageService());

  @override
  Future<ApiResult<T>> execute<T>({
    required String model,
    required String operation,
    Object? data,
    T Function(Object?)? parse,
  }) async {
    final result = {
      'rideId': 7,
      'serverNowUtc': '2026-10-30T10:00:00Z',
      'routeVersion': 0,
      'canRequest': false,
      'history': <Object?>[],
    };
    return ApiSuccess<T>(result as T);
  }
}

class _Driver extends DriverController {
  _Driver(super.repository, super.session);
  int? nextStatus;

  @override
  void onReady() {}

  @override
  Future<void> load({bool showLoading = true}) async {}

  @override
  Future<void> updateStatus(
      Map<String, Object?> ride, int status, String label) async {
    nextStatus = status;
  }
}

class _BoardingDriver extends DriverController {
  _BoardingDriver(super.repository, super.session);
  @override
  void onReady() {}
  @override
  Future<void> load({bool showLoading = true}) async {}
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

AuthSessionService _session() {
  final storage = SecureStorageService();
  return AuthSessionService(storage, ApiClient(storage))
    ..currentUserId.value = 42;
}

FilledButton _button(WidgetTester tester, String label) =>
    tester.widget<FilledButton>(find.ancestor(
      of: find.text(label),
      matching: find.byType(FilledButton),
    ));

Future<void> _mount(WidgetTester tester, Map<String, Object?> ride) async {
  if (!Get.isRegistered<DriverController>()) {
    Get.put<DriverController>(_Driver(_Repository(), _session()));
    Get.put<ApiClient>(_PanelApi());
  }
  await tester.pumpWidget(GetMaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: DriverRideCard(ride: ride)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => Get.reset());
  testWidgets('driver can decline or confirm boarding without duplicate starts',
      (tester) async {
    final repository = _Repository();
    final subject =
        Get.put<DriverController>(_BoardingDriver(repository, _session()));
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    final unboarded = {..._ride, 'passengerBoardedAtUtc': null};
    final declined = subject.updateStatus(unboarded, 5, 'بدأت الرحلة');
    await tester.pumpAndSettle();
    await tester.tap(find.text('لم يصعد بعد'));
    await tester.pumpAndSettle();
    await declined;
    expect(repository.starts, isEmpty);
    final confirmed = subject.updateStatus(unboarded, 5, 'بدأت الرحلة');
    await tester.pumpAndSettle();
    await subject.updateStatus(unboarded, 5, 'بدأت الرحلة');
    expect(find.text('تأكيد صعود الراكب'), findsOneWidget);
    await tester.tap(find.text('صعد الراكب، ابدأ الرحلة'));
    await tester.pumpAndSettle();
    await confirmed;
    expect(repository.starts, [true]);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await subject.updateStatus(_ride, 5, 'بدأت الرحلة');
    await tester.pumpAndSettle();
    expect(repository.starts, [true, false]);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'paid ride offers driver boarding confirmation and hides alerts after boarding',
      (tester) async {
    await _mount(tester, {
      ..._ride,
      'passengerBoardedAtUtc': null,
      'paymentMethodCode': 'wallet',
      'paymentCompleted': true
    });
    expect(_button(tester, 'بدء الرحلة').onPressed, isNotNull);
    expect(find.byTooltip('تنبيه الراكب'), findsOneWidget);
    expect(find.byTooltip('نتيجة التواصل'), findsOneWidget);
    expect(find.byTooltip('محادثة العميل'), findsOneWidget);
    expect(find.byTooltip('اتصال بالعميل'), findsOneWidget);
    expect(find.text('محادثة العميل'), findsNothing);
    expect(find.text('اتصال بالعميل'), findsNothing);
    expect(find.text('تنبيه الراكب'), findsNothing);
    await tester.longPress(find.byTooltip('تنبيه الراكب'));
    await tester.pumpAndSettle();
    expect(find.text('تنبيه الراكب'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await _mount(tester, _ride);
    expect(find.byTooltip('تنبيه الراكب'), findsNothing);
    expect(find.byTooltip('نتيجة التواصل'), findsNothing);
    expect(find.byTooltip('محادثة العميل'), findsOneWidget);
    expect(find.byTooltip('اتصال بالعميل'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('physical service can finish before financial settlement',
      (tester) async {
    await _mount(
        tester, {..._ride, 'status': 5, 'paymentMethodCode': 'wallet'});
    expect(_button(tester, 'إنهاء الرحلة').onPressed, isNotNull);
    expect(find.textContaining('محفظة يمن درايف'), findsOneWidget);
    await _mount(tester, {
      ..._ride,
      'status': 5,
      'paymentMethodCode': 'wallet',
      'paymentCompleted': true,
      'paymentProvider': 'YemenDriveWallet'
    });
    expect(_button(tester, 'إنهاء الرحلة').onPressed, isNotNull);
    expect(find.text('تحصيل الدفع'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final status in [3, 4, 9, 5]) {
    testWidgets(
        'paid method is visible and collection absent at status $status',
        (tester) async {
      for (final method in ['فلوسك', 'جيب']) {
        await _mount(tester, {
          ..._ride,
          'status': status,
          'paymentCompleted': true,
          'paymentMethodNameAr': method,
          'paymentMethodCode': 'Cash',
        });
        expect(find.text('تم الدفع عبر $method'), findsOneWidget);
        expect(find.text('تحصيل الدفع'), findsNothing);
        expect(find.text('تمكين الدفع'), findsNothing);
        final action = switch (status) {
          3 => 'بدء التوجه',
          4 => 'تأكيد الوصول',
          9 => 'بدء الرحلة',
          _ => 'إنهاء الرحلة',
        };
        expect(_button(tester, action).onPressed, isNotNull);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('required payment blocks start until paid or switched to cash',
      (tester) async {
    await _mount(tester, {
      ..._ride,
      'paymentMethodCode': 'Floosak',
      'paymentRequiredBeforeStart': true,
    });
    expect(_button(tester, 'بدء الرحلة').onPressed, isNull);
    expect(find.textContaining('بانتظار دفع الراكب'), findsOneWidget);
    expect(find.textContaining('تم الدفع عبر'), findsNothing);
    await _mount(tester, {
      ..._ride,
      'paymentMethodCode': 'Cash',
      'paymentRequiredBeforeStart': false,
    });
    expect(_button(tester, 'بدء الرحلة').onPressed, isNotNull);
    expect(find.textContaining('بانتظار دفع الراكب'), findsNothing);
    await tester.tap(find.text('بدء الرحلة'));
    expect((Get.find<DriverController>() as _Driver).nextStatus, 5);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending wallet locks start and both collection controls',
      (tester) async {
    await _mount(tester, {..._ride, 'walletPaymentPending': true});
    expect(_button(tester, 'بدء الرحلة').onPressed, isNull);
    expect(find.textContaining('قيد التنفيذ أو التحقق'), findsOneWidget);
    await _mount(tester, {
      ..._ride,
      'status': 5,
      'walletPaymentPending': true,
    });
    expect(_button(tester, 'تحصيل الدفع').onPressed, isNull);
    expect(_button(tester, 'تمكين الدفع').onPressed, isNull);
    expect(find.textContaining('تم الدفع عبر'), findsNothing);
    await _mount(tester, {..._ride, 'status': 5, 'paymentMethodCode': 'Cash'});
    expect(_button(tester, 'تحصيل الدفع').onPressed, isNotNull);
    expect(_button(tester, 'تمكين الدفع').onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final enabledByDriver in [false, true]) {
    testWidgets(
        'payment events reconcile during detail fetch (enabled: $enabledByDriver)',
        (tester) async {
      const geolocation = MethodChannel('flutter.baseflow.com/geolocator');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(geolocation, (_) async => false);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(geolocation, null));
      final repository = _Repository()
        ..latest = {
          ..._ride,
          'paymentRequiredBeforeStart': true,
          'customerPaymentEnabled': enabledByDriver,
        };
      final hub = Get.put<TrackingHubService>(_Hub()) as _Hub;
      final controller =
          Get.put<DriverController>(DriverController(repository, _session()));
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
            body: Obx(() => controller.rides.isEmpty
                ? const SizedBox()
                : SingleChildScrollView(
                    child: DriverRideCard(ride: controller.rides.single)))),
      ));
      await tester.pumpAndSettle();
      expect(controller.paymentEnabledRideIds.contains(7), enabledByDriver);
      expect(_button(tester, 'بدء الرحلة').onPressed, isNull);
      final pendingDetail = Completer<Map<String, Object?>>();
      repository.nextDetail = pendingDetail;
      hub.messages.add(const TrackingHubEvent('paymentUpdated', {'rideId': 7}));
      await tester.pump();
      expect(repository.detailReads, 1);
      repository.latest = {
        ..._ride,
        'paymentCompleted': true,
        'paymentRequiredBeforeStart': false,
        'paymentMethodNameAr': 'جيب',
        'paymentProvider': 'Jaib',
      };
      hub.messages.add(const TrackingHubEvent('paymentUpdated', {'rideId': 7}));
      await tester.pump();
      pendingDetail.complete({
        ..._ride,
        'walletPaymentPending': true,
        'paymentRequiredBeforeStart': true,
        'customerPaymentEnabled': enabledByDriver,
      });
      await tester.pumpAndSettle();
      expect(repository.detailReads, 2);
      expect(controller.rides.single['paymentMethodNameAr'], 'جيب');
      expect(find.text('تم الدفع عبر جيب'), findsWidgets);
      expect(_button(tester, 'بدء الرحلة').onPressed, isNotNull);
      Get.closeAllSnackbars();
      await tester.pumpAndSettle();
      Get.delete<DriverController>();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await hub.messages.close();
    });
  }
}
