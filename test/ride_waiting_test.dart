import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import '../lib/core/network/api_client.dart';
import '../lib/core/network/api_models.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/shared/models/ride_waiting_snapshot.dart';
import '../lib/shared/widgets/ride_waiting_panel.dart';

Map<String, Object?> snapshot({
  bool open = false,
  bool started = false,
  String? pendingKey,
  String? decision,
  int id = 10,
  String now = '2026-10-19T10:01:30.500Z',
  double settled = 100,
  double fee = 131,
  String? deadline,
}) =>
    {
      'serverNowUtc': now,
      'waitingFreeMinutes': 1,
      'waitingPricePerMinute': 60,
      'waitingMaxFee': 150,
      'settledWaitingFee': settled,
      'waitingFee': fee,
      'baseFare': 1000,
      'serviceFee': 100,
      'totalAmount': 1100 + fee,
      'connectionDeadlineUtc': deadline,
      'controlMode': 'driver',
      'canStart': !open,
      'canResume': open && started,
      'canRequestResume': false,
      'canDecideResume': pendingKey != null && decision == null,
      'resumeRequestPending': pendingKey != null && decision == null,
      'session': {
        'id': id,
        'isOpen': open,
        'startedAtUtc': started ? '2026-10-19T10:00:00Z' : null,
        'endedAtUtc': open ? null : now,
        'freeMinutes': 1,
        'pricePerMinute': 60,
        'maxFee': 50,
        'fee': fee - settled,
        if (pendingKey != null)
          'resumeRequest': {
            'requestKey': pendingKey,
            'decision': decision,
          },
      },
    };

class FakeWaitingApi extends ApiClient {
  FakeWaitingApi() : super(SecureStorageService());
  late Future<Map<String, Object?>> Function(String, Map<String, Object?>)
      handle;
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<ApiResult<T>> execute<T>({
    required String model,
    required String operation,
    Object? data,
    T Function(Object?)? parse,
  }) async {
    expect(model, 'RideWaitingModel');
    final body = Map<String, Object?>.from(data! as Map);
    calls.add((operation, body));
    final result = await handle(operation, body);
    return ApiSuccess<T>(result as T);
  }
}

Future<void> mount(WidgetTester tester,
    {int rideId = 7, bool driver = true}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
        body: SingleChildScrollView(
      child: RideWaitingPanel(rideId: rideId, isDriver: driver),
    )),
  ));
  await tester.pumpAndSettle();
}

