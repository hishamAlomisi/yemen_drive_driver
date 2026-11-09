import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class DriverRouteBatch {
  const DriverRouteBatch(
      this.accountId, this.rideId, this.sessionId, this.samples);
  final int accountId;
  final int rideId;
  final String sessionId;
  final List<Map<String, Object?>> samples;
  Map<String, Object?> get payload => {
        'rideId': rideId,
        'sessionId': sessionId,
        'samples': samples,
      };
}

abstract interface class DriverRouteStore {
  Future<void> append(int accountId, int rideId, Map<String, Object?> sample);
  Future<DriverRouteBatch?> next(int accountId, {int? rideId});
  Future<void> acknowledge(DriverRouteBatch batch, Set<String> sampleIds);
  Future<int> count(int accountId, {int? rideId});
  Future<String?> recordingIssue(int accountId, {int? rideId});
}

/// SQLite commits each sample and its sequence together before network sending.
/// An acknowledgement removes only the IDs the server confirms as persisted.
class SqliteDriverRouteStore implements DriverRouteStore {
  SqliteDriverRouteStore({this.capacity = 20000, Future<Database>? database})
      : _database = database;
  final int capacity;
  Future<Database>? _database;
  Future<Database> get _db => _database ??= _open();

  static Future<Database> _open() async {
    final path = await getDatabasesPath();
    return openDatabaseAt('$path/driver_route_outbox_v1.db');
  }

  static Future<Database> openDatabaseAt(String path,
          {DatabaseFactory? factory}) =>
      (factory ?? databaseFactory).openDatabase(path,
          options: OpenDatabaseOptions(
              version: 2,
              onConfigure: (db) async {
                await db.execute('PRAGMA synchronous=FULL');
                await db.execute('PRAGMA foreign_keys=ON');
              },
              onCreate: (db, _) async {
                await db.execute('CREATE TABLE sessions ('
                    'account INTEGER NOT NULL, ride INTEGER NOT NULL, session TEXT NOT NULL UNIQUE, '
                    'sequence INTEGER NOT NULL, observed TEXT, PRIMARY KEY(account,ride))');
                await db.execute('CREATE TABLE samples ('
                    'id TEXT PRIMARY KEY, account INTEGER NOT NULL, ride INTEGER NOT NULL, '
                    'session TEXT NOT NULL REFERENCES sessions(session), sequence INTEGER NOT NULL, '
                    'payload TEXT NOT NULL, UNIQUE(session,sequence))');
                await db.execute(
                    'CREATE INDEX samples_account ON samples(account,ride,sequence)');
                await _createIssues(db);
              },
              onUpgrade: (db, oldVersion, _) async {
                if (oldVersion < 2) await _createIssues(db);
              }));

  static Future<void> _createIssues(Database db) => db.execute(
      'CREATE TABLE recording_issues (account INTEGER NOT NULL, ride INTEGER NOT NULL, '
      'message TEXT NOT NULL, PRIMARY KEY(account,ride))');

  @override
  Future<void> append(
      int accountId, int rideId, Map<String, Object?> sample) async {
    final db = await _db;
    String? incomplete;
    await db.transaction((tx) async {
      final rows = await tx.query('sessions',
          where: 'account=? AND ride=?', whereArgs: [accountId, rideId]);
      final current = rows.isEmpty ? null : rows.single;
      final observed = sample['observedAtUtc'] as String;
      final prior = current?['observed'] as String?;
      // A repeated first-fix/stream callback cannot allocate a second sequence.
      if (prior != null &&
          !DateTime.parse(observed).isAfter(DateTime.parse(prior))) {
        return;
      }
      final size = Sqflite.firstIntValue(await tx.rawQuery(
              'SELECT COUNT(*) FROM samples WHERE account=?', [accountId])) ??
          0;
      if (size >= capacity) {
        incomplete =
            'مخزن المسار ممتلئ؛ توجد عينة لم تُحفظ وتحتاج مراجعة اكتمال المسار.';
        await tx.insert('recording_issues',
            {'account': accountId, 'ride': rideId, 'message': incomplete},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        return;
      }
      final session = current?['session'] as String? ?? const Uuid().v4();
      final sequence = ((current?['sequence'] as int?) ?? 0) + 1;
      final id = const Uuid().v4();
      if (current == null) {
        await tx.insert('sessions', {
          'account': accountId,
          'ride': rideId,
          'session': session,
          'sequence': sequence,
          'observed': observed
        });
      } else {
        await tx.update(
            'sessions', {'sequence': sequence, 'observed': observed},
            where: 'account=? AND ride=?', whereArgs: [accountId, rideId]);
      }
      await tx.insert('samples', {
        'id': id,
        'account': accountId,
        'ride': rideId,
        'session': session,
        'sequence': sequence,
        'payload': jsonEncode({...sample, 'sampleId': id, 'sequence': sequence})
      });
    });
    if (incomplete != null) throw StateError(incomplete!);
  }

  @override
  Future<DriverRouteBatch?> next(int accountId, {int? rideId}) async {
    final db = await _db;
    final first = await db.query('samples',
        where: 'account=?${rideId == null ? '' : ' AND ride=?'}',
        whereArgs: [accountId, if (rideId != null) rideId],
        orderBy: 'ride,sequence',
        limit: 1);
    if (first.isEmpty) return null;
    final row = first.single;
    final rows = await db.query('samples',
        where: 'account=? AND session=?',
        whereArgs: [accountId, row['session']],
        orderBy: 'sequence',
        limit: 64);
    return DriverRouteBatch(
        accountId,
        row['ride']! as int,
        row['session']! as String,
        rows
            .map((item) => Map<String, Object?>.from(
                jsonDecode(item['payload']! as String) as Map<String, Object?>))
            .toList());
  }

  @override
  Future<void> acknowledge(
      DriverRouteBatch batch, Set<String> sampleIds) async {
    if (sampleIds.isEmpty) return;
    final db = await _db;
    await db.transaction((tx) async {
      for (final id in sampleIds) {
        await tx.delete('samples',
            where: 'account=? AND session=? AND id=?',
            whereArgs: [batch.accountId, batch.sessionId, id]);
      }
    });
  }

  @override
  Future<int> count(int accountId, {int? rideId}) async =>
      Sqflite.firstIntValue(await (await _db).rawQuery(
          'SELECT COUNT(*) FROM samples WHERE account=?${rideId == null ? '' : ' AND ride=?'}',
          [accountId, if (rideId != null) rideId])) ??
      0;

  @override
  Future<String?> recordingIssue(int accountId, {int? rideId}) async {
    final rows = await (await _db).query('recording_issues',
        columns: ['message'],
        where: 'account=?${rideId == null ? '' : ' AND ride=?'}',
        whereArgs: [accountId, if (rideId != null) rideId],
        limit: 1);
    return rows.isEmpty ? null : rows.first['message'] as String;
  }
}

class DriverRouteOutbox {
  DriverRouteOutbox(
      {required this.store,
      required this.send,
      required this.isCurrentAccount,
      this.onChanged});
  final DriverRouteStore store;
  final Future<Map<String, Object?>> Function(Map<String, Object?>) send;
  final bool Function(int) isCurrentAccount;
  final void Function()? onChanged;
  Future<void>? _recordTask;
  Future<bool>? _flushTask;
  int? _flushAccountId;
  int? _flushRideId;
  bool? supported;
  Object? failure;
  final Map<String, Object> _recordingFailures = {};

