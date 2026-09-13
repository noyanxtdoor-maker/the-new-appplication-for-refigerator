import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';

import '../../support/test_dependencies.dart';

final class _MutableClock implements AppClock {
  _MutableClock(this._now);

  DateTime _now;

  void advance(Duration by) => _now = _now.add(by);

  @override
  DateTime nowUtc() => _now;
}

final class _SteppingIdentifierSource implements IdentifierSource {
  int _next = 0;

  @override
  String nextUuid() => 'rev-${++_next}';
}

void main() {
  late AppDatabase database;
  late _MutableClock clock;
  late ReminderRecoveryRequest marker;
  late DriftNotificationFoundationRepository repository;
  late String profileId;

  setUp(() async {
    database = openMemoryDatabase();
    clock = _MutableClock(DateTime.utc(2026, 9, 11, 10));
    marker = ReminderRecoveryRequest(
      database: database,
      clock: clock,
      identifiers: _SteppingIdentifierSource(),
    );
    repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
  });

  tearDown(() => database.close());

  Future<BackgroundWorkRequest?> readMarker([String? id]) =>
      repository.readWorkRequest(ReminderRecoveryRequest.stableKeyFor(id ?? profileId));

  Future<int> countMarkers() async {
    // Counted through the durable rows the repository reads, so the assertion
    // is about persisted state rather than a test-only query shape.
    final rows = await database.select(database.backgroundWorkRequests).get();
    return rows
        .where((row) => row.stableKey.startsWith('reconcile:reminders:'))
        .length;
  }

  test('section 27 the marker is one profile-scoped device-global row', () async {
    await marker.mark(database, profileId: profileId);

    final row = await readMarker();
    expect(row, isNotNull);
    expect(
      row!.stableKey,
      'reconcile:reminders:$profileId',
      reason: 'the exact section 27 key shape',
    );
    expect(row.profileId, profileId);
    expect(row.category, BackgroundWorkCategory.reminderRecovery);
    expect(row.ownerKind, BackgroundWorkOwnerKind.profile);
    expect(row.ownerId, profileId);
    expect(row.occurrenceId, isNull);
    expect(row.platformNotificationId, isNull);
    expect(
      row.scheduledForUtc,
      isNull,
      reason: 'a marker is not a notification and carries no target instant',
    );
    expect(row.state, BackgroundWorkState.queued);
    expect(row.attemptCount, 0);
    expect(row.snoozeCount, 0);
  });

  test('the marker carries no private content, only a technical revision', () async {
    await marker.mark(database, profileId: profileId);
    final row = await readMarker();
    expect(row!.sourceRevision, 'rev-1');
    final serialized = <Object?>[
      row.stableKey,
      row.profileId,
      row.ownerId,
      row.occurrenceId,
      row.sourceRevision,
      row.lastFailureCategory,
    ].join('|');
    expect(serialized.contains('@'), isFalse);
    expect(serialized.contains(' '), isFalse);
  });

  test('a repeat mark collapses into ONE pending reconciliation', () async {
    await marker.mark(database, profileId: profileId);
    final first = await readMarker();
    clock.advance(const Duration(minutes: 5));
    await marker.mark(database, profileId: profileId);
    final second = await readMarker();

    expect(await countMarkers(), 1);
    expect(second!.createdAtUtc, first!.createdAtUtc);
    // A mark is a NEW dirty generation: the technical revision must change so an
    // in-flight pass notices that canonical truth moved underneath it and runs
    // exactly one trailing pass.  Collapsing to one ROW (asserted above) is what
    // "one pending reconciliation" means — not freezing the revision, which
    // would make the trailing-pass guard unable to see the newer mutation.
    expect(
      second.sourceRevision,
      isNot(first.sourceRevision),
      reason: 'each mark mints a fresh dirty generation token',
    );
    expect(
      second.updatedAtUtc.isAfter(first.updatedAtUtc),
      isTrue,
      reason: 'the pending flag is refreshed, not duplicated',
    );
  });

  test('a repeat mark never restarts an in-flight repair episode', () async {
    await marker.mark(database, profileId: profileId);
    final key = ReminderRecoveryRequest.stableKeyFor(profileId);
    // Simulate recovery having consumed the marker into a bounded retry.
    await repository.recordAttempt(
      stableKey: key,
      nextState: BackgroundWorkState.retryScheduled,
      failureCategory: 'platform_unavailable',
    );
    clock.advance(const Duration(minutes: 1));
    await marker.mark(database, profileId: profileId);

    final row = await readMarker();
    expect(
      row!.state,
      BackgroundWorkState.retryScheduled,
      reason: 'a new mutation must not erase in-flight repair progress',
    );
    expect(row.attemptCount, 1, reason: 'the budget is preserved, not reset');
    expect(row.lastFailureCategory, 'platform_unavailable');
  });

  test('the marker commits inside the caller transaction, not outside it', () async {
    await expectLater(
      database.transaction(() async {
        await marker.mark(database, profileId: profileId);
        // Roll the whole mutation back: the marker must vanish with it.
        throw StateError('abort');
      }),
      throwsA(isA<StateError>()),
    );
    expect(
      await readMarker(),
      isNull,
      reason: 'a rolled-back mutation never leaves a durable repair intent',
    );
  });
}
