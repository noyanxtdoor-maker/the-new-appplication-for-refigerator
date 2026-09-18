// VS16 M8 — work state machine, bounded retry, marker lifecycle and reserved
// platform ID (Appendix T, T-D). Fail-first targets: reserved-ID skip and the
// planning family filter.
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart'
    hide NotificationPreferences;
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/data/drift_reminder_enrichment_source.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

import '../../../support/test_dependencies.dart';

void main() {
  group('M8 work state machine', () {
    late AppDatabase database;
    late DriftNotificationFoundationRepository repository;
    late FixedClock clock;
    late String profileId;

    setUp(() async {
      database = openMemoryDatabase();
      addTearDown(database.close);
      clock = FixedClock(DateTime.utc(2026, 9, 10, 9));
      repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
    });

    BackgroundWorkRequest baseWork({
      String key = 'reminder:calendarEvent:p:o:base',
      BackgroundWorkState state = BackgroundWorkState.queued,
    }) => BackgroundWorkRequest(
      stableKey: key,
      profileId: profileId,
      category: BackgroundWorkCategory.reminderRecovery,
      ownerKind: BackgroundWorkOwnerKind.occurrence,
      ownerId: 'event-1',
      occurrenceId: 'o',
      sourceRevision: 'rev.m7n_',
      scheduledForUtc: DateTime.utc(2026, 9, 10, 11),
      state: state,
      attemptCount: 0,
      snoozeCount: 0,
      createdAtUtc: clock.nowUtc(),
      updatedAtUtc: clock.nowUtc(),
    );

    test(
      'T36 queued is never counted delivered and transitions are explicit',
      () async {
        await repository.upsertWorkRequest(baseWork());
        await repository.recordAttempt(
          stableKey: 'reminder:calendarEvent:p:o:base',
          nextState: BackgroundWorkState.running,
        );
        var work = await repository.readWorkRequest(
          'reminder:calendarEvent:p:o:base',
        );
        expect(work!.state, BackgroundWorkState.running);
        expect(work.attemptCount, 1);
        expect(work.completedAtUtc, isNull);
        await repository.recordAttempt(
          stableKey: 'reminder:calendarEvent:p:o:base',
          nextState: BackgroundWorkState.completed,
        );
        work = await repository.readWorkRequest(
          'reminder:calendarEvent:p:o:base',
        );
        expect(work!.state, BackgroundWorkState.completed);
        // Compatibility states remain readable.
        await repository.upsertWorkRequest(
          baseWork(
            key: 'reminder:calendarEvent:p:o2:base',
          ).copyWith(state: BackgroundWorkState.delayedBySystem),
        );
        final compatibility = await repository.readWorkRequest(
          'reminder:calendarEvent:p:o2:base',
        );
        expect(compatibility!.state, BackgroundWorkState.delayedBySystem);
        // A completed work row never implies source completion.
        final marker = await repository.readWorkRequest(
          ReminderRecoveryRequest.stableKeyFor(profileId),
        );
        expect(marker, isNull);
      },
    );

    test(
      'T45 reserved badge ID is skipped and existing row relocated',
      () async {
        final seeded = DriftNotificationFoundationRepository(
          database: database,
          clock: clock,
          platformIdSeed: (_) => 0x7ffffffe,
        );
        await repository.upsertWorkRequest(baseWork());
        final allocated = await seeded.allocatePlatformNotificationId(
          'reminder:calendarEvent:p:o:base',
        );
        expect(allocated, isNot(0x7ffffffe));
        expect(allocated, 1);
        // A legitimate row occupying the badge slot is relocated.
        await repository.upsertWorkRequest(
          baseWork(
            key: 'reminder:calendarEvent:p:o3:base',
          ).copyWith(platformNotificationId: 0x7ffffffe),
        );
        final relocated = await repository.allocatePlatformNotificationId(
          'reminder:calendarEvent:p:o3:base',
        );
        expect(relocated, isNot(0x7ffffffe));
        final row = await repository.readWorkRequest(
          'reminder:calendarEvent:p:o3:base',
        );
        expect(row!.platformNotificationId, relocated);
      },
    );

    test('T41 planning family filter keeps families isolated (F03)', () async {
      final weekly = BackgroundWorkRequest(
        stableKey: 'planning:weekly-review:p:shared-token',
        profileId: profileId,
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.planning,
        ownerId: 'plan-1',
        occurrenceId: 'shared-token',
        sourceRevision: 'rev.m7n_',
        scheduledForUtc: DateTime.utc(2026, 9, 10, 11),
        state: BackgroundWorkState.scheduled,
        attemptCount: 0,
        snoozeCount: 0,
        createdAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      );
      final awaiting = BackgroundWorkRequest(
        stableKey: 'planning:awaiting-report:p:shared-token',
        profileId: profileId,
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.planning,
        ownerId: 'event-1',
        occurrenceId: 'shared-token',
        sourceRevision: 'rev.m7n_',
        scheduledForUtc: DateTime.utc(2026, 9, 10, 11),
        state: BackgroundWorkState.scheduled,
        attemptCount: 0,
        snoozeCount: 0,
        createdAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      );
      await repository.upsertWorkRequest(weekly);
      await repository.upsertWorkRequest(awaiting);
      final weeklyRows = await repository.readReminderWork(
        profileId: profileId,
        sourceKind: ReminderSourceKind.weeklyReview,
        windowStartUtc: DateTime.utc(2000),
        windowEndUtc: DateTime.utc(2030),
      );
      final awaitingRows = await repository.readReminderWork(
        profileId: profileId,
        sourceKind: ReminderSourceKind.awaitingReport,
        windowStartUtc: DateTime.utc(2000),
        windowEndUtc: DateTime.utc(2030),
      );
      expect(weeklyRows.map((row) => row.stableKey), <String>[
        'planning:weekly-review:p:shared-token',
      ]);
      expect(awaitingRows.map((row) => row.stableKey), <String>[
        'planning:awaiting-report:p:shared-token',
      ]);
    });

    test('T42 marker lifecycle never completes a newer revision', () async {
      final key = ReminderRecoveryRequest.stableKeyFor(profileId);
      await ReminderRecoveryRequest.markDirty(
        database: database,
        profileId: profileId,
        nowUtc: clock.nowUtc(),
      );
      final owned = await ReminderRecoveryRequest.markRunning(
        database: database,
        profileId: profileId,
        nowUtc: clock.nowUtc(),
      );
      expect(owned, isTrue);
      // A mutation during the pass re-queues a newer episode.
      await ReminderRecoveryRequest.markDirty(
        database: database,
        profileId: profileId,
        nowUtc: clock.nowUtc(),
      );
      await ReminderRecoveryRequest.markCompleted(
        database: database,
        profileId: profileId,
        nowUtc: clock.nowUtc(),
      );
      final marker = await repository.readWorkRequest(key);
      expect(marker!.state, BackgroundWorkState.queued);
      final second = await ReminderRecoveryRequest.markRunning(
        database: database,
        profileId: profileId,
        nowUtc: clock.nowUtc(),
      );
      expect(second, isTrue);
      await ReminderRecoveryRequest.markCompleted(
        database: database,
        profileId: profileId,
        nowUtc: clock.nowUtc(),
      );
      final completed = await repository.readWorkRequest(key);
      expect(completed!.state, BackgroundWorkState.completed);
      expect(completed.completedAtUtc, isNotNull);
    });
  });

  group('M8 bounded retry', () {
    late _RetryHarness h;

    setUp(() async {
      h = await _RetryHarness.create();
    });

    test(
      'T37/T38 attempts 1-4 back off 30/60/120/240s, attempt 5 terminal',
      () async {
        const expectedBackoff = <int>[30, 60, 120, 240];
        for (var attempt = 0; attempt < 4; attempt++) {
          h.repository.failPreferences = true;
          final outcome = await h.service.deliver(
            stableKey: h.stableKey,
            scheduledAtUtc: h.target,
            sourceRevision: 'src1.m7w_',
          );
          expect(outcome, ReminderDeliveryOutcome.retryScheduled);
          h.repository.failPreferences = false;
          final work = await h.repository.readWorkRequest(h.stableKey);
          expect(work!.state, BackgroundWorkState.retryScheduled);
          expect(work.attemptCount, attempt + 1);
          expect(work.lastFailureCategory, 'db_busy');
          expect(
            work.nextEligibleAtUtc!.difference(h.clock.nowUtc()).inSeconds,
            expectedBackoff[attempt],
          );
        }
        h.repository.failPreferences = true;
        final terminal = await h.service.deliver(
          stableKey: h.stableKey,
          scheduledAtUtc: h.target,
          sourceRevision: 'src1.m7w_',
        );
        expect(terminal, ReminderDeliveryOutcome.terminalFailed);
        final work = await h.repository.readWorkRequest(h.stableKey);
        expect(work!.state, BackgroundWorkState.failedActionRequired);
        expect(work.lastFailureCategory, 'retry_exhausted');
      },
    );

    test('T40 dormant Snooze runtime is a handled no-op', () async {
      final handled = await runReminderRuntime(
        snooze: const NotificationResponseIntent(
          profileId: 'profile',
          sourceKind: NotificationSourceKind.task,
          sourceId: 'task',
          occurrenceId: 'occurrence',
          action: NotificationResponseAction.snooze,
        ),
        actionAtUtc: DateTime.utc(2026, 9, 10),
      );
      expect(handled, isTrue);
    });
  });
}

