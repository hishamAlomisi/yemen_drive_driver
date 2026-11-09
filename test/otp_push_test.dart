import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/services/auth_session_service.dart';
import 'package:yemen_drive_driver/core/services/otp_push_request_fields.dart';
import 'package:yemen_drive_driver/core/services/push_notifications_service.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';
import 'package:yemen_drive_driver/features/auth/login/models/login_models.dart';
import 'package:yemen_drive_driver/features/auth/login/providers/login_provider.dart';
import 'package:yemen_drive_driver/features/auth/password_reset/models/password_reset_models.dart';
import 'package:yemen_drive_driver/features/auth/password_reset/providers/password_reset_provider.dart';
import 'package:yemen_drive_driver/features/auth/registration/models/registration_models.dart';
import 'package:yemen_drive_driver/features/auth/registration/providers/registration_provider.dart';
import 'package:yemen_drive_driver/features/driver/models/driver_models.dart';
import 'package:yemen_drive_driver/features/driver/providers/driver_provider.dart';

class _Storage extends SecureStorageService {
  int pendingCleared = 0;
  @override
  Future<void> clearPendingPushToken() async {
    pendingCleared++;
  }
}

class _Session extends AuthSessionService {
  _Session(_Storage super.storage, super.api);
  int pushesOpened = 0;
  @override
  String get deviceId => 'synthetic-device';
  @override
  void openNotificationFromPush(Map<String, dynamic> data) {
    pushesOpened++;
  }
}