  Object? _recordingFailure(int accountId, {int? rideId}) {
    if (rideId != null) return _recordingFailures['$accountId:$rideId'];
    for (final entry in _recordingFailures.entries) {
      if (entry.key.startsWith('$accountId:')) return entry.value;
    }
    return null;
  }

  Future<void> record(int accountId, int rideId, Map<String, Object?> sample) {
    final previous = _recordTask;
    late final Future<void> task;
    task = (() async {
      if (previous != null) {
        try {
          await previous;
        } on Object {/* Retain the failed sample warning. */}
      }
      if (!isCurrentAccount(accountId)) return;
      try {
        await store.append(accountId, rideId, sample);
      } catch (error) {
        _recordingFailures['$accountId:$rideId'] = error;
        failure = error;
        rethrow;
      } finally {
        onChanged?.call();
      }
    })()
        .whenComplete(() {
      if (identical(_recordTask, task)) _recordTask = null;
    });
    _recordTask = task;
    return task;
  }

  Future<bool> flush(int accountId, {int? rideId}) {
    final active = _flushTask;
    if (active != null) {
      if (_flushAccountId == accountId && _flushRideId == rideId) return active;
      return active
          .catchError((Object _) => false)
          .then((_) => flush(accountId, rideId: rideId));
    }
    late final Future<bool> task;
    _flushAccountId = accountId;
    _flushRideId = rideId;
    task = _drain(accountId, rideId: rideId).whenComplete(() {
      if (identical(_flushTask, task)) _flushTask = null;
      onChanged?.call();
    });
    _flushTask = task;
    return task;
  }

  Future<bool> _drain(int accountId, {int? rideId}) async {
    try {
      while (isCurrentAccount(accountId)) {
        await _recordTask;
        final batch = await store.next(accountId, rideId: rideId);
        if (batch == null) {
          failure = await store.recordingIssue(accountId, rideId: rideId) ??
              _recordingFailure(accountId, rideId: rideId);
          return supported == true;
        }
        final response = await send(batch.payload);
        if (!isCurrentAccount(accountId)) return false;
        if (response['enabled'] != true) {
          supported = false;
          return false;
        }
        supported = true;
        final rawIds = response['acceptedSampleIds'];
        if (rawIds is! List)
          throw const FormatException('Missing route acknowledgement');
        final ids = rawIds.map((id) => '$id').toSet();
        final sentIds =
            batch.samples.map((sample) => '${sample['sampleId']}').toSet();
        if (ids.isEmpty || !sentIds.containsAll(ids)) {
          throw const FormatException('Invalid route acknowledgement');
        }
        await store.acknowledge(batch, ids);
        // A previous append/storage failure represents a real missing point;
        // successful network delivery must not clear that warning silently.
      }
      return false;
    } catch (error) {
      failure = error;
      rethrow;
    }
  }

  Future<void> requireSaved(int accountId, int rideId) async {
    if (!isCurrentAccount(accountId))
      throw StateError('تغير الحساب قبل تأكيد المسار.');
    await _recordTask;
    await flush(accountId, rideId: rideId);
    if (!isCurrentAccount(accountId))
      throw StateError('تغير الحساب قبل تأكيد المسار.');
    if (await store.count(accountId, rideId: rideId) != 0) {
      throw StateError(supported == false
          ? 'الخادم لا يدعم تأكيد نقاط المسار المسجلة؛ يلزم استعادة خدمة الحفظ قبل هذه العملية.'
          : 'توجد نقاط مسار غير مؤكدة الحفظ؛ أعد الاتصال وحاول مجدداً.');
    }
    final issue = await store.recordingIssue(accountId, rideId: rideId);
    final missingSampleFailure = _recordingFailure(accountId, rideId: rideId);
    if (issue != null || missingSampleFailure != null) {
      throw StateError(
          'تعذر تأكيد اكتمال سجل المسار: ${issue ?? missingSampleFailure}');
    }
  }
}
