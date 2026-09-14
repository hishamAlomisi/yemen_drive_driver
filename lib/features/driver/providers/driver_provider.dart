import '../../../core/network/api_client.dart';
import '../../../core/network/api_models.dart';

import '../models/driver_models.dart';

class DriverProvider {
  const DriverProvider(this._client);
  final ApiClient _client;

  Future<Map<String, Object?>> login(DriverLoginRequest request) async {
    final response = await _client.dio.post<Object?>(
      'auth/login',
      data: <String, Object?>{
        'phoneNumber': request.phone,
        'password': request.password,
        'deviceId': 'driver-device',
        'isTrustedDevice': true,
      },
    );
    return _map(response.data);
  }

  Future<DriverAuthResult> verifyOtp(
      {required String phone,
      required String code,
      required String challengeId}) async {
    final response = await _client.dio.post<Object?>(
      'auth/sign-in/verify-device',
      data: <String, Object?>{
        'phoneNumber': phone,
        'code': code,
        'challengeId': challengeId,
        'deviceId': 'driver-device',
      },
    );
    return _auth(_map(response.data));
  }

  Future<List<Map<String, Object?>>> list(String model) async {
    final result = await _client.execute<List<Map<String, Object?>>>(
      model: model,
      operation: 'list',
      parse: (json) => json is List
          ? json.map((item) => Map<String, Object?>.from(item as Map)).toList()
          : <Map<String, Object?>>[],
    );
    if (result is ApiFailure<List<Map<String, Object?>>>) throw result.problem;
    return (result as ApiSuccess<List<Map<String, Object?>>>).data;
  }

  Future<void> execute(
      String model, String operation, Map<String, Object?> data) async {
    final result = await _client.execute<Object?>(
        model: model, operation: operation, data: data);
    if (result is ApiFailure<Object?>) throw result.problem;
  }

  Future<Map<String, Object?>> executeData(
      String model, String operation, Map<String, Object?> data) async {
    final result = await _client.execute<Object?>(model: model, operation: operation, data: data);
    if (result is ApiFailure<Object?>) throw result.problem;
    final dataValue = (result as ApiSuccess<Object?>).data;
    return dataValue is Map ? Map<String, Object?>.from(dataValue) : <String, Object?>{};
  }

  DriverAuthResult _auth(Map<String, Object?> body) {
    final data = body['data'];
    final payload = data is Map ? Map<String, Object?>.from(data) : body;
    final user = payload['user'];
    return DriverAuthResult(
      accessToken: payload['accessToken']?.toString(),
      refreshToken: payload['refreshToken']?.toString(),
      userId: user is Map
          ? int.tryParse('${user['id']}')
          : int.tryParse('${payload['userId']}'),
      challengeId: payload['challengeId']?.toString(),
    );
  }

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};
}