void main() {
  test('legacy unstarted session cannot invent a clock or new charges', () {
    final value = RideWaitingSnapshot(snapshot(open: true, fee: 100));
    expect(value.elapsedSeconds(const Duration(minutes: 1)), 0);
    expect(value.waitingFee(const Duration(minutes: 1)), 100);
    expect(value.totalAmount(const Duration(minutes: 1)), 1200);
  });

  test('free minute and fractional-second rounding match server billing', () {
    final free = RideWaitingSnapshot(snapshot(
      open: true,
      started: true,
      now: '2026-10-19T10:00:59.999Z',
      fee: 100,
    ));
    expect(free.waitingFee(Duration.zero), 100);
    final active = RideWaitingSnapshot(snapshot(open: true, started: true));
    expect(active.waitingFee(Duration.zero), 131);
    expect(active.elapsedSeconds(Duration.zero), 90);
    expect(active.totalAmount(Duration.zero), 1231);
  });

  test('all stops respect the remaining cap and local projection freezes', () {
    final active = RideWaitingSnapshot(snapshot(open: true, started: true));
    expect(active.waitingFee(const Duration(hours: 1)), 146);
    expect(active.elapsedSeconds(const Duration(hours: 1)), 105);
    final capped = RideWaitingSnapshot(snapshot(
      open: true,
      started: true,
      now: '2026-10-19T10:05:00Z',
      fee: 150,
    ));
    expect(capped.waitingFee(Duration.zero), 150);
  });

  test('connection deadline freezes time and closed session uses server fees',
      () {
    final active = RideWaitingSnapshot(snapshot(
      open: true,
      started: true,
      deadline: '2026-10-19T10:01:35Z',
    ));
    expect(active.waitingFee(const Duration(seconds: 15)), 135);
    expect(active.elapsedSeconds(const Duration(seconds: 15)), 95);
    final closed = RideWaitingSnapshot(snapshot(settled: 131));
    expect(closed.waitingFee(const Duration(hours: 1)), 131);
    expect(closed.totalAmount(const Duration(hours: 1)), 1231);
    expect(() => RideWaitingSnapshot({}), throwsFormatException);
  });

  tearDown(Get.reset);
  const request = '00000000-0000-4000-8000-000000000001';
  const replacement = '00000000-0000-4000-8000-000000000002';

  void noConsent() {
    for (final label in [
      'توقف بطلب الراكب',
      'طلب انتظار بانتظار الموافقة',
      'مراجعة وموافقة',
      'أوافق على بدء الانتظار',
      'إرسال الطلب',
      'سحب طلب الانتظار'
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(find.byType(AlertDialog), findsNothing);
  }

  test('resume decisions need an active stop and specific pending request', () {
    final pending = RideWaitingSnapshot(
        snapshot(open: true, started: true, pendingKey: request));
    expect(pending.resumeRequestPending, isTrue);
    expect(pending.resumeRequestKey, request);
    expect(
        RideWaitingSnapshot(snapshot(
                open: true,
                started: true,
                pendingKey: request,
                decision: 'rejected'))
            .resumeRequestPending,
        isFalse);
    expect(
        RideWaitingSnapshot(snapshot(pendingKey: request)).resumeRequestPending,
        isFalse);
    final legacy = RideWaitingSnapshot(snapshot()..['controlMode'] = 'consent');
    expect(legacy.canStart, isFalse);
  });

  testWidgets('driver starts waiting immediately without consent',
      (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    var state = snapshot(fee: 100);
    api.handle = (action, body) async {
      if (action == 'start') {
        expect(body['rideId'], 7);
        expect(body.containsKey('sessionId'), isFalse);
        expect(
            body['requestKey'],
            matches(RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));
        state = snapshot(open: true, started: true);
      }
      return state;
    };
    await mount(tester);
    await tester.tap(find.text('بدء التوقف'));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.$1 == 'start'), hasLength(1));
    expect(find.text('الرحلة متوقفة'), findsOneWidget);
    expect(find.text('1:30'), findsOneWidget);
    expect(find.text('استئناف الرحلة وإيقاف الانتظار'), findsOneWidget);
    noConsent();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('driver directly resumes without accepting rider request',
      (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    var state = snapshot(open: true, started: true, pendingKey: request);
    api.handle = (action, body) async {
      if (action == 'resume') {
        expect(body['sessionId'], 10);
        expect(body.containsKey('resumeRequestKey'), isFalse);
        state = snapshot(settled: 131);
      }
      return state;
    };
    await mount(tester);
    await tester.tap(find.text('استئناف الرحلة وإيقاف الانتظار'));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.$1 == 'resume'), hasLength(1));
    expect(api.calls.where((c) => c.$1 == 'accept_resume'), isEmpty);
    expect(find.text('الإجمالي الحالي: 1231 ر.ي'), findsOneWidget);
    expect(find.text('1:30'), findsNothing);
    noConsent();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final accept in [true, false]) {
    testWidgets(
        accept
            ? 'accept rider resume and end waiting'
            : 'reject rider resume and keep waiting running', (tester) async {
      final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
      var state = snapshot(open: true, started: true, pendingKey: request);
      final action = accept ? 'accept_resume' : 'reject_resume';
      api.handle = (operation, body) async {
        if (operation == action) {
          expect(body['sessionId'], 10);
          expect(body['resumeRequestKey'], request);
          state = accept
              ? snapshot(settled: 131)
              : snapshot(
                  open: true,
                  started: true,
                  pendingKey: request,
                  decision: 'rejected');
        }
        return state;
      };
      await mount(tester);
      await tester
          .tap(find.text(accept ? 'قبول طلب الاستئناف' : 'رفض طلب الاستئناف'));
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c.$1 == action), hasLength(1));
      expect(find.text('قبول طلب الاستئناف'), findsNothing);
      expect(find.text('1:30'), accept ? findsNothing : findsOneWidget);
      expect(find.text('استئناف الرحلة وإيقاف الانتظار'),
          accept ? findsNothing : findsOneWidget);
      noConsent();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('rider role cannot execute driver stop or resume decisions',
      (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    api.handle = (_, __) async =>
        snapshot(open: true, started: true, pendingKey: request);
    await mount(tester, driver: false);
    for (final text in [
      'بدء التوقف',
      'استئناف الرحلة وإيقاف الانتظار',
      'قبول طلب الاستئناف',
      'رفض طلب الاستئناف'
    ]) {
      expect(find.text(text), findsNothing);
    }
    noConsent();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('server guards and old flags never expose stop consent',
      (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    api.handle = (_, __) async => snapshot()
      ..addAll({'canStart': false, 'canRequest': true, 'canDecide': true});
    await mount(tester);
    expect(find.text('بدء التوقف'), findsNothing);
    noConsent();
    api.handle = (_, __) async => snapshot()
      ..addAll(
          {'controlMode': 'consent', 'canRequest': true, 'canDecide': true});
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('بدء التوقف'), findsNothing);
    noConsent();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('uncertain start retries with the same idempotency key',
      (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    api.handle = (action, _) async {
      if (action == 'start') throw StateError('connection lost');
      return snapshot(fee: 100);
    };
    await mount(tester);
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.text('بدء التوقف'));
      await tester.pumpAndSettle();
    }
    final starts = api.calls.where((c) => c.$1 == 'start').toList();
    expect(starts, hasLength(2));
    expect(starts[0].$2['requestKey'], starts[1].$2['requestKey']);
    noConsent();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('double taps cannot create two stop operations', (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    final start = Completer<Map<String, Object?>>();
    api.handle = (action, _) =>
        action == 'start' ? start.future : Future.value(snapshot(fee: 100));
    await mount(tester);
    await tester.tap(find.text('بدء التوقف'));
    await tester.tap(find.text('بدء التوقف'));
    expect(api.calls.where((c) => c.$1 == 'start'), hasLength(1));
    start.complete(snapshot(open: true, started: true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('read begun before start cannot replace its active result',
      (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    Completer<Map<String, Object?>>? read;
    var state = snapshot(fee: 100);
    api.handle = (action, _) async {
      if (action == 'start') return state = snapshot(open: true, started: true);
      return read?.future ?? Future.value(state);
    };
    await mount(tester);
    read = Completer<Map<String, Object?>>();
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('بدء التوقف'));
    await tester.pumpAndSettle();
    read.complete(snapshot(fee: 100));
    await tester.pumpAndSettle();
    expect(find.text('1:30'), findsOneWidget);
    expect(find.text('بدء التوقف'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('previous ride reply cannot replace current waiting state',
      (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    final old = Completer<Map<String, Object?>>();
    api.handle = (_, body) =>
        body['rideId'] == 7 ? old.future : Future.value(snapshot(fee: 100));
    await mount(tester);
    await mount(tester, rideId: 8);
    old.complete(snapshot(open: true, started: true));
    await tester.pumpAndSettle();
    expect(find.text('بدء التوقف'), findsOneWidget);
    expect(find.text('1:30'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('replacement resume request requires a new matching key',
      (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    var state = snapshot(open: true, started: true, pendingKey: request);
    api.handle = (action, body) async {
      if (action == 'accept_resume' && body['resumeRequestKey'] == request) {
        state = snapshot(open: true, started: true, pendingKey: replacement);
        throw const FormatException('تغير طلب الاستئناف. راجع الطلب الحالي.');
      }
      if (action == 'accept_resume') {
        expect(body['resumeRequestKey'], replacement);
        state = snapshot(settled: 131);
      }
      return state;
    };
    await mount(tester);
    await tester.tap(find.text('قبول طلب الاستئناف'));
    await tester.pumpAndSettle();
    expect(find.text('1:30'), findsOneWidget);
    await tester.tap(find.text('قبول طلب الاستئناف'));
    await tester.pumpAndSettle();
    expect(
        api.calls
            .where((c) => c.$1 == 'accept_resume')
            .map((c) => c.$2['resumeRequestKey']),
        [request, replacement]);
    expect(find.text('1:30'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('direct resume remains available after refresh failure',
      (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    var failRead = false;
    api.handle = (action, _) async {
      if (action == 'resume') return snapshot(settled: 131);
      if (failRead) throw StateError('offline');
      return snapshot(open: true, started: true);
    };
    await mount(tester);
    failRead = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('استئناف الرحلة وإيقاف الانتظار'));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.$1 == 'resume'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('invalid response offers retry without crashing', (tester) async {
    final api = Get.put<ApiClient>(FakeWaitingApi()) as FakeWaitingApi;
    api.handle = (_, __) async => {};
    await mount(tester);
    expect(find.text('تعذرت مزامنة الانتظار. أعد المحاولة.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
