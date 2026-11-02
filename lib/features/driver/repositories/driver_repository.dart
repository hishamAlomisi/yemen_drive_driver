import 'dart:convert';
import '../../../core/network/api_models.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../../shared/models/ride_waiting_snapshot.dart';
import '../models/driver_models.dart';
import '../providers/driver_provider.dart';

abstract interface class DriverRepository {
  Future<DriverAuthResult> login(DriverLoginRequest request);
  Future<DriverAuthResult> verifyOtp(
      {required String phone,
      required String code,
      required String challengeId,
      required String deviceId});
  Future<DriverSnapshot> load(int? userId);
  Future<void> markRequestViewed(
      {required int rideId, required num customerPrice});
  Future<bool> isRidePaymentCompleted(int rideId);
  Future<Map<String, Object?>> getRide(int rideId);
  Future<Map<String, Object?>> getRideForPayment(int rideId);
  Future<void> sendOffer(
      {required int rideId, required int driverId, required num amount});
  Future<void> updateRideStatus(
      {required int rideId,
      required int status,
      bool? customerPaymentEnabled,
      bool confirmPassengerBoarding = false});
  Future<Map<String, Object?>> registerCashPayment(
      {required int rideId, required num cashReceived});
  Future<Map<String, Object?>> getCashCollectionApproval(int approvalId);
  Future<Map<String, Object?>> getWallet();
  Future<Map<String, Object?>> getFinancialReport(Map<String, Object?> filters);
  Future<void> decideCashPaymentRequest(
      {required int requestId, required bool accept});
  Future<void> decideRideCancellation({
    required int requestId,
    required String operation,
    String? note,
  });
  Future<List<Map<String, Object?>>> notifications();
  Future<void> markNotificationRead(int notificationId);
  Future<bool> isRequestAvailable(int rideId);
  Future<Map<String, Object?>> requestRideCancellation(
      int rideId, String reason,
      {bool safeStopConfirmed = false});
  Future<Map<String, Object?>> getCancellationRequest(int requestId);
  Future<void> chooseCancellationRefund(
      int requestId, int method, int revision);
}

class ApiDriverRepository implements DriverRepository {
  const ApiDriverRepository(this._provider);
  final DriverProvider _provider;
  @override
  Future<void> chooseCancellationRefund(
          int requestId, int method, int revision) =>
      _provider.execute('RideCancellationRequestModel', 'update', {
        'id': requestId,
        'requestedRefundMethod': method,
        'refundChoiceRevision': revision,
        'cashReturned': method == 1,
      });

  @override
  Future<bool> isRequestAvailable(int rideId) async =>
      (await _provider.executeData('RideRequestAvailabilityModel', 'get',
          {'rideId': rideId}))['available'] ==
      true;

  @override
  Future<Map<String, Object?>> requestRideCancellation(
          int rideId, String reason, {bool safeStopConfirmed = false}) =>
      _provider.executeData('RideCancellationRequestModel', 'add', {
        'rideId': rideId,
        'reason': reason,
        'safeStopConfirmed': safeStopConfirmed
      });

  @override
  Future<Map<String, Object?>> getCancellationRequest(int requestId) =>
      _provider.executeData(
          'RideCancellationRequestModel', 'get', {'id': requestId});

  @override
  Future<Map<String, Object?>> getRide(int rideId) async {
    final detail = await _provider.executeData(
      'RideModel',
      'get',
      <String, Object?>{'id': rideId},
    );
    final ride = detail['ride'];
    if (ride is! Map || '${ride['id']}' != '$rideId') {
      throw const FormatException('تعذر تأكيد بيانات الرحلة من الخادم.');
    }
    return <String, Object?>{
      ...Map<String, Object?>.from(ride),
      ..._paymentState(detail),
    };
  }

