import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/services/otp_push_request_fields.dart';
import '../../../../core/services/otp_sms_service.dart';
import '../models/registration_models.dart';

class RegistrationProvider {
  const RegistrationProvider(this._client,
      {OtpPushFieldsSupplier? otpPushFields,})
      : _otpPushFields = otpPushFields;

  final ApiClient _client;
  final OtpPushFieldsSupplier? _otpPushFields;

  Future<Response<Object?>> requestOtp(SignUpDraft draft) async {
    final otpFields = await OtpSmsService.prepareRequest(
      pushFields: () =>
          _otpPushFields?.call(null) ?? requestOtpPushFields(_client),
    );
    return _client.dio.post<Object?>(
      '${ApiEndpoints.signUp}/request-otp',
      data: {
        ...draft.toJson(),
        'clientType': 'driver',
        ...otpFields,
      },
    );
  }

  Future<Response<Object?>> verifyOtp({
    required String phone,
    required String code,
    String? challengeId,
  }) =>
      _client.dio.post<Object?>(
        'auth/verify-otp',
        data: <String, Object?>{
          'destination': phone,
          'code': code,
          'purpose': 'signUp',
          'challengeId': challengeId,
        },
      );

  Future<Response<Object?>> complete({
    required SignUpDraft signUp,
    required ProfileDraft profile,
    required String password,
    String? verificationToken,
    required String deviceId,
  }) =>
      _client.dio.post<Object?>(
        ApiEndpoints.signUp,
        data: <String, Object?>{
          'phoneNumber': signUp.phone,
          'displayName': profile.fullName,
          'role': 'Customer',
          'password': password,
          'verificationToken': verificationToken,
          'deviceId': deviceId,
          'gender': profile.gender,
          'street': profile.street,
          'city': profile.city,
          'district': profile.district,
        },
      );
}
