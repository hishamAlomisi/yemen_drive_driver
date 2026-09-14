import '../models/driver_models.dart';
import '../providers/driver_provider.dart';

abstract interface class DriverRepository {
  Future<DriverAuthResult> login(DriverLoginRequest request);
  Future<DriverAuthResult> verifyOtp(
      {required String phone,
      required String code,
      required String challengeId});
  Future<DriverSnapshot> load(int? userId);
  Future<void> sendOffer(
      {required int rideId, required int driverId, required num amount});
  Future<void> updateRideStatus({required int rideId, required int status});
  Future<void> updateLocation(
      {required int driverId,
      required double latitude,
      required double longitude});
  Future<Map<String, Object?>> registerCashPayment({required int rideId, required num cashReceived});
  Future<List<Map<String, Object?>>> notifications();
}

class ApiDriverRepository implements DriverRepository {
  const ApiDriverRepository(this._provider);
  final DriverProvider _provider;

  @override
  Future<DriverAuthResult> login(DriverLoginRequest request) async {
    final body = await _provider.login(request);
    final data = body['data'];
    final payload = data is Map ? Map<String, Object?>.from(data) : body;
    final user = payload['user'];
    return DriverAuthResult(
      accessToken: payload['accessToken']?.toString(),
      refreshToken: payload['refreshToken']?.toString(),
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
          required String challengeId}) =>
      _provider.verifyOtp(phone: phone, code: code, challengeId: challengeId);

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
  Future<void> sendOffer(
          {required int rideId, required int driverId, required num amount}) =>
      _provider.execute('RideOfferModel', 'add', <String, Object?>{
        'rideId': rideId,
        'driverId': driverId,
        'amount': amount,
        'validForSeconds': 300
      });

  @override
  Future<void> updateRideStatus({required int rideId, required int status}) =>
      _provider.execute('RideModel', 'update',
          <String, Object?>{'id': rideId, 'status': status});

  @override
  Future<void> updateLocation(
          {required int driverId,
          required double latitude,
          required double longitude}) =>
      _provider.execute('DriverLocationModel', 'update', <String, Object?>{
        'driverId': driverId,
        'latitude': latitude,
        'longitude': longitude,
        'isOnline': true
      });

  @override
  Future<Map<String, Object?>> registerCashPayment({required int rideId, required num cashReceived}) =>
      _provider.executeData('DriverCashPaymentModel', 'add', <String, Object?>{
        'rideId': rideId,
        'cashReceived': cashReceived,
        'currency': 'YER',
      });

  @override
  Future<List<Map<String, Object?>>> notifications() =>
      _provider.list('NotificationModel');
}
