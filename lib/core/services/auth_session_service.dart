import 'dart:async';

import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../features/auth/routes/auth_routes.dart';
import '../../features/driver/driver_routes.dart';
import '../network/api_client.dart';
import '../network/api_endpoints.dart';
import '../network/api_models.dart';
import '../realtime/tracking_hub_service.dart';
import '../storage/secure_storage_service.dart';

class AuthSessionService extends GetxService {
  AuthSessionService(this._storage, this._apiClient);

  final SecureStorageService _storage;
  final ApiClient _apiClient;
  final RxBool isAuthenticated = false.obs;
  final RxBool rememberLogin = false.obs;
  final RxnInt currentUserId = RxnInt();
  Future<void>? _identityValidation;
  int _sessionGeneration = 0;

  String? _pendingRoute;
  Object? _pendingArguments;
  bool _pendingNotificationOpen = false;
  late final String deviceId;
  Future<void> Function()? onAuthenticated;
  Future<void> Function()? onSignedOut;
  Future<void> Function()? onSessionEnded;
  Future<void> Function(Map<String, String>)? _onNotificationOpened;

  Future<void> Function(Map<String, String>)? get onNotificationOpened =>
      _onNotificationOpened;

  set onNotificationOpened(
    Future<void> Function(Map<String, String>)? handler,
  ) {
    _onNotificationOpened = handler;
    if (handler == null ||
        !_pendingNotificationOpen ||
        !isAuthenticated.value ||
        Get.currentRoute != DriverRoutes.home) {
      return;
    }
    final arguments = _pendingArguments;
    if (arguments is! Map || arguments['pushNotification'] is! Map) return;
    final payload =
        Map<String, String>.from(arguments['pushNotification'] as Map);
    _pendingRoute = null;
    _pendingArguments = null;
    _pendingNotificationOpen = false;
    unawaited(handler(payload));
  }

  bool get hasPendingNotificationOpen => _pendingNotificationOpen;

  Future<AuthSessionService> init() async {
    _apiClient.onSessionExpired = _handleServerSessionExpired;
    if (Get.isRegistered<TrackingHubService>()) {
      Get.find<TrackingHubService>().onSessionRevoked =
          _handleServerSessionExpired;
    }
    deviceId = await _storage.deviceId ?? const Uuid().v4();
    await _storage.saveDeviceId(deviceId);
    rememberLogin.value = await _storage.rememberMe;

    if (!rememberLogin.value) {
      await _storage.clear();
      isAuthenticated.value = false;
      return this;
    }

    final accessToken = await _storage.accessToken;
    final refreshToken = await _storage.refreshToken;
    isAuthenticated.value = (accessToken?.isNotEmpty ?? false) ||
        (refreshToken?.isNotEmpty ?? false);
    final storedUserId = await _storage.authenticatedUserId;
    currentUserId.value =
        storedUserId != null && storedUserId > 0 ? storedUserId : null;
    if (isAuthenticated.value) await _validateStoredSession();
    return this;
  }

  Future<void> activate({
    required String accessToken,
    required String refreshToken,
    required bool remember,
    int? userId,
  }) async {
    _sessionGeneration++;
    _identityValidation = null;
    if (remember) {
      await _storage.saveTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
      if (userId != null && userId > 0) {
        await _storage.saveAuthenticatedUserId(userId);
      }
    } else {
      await _storage.clear();
      await _storage.holdTemporaryTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
    }
    await _storage.setRememberMe(remember);
    rememberLogin.value = remember;
    isAuthenticated.value = true;
    currentUserId.value = userId != null && userId > 0 ? userId : null;
    if (currentUserId.value == null) {
      await ensureIdentity();
      return;
    }
    // Push registration belongs to every authenticated session. The
    // persistence choice only determines whether this session survives an
    // application restart; it must never behave like a sign-out.
    unawaited(onAuthenticated?.call());
  }

  /// Restores identity for older saved sessions before account-scoped reads
  /// or location publishing. An outage keeps the session available for retry.
  Future<bool> ensureIdentity() async {
    if (!isAuthenticated.value) return false;
    if (currentUserId.value != null) return true;
    await _validateStoredSession();
    return isAuthenticated.value && currentUserId.value != null;
  }

  bool requireAuthentication({
    required String returnRoute,
    Object? arguments,
  }) {
    if (isAuthenticated.value) return true;
    _pendingRoute = returnRoute;
    _pendingArguments = arguments;
    Get.toNamed<void>(AuthRoutes.signIn);
    return false;
  }

  void continueAfterAuthentication({String fallbackRoute = '/home'}) {
    final route = _pendingRoute ?? fallbackRoute;
    final arguments = _pendingArguments;
    _pendingRoute = null;
    _pendingArguments = null;
    _pendingNotificationOpen = false;
    Get.offAllNamed<void>(route, arguments: arguments);
  }