final class _RetryHarness {
  _RetryHarness._({
    required this.database,
    required this.repository,
    required this.clock,
    required this.profileId,
    required this.target,
  });

  final AppDatabase database;
  final _FlakyRepository repository;
  final FixedClock clock;
  final String profileId;
  final DateTime target;

  static Future<_RetryHarness> create() async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final clock = FixedClock(DateTime.utc(2026, 9, 10, 9));
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    final inner = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    await inner.savePreferences(
      profileId: profile.id,
      preferences: const NotificationPreferences.defaults().copyWith(
        systemNotificationsEnabled: true,
        eventRemindersEnabled: true,
      ),
    );
    final repository = _FlakyRepository(inner);
    final target = DateTime.utc(2026, 9, 10, 11);
    final harness = _RetryHarness._(
      database: database,
      repository: repository,
      clock: clock,
      profileId: profile.id,
      target: target,
    );
    await inner.upsertPolicy(
      ReminderPolicy(
        id: 'policy-1',
        profileId: profile.id,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-1',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 60,
        createdAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      ),
    );
    await inner.upsertWorkRequest(
      BackgroundWorkRequest(
        stableKey: harness.stableKey,
        profileId: profile.id,
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        ownerId: 'event-1',
        occurrenceId: 'occurrence-1',
        sourceRevision: 'src1.m7w_',
        scheduledForUtc: target,
        state: BackgroundWorkState.scheduled,
        platformNotificationId: 42,
        attemptCount: 0,
        snoozeCount: 0,
        createdAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      ),
    );
    return harness;
  }

  String get stableKey => ReminderReconciler.stableKey(
    sourceKind: ReminderSourceKind.calendarEvent,
    profileId: profileId,
    occurrenceId: 'occurrence-1',
  );

  ReminderDeliveryService get service {
    final start = DateTime.utc(2026, 9, 10, 12);
    final end = start.add(const Duration(hours: 1));
    return ReminderDeliveryService(
      repository: repository,
      deliveryGateway: _NoopDelivery(),
      notificationGateway: _NoopDelivery(),
      events: _OneOccurrence(
        CalendarEventOccurrence(
          id: 'occurrence-1',
          eventId: 'event-1',
          profileId: profileId,
          title: 'Event',
          timing: CalendarEventTiming.timed,
          originalDate: PlannerDate(year: 2026, month: 9, day: 10),
          displayDate: PlannerDate(year: 2026, month: 9, day: 10),
          status: CalendarEventStatus.scheduled,
          requiresReport: false,
          recurrence: const CalendarRecurrenceRule(
            frequency: CalendarRecurrenceFrequency.none,
          ),
          startUtc: start,
          endUtc: end,
          startDisplay: start.toLocal(),
          endDisplay: end.toLocal(),
        ),
      ),
      tasks: _NoopPlanner(),
      eventTypes: DriftEventTypeRepository(database: database, clock: clock),
      privacy: DriftPrivacyRepository(database: database, clock: clock),
      permission: FakePermissionGateway(
        states: const <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.notifications:
              OperatingSystemPermissionState.granted,
        },
      ),
      enrichmentSource: DriftReminderEnrichmentSource(database: database),
      clock: clock,
    );
  }
}

