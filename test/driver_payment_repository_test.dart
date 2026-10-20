import 'package:flutter_test/flutter_test.dart';

import '../lib/core/network/api_client.dart';
import '../lib/core/network/api_models.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/features/driver/providers/driver_provider.dart';
import '../lib/features/driver/repositories/driver_repository.dart';

class PaymentApi extends ApiClient {
  PaymentApi() : super(SecureStorageService());
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
            },
            'payments': <Object?>[],
            'totalAmount': 1150,
          };
    return ApiSuccess<T>(result as T);
  }
}

void main() {
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

  test('unverified waiting response cannot enable payment', () async {
    final api = PaymentApi()..waiting = {};
    final repository = ApiDriverRepository(DriverProvider(api));
    await expectLater(repository.getRideForPayment(7), throwsFormatException);
  });
}