  void openNotificationFromPush(Map<String, dynamic> data) {
    final payload = _safePushPayload(data);
    if (payload.isEmpty) return;
    final arguments = <String, Object?>{
      'pushNotification': payload,
      'openNotification': true,
    };
    _pendingRoute = DriverRoutes.home;
    _pendingArguments = arguments;
    _pendingNotificationOpen = true;

    if (!isAuthenticated.value) {
      if (Get.key.currentState != null) {
        Get.offAllNamed<void>(DriverRoutes.login);
      }
      return;
    }

    if (Get.key.currentState != null) {
      final openNotification = onNotificationOpened;
      var homeFound = false;
      Get.until((route) {
        homeFound = route.settings.name == DriverRoutes.home;
        return homeFound || route.isFirst;
      });
      if (homeFound && openNotification == null) return;
      _pendingRoute = null;
      _pendingArguments = null;
      _pendingNotificationOpen = false;
      if (openNotification != null) {
        if (!homeFound) Get.toNamed<void>(DriverRoutes.home);
        unawaited(openNotification(payload));
        return;
      }
      Get.offAllNamed<void>(DriverRoutes.home, arguments: arguments);
    }
  }

  Map<String, String> _safePushPayload(Map<String, dynamic> data) {
    const allowedKeys = <String>{
      'notificationId',
      'notificationType',
      'action',
      'rideId',
      'offerId',
      'paymentId',
      'walletTransactionId',
      'cashCollectionApprovalId',
      'cashPaymentRequestId',
      'cancellationRequestId',
      'messageId',
      'safetyIncidentId',
      'safetyRecordingId',
      'driverSettlementPaymentId',
      'status',
      'approved',
      'settled',
    };
    final result = <String, String>{};
    for (final entry in data.entries) {
      if (!allowedKeys.contains(entry.key)) continue;
      final value = entry.value;
      if (value is! String && value is! num && value is! bool) continue;
      final text = '$value'.trim();
      if (text.isNotEmpty && text.length <= 256) result[entry.key] = text;
    }
    return result;
  }

  Future<void> signOut({bool revokeServerSession = true}) async {
    await onSignedOut?.call();
    if (revokeServerSession) {
      try {
        await _apiClient.dio.post<Object?>(ApiEndpoints.logout);
      } on Object {
        // Local sign-out must still finish when the device is offline.
      }
    }
    await _clearLocalSession(navigate: true);
  }

  Future<void> _validateStoredSession() {
    if (_identityValidation != null) return _identityValidation!;
    final generation = _sessionGeneration;
    late final Future<void> task;
    task = _readSessionIdentity(generation).whenComplete(() {
      if (identical(_identityValidation, task)) _identityValidation = null;
    });
    _identityValidation = task;
    return task;
  }

  Future<void> _readSessionIdentity(int generation) async {
    final result = await _apiClient.execute<Object?>(
      model: 'UserModel',
      operation: 'get',
      data: const <String, Object?>{},
    );
    if (generation != _sessionGeneration || !isAuthenticated.value) return;
    if (result is ApiSuccess<Object?>) {
      if (!_hasExpectedAccountType(result.data)) {
        await _clearLocalSession(navigate: false);
        return;
      }
      final user = result.data as Map;
      final id = int.tryParse('${user['id'] ?? user['Id']}');
      if (id == null || id <= 0) return;
      final identityWasMissing = currentUserId.value == null;
      if (rememberLogin.value) await _storage.saveAuthenticatedUserId(id);
      if (generation != _sessionGeneration || !isAuthenticated.value) return;
      currentUserId.value = id;
      if (identityWasMissing) unawaited(onAuthenticated?.call());
      return;
    }

    final failure = result as ApiFailure<Object?>;
    if (failure.problem.status >= 500 ||
        failure.problem.code == 'network_error' ||
        failure.problem.code == 'invalid_response') {
      return;
    }
    await _clearLocalSession(navigate: false);
  }

  bool _hasExpectedAccountType(Object? value) {
    if (value is! Map) return false;
    final role = value['role'] ?? value['Role'];
    if (role is num) return role.toInt() == 1;
    return role?.toString().toLowerCase() == 'driver';
  }

  Future<void> _handleServerSessionExpired() =>
      _clearLocalSession(navigate: true);

  Future<void> _clearLocalSession({required bool navigate}) async {
    _sessionGeneration++;
    _identityValidation = null;
    await onSessionEnded?.call();
    if (Get.isRegistered<TrackingHubService>()) {
      await Get.find<TrackingHubService>().disconnect();
    }
    await _storage.clear();
    rememberLogin.value = false;
    isAuthenticated.value = false;
    currentUserId.value = null;
    if (navigate && Get.key.currentState != null) {
      Get.offAllNamed<void>(DriverRoutes.login);
    }
  }
}
