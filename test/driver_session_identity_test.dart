import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/network/api_models.dart';
import 'package:yemen_drive_driver/core/services/auth_session_service.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';

class _Storage extends SecureStorageService {
  _Storage({this.remembered = true, this.savedId});
  bool remembered;
  int? savedId;
  String? access = 'existing-access';
  String? refresh = 'existing-refresh';
  String? persistedAccess = 'existing-access';
  String? persistedRefresh = 'existing-refresh';
  int clears = 0;
  final savedIds = <int>[];

  @override
  Future<bool> get rememberMe async => remembered;
  @override
  Future<int?> get authenticatedUserId async => savedId;
  @override
  Future<String?> get accessToken async => access;
  @override
  Future<String?> get refreshToken async => refresh;
  @override
  Future<String?> get deviceId async => 'identity-test-device';
  @override
  Future<void> saveDeviceId(String value) async {}
  @override
  Future<void> saveAuthenticatedUserId(int value) async {
    savedId = value;
    savedIds.add(value);
  }

  @override
  Future<void> setRememberMe(bool value) async => remembered = value;
  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    access = persistedAccess = accessToken;
    refresh = persistedRefresh = refreshToken;
  }

  @override
  Future<void> holdTemporaryTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    access = accessToken;
    refresh = refreshToken;
  }

  @override
  Future<void> clear() async {
    clears++;
    access = persistedAccess = null;
    refresh = persistedRefresh = null;
    savedId = null;
    remembered = false;
  }
}

class _Api extends ApiClient {
  _Api(super.storage, this.respond);
  Future<ApiResult<Object?>> Function() respond;
  int identityReads = 0;

  @override
  Future<ApiResult<T>> execute<T>({
    required String model,
    required String operation,
    Object? data,
    T Function(Object?)? parse,
  }) async {
    expect(model, 'UserModel');
    expect(operation, 'get');
    expect(data, isEmpty);
    identityReads++;
    final result = await respond();
    if (result is ApiFailure<Object?>) return ApiFailure<T>(result.problem);
    final value = (result as ApiSuccess<Object?>).data;
    return ApiSuccess<T>(parse == null ? value as T : parse(value));
  }
}

const _verifiedDriver = ApiSuccess<Object?>({'id': 16, 'role': 1});
const _unavailable = ApiFailure<Object?>(
  ApiProblemDetails(
    title: 'Unavailable',
    status: 503,
    code: 'network_error',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => Get.testMode = true);
  tearDown(() => Get.reset());

  test('legacy remembered tokens restore and persist their verified identity',
      () async {
    final storage = _Storage();
    final api = _Api(storage, () async => _verifiedDriver);
    final session = AuthSessionService(storage, api);

    await session.init();

    expect(session.isAuthenticated.value, isTrue);
    expect(session.currentUserId.value, 16);
    expect(storage.savedId, 16);
    expect(storage.remembered, isTrue);
    expect(storage.access, 'existing-access');
    expect(storage.refresh, 'existing-refresh');
    expect(storage.clears, 0);
  });

  test('the verified user replaces a stale stored identity', () async {
    final storage = _Storage(savedId: 99);
    final api = _Api(storage, () async => _verifiedDriver);
    final session = AuthSessionService(storage, api);

    await session.init();

    expect(session.currentUserId.value, 16);
    expect(storage.savedId, 16);
    expect(storage.savedIds, [16]);
  });

  test('an unavailable server retains the stored identity and tokens',
      () async {
    final storage = _Storage(savedId: 16);
    final api = _Api(storage, () async => _unavailable);
    final session = AuthSessionService(storage, api);

    await session.init();

    expect(session.isAuthenticated.value, isTrue);
    expect(session.currentUserId.value, 16);
    expect(session.rememberLogin.value, isTrue);
    expect(storage.savedId, 16);
    expect(storage.access, 'existing-access');
    expect(storage.refresh, 'existing-refresh');
    expect(storage.clears, 0);
    expect(storage.savedIds, isEmpty);
  });

  test('an unidentified session stays gated until the server recovers',
      () async {
    final storage = _Storage();
    final api = _Api(storage, () async => _unavailable);
    final session = AuthSessionService(storage, api);
    var authenticatedCallbacks = 0;
    session.onAuthenticated = () async => authenticatedCallbacks++;

    await session.init();
    expect(await session.ensureIdentity(), isFalse);
    expect(session.currentUserId.value, isNull);
    expect(session.isAuthenticated.value, isTrue);
    expect(authenticatedCallbacks, 0);

    api.respond = () async => _verifiedDriver;
    expect(await session.ensureIdentity(), isTrue);
    expect(session.currentUserId.value, 16);
    expect(storage.savedId, 16);
    expect(authenticatedCallbacks, 1);
  });

  test('temporary login validates a missing identity without remembering it',
      () async {
    final storage = _Storage(remembered: false);
    final reply = Completer<ApiResult<Object?>>();
    final api = _Api(storage, () => reply.future);
    final session = AuthSessionService(storage, api);
    var authenticatedCallbacks = 0;
    session.onAuthenticated = () async => authenticatedCallbacks++;

    final activation = session.activate(
      accessToken: 'temporary-access',
      refreshToken: 'temporary-refresh',
      remember: false,
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.currentUserId.value, isNull);
    expect(authenticatedCallbacks, 0);
    expect(api.identityReads, 1);

    reply.complete(_verifiedDriver);
    await activation;

    expect(session.currentUserId.value, 16);
    expect(session.isAuthenticated.value, isTrue);
    expect(authenticatedCallbacks, 1);
    expect(session.rememberLogin.value, isFalse);
    expect(storage.remembered, isFalse);
    expect(storage.access, 'temporary-access');
    expect(storage.refresh, 'temporary-refresh');
    expect(storage.persistedAccess, isNull);
    expect(storage.persistedRefresh, isNull);
    expect(storage.savedId, isNull);
    expect(storage.savedIds, isEmpty);
  });

  test('sign-out during identity validation cannot restore the ended account',
      () async {
    final storage = _Storage();
    final reply = Completer<ApiResult<Object?>>();
    final api = _Api(storage, () => reply.future);
    final session = AuthSessionService(storage, api);
    final initialization = session.init();
    await Future<void>.delayed(Duration.zero);

    await session.signOut(revokeServerSession: false);
    reply.complete(_verifiedDriver);
    await initialization;

    expect(session.isAuthenticated.value, isFalse);
    expect(session.currentUserId.value, isNull);
    expect(storage.savedId, isNull);
    expect(storage.savedIds, isEmpty);
    expect(storage.access, isNull);
    expect(storage.refresh, isNull);
  });

  test('a successful response for a non-driver clears the session', () async {
    final storage = _Storage(savedId: 16);
    final api = _Api(
      storage,
      () async => const ApiSuccess<Object?>({'id': 16, 'role': 0}),
    );
    final session = AuthSessionService(storage, api);

    await session.init();

    expect(session.isAuthenticated.value, isFalse);
    expect(session.currentUserId.value, isNull);
    expect(storage.access, isNull);
    expect(storage.savedId, isNull);
  });
}
