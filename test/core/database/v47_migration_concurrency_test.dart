// VS16 M7 corrective — first-launch migration concurrency.
//
// The v47 build hung on the splash screen on first launch with
//   SqliteException(5): database is locked  (Causing statement: BEGIN IMMEDIATE)
// raised from `onUpgrade`'s transaction.
//
// Cause: `AppDatabase.defaults()` is constructed from three independent sites
// in one process, and with drift's DEFAULT options each site opened its own
// connection to `next_transfer.sqlite`. Two connections could both decide to run
// the v46 -> v47 migration at once, which deadlocks on lock upgrades:
//   * A holds RESERVED (`BEGIN IMMEDIATE`) and needs EXCLUSIVE to commit;
//   * B holds SHARED (from reading `user_version`) and needs RESERVED.
// Neither can yield, so SQLite raises SQLITE_BUSY — and no timeout helps.
//
// These tests pin the whole argument, including the NEGATIVE results, so a
// future reader cannot mistake a timeout for the fix:
//   * the drift-default connection really does lose the race (the pre-fix
//     failure — the "fail-first" arm);
//   * a busy timeout, WAL, and both together each still lose it;
//   * the production options use drift's shared-connection remedy, which
//     removes the second connection entirely.
//
// `shareAcrossIsolates` itself needs a real Flutter engine (it resolves a
// connection through `IsolateNameServer`), so it is asserted structurally here
// and its mechanism is asserted directly in the single-connection test.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';

/// Materialises a v46 database on disk and returns the file path.
Future<String> _seedV46(Directory dir) async {
  final path = '${dir.path}/next_transfer.sqlite';
  final v46 = AppDatabase.forTesting(
    NativeDatabase(File(path)),
    schemaVersionOverride: 46,
  );
  await v46.select(v46.localProfiles).get();
  final version = await v46.customSelect('PRAGMA user_version').getSingle();
  expect(version.read<int>('user_version'), 46);
  await v46.close();
  return path;
}

/// Races two connections that both open at schema v47 over a v46 file, and
/// reports whether either threw. Deliberately performs NO query before the race:
/// an earlier probe read `PRAGMA busy_timeout` on both connections first, which
/// forced each to open (and migrate) sequentially and hid the race entirely.
Future<bool> _raceThrows(
  String path,
  NativeDatabase Function(String) open,
) async {
  final a = AppDatabase.forTesting(open(path));
  final b = AppDatabase.forTesting(open(path));

  Object? failure;
  Future<void> probe(AppDatabase db) async {
    try {
      await db.select(db.localProfiles).get();
    } catch (error) {
      failure ??= error;
    }
  }

  await Future.wait<void>([probe(a), probe(b)]);
  await a.close();
  await b.close();
  return failure != null;
}

void main() {
  test('structural: production opts into drift\'s shared connection', () {
    expect(
      kAppDatabaseNativeOptions.shareAcrossIsolates,
      isTrue,
      reason:
          'every AppDatabase.defaults() must converge on ONE shared '
          'connection, so a second connection can never race the migration',
    );
    expect(
      kAppDatabaseNativeOptions.setup,
      isNull,
      reason:
          'a busy timeout was measured NOT to fix this deadlock, so the '
          'corrective deliberately carries no connection setup',
    );
  });

  test('FAIL-FIRST ARM: drift defaults lose the v46 -> v47 race', () async {
    final dir = await Directory.systemTemp.createTemp('nt_v47_before');
    try {
      final path = await _seedV46(dir);
      final threw = await _raceThrows(path, (p) => NativeDatabase(File(p)));
      expect(
        threw,
        isTrue,
        reason:
            'PRE-FIX BEHAVIOUR: with two independent connections one of '
            'them throws SqliteException(5) "database is locked" on '
            'BEGIN IMMEDIATE — the exact splash-screen hang seen on device',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('NEGATIVE RESULT: a busy timeout does NOT fix the race', () async {
    final dir = await Directory.systemTemp.createTemp('nt_v47_timeout');
    try {
      final path = await _seedV46(dir);
      final threw = await _raceThrows(
        path,
        (p) => NativeDatabase(
          File(p),
          setup: (db) => db.execute('PRAGMA busy_timeout = 5000'),
        ),
      );
      expect(
        threw,
        isTrue,
        reason:
            'a lock-upgrade deadlock never invokes the busy handler, so a '
            'timeout cannot rescue it — this is why the corrective is the '
            'shared connection, not a timeout',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('NEGATIVE RESULT: WAL does NOT fix the race', () async {
    final dir = await Directory.systemTemp.createTemp('nt_v47_wal');
    try {
      final path = await _seedV46(dir);
      final threw = await _raceThrows(
        path,
        (p) => NativeDatabase(
          File(p),
          setup: (db) {
            db.execute('PRAGMA busy_timeout = 5000');
            db.execute('PRAGMA journal_mode = WAL');
          },
        ),
      );
      expect(
        threw,
        isTrue,
        reason: 'WAL plus a timeout was measured to still lose the race',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'MECHANISM: with ONE connection the migration completes cleanly',
    () async {
      final dir = await Directory.systemTemp.createTemp('nt_v47_single');
      try {
        final path = await _seedV46(dir);
        // The corrective collapses the sites onto a single connection; this is
        // what that connection does when both callers use it.
        final shared = AppDatabase.forTesting(NativeDatabase(File(path)));
        await Future.wait<void>([
          shared.select(shared.localProfiles).get(),
          shared.select(shared.localProfiles).get(),
        ]);
        final version = await shared
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(version.read<int>('user_version'), 49);
        final integrity = await shared
            .customSelect('PRAGMA integrity_check')
            .getSingle();
        expect(integrity.read<String>('integrity_check'), 'ok');
        await shared.close();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
