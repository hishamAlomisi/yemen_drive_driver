import 'package:get/get.dart';

import '../network/api_client.dart';
import 'auth_session_service.dart';
import 'push_notifications_service.dart';

export 'push_notifications_service.dart' show OtpPushRequestCancelled;

typedef OtpPushFieldsSupplier = Future<Map<String, Object?>> Function(
    String? deviceId);

Future<Map<String, Object?>> requestOtpPushFields(ApiClient client,
    {String? deviceId}) async {
  if (!Get.isRegistered<PushNotificationsService>()) return {};
  final push = Get.find<PushNotificationsService>();
  final generation = push.otpPushRequestGeneration;
  push.ensureOtpPushRequestActive(generation);
  String? token;
  try {
    final response = await client.dio.get<Object?>('auth/otp-delivery');
    push.ensureOtpPushRequestActive(generation);
    final body = response.data;
    if (body is! Map || body['success'] != true) return {};
    final data = body['data'];
    if (data is! Map || data['testPushEnabled'] != true) return {};
    token = await push.requestOtpPushToken();
    push.ensureOtpPushRequestActive(generation);
  } on Object {
    push.ensureOtpPushRequestActive(generation);
    rethrow;
  }
  if (token == null || token.isEmpty) {
    throw const FormatException(
      'تعذر تجهيز إشعار رمز التحقق. فعّل إشعارات التطبيق ثم أعد المحاولة.',
    );
  }
  final installation = deviceId ??
      (Get.isRegistered<AuthSessionService>()
          ? Get.find<AuthSessionService>().deviceId
          : null);
  return {
    'otpPushToken': token,
    'deviceId': installation,
    'clientType': 'driver',
  };
}
