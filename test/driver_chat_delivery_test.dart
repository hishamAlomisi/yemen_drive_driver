import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/network/api_models.dart';
import 'package:yemen_drive_driver/core/realtime/tracking_hub_service.dart';
import 'package:yemen_drive_driver/core/services/auth_session_service.dart';
import 'package:yemen_drive_driver/core/services/ride_chat_service.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';
import 'package:yemen_drive_driver/features/driver/views/driver_chat_view.dart';
import 'package:yemen_drive_driver/shared/widgets/ride_chat_badge.dart';

Map<String, Object?> message(int id, String content, {bool outgoing = false}) =>
    {
      'id': id,
      'rideId': 7,
      'senderId': outgoing ? 42 : 11,
      'recipientId': outgoing ? 11 : 42,
      'content': content,
      'createdAtUtc': '2026-11-04T12:00:${id.toString().padLeft(2, '0')}Z',
      'deliveredAtUtc': null,
      'readAtUtc': null,
    };

class _Hub extends TrackingHubService {
  _Hub() : super(SecureStorageService());
  final bus = StreamController<TrackingHubEvent>.broadcast();
  @override
  Stream<TrackingHubEvent> get events => bus.stream;
  @override
  Stream<void> get connectionRestored => const Stream.empty();
  @override
  Future<void> setUserEventListening(Object owner, bool listen) async {}
}

class _Api extends ApiClient {
  _Api() : super(SecureStorageService());
  final rows = <Map<String, Object?>>[];
  final acknowledgements = <Map<String, Object?>>[];
  Completer<void>? pendingSend;
  Completer<void>? pendingList;
  int lists = 0;

  @override
  Future<ApiResult<T>> execute<T>(
      {required String model,
      required String operation,
      Object? data,
      T Function(Object?)? parse}) async {
    final request = Map<String, Object?>.from(data as Map? ?? {});
    Object result;
    if (operation == 'report') {
      final count = rows
          .where((row) => row['recipientId'] == 42 && row['readAtUtc'] == null)
          .length;
      result = {
        'unreadCount': count,
        'rides': [
          if (count > 0) {'rideId': 7, 'unreadCount': count}
        ]
      };
    } else if (operation == 'update') {
      acknowledgements.add(request);
      final ids = request['messageIds'] as List;
      for (final row in rows.where((row) => ids.contains(row['id']))) {
        row['deliveredAtUtc'] ??= '2026-11-04T12:01:00Z';
        if (request['markRead'] == true)
          row['readAtUtc'] ??= '2026-11-04T12:01:01Z';
      }
      result = rows
          .where((row) => ids.contains(row['id']))
          .map(Map<String, Object?>.from)
          .toList();
    } else if (operation == 'add') {
      await pendingSend?.future;
      final row = message(50, '${request['content']}', outgoing: true);
      rows.add(row);
      result = Map<String, Object?>.from(row);
    } else {
      lists++;
      final snapshot = rows.map(Map<String, Object?>.from).toList();
      await pendingList?.future;
      result = snapshot;
    }
    return ApiSuccess<T>(parse != null ? parse(result) : result as T);
  }
}

