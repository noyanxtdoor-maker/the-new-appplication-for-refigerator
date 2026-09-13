// VS16 M8 — state machine, bounded retry and marker lifecycle (contract
// sections 30/31, scenarios T36-T40).
//
// The law under test:
//  * every durable state is readable, and `scheduled` never means delivered;
//  * retry is bounded to 5 persisted attempts per revision with a 30/60/120/240s
//    minimum backoff and a terminal `retry_exhausted` at attempt 5;
//  * an exception inside a pass must NOT lose the attempt count;
//  * an unavailable database terminates the invocation without inventing an
//    attempt row and without looping forever;
//  * unknown/dormant input is a handled no-op that mutates nothing and is never
//    recorded as delivered.
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_repair_decision.dart';
import 'package:rmplanner/core/background/background_retry_policy.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/reconcile_reminders.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

/// Mutable clock so each retry attempt is provably a distinct instant.
final class _MutableClock implements AppClock {
  _MutableClock(this._value);

  DateTime _value;

  void advance(Duration by) => _value = _value.add(by);

  @override
  DateTime nowUtc() => _value;
}

/// Minimal canonical delivery gateway used by the delivery-service scenarios.
final class _DeliveryGateway implements CanonicalReminderDeliveryGateway {
  final List<LocalNotificationRequest> shown = <LocalNotificationRequest>[];

  @override
  Future<void> showCanonicalReminder(LocalNotificationRequest request) async =>
      shown.add(request);

  @override
  Future<bool> hasDisplayedReminder(int platformId) async => false;

  @override
  Future<bool> hasPendingReminder(int platformId, DateTime atUtc) async => false;
}

/// A source reader that is absent for every occurrence, i.e. the canonical
/// source row no longer exists.
final class _AbsentSource implements ReminderDeliverySourceReader {
  const _AbsentSource();

  @override
  Future<ReminderDeliverySnapshot?> read({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
  }) async => null;
}

/// Records enqueued work so a dormant path can be proven to enqueue nothing.
final class _RecordingBackgroundWorkGateway implements BackgroundWorkGateway {
  _RecordingBackgroundWorkGateway(this.enqueued);

  final List<BackgroundWorkSpec> enqueued;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async =>
      enqueued.add(work);

  @override
  Future<void> cancelUnique(String uniqueName) async {}

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async =>
      BackgroundGatewayWorkState.absent;
}

