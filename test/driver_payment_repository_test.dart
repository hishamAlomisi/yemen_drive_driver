import 'package:flutter_test/flutter_test.dart';

import '../lib/core/network/api_client.dart';
import '../lib/core/network/api_models.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/features/driver/providers/driver_provider.dart';
import '../lib/features/driver/repositories/driver_repository.dart';

class PaymentApi extends ApiClient {
  PaymentApi() : super(SecureStorageService());
  bool walletPaymentPending = false;
  List<Object?> payments = [];
  String? paymentMethodNameAr;
  String? paymentProvider;
  bool paymentRequiredBeforeStart = false;
  Map<String, Object?> waiting = {
    'serverNowUtc': '2026-10-19T10:00:00Z',
    'session': {'isOpen': true},
  };

  @override
  Future<ApiResult<T>> execute<T>(
      {required String model,
      required String operation,
      Object? data,
      T Function(Object?)? parse}) async {
    expect(operation, 'get');
    final result = model == 'RideWaitingModel'
        ? waiting
        : {
            'ride': {
              'id': 7,
              'customerPrice': 1000,
              'waitingFee': 50,
              'serviceFee': 100,
              'totalAmount': 1150,
              'driverShare': 950,
              'platformShare': 200,
              'paymentMethodCode': 'Floosak',
              'paymentRequiredBeforeStart': paymentRequiredBeforeStart,
            },
            'payments': payments,
            'walletPaymentPending': walletPaymentPending,
            'paymentMethodNameAr': paymentMethodNameAr,
            'paymentProvider': paymentProvider,
            'totalAmount': 1150,
          };
    return ApiSuccess<T>(result as T);
  }
}

void main() {
  test('cash snapshot carries pending wallet and every provider paid status',
      () async {
    final api = PaymentApi()..walletPaymentPending = true;
    final repository = ApiDriverRepository(DriverProvider(api));
    final pending = await repository.getRideForPayment(7);
    expect(pending['walletPaymentPending'], isTrue);
    expect(pending['paymentCompleted'], isFalse);
    expect((await repository.getRide(7))['walletPaymentPending'], isTrue);
    api.walletPaymentPending = false;
    api.payments = [
      {'provider': 'Floosak', 'status': 2}
    ];
    final paid = await repository.getRideForPayment(7);
    expect(paid['walletPaymentPending'], isFalse);
    expect(paid['paymentCompleted'], isTrue);
    expect((await repository.getRide(7))['paymentCompleted'], isTrue);
  });

  test('payment snapshot unwraps ride detail and carries open waiting guard',
      () async {
    final api = PaymentApi();
    final repository = ApiDriverRepository(DriverProvider(api));
    final detail = await repository.getRideForPayment(7);
    expect(detail['id'], 7);
    expect(detail['totalAmount'], 1150);
    expect(detail['waitingFee'], 50);
    expect(detail['driverShare'], 950);
    expect(detail['waitingIsOpen'], isTrue);
    api.waiting['session'] = {'isOpen': false};
    expect((await repository.getRideForPayment(7))['waitingIsOpen'], isFalse);
  });

  test('ride and cash detail retain actual method and the early payment gate',
      () async {
    final api = PaymentApi()..paymentRequiredBeforeStart = true;
    final repository = ApiDriverRepository(DriverProvider(api));
    final required = await repository.getRide(7);
    expect(required['paymentRequiredBeforeStart'], isTrue);
    expect(required['paymentMethodNameAr'], isNull);
    api
      ..paymentRequiredBeforeStart = false
      ..payments = [
        {'provider': 'Jaib', 'status': 'Paid'}
      ]
      ..paymentMethodNameAr = 'جيب'
      ..paymentProvider = 'Jaib';
    for (final detail in [
      await repository.getRide(7),
      await repository.getRideForPayment(7),
    ]) {
      expect(detail['paymentCompleted'], isTrue);
      expect(detail['paymentRequiredBeforeStart'], isFalse);
      expect(detail['paymentMethodNameAr'], 'جيب');
      expect(detail['paymentProvider'], 'Jaib');
      expect(detail['paymentMethodCode'], 'Floosak');
    }
  });

  test('unverified waiting response cannot enable payment', () async {
    final api = PaymentApi()..waiting = {};
    final repository = ApiDriverRepository(DriverProvider(api));
    await expectLater(repository.getRideForPayment(7), throwsFormatException);
  });
}
