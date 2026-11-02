import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/network/api_models.dart';
import 'package:yemen_drive_driver/core/services/ride_request_alert.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';
import 'package:yemen_drive_driver/core/utils/utc_timestamp.dart';

class _Api extends ApiClient {
  _Api() : super(SecureStorageService());
  bool available = true;
  @override
  Future<ApiResult<T>> execute<T>(
          {required String model,
          required String operation,
          Object? data,
          T Function(Object?)? parse}) async =>
      ApiSuccess<T>({'available': available} as T);
}

class _Notifications implements FlutterLocalNotificationsPlugin {
  int shown = 0;
  bool fail = false;
  NotificationDetails? details;
  @override
  Future<void> show(
      {required int id,
      String? title,
      String? body,
      NotificationDetails? notificationDetails,
      String? payload}) async {
    if (fail) throw StateError('Notification service temporarily unavailable');
    shown++;
    details = notificationDetails;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a database timestamp without Z has the same UTC age as its FCM timestamp', () {
    const databaseTime = '2026-11-02T18:15:20';
    expect(parseUtcTimestamp(databaseTime)?.isUtc, true);
    expect(parseUtcTimestamp(databaseTime), DateTime.utc(2026, 11, 2, 18, 15, 20));
    expect(isFreshRideRequestAlert({'action': 'open_ride_offer', 'rideId': 7,
      'notificationId': 11, 'createdAtUtc': databaseTime},
      now: DateTime.utc(2026, 11, 2, 18, 15, 40)), true);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  final stored = <String, String>{};
  setUp(() {
    stored.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = Map<String, Object?>.from(call.arguments as Map);
        if (call.method == 'read') return stored[args['key']];
        if (call.method == 'write')
          stored['${args['key']}'] = '${args['value']}';
        return null;
      },
    );
  });
  Map<String, dynamic> payload() => {
        'action': 'open_ride_offer',
        'rideId': 7,
        'notificationId': 11,
        'createdAtUtc': DateTime.now().toUtc().toIso8601String()
      };
  test('Hub and FCM deliveries produce one audible alert per account',
      () async {
    final api = _Api();
    final notifications = _Notifications();
    final data = payload();
    await Future.wait([
      showVerifiedRideRequestAlert(api, data,
          notifications: notifications, userId: 42),
      showVerifiedRideRequestAlert(api, data,
          notifications: notifications, userId: 42),
    ]);
    expect(notifications.shown, 1);
    expect(notifications.details?.android?.playSound, true);
    expect(notifications.details?.android?.enableVibration, true);
    await showVerifiedRideRequestAlert(api, data,
        notifications: notifications, userId: 43);
    expect(notifications.shown, 2);
  });
  test('an unavailable or expired invitation cannot produce a request alert',
      () async {
    final api = _Api()..available = false;
    final notifications = _Notifications();
    await showVerifiedRideRequestAlert(api, payload(),
        notifications: notifications, userId: 42);
    api.available = true;
    await showVerifiedRideRequestAlert(
        api,
        {
          ...payload(),
          'createdAtUtc': DateTime.now()
              .subtract(const Duration(minutes: 2))
              .toIso8601String()
        },
        notifications: notifications,
        userId: 42);
    expect(notifications.shown, 0);
  });
  test('notification display failure does not consume a later valid retry',
      () async {
    final api = _Api();
    final notifications = _Notifications()..fail = true;
    final data = payload();
    await showVerifiedRideRequestAlert(api, data,
        notifications: notifications, userId: 42);
    notifications.fail = false;
    await showVerifiedRideRequestAlert(api, data,
        notifications: notifications, userId: 42);
    expect(notifications.shown, 1);
  });
}
