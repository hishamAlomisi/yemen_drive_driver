import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/services/otp_push_request_fields.dart';
import '../../../../core/services/otp_sms_service.dart';
import '../models/password_reset_models.dart';

class PasswordResetProvider {
  const PasswordResetProvider(this._client,
      {OtpPushFieldsSupplier? otpPushFields,})
      : _otpPushFields = otpPushFields;
  final ApiClient _client;
  final OtpPushFieldsSupplier? _otpPushFields;

  Future<Response<Object?>> request(
      {required String identity, required RecoveryChannel channel,}) async {
    final otpFields = await OtpSmsService.prepareRequest(
      pushFields: () =>
          _otpPushFields?.call(null) ?? requestOtpPushFields(_client),
    );
    return _client.dio
        .post<Object?>('auth/password/request-reset', data: <String, Object?>{
      'identity': identity,
      'channel': channel.name,
      'clientType': 'driver',
      ...otpFields,
    },);
  }

  Future<Response<Object?>> verify(
          {required String identity, required String code,}) =>
      _client.dio.post<Object?>('auth/verify-otp', data: <String, Object?>{
        'destination': identity,
        'code': code,
        'purpose': 'passwordReset',
      },);

  Future<Response<Object?>> reset(
          {required String identity,
          required String password,
          String? verificationToken,}) =>
      _client.dio.post<Object?>('auth/password/reset', data: <String, Object?>{
        'identity': identity,
        'newPassword': password,
        'verificationToken': verificationToken,
      },);
}
