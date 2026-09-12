class DriverLoginRequest {
  const DriverLoginRequest({required this.phone, required this.password});
  final String phone;
  final String password;
}

class DriverAuthResult {
  const DriverAuthResult(
      {this.accessToken, this.refreshToken, this.userId, this.challengeId});
  final String? accessToken;
  final String? refreshToken;
  final int? userId;
  final String? challengeId;
  bool get requiresOtp => challengeId?.isNotEmpty ?? false;
}

class DriverSnapshot {
  const DriverSnapshot({required this.profile, required this.rides});
  final Map<String, Object?>? profile;
  final List<Map<String, Object?>> rides;
}
