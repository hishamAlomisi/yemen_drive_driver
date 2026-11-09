import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import '../lib/core/network/api_client.dart';
import '../lib/core/network/api_models.dart';
import '../lib/core/realtime/tracking_hub_service.dart';
import '../lib/core/realtime/state_change_coordinator.dart';
import '../lib/core/services/auth_session_service.dart';
import '../lib/core/services/ride_chat_service.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/features/driver/controllers/driver_controller.dart';
import '../lib/features/driver/models/driver_models.dart';
import '../lib/features/driver/repositories/driver_repository.dart';
import '../lib/features/driver/views/driver_chat_view.dart';

class _Hub extends TrackingHubService {
  _Hub() : super(SecureStorageService());
  final messages = StreamController<TrackingHubEvent>.broadcast();
  @override
  Stream<TrackingHubEvent> get events => messages.stream;
  @override
  Stream<void> get connectionRestored => const Stream.empty();
  @override
  Future<void> setUserEventListening(Object owner, bool listen) async {}
}

class _Api extends ApiClient {
  _Api() : super(SecureStorageService());
  List<Map<String, Object?>> rows = [];
  @override
  Future<ApiResult<T>> execute<T>({
    required String model,
    required String operation,
    Object? data,
    T Function(Object?)? parse,
  }) async {
    final Object result = operation == 'report'
        ? {'rides': [], 'unreadCount': 0}
        : operation == 'update'
            ? <Map<String, Object?>>[]
            : rows;
    return ApiSuccess<T>(parse != null ? parse(result) : result as T);
  }
}

class _Repository implements DriverRepository {
  final cancellations = <int>[];
  @override
  Future<Map<String, Object?>> requestRideCancellation(
      int rideId, String reason,
      {bool safeStopConfirmed = false}) async {
    cancellations.add(rideId);
    return {'rideStatus': 7};
  }

