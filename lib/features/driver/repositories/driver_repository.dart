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
      {required int rideId, required int status, bool? customerPaymentEnabled});
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
      int rideId, String reason);
  Future<Map<String, Object?>> getCancellationRequest(int requestId);
}

class ApiDriverRepository implements DriverRepository {
  const ApiDriverRepository(this._provider);
  final DriverProvider _provider;

  @override
  Future<bool> isRequestAvailable(int rideId) async =>
      (await _provider.executeData('RideRequestAvailabilityModel', 'get',
          {'rideId': rideId}))['available'] ==
      true;

  @override
  Future<Map<String, Object?>> requestRideCancellation(
          int rideId, String reason) =>
      _provider.executeData('RideCancellationRequestModel', 'add',
          {'rideId': rideId, 'reason': reason});

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
      'paymentCompleted':
          detail['paymentCompleted'] == true || paidPayment != null,
      'walletPaymentPending': detail['walletPaymentPending'] == true,
      'paymentMethodNameAr': detail['paymentMethodNameAr'],
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
    final payments = detail['payments'];
    return payments is List &&
        payments.any((raw) {
          if (raw is! Map) return false;
          final status = '${raw['status'] ?? ''}'.toLowerCase();
          return status == '2' || status == 'paid';
        });
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
          bool? customerPaymentEnabled}) =>
      _provider.execute('RideModel', 'update', <String, Object?>{
        'id': rideId,
        'status': status,
        if (customerPaymentEnabled != null)
          'customerPaymentEnabled': customerPaymentEnabled
      });

  @override
  Future<Map<String, Object?>> registerCashPayment(
          {required int rideId, required num cashReceived}) =>
      _provider.executeData('DriverCashPaymentModel', 'add', <String, Object?>{
        'rideId': rideId,
        'cashReceived': cashReceived,
        'currency': 'YER',
      });

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
