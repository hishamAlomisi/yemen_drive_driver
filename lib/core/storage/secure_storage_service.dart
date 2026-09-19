import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

class SecureStorageService extends GetxService {
  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenKey = 'refresh_token';
  static const String _rememberMeKey = 'remember_me';
  static const String _userIdKey = 'authenticated_user_id';
  static const String _deviceIdKey = 'device_id';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  String? _temporaryAccessToken;
  String? _temporaryRefreshToken;

  Future<String?> get accessToken async =>
      _temporaryAccessToken ?? await _storage.read(key: _accessTokenKey);
  Future<String?> get refreshToken async =>
      _temporaryRefreshToken ?? await _storage.read(key: _refreshTokenKey);
  Future<bool> get rememberMe async =>
      await _storage.read(key: _rememberMeKey) == 'true';
  Future<String?> get deviceId => _storage.read(key: _deviceIdKey);
  Future<int?> get authenticatedUserId async =>
      int.tryParse(await _storage.read(key: _userIdKey) ?? '');

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) {
    _temporaryAccessToken = accessToken;
    _temporaryRefreshToken = refreshToken;
    return Future.wait<void>(<Future<void>>[
      _storage.write(key: _accessTokenKey, value: accessToken),
      _storage.write(key: _refreshTokenKey, value: refreshToken),
    ]);
  }

  /// Keeps a valid session available for the current process without writing
  /// its tokens to disk when the driver did not opt into "remember me".
  Future<void> holdTemporaryTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    _temporaryAccessToken = accessToken;
    _temporaryRefreshToken = refreshToken;
  }

  /// Applies a refreshed session using the same persistence decision selected
  /// at sign-in. A background token refresh must never turn a temporary
  /// session into a remembered one.
  Future<void> replaceTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    if (await rememberMe) {
      await saveTokens(accessToken: accessToken, refreshToken: refreshToken);
      return;
    }
    await holdTemporaryTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<void> saveAuthenticatedUserId(int value) =>
      _storage.write(key: _userIdKey, value: value.toString());

  Future<void> setRememberMe(bool value) =>
      _storage.write(key: _rememberMeKey, value: value.toString());

  Future<void> saveDeviceId(String value) =>
      _storage.write(key: _deviceIdKey, value: value);

  Future<bool> isTrustedPhone(String phone) async =>
      await _storage.read(key: 'trusted_device_$phone') == 'true';

  Future<void> trustPhone(String phone) =>
      _storage.write(key: 'trusted_device_$phone', value: 'true');

  Future<void> clear() {
    _temporaryAccessToken = null;
    _temporaryRefreshToken = null;
    return Future.wait<void>(<Future<void>>[
      _storage.delete(key: _accessTokenKey),
      _storage.delete(key: _refreshTokenKey),
      _storage.delete(key: _rememberMeKey),
      _storage.delete(key: _userIdKey),
    ]);
  }

  static Future<void> write({
    required String key,
    required String value,
  }) =>
      Future.wait<void>(<Future<void>>[
        _storage.write(key: key, value: value),
      ]);
  static Future<void> delete({required String key}) =>
      _storage.delete(key: key);

  static Future<String> read({required String key}) async {
    final result = await _storage.read(key: key);
    if (result != null) {
      return result;
    }
    return "";
  }
}
