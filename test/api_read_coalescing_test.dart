import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:signalr_netcore/signalr_client.dart';
import 'package:yemen_drive_driver/core/config/app_environment.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/network/api_models.dart';
import 'package:yemen_drive_driver/core/realtime/tracking_hub_service.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';

class _Storage extends SecureStorageService {
  String? token = 'account-one';
  @override
  Future<String?> get accessToken async => token;
}

class _Connection extends Fake implements HubConnection {
  final methods = <String, MethodInvocationFunc>{};
  HubConnectionState currentState = HubConnectionState.Disconnected;
  Map<Object?, Object?> replay = {
    'supported': true,
    'events': <Object?>[],
    'hasMore': false,
  };
  @override
  HubConnectionState? get state => currentState;
  @override
  Future<void> start() async => currentState = HubConnectionState.Connected;
  @override
  Future<void> stop() async => currentState = HubConnectionState.Disconnected;
  @override
  void on(String name, MethodInvocationFunc method) => methods[name] = method;
  @override
  void onclose(ClosedCallback callback) {}
  @override
  void onreconnecting(ReconnectingCallback callback) {}
  @override
  void onreconnected(ReconnectedCallback callback) {}
  @override
  Future<Object?> invoke(String name, {List<Object>? args}) async =>
      name == 'ReplayStateChanges' ? replay : null;