  @override
  Future<DriverSnapshot> load(int? userId) async =>
      const DriverSnapshot(profile: null, rides: []);
  @override
  Future<List<Map<String, Object?>>> notifications() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Driver extends DriverController {
  _Driver(super.repository, super.session);
  final acknowledgement = Completer<void>();
  final checkedRides = <int>[];
  @override
  Future<void> ensureRouteSamplesSaved(int rideId) {
    checkedRides.add(rideId);
    return acknowledgement.future;
  }
}

class _WalletRepository extends _Repository {
  final reads = <Completer<Map<String, Object?>>>[];
  @override
  Future<Map<String, Object?>> getWallet() {
    final request = Completer<Map<String, Object?>>();
    reads.add(request);
    return request.future;
  }
}

Map<String, Object?> _message(int id, String content) => {
      'id': id,
      'senderId': 11,
      'recipientId': 42,
      'rideId': 7,
      'content': content,
      'createdAtUtc': '2026-11-03T12:00:00Z',
    };

AuthSessionService _session(ApiClient api) =>
    AuthSessionService(SecureStorageService(), api)
      ..currentUserId.value = 42
      ..isAuthenticated.value = true;

void main() {
  tearDown(() => Get.reset());

  testWidgets(
      'driver chat keeps canonical content and accepts new live messages during recovery',
      (tester) async {
    final hub = _Hub();
    final api = _Api();
    Get.put<TrackingHubService>(hub);
    Get.put<ApiClient>(api);
    Get.put<AuthSessionService>(_session(api));
    await tester
        .pumpWidget(const GetMaterialApp(home: DriverChatView(rideId: '7')));
    await tester.pumpAndSettle();

    hub.supportsStateRecovery.value = true;
    api.rows = [_message(1, 'committed message')];
    final recovery = hub.stateChanges.recover((_, __) async => {
          'supported': true,
          'hasMore': false,
          'events': [
            {
              'schemaVersion': 1,
              'stream': 'messages:7',
              'version': 2,
              'resource': 'messages',
              'resourceId': 7,
            }
          ],
        });
    await tester.pumpAndSettle();
    await recovery;
    expect(find.text('committed message'), findsOneWidget);
    expect(hub.stateChanges.versions['messages:7'], 2);

    hub.messages.add(TrackingHubEvent(
        'rideMessageCreated', _message(1, 'superseded legacy payload')));
    hub.messages.add(TrackingHubEvent(
        'rideMessageCreated', _message(2, 'unverified legacy message')));
    await tester.pumpAndSettle();
    expect(find.text('committed message'), findsOneWidget);
    expect(find.text('superseded legacy payload'), findsNothing);
    expect(find.text('unverified legacy message'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    if (Get.isRegistered<RideChatService>())
      Get.delete<RideChatService>(force: true);
    hub.stateChanges.dispose();
    await hub.messages.close();
  });

  testWidgets('driver chat retains legacy delivery on older servers',
      (tester) async {
    final hub = _Hub();
    final api = _Api();
    Get.put<TrackingHubService>(hub);
    Get.put<ApiClient>(api);
    Get.put<AuthSessionService>(_session(api));
    await tester
        .pumpWidget(const GetMaterialApp(home: DriverChatView(rideId: '7')));
    await tester.pumpAndSettle();
    hub.messages.add(TrackingHubEvent(
        'rideMessageCreated', _message(1, 'compatible message')));
    await tester.pumpAndSettle();
    expect(find.text('compatible message'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    if (Get.isRegistered<RideChatService>())
      Get.delete<RideChatService>(force: true);
    hub.stateChanges.dispose();
    await hub.messages.close();
  });

  test('unrelated chat events do not restart a wallet snapshot', () async {
    final hub = _Hub();
    Get.put<TrackingHubService>(hub);
    final repository = _WalletRepository();
    final subject = _Driver(repository, _session(_Api()));
    final loading = subject.loadWallet();
    expect(repository.reads, hasLength(1));
    hub.stateChanges.observe(const StateChange('messages:7', 1, 'messages', 7));
    repository.reads.single.complete({'balance': 1200, 'transactions': []});
    await Future<void>.delayed(Duration.zero);
    // Complete any unwanted retry so the pre-fix reproduction cannot hang.
    final countAfterUnrelatedChange = repository.reads.length;
    for (final request in repository.reads.skip(1)) {
      request.complete({'balance': 1200, 'transactions': []});
    }
    await loading;
    expect(countAfterUnrelatedChange, 1);
    expect(subject.walletBalance.value, 1200);
    hub.stateChanges.dispose();
    await hub.messages.close();
  });

  for (final disconnect in [false, true]) {
    test(
        disconnect
            ? 'disconnect still rejects an in-flight wallet snapshot'
            : 'wallet events still reject an older wallet balance', () async {
      final hub = _Hub();
      Get.put<TrackingHubService>(hub);
      final repository = _WalletRepository();
      final subject = _Driver(repository, _session(_Api()));
      final loading = subject.loadWallet();
      if (disconnect) {
        hub.stateChanges.disconnected();
      } else {
        hub.stateChanges
            .observe(const StateChange('wallet:42', 1, 'wallet', 42));
      }
      repository.reads.single.complete({'balance': 500, 'transactions': []});
      await Future<void>.delayed(Duration.zero);
      expect(repository.reads, hasLength(2));
      expect(subject.walletBalance.value, 0);
      repository.reads.last.complete({'balance': 1200, 'transactions': []});
      await loading;
      expect(subject.walletBalance.value, 1200);
      hub.stateChanges.dispose();
      await hub.messages.close();
    });
  }

  test('account replacement cannot apply the previous wallet balance',
      () async {
    final hub = _Hub();
    Get.put<TrackingHubService>(hub);
    final repository = _WalletRepository();
    final session = _session(_Api());
    final subject = _Driver(repository, session);
    final loading = subject.loadWallet();
    session.currentUserId.value = 99;
    hub.stateChanges.reset();
    repository.reads.single.complete({'balance': 9000, 'transactions': []});
    await loading;
    expect(subject.walletBalance.value, 0);
    expect(subject.isWalletLoaded.value, isFalse);
    hub.stateChanges.dispose();
    await hub.messages.close();
  });

  for (final accepted in [true, false]) {
    testWidgets(
        accepted
            ? 'driver cancellation waits for route acknowledgement before pricing'
            : 'missing route acknowledgement prevents a priced cancellation',
        (tester) async {
      final repository = _Repository();
      final subject = _Driver(repository, _session(_Api()));
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      final cancellation = subject.requestCancellation(
          {'id': 7, 'driverId': 42, 'status': 5},
          initialReason: 'توقف النقل عند نقطة آمنة');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'إرسال'));
      await tester.pumpAndSettle();
      expect(subject.checkedRides, [7]);
      expect(repository.cancellations, isEmpty);
      if (accepted) {
        subject.acknowledgement.complete();
      } else {
        subject.acknowledgement
            .completeError(StateError('Unconfirmed samples'));
      }
      await tester.pumpAndSettle();
      await cancellation;
      expect(repository.cancellations, accepted ? [7] : isEmpty);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      if (Get.isRegistered<RideChatService>())
        Get.delete<RideChatService>(force: true);
    });
  }
}
