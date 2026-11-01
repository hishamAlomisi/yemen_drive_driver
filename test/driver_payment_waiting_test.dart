import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/realtime/tracking_hub_service.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/features/driver/repositories/driver_repository.dart';
import '../lib/features/driver/views/driver_payment_view.dart';

Map<String, Object?> ride({int waitingFee = 0, bool open = false}) => {
      'id': 7,
      'paymentMethodCode': 'cash',
      'customerPrice': 1000,
      'serviceFee': 100,
      'waitingFee': waitingFee,
      'totalAmount': 1100 + waitingFee,
      'driverCommissionAmount': 100,
      'platformShare': 200,
      'driverShare': 900 + waitingFee,
      'waitingIsOpen': open,
    };

class PaymentRepository implements DriverRepository {
  Map<String, Object?> latest = ride();
  bool fail = false;
  int detailReads = 0;
  Completer<Map<String, Object?>>? nextDetail;
  final collections = <num>[];

  @override
  Future<Map<String, Object?>> getRideForPayment(int rideId) async {
    detailReads++;
    final held = nextDetail;
    nextDetail = null;
    if (held != null) return held.future;
    if (fail) throw StateError('offline');
    return Map.of(latest);
  }

  @override
  Future<Map<String, Object?>> registerCashPayment(
      {required int rideId, required num cashReceived}) async {
    collections.add(cashReceived);
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PaymentHub extends TrackingHubService {
  PaymentHub() : super(SecureStorageService());
  final messages = StreamController<TrackingHubEvent>.broadcast();

  @override
  Stream<TrackingHubEvent> get events => messages.stream;
}

Future<void> mount(WidgetTester tester, PaymentRepository repository) async {
  await tester.pumpWidget(MaterialApp(
      home: DriverPaymentView(
    ride: ride(),
    repository: repository,
    hub: TrackingHubService(SecureStorageService()),
  )));
  await tester.pumpAndSettle();
}

Future<void> collect(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('تسجيل التحصيل فقط'),
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('تسجيل التحصيل فقط'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'confirmed rider cash replacement enables collection after wallet rejection',
      (tester) async {
    final repository = PaymentRepository()
      ..latest = {
        ...ride(),
        'paymentMethodCode': '9',
        'selectedPaymentMethodNameAr': 'فلوسك',
        'walletPaymentPending': false,
      };
    final hub = PaymentHub();
    await tester.pumpWidget(MaterialApp(
        home: DriverPaymentView(
            ride: repository.latest, repository: repository, hub: hub)));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    repository.latest = {...ride(), 'walletPaymentPending': false};
    hub.messages.add(const TrackingHubEvent('rideStatusUpdated', {
      'rideId': 7,
      'paymentMethodCode': 'cash',
    }));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await collect(tester);
    expect(repository.collections, [1100]);
    await tester.pumpWidget(const SizedBox());
    await hub.messages.close();
  });
  testWidgets(
      'selected wallet replaces cash form and updates to actual paid state',
      (tester) async {
    final repository = PaymentRepository()
      ..latest = {
        ...ride(),
        'paymentMethodCode': '9',
        'selectedPaymentMethodNameAr': 'فلوسك',
      };
    final hub = PaymentHub();
    await tester.pumpWidget(MaterialApp(
        home: DriverPaymentView(
            ride: repository.latest, repository: repository, hub: hub)));
    await tester.pumpAndSettle();
    expect(find.text('فلوسك'), findsOneWidget);
    expect(find.textContaining('لم يتم الدفع بعد'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(repository.collections, isEmpty);
    repository.latest = {
      ...repository.latest,
      'paymentCompleted': true,
      'paymentProvider': 'Floosak',
      'paymentMethodNameAr': 'فلوسك'
    };
    hub.messages.add(const TrackingHubEvent('paymentUpdated', {'rideId': 7}));
    await tester.pumpAndSettle();
    expect(find.text('تم الدفع عبر فلوسك'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await hub.messages.close();
  });
  testWidgets('settlement during fare refresh replaces the cash form',
      (tester) async {
    final pendingDetail = Completer<Map<String, Object?>>();
    final repository = PaymentRepository()..nextDetail = pendingDetail;
    final hub = PaymentHub();
    await tester.pumpWidget(
      MaterialApp(
        home: DriverPaymentView(
          ride: ride(),
          repository: repository,
          hub: hub,
        ),
      ),
    );
    expect(repository.detailReads, 1);
    repository.latest = {
      ...ride(),
      'paymentCompleted': true,
      'paymentMethodNameAr': 'فلوسك',
      'paymentProvider': 'Floosak',
    };
    hub.messages.add(const TrackingHubEvent('paymentUpdated', {'rideId': 7}));
    await tester.pump();
    pendingDetail.complete(ride());
    await tester.pumpAndSettle();
    expect(repository.detailReads, 2);
    expect(find.text('تم الدفع عبر فلوسك'), findsOneWidget);
    expect(find.text('تسجيل التحصيل فقط'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(repository.collections, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await hub.messages.close();
  });

  testWidgets(
      'rider selecting a wallet while cash form is open prevents cash submission',
      (tester) async {
    final repository = PaymentRepository();
    await mount(tester, repository);
    repository.latest = {
      ...ride(),
      'paymentMethodCode': '9',
      'selectedPaymentMethodNameAr': 'فلوسك',
    };
    await collect(tester);
    await tester.pumpAndSettle();
    expect(find.text('فلوسك'), findsOneWidget);
    expect(find.text('تسجيل التحصيل فقط'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(repository.collections, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final state in ['paymentCompleted', 'walletPaymentPending']) {
    testWidgets('$state arriving after opening cash screen prevents collection',
        (tester) async {
      final repository = PaymentRepository();
      await mount(tester, repository);
      repository.latest = {
        ...ride(),
        state: true,
        'paymentMethodNameAr': 'جيب',
        'paymentProvider': 'Jaib',
      };
      await collect(tester);
      expect(repository.collections, isEmpty);
      if (state == 'paymentCompleted') {
        expect(find.text('تسجيل التحصيل فقط'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('تم الدفع عبر جيب'), findsOneWidget);
        expect(
            find.textContaining('إجمالي مديونيتك بعد التحصيل'), findsNothing);
      } else {
        final button = tester.widget<FilledButton>(find.ancestor(
          of: find.text('تسجيل التحصيل فقط'),
          matching: find.byType(FilledButton),
        ));
        expect(button.onPressed, isNull);
        expect(
            tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      }
    });
  }

  testWidgets('changed route at the same price requires another fare review',
      (tester) async {
    final repository = PaymentRepository();
    await mount(tester, repository);
    repository.latest = {
      ...ride(),
      'routeVersion': 1,
      'destinationDisplayName': 'الوجهة الجديدة',
      'routeChangeFees': 100,
    };
    await collect(tester);
    expect(repository.collections, isEmpty);
    expect(find.text('الوجهة الحالية: الوجهة الجديدة'), findsOneWidget);
    expect(find.text('منها رسوم تغيير الوجهة: 100 ر.ي'), findsOneWidget);
    expect(find.text('إجمالي المطلوب تحصيله: 1100 ر.ي'), findsOneWidget);
    await collect(tester);
    expect(repository.collections, [1100]);
  });

  testWidgets(
      'changed waiting fees update total and require review before collection',
      (tester) async {
    final repository = PaymentRepository();
    await mount(tester, repository);
    repository.latest = ride(waitingFee: 50);
    await collect(tester);
    expect(repository.collections, isEmpty);
    expect(find.text('إجمالي المطلوب تحصيله: 1150 ر.ي'), findsOneWidget);
    expect(find.text('صافي مستحقك من الأجرة: 950 ر.ي'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '1150');
    await collect(tester);
    expect(repository.collections, [1150]);
  });

  testWidgets('waiting beginning after opening payment blocks collection',
      (tester) async {
    final repository = PaymentRepository();
    await mount(tester, repository);
    repository.latest = ride(open: true);
    await collect(tester);
    expect(repository.collections, isEmpty);
    final button = tester.widget<FilledButton>(find.ancestor(
      of: find.text('تسجيل التحصيل فقط'),
      matching: find.byType(FilledButton),
    ));
    expect(button.onPressed, isNull);
  });

  testWidgets(
      'failed fare verification prevents collection until retry succeeds',
      (tester) async {
    final repository = PaymentRepository();
    await mount(tester, repository);
    repository.fail = true;
    await collect(tester);
    expect(repository.collections, isEmpty);
    expect(find.text('تعذر تأكيد الأجرة. أعد التحديث قبل تسجيل التحصيل.'),
        findsOneWidget);
    repository.fail = false;
    await tester.ensureVisible(find.text('تحديث الأجرة وحالة الانتظار'));
    await tester.tap(find.text('تحديث الأجرة وحالة الانتظار'));
    await tester.pumpAndSettle();
    await collect(tester);
    expect(repository.collections, [1100]);
  });

  testWidgets('refresh preserves a manually entered cash amount',
      (tester) async {
    final repository = PaymentRepository();
    await mount(tester, repository);
    await tester.enterText(find.byType(TextField), '1200');
    repository.latest = ride(waitingFee: 50);
    await collect(tester);
    expect(repository.collections, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '1200');
    await collect(tester);
    expect(repository.collections, [1200]);
  });
}