class _Adapter implements HttpClientAdapter {
  bool testPushEnabled = true;
  Completer<void>? pendingCapability;
  bool capabilityFails = false;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.method == 'GET') {
      await pendingCapability?.future;
      if (capabilityFails) throw StateError('synthetic capability failure');
    }
    return ResponseBody.fromString(
      jsonEncode({
        'success': true,
        'data': options.method == 'GET'
            ? {'testPushEnabled': testPushEnabled}
            : {'requiresOtp': true, 'challengeId': 'synthetic-challenge'},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Api extends ApiClient {
  _Api(this.adapter) : super(_Storage()) {
    dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/'));
    dio.httpClientAdapter = adapter;
  }
  final _Adapter adapter;
}

class _Settings implements NotificationSettings {
  _Settings(this.authorizationStatus);
  @override
  final AuthorizationStatus authorizationStatus;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Messaging implements FirebaseMessaging {
  AuthorizationStatus permission = AuthorizationStatus.authorized;
  int permissionRequests = 0;
  int tokenRequests = 0;
  int deleted = 0;
  final autoInit = <bool>[];
  Completer<String?>? pendingToken;
  Completer<NotificationSettings>? pendingPermission;
  Completer<void>? pendingAutoInit;
  String? token = ' synthetic-fcm-token ';
  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    permissionRequests++;
    return await (pendingPermission?.future ??
        Future.value(_Settings(permission)));
  }

  @override
  Future<void> setAutoInitEnabled(bool enabled) async {
    autoInit.add(enabled);
    if (enabled) await pendingAutoInit?.future;
  }

  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) {
    tokenRequests++;
    return pendingToken?.future ?? Future.value(token);
  }

  @override
  Future<void> deleteToken() async {
    deleted++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AndroidNotifications implements AndroidFlutterLocalNotificationsPlugin {
  bool? enabled = true;
  Completer<bool?>? pendingEnabled;
  int checks = 0;
  @override
  Future<bool?> areNotificationsEnabled() async {
    checks++;
    return await (pendingEnabled?.future ?? Future.value(enabled));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifications implements FlutterLocalNotificationsPlugin {
  final android = _AndroidNotifications();
  final shown = <Map<String, Object?>>[];
  @override
  T? resolvePlatformSpecificImplementation<
          T extends FlutterLocalNotificationsPlatform>() =>
      android as T;
  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add({
      'id': id,
      'title': title,
      'body': body,
      'payload': payload,
      'channel': notificationDetails?.android?.channelId,
      'details': notificationDetails,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixture {
  _Fixture() {
    api = _Api(adapter);
    session = _Session(storage, api);
    push = PushNotificationsService(
      api,
      session,
      storage,
      messaging: messaging,
      localNotifications: notifications,
    );
  }
  final adapter = _Adapter();
  final storage = _Storage();
  final messaging = _Messaging();
  final notifications = _Notifications();
  late final _Api api;
  late final _Session session;
  late final PushNotificationsService push;
  void register() {
    Get.put<AuthSessionService>(session);
    Get.put<PushNotificationsService>(push);
  }
}

Map<String, dynamic> otpData({
  String clientType = 'driver',
  DateTime? expires,
}) =>
    {
      'action': 'test_otp',
      'clientType': clientType,
      'challengeId': 'synthetic-challenge',
      'purpose': 'signInDriver',
      'expiresAtUtc':
          (expires ?? DateTime.now().toUtc().add(const Duration(minutes: 5)))
              .toIso8601String(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => Get.testMode = true);
  tearDown(() {
    Get.reset();
  });

  test('foreground data notifications display both app icons', () async {
    final f = _Fixture();
    await f.push.showForegroundNotification(
      const RemoteMessage(
        data: {
          'notificationRenderer': 'app',
          'notificationId': '91',
          'title': 'تحديث الرحلة',
          'body': 'رسالة تجريبية',
          'action': 'open_active_ride',
        },
      ),
    );
    final shown = f.notifications.shown.single;
    final details = (shown['details'] as NotificationDetails).android!;
    expect(details.icon, 'ic_stat_yemendrive');
    expect(
      (details.largeIcon as DrawableResourceAndroidBitmap).data,
      'ic_brand_notification',
    );
    expect(shown['body'], 'رسالة تجريبية');
  });

  test(
      'signed-out device gets a push target without creating an authenticated installation',
      () async {
    final f = _Fixture();
    expect(await f.push.requestOtpPushToken(), 'synthetic-fcm-token');
    expect(f.session.isAuthenticated.value, isFalse);
    expect(f.adapter.requests, isEmpty);
    expect(f.messaging.autoInit, [true]);
  });

  test('concurrent OTP requests share token preparation', () async {
    final f = _Fixture();
    f.messaging.pendingToken = Completer<String?>();
    final first = f.push.requestOtpPushToken();
    final second = f.push.requestOtpPushToken();
    await Future<void>.delayed(Duration.zero);
    f.messaging.pendingToken!.complete('synthetic-later-token');
    expect(await first, 'synthetic-later-token');
    expect(await second, 'synthetic-later-token');
    expect(f.messaging.permissionRequests, 1);
    expect(f.messaging.tokenRequests, 1);
  });

  test(
      'blocked notifications do not create a token and driver login still reaches API',
      () async {
    final f = _Fixture();
    f.notifications.android.enabled = false;
    f.register();
    await DriverProvider(f.api).login(
      const DriverLoginRequest(
        phone: '700000001',
        password: 'synthetic-password',
        deviceId: 'synthetic-device',
      ),
    );
    expect(f.messaging.tokenRequests, 0);
    expect(
      (f.adapter.requests.last.data as Map<String, Object?>)['otpPushToken'],
      isNull,
    );
    expect(f.adapter.requests.last.path, 'auth/login');
  });

  test('sign-out invalidates a token request and deletes the temporary address',
      () async {
    final f = _Fixture();
    f.messaging.pendingToken = Completer<String?>();
    final request = f.push.requestOtpPushToken();
    final cancelled =
        expectLater(request, throwsA(isA<OtpPushRequestCancelled>()));
    await Future<void>.delayed(Duration.zero);
    await f.push.onSessionEnded();
    f.messaging.pendingToken!.complete('synthetic-late-token');
    await cancelled;
    expect(f.messaging.deleted, 1);
    expect(f.messaging.autoInit, [true, false]);
    expect(f.storage.pendingCleared, 1);
  });

  test(
      'valid driver OTP appears before authentication but wrong-app and expired OTP do not',
      () async {
    final f = _Fixture();
    await f.push.showForegroundNotification(
      RemoteMessage(
        data: otpData(),
        notification: const RemoteNotification(
          title: 'رمز التحقق',
          body: 'رمزك التجريبي 654321',
        ),
      ),
    );
    expect(f.notifications.shown, hasLength(1));
    expect(f.notifications.shown.single['body'], contains('654321'));
    expect(f.notifications.shown.single['channel'], pushNotificationChannelId);
    await f.push.showForegroundNotification(
      RemoteMessage(
        data: otpData(clientType: 'customer'),
        notification: const RemoteNotification(body: 'stale'),
      ),
    );
    await f.push.showForegroundNotification(
      RemoteMessage(
        data: otpData(
          expires: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
        notification: const RemoteNotification(body: 'stale'),
      ),
    );
    expect(f.notifications.shown, hasLength(1));
  });

  test(
      'tapping OTP leaves auth routing untouched; ordinary pushes keep existing routing',
      () {
    final f = _Fixture();
    f.register();
    f.push.openNotificationFromPush(otpData());
    expect(f.session.pushesOpened, 0);
    f.push
        .openNotificationFromPush({'action': 'open_active_ride', 'rideId': 7});
    expect(f.session.pushesOpened, 1);
  });

  test('server can turn OTP push on and off without another app build',
      () async {
    final f = _Fixture();
    f.register();
    f.adapter.testPushEnabled = false;
    expect(await requestOtpPushFields(f.api), isEmpty);
    expect(f.messaging.permissionRequests, 0);
    f.adapter.testPushEnabled = true;
    expect(await requestOtpPushFields(f.api), {
      'otpPushToken': 'synthetic-fcm-token',
      'deviceId': 'synthetic-device',
      'clientType': 'driver',
    });
    expect(f.messaging.permissionRequests, 1);
    f.adapter.testPushEnabled = false;
    expect(await requestOtpPushFields(f.api), isEmpty);
    expect(f.messaging.permissionRequests, 1);
    expect(
      f.adapter.requests
          .every((r) => r.method == 'GET' && r.path == 'auth/otp-delivery'),
      isTrue,
    );
  });

  test(
      'active driver login sends push token and device with original credentials after preparing token',
      () async {
    final f = _Fixture();
    f.register();
    await DriverProvider(f.api).login(
      const DriverLoginRequest(
        phone: '700000001',
        password: 'synthetic-password',
        deviceId: 'request-device',
        trustedDeviceToken: 'synthetic-trusted-device',
      ),
    );
    final posts = f.adapter.requests.where((r) => r.method == 'POST').toList();
    expect(posts, hasLength(1));
    expect(posts.single.data, {
      'phoneNumber': '700000001',
      'password': 'synthetic-password',
      'deviceId': 'request-device',
      'trustedDeviceToken': 'synthetic-trusted-device',
      'clientType': 'driver',
      'otpPushToken': 'synthetic-fcm-token',
      'notificationRenderer': 'app',
    });
  });

  test(
      'without push service existing login calls do not access Firebase or discovery endpoint',
      () async {
    final f = _Fixture();
    await DriverProvider(f.api).login(
      const DriverLoginRequest(
        phone: '700000001',
        password: 'synthetic-password',
        deviceId: 'request-device',
      ),
    );
    expect(f.adapter.requests, hasLength(1));
    expect(f.adapter.requests.single.method, 'POST');
    expect(
      (f.adapter.requests.single.data as Map<String, Object?>)
          .containsKey('otpPushToken'),
      isFalse,
    );
  });

  test(
      'registration resend and password reset prepare a fresh delivery target each time',
      () async {
    final f = _Fixture();
    var calls = 0;
    Future<Map<String, Object?>> fields(String? deviceId) async => {
          'otpPushToken': 'synthetic-token-${++calls}',
          'deviceId': 'request-device',
          'clientType': 'driver',
        };
    final registration = RegistrationProvider(f.api, otpPushFields: fields);
    await registration.requestOtp(const SignUpDraft(phone: '700000001'));
    await registration.requestOtp(const SignUpDraft(phone: '700000001'));
    await PasswordResetProvider(f.api, otpPushFields: fields)
        .request(identity: '700000001', channel: RecoveryChannel.sms);
    expect(
      f.adapter.requests
          .map((r) => (r.data as Map<String, Object?>)['otpPushToken'])
          .toList(),
      ['synthetic-token-1', 'synthetic-token-2', 'synthetic-token-3'],
    );
    expect(
      (f.adapter.requests.last.data as Map<String, Object?>)['identity'],
      '700000001',
    );
    expect(
      (f.adapter.requests.last.data as Map<String, Object?>)['clientType'],
      'driver',
    );
  });

  test(
      'generic driver auth provider includes correct role and never prepares a new OTP during verification',
      () async {
    final f = _Fixture();
    var calls = 0;
    final provider = LoginProvider(
      f.api,
      otpPushFields: (_) async {
        calls++;
        return {'otpPushToken': 'synthetic-fcm-token'};
      },
    );
    await provider.login(
      const LoginRequest(
        phone: '700000001',
        password: 'synthetic-password',
        deviceId: 'request-device',
      ),
    );
    await provider.verifyDeviceOtp(
      const DeviceOtpRequest(
        phone: '700000001',
        code: '654321',
        challengeId: 'synthetic-challenge',
        deviceId: 'request-device',
      ),
    );
    expect(calls, 1);
    expect(
      f.adapter.requests.every(
        (r) => (r.data as Map<String, Object?>)['clientType'] == 'driver',
      ),
      isTrue,
    );
    expect(
      (f.adapter.requests.last.data as Map<String, Object?>)
          .containsKey('otpPushToken'),
      isFalse,
    );
  });

  test('delivery preparation failure does not prevent a trusted login request',
      () async {
    final f = _Fixture();
    final provider = DriverProvider(
      f.api,
      otpPushFields: (_) async {
        throw const FormatException('synthetic denied permission');
      },
    );
    await provider.login(
      const DriverLoginRequest(
        phone: '700000001',
        password: 'synthetic-password',
        deviceId: 'request-device',
        trustedDeviceToken: 'synthetic-trusted-device',
      ),
    );
    expect(f.adapter.requests, hasLength(1));
    expect(
      (f.adapter.requests.single.data
          as Map<String, Object?>)['trustedDeviceToken'],
      'synthetic-trusted-device',
    );
    expect(
      (f.adapter.requests.single.data as Map<String, Object?>)
          .containsKey('otpPushToken'),
      isFalse,
    );
  });

  test('registration reports blocked notifications before creating an OTP',
      () async {
    final f = _Fixture();
    f.notifications.android.enabled = false;
    f.register();
    await expectLater(
      RegistrationProvider(f.api)
          .requestOtp(const SignUpDraft(phone: '700000001')),
      throwsA(isA<FormatException>()),
    );
    expect(f.adapter.requests.every((r) => r.method == 'GET'), isTrue);
    expect(f.messaging.tokenRequests, 0);
  });

  for (final provider in ['generic', 'driver']) {
    Future<void> login(_Fixture f) async {
      if (provider == 'generic') {
        await LoginProvider(f.api).login(
          const LoginRequest(
            phone: '700000001',
            password: 'synthetic-password',
            deviceId: 'request-device',
            trustedDeviceToken: 'synthetic-trusted-device',
          ),
        );
      } else {
        await DriverProvider(f.api).login(
          const DriverLoginRequest(
            phone: '700000001',
            password: 'synthetic-password',
            deviceId: 'request-device',
            trustedDeviceToken: 'synthetic-trusted-device',
          ),
        );
      }
    }

    for (final stage in [
      'capability',
      'permission',
      'notifications',
      'auto-init',
      'token',
    ]) {
      for (final lifecycle in ['session end', 'close']) {
        test(
            '$provider login never posts old credentials after $lifecycle during $stage',
            () async {
          final f = _Fixture();
          f.register();
          switch (stage) {
            case 'capability':
              f.adapter.pendingCapability = Completer<void>();
            case 'permission':
              f.messaging.pendingPermission = Completer<NotificationSettings>();
            case 'notifications':
              f.notifications.android.pendingEnabled = Completer<bool?>();
            case 'auto-init':
              f.messaging.pendingAutoInit = Completer<void>();
            case 'token':
              f.messaging.pendingToken = Completer<String?>();
          }
          final request = login(f);
          final cancelled =
              expectLater(request, throwsA(isA<OtpPushRequestCancelled>()));
          for (var i = 0; i < 8; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(f.adapter.requests, hasLength(1));
          expect(f.adapter.requests.single.method, 'GET');
          if (stage == 'permission') expect(f.messaging.permissionRequests, 1);
          if (stage == 'notifications') {
            expect(f.notifications.android.checks, 1);
          }
          if (stage == 'auto-init') expect(f.messaging.autoInit, [true]);
          if (stage == 'token') expect(f.messaging.tokenRequests, 1);
          if (lifecycle == 'session end') {
            await f.push.onSessionEnded();
          } else {
            f.push.onClose();
          }
          switch (stage) {
            case 'capability':
              f.adapter.pendingCapability!.complete();
            case 'permission':
              f.messaging.pendingPermission!
                  .complete(_Settings(AuthorizationStatus.denied));
            case 'notifications':
              f.notifications.android.pendingEnabled!.complete(false);
            case 'auto-init':
              f.messaging.pendingAutoInit!.complete();
            case 'token':
              f.messaging.pendingToken!.complete('synthetic-late-token');
          }
          await cancelled;
          expect(f.adapter.requests.every((r) => r.method == 'GET'), isTrue);
          if (stage == 'permission') expect(f.notifications.android.checks, 0);
          if (stage != 'token') expect(f.messaging.tokenRequests, 0);
        });
      }
    }

    test(
        '$provider login aborts if capability discovery fails after session end',
        () async {
      final f = _Fixture();
      f.register();
      f.adapter.pendingCapability = Completer<void>();
      f.adapter.capabilityFails = true;
      final request = login(f);
      final cancelled =
          expectLater(request, throwsA(isA<OtpPushRequestCancelled>()));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await f.push.onSessionEnded();
      f.adapter.pendingCapability!.complete();
      await cancelled;
      expect(f.adapter.requests, hasLength(1));
      expect(f.adapter.requests.single.method, 'GET');
    });
  }

  for (final stage in ['notifications', 'auto-init']) {
    test('$stage preparation times out without waiting indefinitely', () {
      fakeAsync((clock) {
        final f = _Fixture();
        if (stage == 'notifications') {
          f.notifications.android.pendingEnabled = Completer<bool?>();
        } else {
          f.messaging.pendingAutoInit = Completer<void>();
        }
        var completed = false;
        f.push.requestOtpPushToken().then((token) {
          expect(token, isNull);
          completed = true;
        });
        clock.flushMicrotasks();
        expect(completed, isFalse);
        clock.elapse(const Duration(seconds: 8));
        clock.flushMicrotasks();
        expect(completed, isTrue);
        expect(f.messaging.tokenRequests, 0);
      });
    });
  }
}