  @override
  Future<Map<String, Object?>> getRideForPayment(int rideId) async {
    final waiting = await _provider.executeData(
      'RideWaitingModel',
      'get',
      <String, Object?>{'rideId': rideId},
    );
    final waitingSnapshot = RideWaitingSnapshot(waiting);
    final detail = await _provider.executeData(
      'RideModel',
      'get',
      <String, Object?>{'id': rideId},
    );
    final ride = detail['ride'];
    if (ride is! Map ||
        '${ride['id']}' != '$rideId' ||
        ride['totalAmount'] == null ||
        ride['waitingFee'] == null) {
      throw const FormatException('تعذر تأكيد إجمالي الرحلة من الخادم.');
    }
    return <String, Object?>{
      ...Map<String, Object?>.from(ride),
      'waitingIsOpen': waitingSnapshot.isOpen,
      ..._paymentState(detail),
    };
  }

  Map<String, Object?> _paymentState(Map<String, Object?> detail) {
    Map<Object?, Object?>? paidPayment;
    final payments = detail['payments'];
    if (payments is List) {
      for (final payment in payments) {
        if (payment is Map &&
            {'2', 'paid'}.contains('${payment['status']}'.toLowerCase())) {
          paidPayment = payment;
          break;
        }
      }
    }
    return {
      'paymentCompleted': detail['paymentCompleted'] == true,
      'walletPaymentPending': detail['walletPaymentPending'] == true,
      'finance': detail['finance'],
      'outstandingAmount': detail['outstandingAmount'],
      'paidAmount': detail['paidAmount'],
      'refundedAmount': detail['refundedAmount'],
      'paymentMethodNameAr': detail['paymentMethodNameAr'],
      'paymentMethodNameEn': detail['paymentMethodNameEn'],
      'selectedPaymentMethodNameAr': detail['selectedPaymentMethodNameAr'],
      'selectedPaymentMethodNameEn': detail['selectedPaymentMethodNameEn'],
      'paymentProvider': detail['paymentProvider'] ?? paidPayment?['provider'],
      if (detail.containsKey('paymentRequiredBeforeStart'))
        'paymentRequiredBeforeStart':
            detail['paymentRequiredBeforeStart'] == true,
    };
  }

  @override
  Future<DriverAuthResult> login(DriverLoginRequest request) async {
    final body = await _provider.login(request);
    final data = body['data'];
    final payload = data is Map ? Map<String, Object?>.from(data) : body;
    final user = payload['user'];
    return DriverAuthResult(
      accessToken: payload['accessToken']?.toString(),
      refreshToken: payload['refreshToken']?.toString(),
      trustedDeviceToken: payload['trustedDeviceToken']?.toString(),
      userId: user is Map
          ? int.tryParse('${user['id']}')
          : int.tryParse('${payload['userId']}'),
      challengeId: payload['requiresOtp'] == true
          ? payload['challengeId']?.toString()
          : null,
    );
  }

  @override
  Future<DriverAuthResult> verifyOtp(
          {required String phone,
          required String code,
          required String challengeId,
          required String deviceId}) =>
      _provider.verifyOtp(
          phone: phone,
          code: code,
          challengeId: challengeId,
          deviceId: deviceId);

  @override
  Future<DriverSnapshot> load(int? userId) async {
    final drivers = await _provider.list('DriverModel');
    final profile = drivers
        .where((item) => item['userId']?.toString() == userId?.toString())
        .firstOrNull;
    final rides = await _provider.list('RideModel');
    return DriverSnapshot(profile: profile, rides: rides);
  }

  @override
  Future<bool> isRidePaymentCompleted(int rideId) async {
    final detail = await _provider.executeData(
      'RideModel',
      'get',
      <String, Object?>{'id': rideId},
    );
    return detail['paymentCompleted'] == true;
  }

  @override
  Future<void> markRequestViewed(
          {required int rideId, required num customerPrice}) =>
      _provider.execute('RideSearchViewModel', 'update', <String, Object?>{
        'rideId': rideId,
        'customerPrice': customerPrice,
      });