final class _FlakyRepository implements NotificationFoundationRepository {
  _FlakyRepository(this._inner);

  final DriftNotificationFoundationRepository _inner;
  bool failPreferences = false;

  @override
  Future<NotificationPreferences> readPreferences({required String profileId}) {
    if (failPreferences) throw StateError('db_busy');
    return _inner.readPreferences(profileId: profileId);
  }

  @override
  Future<NotificationPreferences> savePreferences({
    required String profileId,
    required NotificationPreferences preferences,
  }) => _inner.savePreferences(profileId: profileId, preferences: preferences);

  @override
  Future<List<ReminderPolicy>> readPolicies({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
  }) => _inner.readPolicies(
    profileId: profileId,
    sourceKind: sourceKind,
    sourceId: sourceId,
  );

  @override
  Future<ReminderPolicy> upsertPolicy(ReminderPolicy policy) =>
      _inner.upsertPolicy(policy);

  @override
  Future<void> deletePolicy({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
  }) => _inner.deletePolicy(
    profileId: profileId,
    sourceKind: sourceKind,
    sourceId: sourceId,
    occurrenceId: occurrenceId,
  );

  @override
  Future<BackgroundWorkRequest?> readWorkRequest(String stableKey) =>
      _inner.readWorkRequest(stableKey);