void main() {
  late _Hub hub;
  late _Api api;
  late RideChatService chat;
  var sounds = 0;

  void initialize() {
    Get.testMode = true;
    sounds = 0;
    api = _Api();
    hub = _Hub()..supportsStateRecovery.value = true;
    Get.put<ApiClient>(api);
    Get.put<TrackingHubService>(hub);
    final session = Get.put(AuthSessionService(SecureStorageService(), api)
      ..currentUserId.value = 42
      ..isAuthenticated.value = true);
    chat = Get.put(RideChatService(api, session, hub));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('yemendrive/chat_sound'),
            (call) async {
      sounds++;
      return null;
    });
  }

  tearDown(() async {
    Get.reset();
    await hub.bus.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('yemendrive/chat_sound'), null);
  });

  testWidgets(
      'live messages render with recovery enabled, sound once, and acknowledge visible reading',
      (tester) async {
    initialize();
    await tester
        .pumpWidget(const GetMaterialApp(home: DriverChatView(rideId: '7')));
    await tester.pumpAndSettle();
    final incoming = message(1, 'وصلت إلى المكان');
    api.rows.add(Map.of(incoming));
    hub.bus.add(TrackingHubEvent('rideMessageCreated', incoming));
    await tester.pumpAndSettle();
    expect(find.text('وصلت إلى المكان'), findsOneWidget);
    expect(sounds, 1);
    expect(api.rows.single['deliveredAtUtc'], isNotNull);
    expect(api.rows.single['readAtUtc'], isNotNull);
    expect(chat.unreadFor(7), 0);
    hub.bus.add(TrackingHubEvent('rideMessageCreated', incoming));
    await tester.pumpAndSettle();
    expect(find.text('وصلت إلى المكان'), findsOneWidget);
    expect(sounds, 1);
    await tester.pumpWidget(const SizedBox());
    Get.delete<RideChatService>(force: true);
  });

  testWidgets(
      'outside chat receives delivery and red unread count without reading or sound',
      (tester) async {
    initialize();
    await tester.pumpWidget(
        const GetMaterialApp(home: Scaffold(body: RideChatBadge(rideId: 7))));
    await tester.pumpAndSettle();
    final incoming = message(1, 'أين أنت؟');
    api.rows.add(Map.of(incoming));
    hub.bus.add(TrackingHubEvent('rideMessageCreated', incoming));
    await tester.pumpAndSettle();
    expect(chat.unreadFor(7), 1);
    expect(find.text('1'), findsOneWidget);
    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.backgroundColor, const Color(0xffd32f2f));
    expect(api.rows.single['deliveredAtUtc'], isNotNull);
    expect(api.rows.single['readAtUtc'], isNull);
    expect(
        api.acknowledgements.every((ack) => ack['markRead'] == false), isTrue);
    expect(sounds, 0);
    await tester.pumpWidget(const SizedBox());
    Get.delete<RideChatService>(force: true);
  });

  testWidgets(
      'paused conversation does not mark read or sound; resume catches up',
      (tester) async {
    initialize();
    await tester
        .pumpWidget(const GetMaterialApp(home: DriverChatView(rideId: '7')));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final incoming = message(1, 'رسالة أثناء الخلفية');
    api.rows.add(Map.of(incoming));
    hub.bus.add(TrackingHubEvent('rideMessageCreated', incoming));
    await tester.pumpAndSettle();
    expect(api.rows.single['readAtUtc'], isNull);
    expect(sounds, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(api.rows.single['readAtUtc'], isNotNull);
    expect(find.text('رسالة أثناء الخلفية'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    Get.delete<RideChatService>(force: true);
  });

  testWidgets(
      'pending becomes sent, then delivered and read without reopening chat',
      (tester) async {
    initialize();
    await tester
        .pumpWidget(const GetMaterialApp(home: DriverChatView(rideId: '7')));
    await tester.pumpAndSettle();
    api.pendingSend = Completer<void>();
    await tester.enterText(find.byType(TextField), 'أنا في الطريق');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    api.pendingSend!.complete();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    final delivered = {
      ...api.rows.single,
      'deliveredAtUtc': '2026-11-04T12:02:00Z'
    };
    hub.bus.add(TrackingHubEvent('rideMessageUpdated', delivered));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    expect(find.byTooltip('تم الوصول'), findsOneWidget);
    hub.bus.add(TrackingHubEvent('rideMessageUpdated',
        {...delivered, 'readAtUtc': '2026-11-04T12:03:00Z'}));
    await tester.pumpAndSettle();
    expect(find.byTooltip('تمت القراءة'), findsOneWidget);
    // A stale canonical response must not undo an acknowledged receipt.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byTooltip('تمت القراءة'), findsOneWidget);
    expect(sounds, 0);
    await tester.pumpWidget(const SizedBox());
    Get.delete<RideChatService>(force: true);
  });

  testWidgets(
      'sender echo and receipt before POST response never duplicate a pending bubble',
      (tester) async {
    initialize();
    await tester
        .pumpWidget(const GetMaterialApp(home: DriverChatView(rideId: '7')));
    await tester.pumpAndSettle();
    api.pendingSend = Completer<void>();
    await tester.enterText(find.byType(TextField), 'رسالة واحدة فقط');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    final own = message(50, 'رسالة واحدة فقط', outgoing: true);
    hub.bus.add(TrackingHubEvent('rideMessageCreated', own));
    hub.bus.add(TrackingHubEvent('rideMessageUpdated', {
      ...own,
      'deliveredAtUtc': '2026-11-04T12:02:00Z',
    }));
    await tester.pumpAndSettle();
    expect(find.text('رسالة واحدة فقط'), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    api.pendingSend!.complete();
    await tester.pumpAndSettle();
    expect(find.text('رسالة واحدة فقط'), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    expect(sounds, 0);
    await tester.pumpWidget(const SizedBox());
    Get.delete<RideChatService>(force: true);
  });

  testWidgets('visible fallback recovers a missed live event', (tester) async {
    initialize();
    await tester
        .pumpWidget(const GetMaterialApp(home: DriverChatView(rideId: '7')));
    await tester.pumpAndSettle();
    api.rows.add(message(1, 'وصلت بعد انقطاع الاتصال'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('وصلت بعد انقطاع الاتصال'), findsOneWidget);
    expect(api.rows.single['readAtUtc'], isNotNull);
    expect(sounds, 1);
    await tester.pumpWidget(const SizedBox());
    Get.delete<RideChatService>(force: true);
  });
}
