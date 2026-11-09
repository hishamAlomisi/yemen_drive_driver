import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yemen_drive_driver/core/realtime/state_change_coordinator.dart';

void main() {
  test('replay cursor covers more than the bounded version cache', () async {
    final feed = StateChangeCoordinator();
    addTearDown(feed.dispose);
    final refreshed = <int>{};
    feed.register('rides', (changes) async {
      refreshed.addAll(changes.map((c) => c.resourceId));
    });
    await feed.recover((versions, afterStream) async {
      expect(versions.length, lessThanOrEqualTo(512));
      final start = afterStream == null ? 1 : int.parse(afterStream) + 1;
      final end = start + 127 < 600 ? start + 127 : 600;
      return {
        'supported': true,
        'hasMore': end < 600,
        'nextStream': '$end',
        'events': [
          for (var i = start; i <= end; i++)
            {
              'stream': 'ride:$i',
              'resource': 'ride',
              'resourceId': i,
              'version': 1
            }
        ]
      };
    });
    expect(refreshed.length, 600);
    expect(feed.versions.length, 512);
    expect(feed.synchronized, isTrue);
  });
  StateChange change(int version) => StateChange('ride:7', version, 'ride', 7);
  Map<Object?, Object?> page(List<int> versions) => {
        'supported': true,
        'hasMore': false,
        'events': [
          for (final v in versions)
            {
              'stream': 'ride:7',
              'version': v,
              'resource': 'ride',
              'resourceId': 7
            }
        ]
      };
  test('independent owners read concurrently and acknowledge only after both',
      () async {
    final feed = StateChangeCoordinator();
    addTearDown(feed.dispose);
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstDone = Completer<void>();
    final secondDone = Completer<void>();
    feed.register('trip', (_) async {
      firstStarted.complete();
      await firstDone.future;
    });
    feed.register('waiting-panel', (_) async {
      secondStarted.complete();
      await secondDone.future;
    });
    final recovering = feed.recover((_, __) async => page([4]));
    await Future.wait([firstStarted.future, secondStarted.future])
        .timeout(const Duration(seconds: 1));
    expect(feed.versions, isEmpty);
    secondDone.complete();
    await Future<void>.delayed(Duration.zero);
    expect(feed.versions, isEmpty);
    firstDone.complete();
    await recovering;
    expect(feed.versions['ride:7'], 4);
  });

  test(
      'owner failure waits for remaining reads and never acknowledges the batch',
      () async {
    final feed = StateChangeCoordinator();
    addTearDown(feed.dispose);
    final started = Completer<void>();
    final finish = Completer<void>();
    var returned = false;
    feed.register('slow-trip', (_) async {
      started.complete();
      await finish.future;
    });
    feed.register('failed-wallet', (_) async => throw StateError('offline'));
    final recovering = feed
        .recover((_, __) async => page([4]))
        .whenComplete(() => returned = true);
    final failure = expectLater(recovering, throwsStateError);
    await started.future;
    await Future<void>.delayed(Duration.zero);
    expect(returned, isFalse);
    finish.complete();
    await failure;
    expect(feed.versions, isEmpty);
    expect(feed.synchronized, isFalse);
  });
  test(
      'coalesces duplicates and old events only after canonical refresh finishes',
      () async {
    final feed = StateChangeCoordinator();
    addTearDown(feed.dispose);
    var calls = 0;
    final release = Completer<void>();
    feed.register('trip', (_) async {
      calls++;
      await release.future;
    });
    final recovering = feed.recover((_, __) async => page([1, 2, 1]));
    await Future<void>.delayed(Duration.zero);
    expect(feed.versions, isEmpty);
    expect(feed.synchronized, isFalse);
    release.complete();
    await recovering;
    expect(calls, 1);
    expect(feed.versions['ride:7'], 2);
    expect(feed.synchronized, isTrue);
    feed.observe(change(1));
    await feed.flush();
    expect(calls, 1);
  });
  test('a later event during a snapshot is retained and reconciled again',
      () async {
    final feed = StateChangeCoordinator();
    addTearDown(feed.dispose);
    final release = Completer<void>();
    final started = Completer<void>();
    var calls = 0;
    feed.register('trip', (_) async {
      calls++;
      if (calls == 1) {
        started.complete();
        await release.future;
      }
    });
    final recovering = feed.recover((_, __) async => page([1]));
    await started.future;
    final earlierEpoch = feed.epoch;
    feed.observe(change(2));
    expect(feed.epoch, greaterThan(earlierEpoch));
    release.complete();
    await recovering;
    expect(calls, 2);
    expect(feed.versions['ride:7'], 2);
  });
  test(
      'failed owner is not acknowledged and reconnect retries the same version',
      () async {
    final feed = StateChangeCoordinator();
    addTearDown(feed.dispose);
    var fails = true;
    feed.register('wallet', (_) async {
      if (fails) throw StateError('offline');
    });
    await expectLater(
        feed.recover((_, __) async => page([3])), throwsStateError);
    expect(feed.versions, isEmpty);
    expect(feed.synchronized, isFalse);
    feed.disconnected();
    fails = false;
    await feed.recover((known, _) async {
      expect(known, isEmpty);
      return page([3]);
    });
    expect(feed.versions['ride:7'], 3);
    expect(feed.synchronized, isTrue);
  });
  test('disconnect invalidates old snapshots and reset separates user accounts',
      () async {
    final feed = StateChangeCoordinator();
    addTearDown(feed.dispose);
    final release = Completer<Map<Object?, Object?>>();
    final recovering = feed.recover((_, __) => release.future);
    final epoch = feed.epoch;
    feed.disconnected();
    release.complete(page([4]));
    await recovering;
    expect(feed.epoch, greaterThan(epoch));
    expect(feed.versions, isEmpty);
    await feed.recover((_, __) async => page([5]));
    feed.reset();
    expect(feed.versions, isEmpty);
    expect(feed.synchronized, isFalse);
  });
  test(
      'reconnect during an owner refresh reconciles without acknowledging the old result',
      () async {
    final feed = StateChangeCoordinator();
    addTearDown(feed.dispose);
    final started = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    feed.register('trip', (_) async {
      calls++;
      if (calls == 1) {
        started.complete();
        await release.future;
      }
    });
    final first = feed.recover((_, __) async => page([1]));
    await started.future;
    feed.disconnected();
    final second = feed.recover((_, __) async => page([2]));
    release.complete();
    await Future.wait([first, second]);
    expect(calls, 2);
    expect(feed.versions['ride:7'], 2);
    expect(feed.synchronized, isTrue);
  });
  test('an unsupported older server does not report synchronized', () async {
    final feed = StateChangeCoordinator();
    addTearDown(feed.dispose);
    await expectLater(
        feed.recover((_, __) async => {'supported': false}), throwsStateError);
    expect(feed.synchronized, isFalse);
    expect(feed.versions, isEmpty);
  });
}
