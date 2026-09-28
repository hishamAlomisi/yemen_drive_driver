class DriverLoginRequest {
  const DriverLoginRequest({
    required this.phone,
    required this.password,
    required this.deviceId,
    this.trustedDeviceToken,
  });
  final String phone;
  final String password;
  final String deviceId;
  final String? trustedDeviceToken;
}

class DriverAuthResult {
  const DriverAuthResult(
      {this.accessToken,
      this.refreshToken,
      this.userId,
      this.challengeId,
      this.trustedDeviceToken});
  final String? accessToken;
  final String? refreshToken;
  final int? userId;
  final String? challengeId;
  final String? trustedDeviceToken;
  bool get requiresOtp => challengeId?.isNotEmpty ?? false;
}

class DriverSnapshot {
  const DriverSnapshot({required this.profile, required this.rides});
  final Map<String, Object?>? profile;
  final List<Map<String, Object?>> rides;
}
