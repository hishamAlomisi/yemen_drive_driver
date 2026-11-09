import 'dart:convert';

import 'package:flutter/painting.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../network/api_client.dart';
import '../network/api_models.dart';
import '../utils/utc_timestamp.dart';

/// Shared by foreground Hub/FCM delivery and the background FCM isolate.
Future<void> showVerifiedRideRequestAlert(
    ApiClient client, Map<String, dynamic> payload,
    {FlutterLocalNotificationsPlugin? notifications, int? userId}) {
  final task =
      _alertQueue.then((_) => _show(client, payload, notifications, userId));
  _alertQueue = task.catchError((Object _) {});
  return task;
}

Future<void> _alertQueue = Future<void>.value();

bool isFreshRideRequestAlert(Map<String, dynamic> payload, {DateTime? now}) {
  if (payload['action'] != 'open_ride_offer') return false;
  final id = int.tryParse('${payload['notificationId']}');
  final rideId = int.tryParse('${payload['rideId']}');
  final created = parseUtcTimestamp(payload['createdAtUtc']);
  if (id == null || id <= 0 || rideId == null || rideId <= 0 || created == null)
    return false;
  final age = (now ?? DateTime.now()).toUtc().difference(created);
  return age <= const Duration(seconds: 60) &&
      age >= const Duration(seconds: -5);
}

Future<void> _show(
    ApiClient client,
    Map<String, dynamic> payload,
    FlutterLocalNotificationsPlugin? notifications,
    int? authenticatedUserId) async {
  if (!isFreshRideRequestAlert(payload)) return;
  final id = int.parse('${payload['notificationId']}');
  final rideId = int.parse('${payload['rideId']}');
  try {
    final result = await client.execute<Object?>(
        model: 'RideRequestAvailabilityModel',
        operation: 'get',
        data: {'rideId': rideId});
    if (result is! ApiSuccess<Object?> ||
        result.data is! Map ||
        (result.data as Map)['available'] != true) return;
    const storage = FlutterSecureStorage();
    final userId = authenticatedUserId ??
        int.tryParse(await storage.read(key: 'authenticated_user_id') ?? '');
    if (userId == null) return;
    final key = 'driver_request_alerts_$userId';
    final seen = (await storage.read(key: key) ?? '')
        .split(',')
        .where((x) => x.isNotEmpty)
        .toSet();
    if (!seen.add('$id')) return;
    while (seen.length > 200) {
      seen.remove(seen.first);
    }
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
                'yemendrive_ride_requests_v2', 'طلبات الرحلات الجديدة',
                channelDescription: 'تنبيه صوتي عند وصول طلب رحلة متاح',
                importance: Importance.high,
                priority: Priority.high,
                playSound: true,
                enableVibration: true,
                icon: 'ic_stat_yemendrive',
                color: Color(0xFF174C43),
                largeIcon:
                    DrawableResourceAndroidBitmap('ic_brand_notification'),
              ),
            ),
        payload: jsonEncode(payload));
    await storage.write(key: key, value: seen.join(','));
  } on Object {
    // Offline, expired-session and verification failures never produce an alert.
  }
}
