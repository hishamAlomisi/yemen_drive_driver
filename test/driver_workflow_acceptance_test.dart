import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import '../lib/core/network/api_client.dart';
import '../lib/core/services/auth_session_service.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/features/driver/controllers/driver_controller.dart';
import '../lib/features/driver/models/driver_models.dart';
import '../lib/features/driver/repositories/driver_repository.dart';
import '../lib/features/driver/views/driver_notifications_view.dart';
import '../lib/features/driver/widgets/driver_ride_card.dart';
import 'ride_route_change_test.dart' show RouteApi, routeSnapshot;

class _Repository implements DriverRepository {
  final checks = <Completer<bool>>[];
  bool canDecide = true;
  int decisions = 0;
  @override
  Future<bool> isRequestAvailable(int rideId) {
    final check = Completer<bool>();
    checks.add(check);
    return check.future;
  }

  @override
  Future<DriverSnapshot> load(int? userId) async =>
      const DriverSnapshot(profile: {'isAvailable': true}, rides: []);
  @override
  Future<List<Map<String, Object?>>> notifications() async => [];
  @override
  Future<Map<String, Object?>> getCancellationRequest(int requestId) async =>
      {'id': requestId, 'canDecide': canDecide, 'reason': 'تغيرت الخطة'};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Driver extends DriverController {
  _Driver(this.repository, AuthSessionService session)
      : super(repository, session);
  final _Repository repository;
  int? nextStatus;
  @override
  void onReady() {}
  @override
  Future<void> updateStatus(
      Map<String, Object?> ride, int status, String label) async {
    nextStatus = status;
  }

  @override
  Future<void> decideCancellation(int requestId, String operation) async {
    repository.decisions++;
    repository.canDecide = false;
    // An unread marker can fail independently of the authoritative decision.
  }
}

_Driver controller(_Repository repository) {
  final storage = SecureStorageService();
  final session = AuthSessionService(storage, ApiClient(storage));
  session.currentUserId.value = 42;
  return _Driver(repository, session);
}

const request = <String, Object?>{
  'id': 7,
  'status': 1,
  'customerPrice': 1000,
  'pickupDisplayName': 'حدة',
  'destinationDisplayName': 'التحرير',
};

void main() {
  tearDown(() => Get.reset());

  test(
      'a verified request appears immediately; unavailable requests never appear',
      () async {
    final repository = _Repository();
    final subject = controller(repository);
    final available = subject.receiveAvailableRequest(request, 7);
    repository.checks[0].complete(true);
    await available;
    expect(subject.rides.single['id'], 7);
    final unavailable =
        subject.receiveAvailableRequest({...request, 'id': 8}, 8);
    repository.checks[1].complete(false);
    await unavailable;
    expect(subject.rides.map((ride) => ride['id']), [7]);
  });

  test('a reconnect snapshot invalidates earlier request verification',
      () async {
    final repository = _Repository();
    final subject = controller(repository);
    final oldCheck = subject.receiveAvailableRequest(request, 7);
    await subject.load(showLoading: false);
    repository.checks.single.complete(true);
    await oldCheck;
    expect(subject.rides, isEmpty);
    expect(subject.profile.value?['isAvailable'], true);
  });

  test('a later unavailable check wins over an older successful response',
      () async {
    final repository = _Repository();
    final subject = controller(repository);
    final first = subject.receiveAvailableRequest(request, 7);
    final second = subject.receiveAvailableRequest(request, 7);
    repository.checks[1].complete(false);
    await second;
    repository.checks[0].complete(true);
    await first;
    expect(subject.rides, isEmpty);
  });

  testWidgets(
      'arrival confirmation precedes the start button and retains cancellation',
      (tester) async {
    final subject =
        Get.put<DriverController>(controller(_Repository())) as _Driver;
    Future<void> mount(int status) => tester.pumpWidget(GetMaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: DriverRideCard(
            ride: {...request, 'driverId': 42, 'status': status},
          ))),
        ));
    await mount(4);
    await tester.pumpAndSettle();
    expect(find.text('بدء الرحلة'), findsNothing);
    expect(find.text('إلغاء الرحلة'), findsOneWidget);
    await tester.tap(find.text('تأكيد الوصول إلى الراكب'));
    expect(subject.nextStatus, 9);
    await mount(9);
    await tester.pumpAndSettle();
    expect(find.text('تأكيد الوصول إلى الراكب'), findsNothing);
    expect(find.text('بدء الرحلة'), findsOneWidget);
    await tester.tap(find.text('بدء الرحلة'));
    expect(subject.nextStatus, 5);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'notification decisions refresh even when the read marker remains unread',
      (tester) async {
    final repository = _Repository();
    final subject = Get.put<DriverController>(controller(repository));
    subject.notifications.add({
      'id': 11,
      'title': 'طلب إلغاء رحلة',
      'body': 'يرجى مراجعة السبب',
      'isRead': false,
      'dataJson': '{"rideId":7,"cancellationRequestId":21}',
    });
    await tester
        .pumpWidget(const GetMaterialApp(home: DriverNotificationsView()));
    await tester.pumpAndSettle();
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('موافقة'), findsOneWidget);
    expect(tester.widget<Card>(find.byType(Card)).shape,
        isA<RoundedRectangleBorder>());
    await tester.tap(find.text('موافقة'));
    await tester.pumpAndSettle();
    expect(repository.decisions, 1);
    expect(find.text('موافقة'), findsNothing);
    expect(find.text('لا يوجد قرار مطلوب لهذا الطلب.'), findsOneWidget);
    expect(subject.notifications.single['isRead'], false);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'route approval opens inside its notification and waiting requests have an entry',
      (tester) async {
    final subject = Get.put<DriverController>(controller(_Repository()));
    final api = Get.put<ApiClient>(RouteApi()) as RouteApi;
    api.handle = (_, __) async =>
        routeSnapshot(status: 'pending', mine: false, canRequest: false);
    subject.notifications.assignAll([
      {
        'id': 12,
        'title': 'طلب تغيير مسار الرحلة',
        'body': 'راجع الوجهة والفاتورة',
        'isRead': false,
        'dataJson': '{"rideId":7,"routeChangeId":9}'
      },
      {
        'id': 13,
        'title': 'طلب توقف أثناء الرحلة',
        'body': 'راجع سياسة الانتظار',
        'isRead': false,
        'dataJson': '{"rideId":7,"action":"review_waiting"}'
      },
    ]);
    await tester
        .pumpWidget(const GetMaterialApp(home: DriverNotificationsView()));
    await tester.pumpAndSettle();
    expect(find.text('مراجعة طلب الانتظار'), findsOneWidget);
    await tester.tap(find.text('مراجعة طلب تغيير المسار'));
    await tester.pumpAndSettle();
    expect(find.text('مراجعة الفاتورة والموافقة'), findsOneWidget);
    expect(find.text('اختيار وجهة جديدة وعرض الفاتورة'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