  @override
  Future<void> sendOffer(
          {required int rideId, required int driverId, required num amount}) =>
      _provider.execute('RideOfferModel', 'add', <String, Object?>{
        'rideId': rideId,
        'driverId': driverId,
        'amount': amount,
        'validForSeconds': 60
      });

  @override
  Future<void> updateRideStatus(
          {required int rideId,
          required int status,
          bool? customerPaymentEnabled,
          bool confirmPassengerBoarding = false}) =>
      _provider.execute('RideModel', 'update', <String, Object?>{
        'id': rideId,
        'status': status,
        if (confirmPassengerBoarding) 'confirmPassengerBoarding': true,
        if (customerPaymentEnabled != null)
          'customerPaymentEnabled': customerPaymentEnabled
      });

  @override
  Future<Map<String, Object?>> registerCashPayment(
      {required int rideId, required num cashReceived}) async {
    final owner = await SecureStorageService.read(key: 'authenticated_user_id');
    final storageKey = 'cash_receipt_${owner}_$rideId';
    final persisted = await SecureStorageService.read(key: storageKey);
    final saved = persisted.isEmpty ? null : jsonDecode(persisted) as Map;
    if (saved != null && num.tryParse('${saved['amount']}') != cashReceived) {
      throw const FormatException(
          'توجد محاولة تحصيل لم تصل نتيجتها. أعد إرسال المبلغ نفسه أولاً لتأكيدها؛ لا تسجل قبضاً جديداً قبل حسمها.');
    }
    final reference = saved?['key'] ??
        'cash-$rideId-${DateTime.now().microsecondsSinceEpoch}';
    await SecureStorageService.write(
        key: storageKey,
        value: jsonEncode({'key': reference, 'amount': '$cashReceived'}));
    Map<String, Object?> result;
    try {
      result = await _provider
          .executeData('DriverCashPaymentModel', 'add', <String, Object?>{
        'rideId': rideId,
        'cashReceived': cashReceived,
        'idempotencyKey': reference,
        'currency': 'YER',
      });
    } on ApiProblemDetails catch (problem) {
      // Only a definite validation/permission rejection proves no receipt was committed.
      if (problem.status >= 400 &&
          problem.status < 500 &&
          problem.status != 408 &&
          problem.status != 409 &&
          problem.status != 429) {
        await SecureStorageService.delete(key: storageKey);
      }
      rethrow;
    }
    // A lost response retains this reference, including across app restarts.
    await SecureStorageService.delete(key: storageKey);
    return result;
  }

  @override
  Future<Map<String, Object?>> getCashCollectionApproval(int approvalId) =>
      _provider
          .executeData('CashCollectionApprovalModel', 'get', <String, Object?>{
        'id': approvalId,
      });

  @override
  Future<Map<String, Object?>> getWallet() =>
      _provider.executeData('WalletModel', 'get', <String, Object?>{});

  @override
  Future<Map<String, Object?>> getFinancialReport(
          Map<String, Object?> filters) =>
      _provider.financialReport(filters);

  @override
  Future<void> decideCashPaymentRequest(
          {required int requestId, required bool accept}) =>
      _provider.execute('CashPaymentRequestModel', accept ? 'accept' : 'reject',
          <String, Object?>{'id': requestId});

  @override
  Future<void> decideRideCancellation({
    required int requestId,
    required String operation,
    String? note,
  }) =>
      _provider.execute(
        'RideCancellationRequestModel',
        operation,
        <String, Object?>{'id': requestId, if (note != null) 'note': note},
      );

  @override
  Future<List<Map<String, Object?>>> notifications() =>
      _provider.list('NotificationModel');

  @override
  Future<void> markNotificationRead(int notificationId) =>
      _provider.execute('NotificationModel', 'update', <String, Object?>{
        'id': notificationId,
        'isRead': true,
      });
}
