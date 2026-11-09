import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:signalr_netcore/signalr_client.dart';
import 'package:yemen_drive_driver/core/config/app_environment.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/realtime/tracking_hub_service.dart';
import 'package:yemen_drive_driver/core/services/auth_session_service.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';

class _Storage extends SecureStorageService {
  String? token = 'driver-a-token';
  int reads = 0;
  int? blockAtRead;
  final blocked = Completer<void>();
  final releaseRead = Completer<String?>();

  @override
  Future<String?> get accessToken {
    if (++reads == blockAtRead) {
      blocked.complete();
      return releaseRead.future;
    }
    return Future.value(token);
  }
}

class _Connection extends Fake implements HubConnection {
  HubConnectionState currentState = HubConnectionState.Disconnected;
  final started = Completer<void>();
  Completer<void>? startWait;
  Completer<Object?>? publicationWait;
  final publicationStarted = Completer<void>();
  final publications = <Map<String, Object?>>[];
  bool failStart = false;
  bool failPublication = false;

  @override
  HubConnectionState? get state => currentState;

  @override
  Future<void> start() async {
    currentState = HubConnectionState.Connecting;
    started.complete();
    await startWait?.future;
    if (failStart) throw StateError('Test connection unavailable');
    currentState = HubConnectionState.Connected;
  }

  @override
  Future<void> stop() async => currentState = HubConnectionState.Disconnected;

  @override
  void on(String methodName, MethodInvocationFunc newMethod) {}
  @override
  void onclose(ClosedCallback callback) {}
  @override
  void onreconnecting(ReconnectingCallback callback) {}
  @override
  void onreconnected(ReconnectedCallback callback) {}

  @override
  Future<Object?> invoke(String methodName, {List<Object>? args}) async {
    if (methodName == 'ReplayStateChanges') return {'supported': false};
    if (!methodName.startsWith('PublishDriverLocation')) return null;
    publications.add(Map<String, Object?>.from(args!.single as Map));
    if (!publicationStarted.isCompleted) publicationStarted.complete();
    if (publicationWait != null) return publicationWait!.future;
    if (failPublication) throw StateError('Test Hub send failed');
    return null;
  }
}

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    requests.add(options);
    return ResponseBody.fromString(
        '{"success":true,"data":{"accepted":true,"enabled":true,"acceptedSampleIds":["sample-1"]}}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

class _Harness {
  final storage = _Storage();
  final connection = _Connection();
  final adapter = _Adapter();
  late ApiClient client;
  late AuthSessionService session;
  late TrackingHubService hub;

  Future<void> init() async {
    client = Get.put(await ApiClient(storage).init());
    client.dio.httpClientAdapter = adapter;
    session = Get.put(AuthSessionService(storage, client));
    session.isAuthenticated.value = true;
    session.currentUserId.value = 7;
    hub = Get.put(
        TrackingHubService(storage, connectionFactory: () => connection));
    addTearDown(() async {
      await hub.disconnect();
      client.dio.close(force: true);
    });
  }

  void replaceAccount() {
    storage.token = 'driver-b-token';
    session.currentUserId.value = 8;
  }
}

Map<String, Object?> _sample() => {
      'rideId': null,
      'latitude': 15.36,
      'longitude': 44.19,
      'accuracy': 10,
      'observedAtUtc': DateTime.now().toUtc().toIso8601String(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    Get.testMode = true;
    AppEnvironment.configure(baseUrl: 'https://location-scope.invalid/api');
  });
  tearDown(Get.reset);

  test('account change during connect prevents both GPS transports', () async {
    final h = _Harness();
    await h.init();
    h.connection.startWait = Completer<void>();
    final sending = h.hub.publishDriverLocation(_sample());
    await h.connection.started.future;
    h.replaceAccount();
    h.connection.startWait!.complete();
    expect(await sending, false);
    expect(h.connection.publications, isEmpty);
    expect(h.adapter.requests, isEmpty);
  });

  test('failed Hub send cannot fall back using the next account', () async {
    final h = _Harness();
    await h.init();
    h.connection.publicationWait = Completer<Object?>();
    final sending = h.hub.publishDriverLocation(_sample());
    await h.connection.publicationStarted.future;
    h.replaceAccount();
    h.connection.publicationWait!.completeError(StateError('Lost Hub reply'));
    expect(await sending, false);
    expect(h.connection.publications, hasLength(1));
    expect(h.adapter.requests, isEmpty);
  });

  test('request guard rejects a token replaced during HTTP authentication',
      () async {
    final h = _Harness();
    await h.init();
    h.connection.failStart = true;
    // Capture, post-connect check, pre-fallback check, then ApiClient auth.
    h.storage.blockAtRead = 4;
    final sending = h.hub.publishDriverLocation(_sample());
    await h.storage.blocked.future;
    // Token storage changes before AuthSession.activate updates the user id.
    h.storage.token = 'replacement-token';
    h.storage.releaseRead.complete(h.storage.token);
    expect(await sending, false);
    expect(h.adapter.requests, isEmpty);
    expect(h.client.dio.interceptors, hasLength(2),
        reason: 'Only Dio content type and ApiClient interceptors remain.');
  });

  test('same account fallback preserves the exact sample and original token',
      () async {
    final h = _Harness();
    await h.init();
    h.connection.failPublication = true;
    final sample = _sample();
    expect(await h.hub.publishDriverLocation(sample), true);
    expect(h.adapter.requests, hasLength(1));
    expect(h.adapter.requests.single.data, sample);
    expect(h.adapter.requests.single.headers['Authorization'],
        'Bearer driver-a-token');
    expect(h.connection.publications.single, sample);
  });

  test('old idle fix cannot follow an active ride change while connecting',
      () async {
    final h = _Harness();
    await h.init();
    h.connection.startWait = Completer<void>();
    final sending = h.hub.publishDriverLocation(_sample());
    await h.connection.started.future;
    final joining = h.hub.setRideSubscriptions({91});
    h.connection.startWait!.complete();
    expect(await sending, false);
    await joining;
    expect(h.connection.publications, isEmpty);
    expect(h.adapter.requests, isEmpty);
  });

  test('a batch fallback cannot use a replacement account', () async {
    final h = _Harness();
    await h.init();
    await h.hub.setUserEventListening(Object(), true);
    h.connection.publicationWait = Completer<Object?>();
    final sending = h.hub.publishDriverLocationBatch({
      'rideId': 91,
      'sessionId': 'test-route',
      'samples': [
        {..._sample(), 'sampleId': 'sample-1', 'sequence': 1}
      ],
    });
    final failure = expectLater(sending, throwsA(isA<FormatException>()));
    await h.connection.publicationStarted.future;
    h.replaceAccount();
    h.connection.publicationWait!.completeError(StateError('Lost batch reply'));
    await failure;
    expect(h.adapter.requests, isEmpty);
  });

  test('session disconnect invalidates a pending publication for the same user',
      () async {
    final h = _Harness();
    await h.init();
    h.connection.startWait = Completer<void>();
    final sending = h.hub.publishDriverLocation(_sample());
    await h.connection.started.future;
    await h.hub.disconnect();
    h.connection.startWait!.complete();
    expect(await sending, false);
    expect(h.connection.publications, isEmpty);
    expect(h.adapter.requests, isEmpty);
  });
}