  void emit(String name, Map<String, Object?> payload) =>
      methods[name]!([payload]);
}

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final responses = <Completer<ResponseBody>>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelled) {
    requests.add(options);
    final response = Completer<ResponseBody>();
    responses.add(response);
    return response.future;
  }

  void complete(int index, [int id = 42]) => responses[index].complete(
        ResponseBody.fromString('{"success":true,"data":{"id":$id}}', 200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType]
            }),
      );
  @override
  void close({bool force = false}) {}
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    Get.testMode = true;
    AppEnvironment.configure(baseUrl: 'https://coalesce.invalid/api');
  });
  tearDown(Get.reset);

  test('100 simultaneous ride reads share one request and parse independently',
      () async {
    final adapter = _Adapter();
    final api = await ApiClient(_Storage()).init();
    api.dio.httpClientAdapter = adapter;
    addTearDown(() => api.dio.close(force: true));
    final reads = List.generate(
        100,
        (_) => api.execute<int>(
            model: 'RideModel',
            operation: 'get',
            data: {'rideId': 42},
            parse: (json) => (json as Map)['id'] as int));
    await _settle();
    expect(adapter.requests, hasLength(1));
    adapter.complete(0);
    final values = await Future.wait(reads);
    expect(
        values.every((value) => value is ApiSuccess<int> && value.data == 42),
        isTrue);
    final fresh = api.execute<Object?>(
        model: 'RideModel', operation: 'get', data: {'rideId': 42});
    await _settle();
    expect(adapter.requests, hasLength(2),
        reason: 'completed snapshots must not hide later live state');
    adapter.complete(1, 43);
    expect((await fresh as ApiSuccess<Object?>).data, {'id': 43});
  });

  test(
      'canonical query data shares reads but differing ride and account do not',
      () async {
    final adapter = _Adapter();
    final storage = _Storage();
    final api = await ApiClient(storage).init();
    api.dio.httpClientAdapter = adapter;
    addTearDown(() => api.dio.close(force: true));
    Future<ApiResult<Object?>> read(Map<String, Object?> data) =>
        api.execute<Object?>(model: 'RideModel', operation: 'get', data: data);
    final first = read({'rideId': 42, 'includeDetails': true});
    final same = read({'includeDetails': true, 'rideId': 42});
    final otherRide = read({'rideId': 99, 'includeDetails': true});
    await _settle();
    expect(adapter.requests, hasLength(2));
    storage.token = 'account-two';
    final otherAccount = read({'rideId': 42, 'includeDetails': true});
    await _settle();
    expect(adapter.requests, hasLength(3));
    for (var i = 0; i < 3; i++) {
      adapter.complete(i);
    }
    await Future.wait([first, same, otherRide, otherAccount]);
  });

  test('actions and unknown contracts never share requests or retry themselves',
      () async {
    final adapter = _Adapter();
    final api = await ApiClient(_Storage()).init();
    api.dio.httpClientAdapter = adapter;
    addTearDown(() => api.dio.close(force: true));
    final actions = [
      for (var i = 0; i < 2; i++)
        api.execute<Object?>(
            model: 'RideModel', operation: 'update', data: {'rideId': 42}),
      for (var i = 0; i < 2; i++)
        api.execute<Object?>(model: 'UnknownModel', operation: 'get'),
    ];
    await _settle();
    expect(adapter.requests, hasLength(4));
    for (var i = 0; i < 4; i++) {
      adapter.complete(i);
    }
    await Future.wait(actions);
    expect(adapter.requests, hasLength(4));
  });

  test('a failed read is evicted so the next recovery read can succeed',
      () async {
    final adapter = _Adapter();
    final api = await ApiClient(_Storage()).init();
    api.dio.httpClientAdapter = adapter;
    addTearDown(() => api.dio.close(force: true));
    Future<ApiResult<Object?>> read() => api.execute<Object?>(
        model: 'RideModel', operation: 'get', data: {'rideId': 42});
    final first = read();
    final duplicate = read();
    await _settle();
    adapter.responses[0].completeError(DioException(
        requestOptions: adapter.requests[0],
        type: DioExceptionType.connectionError));
    expect(await first, isA<ApiFailure<Object?>>());
    expect(await duplicate, isA<ApiFailure<Object?>>());
    final next = read();
    await _settle();
    expect(adapter.requests, hasLength(2));
    adapter.complete(1);
    expect(await next, isA<ApiSuccess<Object?>>());
  });

  test('post-action read cannot reuse a pre-action pending snapshot', () async {
    final adapter = _Adapter();
    final api = await ApiClient(_Storage()).init();
    api.dio.httpClientAdapter = adapter;
    addTearDown(() => api.dio.close(force: true));
    Future<ApiResult<Object?>> read() => api.execute<Object?>(
        model: 'RideModel', operation: 'get', data: {'rideId': 42});
    final old = read();
    await _settle();
    final action = api.execute<Object?>(
        model: 'RideModel', operation: 'update', data: {'rideId': 42});
    await _settle();
    adapter.complete(1);
    await action;
    final fresh = read();
    await _settle();
    expect(adapter.requests, hasLength(3));
    adapter.complete(2, 43);
    expect((await fresh as ApiSuccess<Object?>).data, {'id': 43});
    adapter.complete(0, 42);
    expect((await old as ApiSuccess<Object?>).data, {'id': 42});
  });

  for (final boundary in [
    'legacy event',
    'stateChanged',
    'replay page',
    'reconnect'
  ]) {
    test('$boundary separates old reads while fresh canonical peers coalesce',
        () async {
      final storage = _Storage();
      final adapter = _Adapter();
      final api = Get.put(await ApiClient(storage).init());
      api.dio.httpClientAdapter = adapter;
      final connection = _Connection();
      final hub = Get.put(
          TrackingHubService(storage, connectionFactory: () => connection));
      addTearDown(() async {
        await hub.disconnect();
        api.dio.close(force: true);
      });
      await hub.setUserEventListening('test', true);
      Future<ApiResult<Object?>> read() => api.execute<Object?>(
          model: 'RideModel', operation: 'get', data: {'rideId': 42});
      final old = read();
      await _settle();
      expect(adapter.requests, hasLength(1));
      final peers = <Future<ApiResult<Object?>>>[];
      StreamSubscription<Object?>? subscription;
      Future<void>? recovery;
      if (boundary == 'legacy event') {
        subscription = hub.events.listen((event) {
          peers.add(read());
          peers.add(read());
        });
        connection.emit('rideStatusUpdated', {'rideId': 42, 'rideStatus': 5});
      } else if (boundary == 'reconnect') {
        subscription = hub.connectionRestored.listen((_) {
          peers.add(read());
          peers.add(read());
        });
        recovery = hub.reconnectAfterApiRecovery();
      } else {
        for (final owner in ['ride', 'waiting']) {
          hub.stateChanges.register(owner, (_) async {
            final request = read();
            peers.add(request);
            await request;
          });
        }
        final event = <String, Object?>{
          'stream': 'ride:42',
          'resource': 'ride',
          'resourceId': 42,
          'version': 1,
        };
        if (boundary == 'stateChanged') {
          connection.emit('stateChanged', event);
        } else {
          connection.replay = {
            'supported': true,
            'events': [event],
            'hasMore': false
          };
          recovery = hub.recoverState();
        }
      }
      await _settle();
      expect(peers, hasLength(2));
      expect(adapter.requests, hasLength(2));
      adapter.complete(0, 42);
      expect((await old as ApiSuccess<Object?>).data, {'id': 42},
          reason: 'Invalidation does not cancel or replay existing callers.');
      peers.add(read());
      await _settle();
      expect(adapter.requests, hasLength(2),
          reason: 'Old completion cannot evict the new read-sharing window.');
      adapter.complete(1, 43);
      final values = await Future.wait(peers);
      expect(
          values.every(
              (v) => v is ApiSuccess<Object?> && (v.data as Map)['id'] == 43),
          isTrue);
      await recovery;
      await hub.stateChanges.flush();
      await subscription?.cancel();
    });
  }

  test('GPS and nearby availability do not split an in-flight canonical read',
      () async {
    final storage = _Storage();
    final adapter = _Adapter();
    final api = Get.put(await ApiClient(storage).init());
    api.dio.httpClientAdapter = adapter;
    final connection = _Connection();
    final hub = Get.put(
        TrackingHubService(storage, connectionFactory: () => connection));
    addTearDown(() async {
      await hub.disconnect();
      api.dio.close(force: true);
    });
    await hub.setUserEventListening('test', true);
    Future<ApiResult<Object?>> read() => api.execute<Object?>(
        model: 'RideModel', operation: 'get', data: {'rideId': 42});
    final peers = [read()];
    await _settle();
    final subscription = hub.events.listen((_) => peers.add(read()));
    for (final name in [
      'driverLocationUpdated',
      'passengerLocationUpdated',
      'nearbyDriverLocationUpdated',
      'nearbyDriverAvailabilityChanged',
      'trackingDemandChanged',
    ]) {
      connection.emit(name, {'rideId': 42});
    }
    await _settle();
    expect(peers, hasLength(6));
    expect(adapter.requests, hasLength(1));
    adapter.complete(0);
    await Future.wait(peers);
    await subscription.cancel();
  });
}
