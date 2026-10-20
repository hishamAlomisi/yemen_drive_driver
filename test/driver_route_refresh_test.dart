import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import '../lib/core/network/api_client.dart';
import '../lib/core/services/auth_session_service.dart';
import '../lib/core/storage/secure_storage_service.dart';
import '../lib/features/driver/controllers/driver_controller.dart';
import '../lib/features/driver/models/driver_models.dart';
import '../lib/features/driver/repositories/driver_repository.dart';

class RouteRepositoryFake implements DriverRepository {
  final requests = <Completer<Map<String, Object?>>>[];
  final listRequest = Completer<DriverSnapshot>();

  @override
  Future<Map<String, Object?>> getRide(int rideId) {
    final request = Completer<Map<String, Object?>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<DriverSnapshot> load(int? userId) => listRequest.future;

  @override
  Future<List<Map<String, Object?>>> notifications() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object?> ride(int version) => {
      'id': 7,
      'status': 5,
      'routeVersion': version,
      'destinationDisplayName': 'وجهة $version',
      'destinationLatitude': 15.3 + version / 100,
      'destinationLongitude': 44.2,
      'totalAmount': 1100 + version * 100,
    };

DriverController controller(RouteRepositoryFake repository) {
  final storage = SecureStorageService();
  return DriverController(
      repository, AuthSessionService(storage, ApiClient(storage)));
}

void main() {
  tearDown(() => Get.reset());

  test('approval refresh updates destination and total together', () async {
    final repository = RouteRepositoryFake();
    final subject = controller(repository);
    subject.rides.add({...ride(0), 'driverId': 55});
    final refresh = subject.refreshRide(7);
    repository.requests.single.complete(ride(1));
    await refresh;
    expect(subject.rides.single['destinationDisplayName'], 'وجهة 1');
    expect(subject.rides.single['destinationLatitude'], 15.31);
    expect(subject.rides.single['totalAmount'], 1200);
    expect(subject.rides.single['driverId'], 55);
  });

  test('an approval arriving during a refresh triggers another fetch',
      () async {
    final repository = RouteRepositoryFake();
    final subject = controller(repository);
    subject.rides.add(ride(0));
    final first = subject.refreshRide(7);
    final second = subject.refreshRide(7);
    expect(repository.requests, hasLength(1));
    repository.requests[0].complete(ride(0));
    await Future<void>.delayed(Duration.zero);
    expect(repository.requests, hasLength(2));
    repository.requests[1].complete(ride(1));
    await Future.wait([first, second]);
    expect(subject.rides.single['routeVersion'], 1);
  });

  test('a stale home list cannot replace a newly accepted destination',
      () async {
    final repository = RouteRepositoryFake();
    final subject = controller(repository);
    subject.rides.add(ride(0));
    final load = subject.load(showLoading: false);
    final refresh = subject.refreshRide(7);
    repository.requests.single.complete(ride(2));
    await refresh;
    repository.listRequest
        .complete(DriverSnapshot(profile: null, rides: [ride(0)]));
    await load;
    expect(subject.rides.single['routeVersion'], 2);
    expect(subject.rides.single['totalAmount'], 1300);
  });

  test('failed refresh can be retried and older route versions are ignored',
      () async {
    final repository = RouteRepositoryFake();
    final subject = controller(repository);
    subject.rides.add(ride(2));
    final failed = subject.refreshRide(7);
    repository.requests[0].completeError(StateError('offline'));
    await expectLater(failed, throwsStateError);
    final retry = subject.refreshRide(7);
    repository.requests[1].complete(ride(1));
    await retry;
    expect(subject.rides.single['routeVersion'], 2);
  });
}
