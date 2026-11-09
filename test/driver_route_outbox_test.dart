import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yemen_drive_driver/core/services/driver_route_outbox.dart';

Map<String, Object?> point(int seconds) => {
      'latitude': 15.36 + seconds / 100000,
      'longitude': 44.19,
      'accuracy': 10.0,
      'bearing': 90.0,
      'speed': 3.0,
      'observedAtUtc':
          DateTime.utc(2026, 11, 3, 10, 0, seconds).toIso8601String(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late SqliteDriverRouteStore store;
  late Directory directory;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('yemendrive-route-test-');
    path = '${directory.path}/outbox.db';
    db = await SqliteDriverRouteStore.openDatabaseAt(path,
        factory: databaseFactoryFfi);
    store = SqliteDriverRouteStore(database: Future.value(db), capacity: 4);
  });
  tearDown(() async {
    await db.close();
    // Only the test-created database directory is removed.
    final resolved = directory.absolute.path;
    if (!resolved.startsWith(Directory.systemTemp.absolute.path) ||
        !directory.uri.pathSegments
            .any((part) => part.startsWith('yemendrive-route-test-'))) {
      throw StateError('Unexpected test cleanup path');
    }
    await directory.delete(recursive: true);
  });

  test(
      'SQLite restart preserves sample identity, pending points and next sequence',
      () async {
    await store.append(42, 7, point(1));
    await store.append(42, 7, point(1));
    await store.append(42, 7, point(2));
    final original = (await store.next(42))!;
    expect(original.samples.length, 2);
    await store
        .acknowledge(original, {'${original.samples.first['sampleId']}'});
    await db.close();
    db = await SqliteDriverRouteStore.openDatabaseAt(path,
        factory: databaseFactoryFfi);
    store = SqliteDriverRouteStore(database: Future.value(db), capacity: 4);
    final recovered = (await store.next(42))!;
    expect(recovered.sessionId, original.sessionId);
    expect(recovered.samples.single, original.samples.last);
    await store.append(42, 7, point(3));
    expect((await store.next(42))!.samples.last['sequence'], 3);
    expect(await store.next(99), isNull);
  });

  test(
      'lost acknowledgement retries same IDs and new points are not dropped during upload',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final sent = <List<String>>[];
    var attempt = 0;
    final outbox = DriverRouteOutbox(
        store: store,
        isCurrentAccount: (id) => id == 42,
        send: (payload) async {
          final samples = payload['samples']! as List<Map<String, Object?>>;
          final ids = samples.map((s) => '${s['sampleId']}').toList();
          sent.add(ids);
          if (attempt++ == 0) {
            started.complete();
            await release.future;
            throw const SocketException('Response lost after server commit');
          }
          return {'enabled': true, 'acceptedSampleIds': ids};
        });
    await outbox.record(42, 7, point(1));
    final failed =
        expectLater(outbox.flush(42), throwsA(isA<SocketException>()));
    await started.future;
    await outbox.record(42, 7, point(2));
    release.complete();
    await failed;
    expect(await store.count(42), 2);
    expect(await outbox.flush(42), true);
    expect(sent.last.first, sent.first.single);
    expect(sent.last.length, 2);
    expect(await store.count(42), 0);
    expect(outbox.failure, isNull);
  });

  test(
      'disabled batch support preserves points; invalid IDs cannot delete them',
      () async {
    final outbox = DriverRouteOutbox(
        store: store,
        isCurrentAccount: (id) => id == 42,
        send: (_) async => {'enabled': false});
    await outbox.record(42, 7, point(1));
    expect(await outbox.flush(42), false);
    expect(await store.count(42), 1);
    final invalid = DriverRouteOutbox(
        store: store,
        isCurrentAccount: (_) => true,
        send: (_) async => {
              'enabled': true,
              'acceptedSampleIds': ['other-user-id']
            });
    await expectLater(invalid.flush(42), throwsFormatException);
    expect(await store.count(42), 1);
  });

  test(
      'capacity failure rolls back sequence and never evicts unacknowledged points',
      () async {
    for (var i = 1; i <= 4; i++) {
      await store.append(42, 7, point(i));
    }
    await expectLater(store.append(42, 7, point(5)), throwsStateError);
    expect(await store.count(42), 4);
    final full = (await store.next(42))!;
    await store.acknowledge(full, {'${full.samples.first['sampleId']}'});
    await store.append(42, 7, point(6));
    expect((await store.next(42))!.samples.last['sequence'], 5);
  });

  test(
      'required-history command waits for every recorded sample acknowledgement',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final outbox = DriverRouteOutbox(
        store: store,
        isCurrentAccount: (id) => id == 42,
        send: (payload) async {
          if (!started.isCompleted) {
            started.complete();
            await release.future;
          }
          return {
            'enabled': true,
            'acceptedSampleIds':
                (payload['samples']! as List<Map<String, Object?>>)
                    .map((s) => s['sampleId'])
                    .toList()
          };
        });
    await outbox.record(42, 7, point(1));
    var allowed = false;
    final barrier = outbox.requireSaved(42, 7).then((_) => allowed = true);
    await started.future;
    await outbox.record(42, 7, point(2));
    expect(allowed, false);
    release.complete();
    await barrier;
    expect(allowed, true);
    expect(await store.count(42), 0);
  });

  test('unavailable batch server cannot certify a required-history command',
      () async {
    final outbox = DriverRouteOutbox(
        store: store,
        isCurrentAccount: (_) => true,
        send: (_) async => {'enabled': false});
    await outbox.record(42, 7, point(1));
    await expectLater(outbox.requireSaved(42, 7), throwsStateError);
    expect(await store.count(42), 1);
  });

  test('capacity gap survives process restart and successful delivery',
      () async {
    for (var i = 1; i <= 4; i++) {
      await store.append(42, 7, point(i));
    }
    await expectLater(store.append(42, 7, point(5)), throwsStateError);
    await db.close();
    db = await SqliteDriverRouteStore.openDatabaseAt(path,
        factory: databaseFactoryFfi);
    store = SqliteDriverRouteStore(database: Future.value(db), capacity: 4);
    final outbox = DriverRouteOutbox(
        store: store,
        isCurrentAccount: (_) => true,
        send: (payload) async => {
              'enabled': true,
              'acceptedSampleIds':
                  (payload['samples']! as List<Map<String, Object?>>)
                      .map((s) => s['sampleId'])
                      .toList()
            });
    await expectLater(outbox.requireSaved(42, 7), throwsStateError);
    expect(await store.count(42), 0);
    expect(await store.recordingIssue(42, rideId: 7), isNotNull);
    expect(await store.recordingIssue(99), isNull);
  });

  test('an old account upload cannot acknowledge after account switch',
      () async {
    var account = 42;
    final started = Completer<void>();
    final release = Completer<void>();
    final outbox = DriverRouteOutbox(
        store: store,
        isCurrentAccount: (id) => id == account,
        send: (payload) async {
          started.complete();
          await release.future;
          return {
            'enabled': true,
            'acceptedSampleIds':
                (payload['samples']! as List<Map<String, Object?>>)
                    .map((s) => s['sampleId'])
                    .toList()
          };
        });
    await outbox.record(42, 7, point(1));
    final result = outbox.flush(42);
    await started.future;
    account = 99;
    release.complete();
    expect(await result, false);
    expect(await store.count(42), 1);
    expect(await store.count(99), 0);
  });

  test('an unrecoverable old ride does not block the current ride archive',
      () async {
    final outbox = DriverRouteOutbox(
        store: store,
        isCurrentAccount: (_) => true,
        send: (payload) async {
          if (payload['rideId'] == 7)
            throw const FormatException('Historical recovery window expired');
          return {
            'enabled': true,
            'acceptedSampleIds':
                (payload['samples']! as List<Map<String, Object?>>)
                    .map((s) => s['sampleId'])
                    .toList()
          };
        });
    await outbox.record(42, 7, point(1));
    await outbox.record(42, 8, point(2));
    await expectLater(outbox.flush(42), throwsFormatException);
    await outbox.requireSaved(42, 8);
    expect(await store.count(42, rideId: 8), 0);
    expect(await store.count(42, rideId: 7), 1);
  });
}