  @override
  Future<BackgroundWorkRequest?> readWorkRequestByPlatformId(int platformId) =>
      _inner.readWorkRequestByPlatformId(platformId);

  @override
  Future<List<BackgroundWorkRequest>> readActiveReminderWork({
    required String profileId,
    ReminderSourceKind? sourceKind,
  }) => _inner.readActiveReminderWork(
    profileId: profileId,
    sourceKind: sourceKind,
  );

  @override
  Future<List<BackgroundWorkRequest>> readReminderWork({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    String? sourceId,
  }) => _inner.readReminderWork(
    profileId: profileId,
    sourceKind: sourceKind,
    windowStartUtc: windowStartUtc,
    windowEndUtc: windowEndUtc,
    sourceId: sourceId,
  );

  @override
  Future<BackgroundWorkRequest> upsertWorkRequest(
    BackgroundWorkRequest request,
  ) => _inner.upsertWorkRequest(request);

  @override
  Future<void> recordAttempt({
    required String stableKey,
    required BackgroundWorkState nextState,
    String? failureCategory,
    DateTime? nextEligibleAtUtc,
  }) => _inner.recordAttempt(
    stableKey: stableKey,
    nextState: nextState,
    failureCategory: failureCategory,
    nextEligibleAtUtc: nextEligibleAtUtc,
  );

  @override
  Future<void> recordClaim({required String stableKey}) =>
      _inner.recordClaim(stableKey: stableKey);

  @override
  Future<void> recordSnooze({
    required String stableKey,
    required DateTime untilUtc,
  }) => _inner.recordSnooze(stableKey: stableKey, untilUtc: untilUtc);

  @override
  Future<int> allocatePlatformNotificationId(String stableKey) =>
      _inner.allocatePlatformNotificationId(stableKey);

  @override
  Future<int> countPendingWork({required String profileId}) =>
      _inner.countPendingWork(profileId: profileId);

  @override
  Future<bool> beginReminderRepair({required String profileId}) =>
      _inner.beginReminderRepair(profileId: profileId);

  @override
  Future<void> completeReminderRepair({required String profileId}) =>
      _inner.completeReminderRepair(profileId: profileId);
}

final class _NoopDelivery
    implements NotificationGateway, CanonicalReminderDeliveryGateway {
  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {}

  @override
  Future<void> cancel(int platformId) async {}

  @override
  Future<List<PendingLocalNotification>> pending() async =>
      const <PendingLocalNotification>[];

  @override
  NotificationResponseIntent? takeInitialResponse() => null;

  @override
  Future<bool> hasPendingReminder(
    int platformId,
    DateTime scheduledAtUtc,
  ) async => false;

  @override
  Future<bool> hasDisplayedReminder(int platformId) async => false;

  @override
  Future<void> showCanonicalReminder(LocalNotificationRequest request) async {}
}

final class _OneOccurrence implements CalendarEventOccurrenceIdLookup {
  _OneOccurrence(this.occurrence);

  final CalendarEventOccurrence occurrence;

  @override
  Future<CalendarEventOccurrence?> readOccurrenceById({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  }) async => occurrence;
}

final class _NoopPlanner implements PlannerRepository {
  @override
  Future<PlannerTask?> readTask({
    required String profileId,
    required String taskId,
  }) async => null;

  @override
  Future<PlannerDay> readDay({
    required String profileId,
    required PlannerDate selectedDate,
    required PlannerDate today,
  }) async => throw UnimplementedError();

  @override
  Future<PlannerTask> saveTask({
    required String profileId,
    required PlannerTaskDraft draft,
    bool confirmLinkedTypeTransfer = false,
  }) async => throw UnimplementedError();

  @override
  Future<TaskStatusChangeOutcome> changeTaskStatus({
    required String profileId,
    required String taskId,
    required PlannerTaskStatus target,
    required String operationId,
    String? reason,
    bool confirmLinkedTypeTransfer = false,
  }) async => throw UnimplementedError();

  @override
  Future<TaskHardDeleteOutcome> hardDeleteTask({
    required String profileId,
    required String taskId,
  }) async => TaskHardDeleteOutcome.notFound;
}