void main() {
  const profileId = '11111111-1111-4111-8111-111111111111';
  final base = DateTime.utc(2026, 9, 12, 9);

  DriftNotificationFoundationRepository repositoryFor(
    AppDatabase database,
    AppClock clock,
  ) => DriftNotificationFoundationRepository(
    database: database,
    clock: clock,
  );

  ReminderRecoveryRequest markerFor(AppDatabase database, AppClock clock) =>
      ReminderRecoveryRequest(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );

  group('T36 required state machine', () {
    test('T36 every declared durable state round-trips through storage', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = repositoryFor(database, FixedClock(base));

      // The compatibility states stay READABLE.  Assigning one is a separate,
      // evidence-bound decision; this proves storage does not invent or drop
      // any of the declared states.
      for (final state in BackgroundWorkState.values) {
        final key = 'foundation:state:${state.name}';
        await repository.upsertWorkRequest(
          BackgroundWorkRequest(
            stableKey: key,
            profileId: profileId,
            category: BackgroundWorkCategory.notificationFoundation,
            ownerKind: BackgroundWorkOwnerKind.profile,
            ownerId: profileId,
            state: state,
            attemptCount: 0,
            snoozeCount: 0,
            createdAtUtc: base,
            updatedAtUtc: base,
          ),
        );
        expect((await repository.readWorkRequest(key))?.state, state);
      }
      expect(BackgroundWorkState.values, hasLength(9));
    });

    test('T36 the retry law never assigns a reserved compatibility state',
        () async {
      // The bounded retry law assigns only retryScheduled / failedActionRequired.
      // waitingForConstraints and delayedBySystem require ACTUAL platform
      // evidence, so no path here may produce them.
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = markerFor(database, clock);
      await marker.mark(database, profileId: profileId);
      final token = (await marker.claimRunning(database, profileId: profileId))!;

      for (var attempt = 0; attempt < 5; attempt++) {
        await marker.recordRepairFailure(
          database,
          profileId: profileId,
          capturedToken: token,
          failureCategory: 'platform_unavailable',
        );
        final row = await marker.read(database, profileId: profileId);
        expect(
          row!.state,
          isNot(BackgroundWorkState.waitingForConstraints),
          reason: 'constraint waiting requires real platform evidence',
        );
        expect(
          row.state,
          isNot(BackgroundWorkState.delayedBySystem),
          reason: 'OS delay requires real platform evidence',
        );
      }
    });

    test('T36 queued is never counted delivered and scheduled is not delivered',
        () {
      // `delivered` is deliberately not a state: completion is the only durable
      // evidence of a post, and it is written only after a confirmed show.
      expect(
        BackgroundWorkState.values.map((state) => state.name),
        isNot(contains('delivered')),
      );
      expect(
        ReminderRecoveryRequest.isLiveEpisode(BackgroundWorkState.queued),
        isTrue,
      );
      expect(
        ReminderRecoveryRequest.isLiveEpisode(BackgroundWorkState.scheduled),
        isFalse,
        reason: 'a scheduled native alarm is a registration, not a repair',
      );
      expect(
        ReminderDeliveryOutcome.values,
        contains(ReminderDeliveryOutcome.posted),
        reason: 'only a confirmed show produces the posted outcome',
      );
    });

    test('T36 a completed reminder row never implies source completion', () async {
      // The durable reminder lifecycle is a notification fact.  Completing the
      // reminder must leave the canonical source untouched.
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final planner = DriftPlannerRepository(
        database: database,
        clock: FixedClock(base),
      );
      await planner.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'task-1',
          title: 'Task 1',
          dueDate: PlannerDate(year: 2026, month: 9, day: 12),
          dueMinute: 9 * 60,
          requiresReport: true,
        ),
      );
      await repositoryFor(database, FixedClock(base)).upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: 'reminder:task:${profile.id}:task:task-1:2026-09-12:base',
          profileId: profile.id,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.task,
          ownerId: 'task-1',
          occurrenceId: 'task:task-1:2026-09-12',
          state: BackgroundWorkState.completed,
          attemptCount: 1,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );

      final task = await planner.readTask(
        profileId: profile.id,
        taskId: 'task-1',
      );
      expect(
        task!.status,
        PlannerTaskStatus.incomplete,
        reason: 'completing a REMINDER must never complete the Task',
      );
    });
  });

  group('T37 bounded retry law', () {
    test('T37 attempts 1-4 use 30/60/120/240s minimum backoff', () {
      expect(
        <int>[1, 2, 3, 4].map(BackgroundRetryPolicy.minimumBackoffFor),
        <Duration>[
          const Duration(seconds: 30),
          const Duration(seconds: 60),
          const Duration(seconds: 120),
          const Duration(seconds: 240),
        ],
      );
      expect(BackgroundRetryPolicy.maxAttemptsPerRevision, 5);
    });

    test('T37 attempt 5 is terminal retry_exhausted with no eligibility window',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = markerFor(database, clock);
      await marker.mark(database, profileId: profileId);
      final token = (await marker.claimRunning(database, profileId: profileId))!;

      final states = <BackgroundWorkState>[];
      final nextEligible = <DateTime?>[];
      for (var attempt = 0; attempt < 5; attempt++) {
        clock.advance(const Duration(minutes: 1));
        await marker.recordRepairFailure(
          database,
          profileId: profileId,
          capturedToken: token,
          failureCategory: 'platform_unavailable',
        );
        final row = await marker.read(database, profileId: profileId);
        states.add(row!.state);
        nextEligible.add(row.nextEligibleAtUtc);
        if (attempt < 4) {
          expect(row.attemptCount, attempt + 1);
          expect(row.lastFailureCategory, 'platform_unavailable');
          // Drift returns the persisted instant in the local zone, so compare
          // the INSTANT rather than the DateTime's isUtc flag.
          expect(
            row.nextEligibleAtUtc!.toUtc(),
            clock.nowUtc().add(
              BackgroundRetryPolicy.minimumBackoffFor(attempt + 1),
            ),
          );
        }
      }

      expect(states.take(4), everyElement(BackgroundWorkState.retryScheduled));
      expect(states.last, BackgroundWorkState.failedActionRequired);
      expect(nextEligible.last, isNull);
      final exhausted = await marker.read(database, profileId: profileId);
      expect(exhausted!.attemptCount, 5);
      expect(exhausted.lastFailureCategory, 'retry_exhausted');
    });

    test('T37 per-attempt timestamps come from actual attempts', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = markerFor(database, clock);
      await marker.mark(database, profileId: profileId);
      final token = (await marker.claimRunning(database, profileId: profileId))!;

      final observed = <DateTime>[];
      for (var attempt = 0; attempt < 3; attempt++) {
        clock.advance(const Duration(seconds: 45));
        await marker.recordRepairFailure(
          database,
          profileId: profileId,
          capturedToken: token,
          failureCategory: 'db_busy',
        );
        observed.add(
          (await marker.read(
            database,
            profileId: profileId,
          ))!.lastAttemptAtUtc!.toUtc(),
        );
      }
      expect(observed, <DateTime>[
        base.add(const Duration(seconds: 45)),
        base.add(const Duration(seconds: 90)),
        base.add(const Duration(seconds: 135)),
      ]);
    });

    test('T37 only allow-listed technical categories are storable', () {
      const allowed = <String>{
        'db_busy',
        'platform_unavailable',
        'platform_schedule_failed',
        'invalid_identity',
        'invalid_source',
        'stale_source',
        'permission_disabled',
        'source_unavailable',
        'retry_exhausted',
        'delivery_uncertain',
        'runtime_unavailable',
      };
      for (final category in allowed) {
        expect(
          BackgroundWorkRequest(
            stableKey: 'reminder:task:p:o:base',
            category: BackgroundWorkCategory.reminderRecovery,
            ownerKind: BackgroundWorkOwnerKind.task,
            state: BackgroundWorkState.failedActionRequired,
            attemptCount: 5,
            snoozeCount: 0,
            lastFailureCategory: category,
            createdAtUtc: base,
            updatedAtUtc: base,
          ).validate,
          returnsNormally,
        );
      }
      // Raw exception text and private content are rejected by the sanitizer.
      for (final rejected in <String>[
        'StateError: boom',
        'Exception: Visit Private Place',
        'Visit Private Place tomorrow',
      ]) {
        expect(
          () => BackgroundWorkRequest(
            stableKey: 'reminder:task:p:o:base',
            category: BackgroundWorkCategory.reminderRecovery,
            ownerKind: BackgroundWorkOwnerKind.task,
            state: BackgroundWorkState.failedActionRequired,
            attemptCount: 5,
            snoozeCount: 0,
            lastFailureCategory: rejected,
            createdAtUtc: base,
            updatedAtUtc: base,
          ).validate(),
          throwsArgumentError,
        );
      }
    });
  });

  group('T38 exception does not lose the attempt count', () {
    test('T38 a pass that throws still records exactly one attempt', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = markerFor(database, clock);
      await marker.mark(database, profileId: profileId);

      var passes = 0;
      final reconcile = ReconcileReminders(
        reconcileEvents: () async {
          passes++;
          throw StateError('Injected mid-pass failure');
        },
        reconcileTasks: () async {},
        claimRepair: () => marker.claimRunning(database, profileId: profileId),
        completeRepair: (token) => marker.completeIfUnchanged(
          database,
          profileId: profileId,
          capturedToken: token,
        ),
        failRepair: (token, category) => marker.recordRepairFailure(
          database,
          profileId: profileId,
          capturedToken: token,
          failureCategory: category,
        ),
      );

      await expectLater(reconcile(), throwsA(isA<StateError>()));

      final row = await marker.read(database, profileId: profileId);
      expect(passes, 1);
      expect(
        row!.attemptCount,
        1,
        reason: 'the failed attempt must be committed OUTSIDE the pass',
      );
      expect(row.state, BackgroundWorkState.retryScheduled);
      expect(
        row.lastFailureCategory,
        ReconcileReminders.unavailableFailureCategory,
      );
      expect(row.completedAtUtc, isNull);
    });

    test('T38 repeated failures accumulate the count instead of resetting it',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = markerFor(database, clock);
      await marker.mark(database, profileId: profileId);

      Future<void> failingPass() => ReconcileReminders(
        reconcileEvents: () async => throw StateError('boom'),
        reconcileTasks: () async {},
        claimRepair: () => marker.claimRunning(database, profileId: profileId),
        completeRepair: (token) => marker.completeIfUnchanged(
          database,
          profileId: profileId,
          capturedToken: token,
        ),
        failRepair: (token, category) => marker.recordRepairFailure(
          database,
          profileId: profileId,
          capturedToken: token,
          failureCategory: category,
        ),
      )();

      for (var attempt = 1; attempt <= 5; attempt++) {
        clock.advance(const Duration(minutes: 1));
        await expectLater(failingPass(), throwsA(isA<StateError>()));
        final row = await marker.read(database, profileId: profileId);
        expect(row!.attemptCount, attempt);
      }
      final terminal = await marker.read(database, profileId: profileId);
      expect(terminal!.state, BackgroundWorkState.failedActionRequired);
      expect(terminal.lastFailureCategory, 'retry_exhausted');
    });
  });

  group('T39 database unavailable terminates truthfully', () {
    test('T39 an unrecordable failure neither invents a row nor loops forever',
        () async {
      var passes = 0;
      var failureRecords = 0;
      final reconcile = ReconcileReminders(
        reconcileEvents: () async {
          passes++;
          throw StateError('original failure');
        },
        reconcileTasks: () async {},
        claimRepair: () async => 'revision@1',
        completeRepair: (token) async => true,
        failRepair: (token, category) async {
          failureRecords++;
          // The database cannot be written: no attempt row exists and the
          // invocation must terminate rather than spin.
          throw StateError('database unavailable');
        },
      );

      await expectLater(
        reconcile(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'original failure',
          ),
        ),
        reason:
            'a bookkeeping failure must never mask the real failure that '
            'caused it',
      );
      expect(passes, 1, reason: 'no infinite retry loop');
      expect(failureRecords, 1, reason: 'recorded once, then terminated');
    });

    test('T39 a later real trigger re-initializes successfully', () async {
      var attempts = 0;
      var databaseHealthy = false;
      final reconcile = ReconcileReminders(
        reconcileEvents: () async {
          attempts++;
          if (!databaseHealthy) throw StateError('database unavailable');
        },
        reconcileTasks: () async {},
        claimRepair: () async => databaseHealthy ? null : 'revision@1',
        completeRepair: (token) async => true,
        failRepair: (token, category) async {
          if (!databaseHealthy) throw StateError('database unavailable');
        },
      );

      await expectLater(reconcile(), throwsA(isA<StateError>()));
      expect(attempts, 1);

      // The real startup/resume/recovery trigger arrives once storage is usable.
      databaseHealthy = true;
      await reconcile();
      expect(attempts, 2);
    });
  });

  group('T40 unknown and dormant input is a handled no-op', () {
    test('T40 an unknown durable key is obsolete and mutates nothing', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final gateway = _DeliveryGateway();
      final service = ReminderDeliveryService(
        repository: repositoryFor(database, FixedClock(base)),
        gateway: gateway,
        source: const _AbsentSource(),
        clock: FixedClock(base),
      );
      const key = 'reminder:task:p:task:missing:2026-09-12:base';

      expect(
        await service.deliver(
          stableKey: key,
          scheduledUtcMs: base.millisecondsSinceEpoch,
          sourceRevision: 'm7w_task_generic',
        ),
        ReminderDeliveryOutcome.handledObsolete,
      );
      expect(gateway.shown, isEmpty);
      expect(
        await repositoryFor(database, FixedClock(base)).readWorkRequest(key),
        isNull,
        reason: 'no row may be invented for an unknown key',
      );
    });

    test('T40 a vanished Task source is suppressed, never recorded delivered',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = repositoryFor(database, FixedClock(base));
      final gateway = _DeliveryGateway();
      const key = 'reminder:task:p:task:gone:2026-09-12:base';
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: key,
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.task,
          ownerId: 'gone',
          occurrenceId: 'task:gone:2026-09-12',
          sourceRevision: 'm7w_task_generic',
          scheduledForUtc: base,
          state: BackgroundWorkState.scheduled,
          platformNotificationId: 900,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );
      final service = ReminderDeliveryService(
        repository: repository,
        gateway: gateway,
        source: const _AbsentSource(),
        clock: FixedClock(base),
      );

      expect(
        await service.deliver(
          stableKey: key,
          scheduledUtcMs: base.millisecondsSinceEpoch,
          sourceRevision: 'm7w_task_generic',
        ),
        ReminderDeliveryOutcome.suppressed,
      );
      final row = await repository.readWorkRequest(key);
      expect(row!.state, BackgroundWorkState.cancelledObsolete);
      expect(row.lastFailureCategory, 'stale_source');
      expect(
        row.completedAtUtc,
        isNull,
        reason: 'suppression is never a delivery receipt',
      );
      expect(gateway.shown, isEmpty);
    });

    test('T40 dormant Snooze is handled true with zero work and zero mutation',
        () async {
      final enqueued = <BackgroundWorkSpec>[];
      final handled = await enqueueReminderSnooze(
        snooze: const NotificationResponseIntent(
          profileId: profileId,
          sourceKind: NotificationSourceKind.task,
          sourceId: 'task-1',
          occurrenceId: 'task:task-1:2026-09-12',
          action: NotificationResponseAction.snooze,
          generation: 3,
        ),
        actionAtUtc: base,
        applySnooze: (_, _) async {
          throw StateError('dormant Snooze must never execute');
        },
        backgroundWork: _RecordingBackgroundWorkGateway(enqueued),
      );

      expect(handled, isTrue, reason: 'a handled no-op stops OS retry');
      expect(enqueued, isEmpty, reason: 'no deferred work may be enqueued');

      // The runtime entry point is terminal for the same reason and must not
      // even open a database.
      expect(
        await runReminderRuntime(
          snooze: const NotificationResponseIntent(
            profileId: profileId,
            sourceKind: NotificationSourceKind.task,
            sourceId: 'task-1',
            action: NotificationResponseAction.snooze,
          ),
          actionAtUtc: base,
        ),
        isTrue,
      );
    });

    test('T40 malformed dispatch input is obsolete before any read', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final gateway = _DeliveryGateway();
      final service = ReminderDeliveryService(
        repository: repositoryFor(database, FixedClock(base)),
        gateway: gateway,
        source: const _AbsentSource(),
        clock: FixedClock(base),
      );

      for (final invalid in <(String, int, String)>[
        ('not-a-reminder-key', 0, 'm7w_1'),
        ('reminder:task:p:o:base', -1, 'm7w_1'),
        ('reminder:task:p:o:base', 0, 'private content here'),
      ]) {
        expect(
          await service.deliver(
            stableKey: invalid.$1,
            scheduledUtcMs: invalid.$2,
            sourceRevision: invalid.$3,
          ),
          ReminderDeliveryOutcome.handledObsolete,
        );
      }
      expect(gateway.shown, isEmpty);
    });
  });

  group('T36 pure repair matrix is total and evidence-bound', () {
    test('T36 durable terminal truth always outranks platform state', () {
      for (final platform in BackgroundRegistrationState.values) {
        expect(
          BackgroundRepairDecision.decide(
            durable: BackgroundDurableEligibility.terminal,
            platform: platform,
            sameGeneration: true,
          ),
          BackgroundRepairAction.none,
        );
      }
    });

    test('T36 an unreadable platform never produces a registration change', () {
      for (final durable in BackgroundDurableEligibility.values) {
        if (durable == BackgroundDurableEligibility.terminal) continue;
        expect(
          BackgroundRepairDecision.decide(
            durable: durable,
            platform: BackgroundRegistrationState.unavailable,
            sameGeneration: true,
          ),
          BackgroundRepairAction.unavailable,
        );
      }
    });

    test('T36 the matrix is total — every combination yields one action', () {
      for (final durable in BackgroundDurableEligibility.values) {
        for (final platform in BackgroundRegistrationState.values) {
          for (final sameGeneration in <bool>[true, false]) {
            expect(
              () => BackgroundRepairDecision.decide(
                durable: durable,
                platform: platform,
                sameGeneration: sameGeneration,
              ),
              returnsNormally,
            );
          }
        }
      }
    });
  });
}
