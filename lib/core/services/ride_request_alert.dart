import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../network/api_client.dart';
import '../network/api_models.dart';

/// Shared by foreground Hub/FCM delivery and the background FCM isolate.
Future<void> showVerifiedRideRequestAlert(
    ApiClient client, Map<String, dynamic> payload,
    {FlutterLocalNotificationsPlugin? notifications}) {
  final task = _alertQueue.then((_) => _show(client, payload, notifications));
  _alertQueue = task.catchError((Object _) {});
  return task;
}

Future<void> _alertQueue = Future<void>.value();

Future<void> _show(ApiClient client, Map<String, dynamic> payload,
    FlutterLocalNotificationsPlugin? notifications) async {
  if (payload['action'] != 'open_ride_offer') return;
  final id = int.tryParse('${payload['notificationId']}');
  final rideId = int.tryParse('${payload['rideId']}');
  final created = DateTime.tryParse('${payload['createdAtUtc']}')?.toUtc();
  if (id == null ||
      rideId == null ||
      created == null ||
      DateTime.now().toUtc().difference(created).inSeconds > 60) return;
  try {
    final result = await client.execute<Object?>(
        model: 'RideRequestAvailabilityModel',
        operation: 'get',
        data: {'rideId': rideId});
    if (result is! ApiSuccess<Object?> ||
        result.data is! Map ||
        (result.data as Map)['available'] != true) return;
    const storage = FlutterSecureStorage();
    final userId = await storage.read(key: 'authenticated_user_id');
    final key = 'driver_request_alerts_$userId';
    final seen = (await storage.read(key: key) ?? '')
        .split(',')
        .where((x) => x.isNotEmpty)
        .toSet();
    if (!seen.add('$id')) return;
    while (seen.length > 200) {
      seen.remove(seen.first);
    }
    await storage.write(key: key, value: seen.join(','));
    final plugin = notifications ?? FlutterLocalNotificationsPlugin();
    if (notifications == null) {
      await plugin.initialize(
          settings: const InitializationSettings(
              android: AndroidInitializationSettings('ic_stat_yemendrive')));
    }
    await plugin.show(
        id: id,
        title: '${payload['title'] ?? 'طلب رحلة جديد'}',
        body: '${payload['body'] ?? 'يوجد طلب رحلة متاح بالقرب منك.'}',
        notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
                'yemendrive_alerts', 'إشعارات يمن درايف',
                importance: Importance.high,
                priority: Priority.high,
                playSound: true,
                icon: 'ic_stat_yemendrive')),
        payload: jsonEncode(payload));
  } on Object {
    // Offline, expired-session and verification failures never produce an alert.
  }
}
