// VS16 M8 — privacy-safe background diagnostics (contract sections 38/39,
// scenarios T68-T70).
//
// The law under test:
//  * the snapshot is TYPED technical state only — enums, counts, booleans and
//    UTC timestamps — and its text projection contains no owner content and no
//    identifier of any kind;
//  * producing a snapshot is a READ-ONLY operation: no reconciliation, no
//    enqueue, no permission request and no export;
//  * missing platform data is reported as a factual "Unavailable" or
//    "Not recorded" distinction instead of an invented zero.
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_repair_decision.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/background_diagnostic_rows.dart';
import 'package:rmplanner/features/notifications/application/background_diagnostics_provider.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

/// Every owner-visible sentinel that must NEVER reach the snapshot.
const List<String> _sentinels = <String>[
  'Willow',
  'Cara',
  'Willowbank Clinic',
  '3 Observatory Lane',
  'private note about the appointment',
  'the reflection I wrote',
  '121.7740',
  '14.5995',
];

final class _RecordingBackgroundWork implements BackgroundWorkGateway {
  int enqueues = 0;
  int cancels = 0;
  int inspects = 0;
  BackgroundGatewayWorkState inspectResult = BackgroundGatewayWorkState.absent;
  Object? inspectFailure;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async => enqueues++;

  @override
  Future<void> cancelUnique(String uniqueName) async => cancels++;

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async {
    inspects++;
    final failure = inspectFailure;
    if (failure != null) throw failure;
    return inspectResult;
  }
}

final class _RecordingNotificationGateway implements NotificationGateway {
  int schedules = 0;
  int cancels = 0;
  int pendingReads = 0;
  List<PendingLocalNotification> pendingItems = const <PendingLocalNotification>[];
  Object? pendingFailure;

  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async => schedules++;

  @override
  Future<void> cancel(int platformId) async => cancels++;

  @override
  Future<List<PendingLocalNotification>> pending() async {
    pendingReads++;
    final failure = pendingFailure;
    if (failure != null) throw failure;
    return pendingItems;
  }

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

void main() {
  const profileId = '11111111-1111-4111-8111-111111111111';
  final now = DateTime.utc(2026, 9, 12, 9);

  BackgroundDiagnostics diagnosticsFor({
    required DriftNotificationFoundationRepository repository,
    required NotificationGateway gateway,
    required BackgroundWorkGateway backgroundWork,
    bool notificationsInstalled = true,
    bool backgroundInstalled = true,
    AppClock? clock,
  }) => BackgroundDiagnostics(
    repository: repository,
    gateway: gateway,
    backgroundWork: backgroundWork,
    clock: clock ?? FixedClock(now),
    notificationsAdapterInstalled: notificationsInstalled,
    backgroundAdapterInstalled: backgroundInstalled,
    reservedPlatformId:
        DriftNotificationFoundationRepository.reservedPlatformNotificationId,
  );

  group('T68 typed, privacy-safe snapshot', () {
    test('T68 the snapshot exposes only typed technical fields', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      final gateway = _RecordingNotificationGateway();
      final background = _RecordingBackgroundWork();

      final snapshot = await diagnosticsFor(
        repository: repository,
        gateway: gateway,
        backgroundWork: background,
      ).snapshot(profileId: profileId);

      expect(snapshot.capturedAtUtc, isA<DateTime>());
      expect(snapshot.capturedAtUtc.isUtc, isTrue);
      expect(snapshot.notificationAdapter, isA<BackgroundAdapterAvailability>());
      expect(snapshot.backgroundAdapter, isA<BackgroundAdapterAvailability>());
      expect(
        snapshot.workCountsByState,
        isA<Map<BackgroundWorkState, int>>(),
      );
      expect(
        snapshot.recoveryWorkerRegistration,
        isA<BackgroundRegistrationState>(),
      );
      expect(
        snapshot.pendingNativeReminderCount,
        anyOf(isNull, isA<int>()),
      );
      expect(snapshot.recoveryState, anyOf(isNull, isA<BackgroundWorkState>()));
      expect(snapshot.recoveryAttemptCount, anyOf(isNull, isA<int>()));
      expect(snapshot.recoveryFailureCategory, anyOf(isNull, isA<String>()));
      for (final instant in <DateTime?>[
        snapshot.recoveryLastAttemptAtUtc,
        snapshot.recoveryNextEligibleAtUtc,
        snapshot.recoveryCompletedAtUtc,
      ]) {
        expect(instant, anyOf(isNull, isA<DateTime>()));
      }
    });

    test('T68 a sentinel-laden database never leaks owner content into the '
        'projection', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final clock = FixedClock(now);
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      final zones = IanaCalendarEventTimeZones(
        displayTimeZoneId: 'Asia/Manila',
      );

      // Real owner content carrying every sentinel.
      final planner = DriftPlannerRepository(
        database: database,
        clock: clock,
        calendarSource: DriftCalendarEventRepository(
          database: database,
          clock: clock,
          timeZones: zones,
        ),
      );
      await planner.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'task-sentinel',
          title: 'Call Willow at Willowbank Clinic',
          notes: 'private note about the appointment',
          dueDate: PlannerDate(year: 2026, month: 9, day: 14),
          dueMinute: 9 * 60,
          requiresReport: true,
        ),
      );
      await DriftCalendarEventRepository(
        database: database,
        clock: clock,
        timeZones: zones,
      ).saveEvent(
        profileId: profile.id,
        draft: const CalendarEventDraft(
          id: '3f1c9a72-5b4e-4d81-9c07-2a6e8b1d4f30',
          title: 'Meet Cara at Willowbank Clinic',
          timing: CalendarEventTiming.timed,
          startDate: PlannerDate(year: 2026, month: 9, day: 15),
          startMinute: 600,
          endMinute: 660,
          timeZoneId: 'Asia/Manila',
          locationText: '3 Observatory Lane',
          notes: 'the reflection I wrote',
          requiresReport: true,
        ),
      );

      // Durable reminder work for those sources, plus a live repair marker with
      // a bounded attempt history.
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: ReminderReconciler.stableKey(
            sourceKind: ReminderSourceKind.task,
            profileId: profile.id,
            occurrenceId: 'task:task-sentinel:2026-09-14',
          ),
          profileId: profile.id,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.task,
          ownerId: 'task-sentinel',
          occurrenceId: 'task:task-sentinel:2026-09-14',
          sourceRevision: 'm7w_task_detailed',
          scheduledForUtc: DateTime.utc(2026, 9, 14, 9),
          state: BackgroundWorkState.scheduled,
          platformNotificationId: 501,
          attemptCount: 2,
          snoozeCount: 0,
          lastAttemptAtUtc: now,
          lastFailureCategory: 'platform_unavailable',
          createdAtUtc: now,
          updatedAtUtc: now,
        ),
      );
      await marker.mark(database, profileId: profile.id);
      final token = (await marker.claimRunning(
        database,
        profileId: profile.id,
      ))!;
      await marker.recordRepairFailure(
        database,
        profileId: profile.id,
        capturedToken: token,
        failureCategory: 'platform_unavailable',
      );

      final snapshot = await diagnosticsFor(
        repository: repository,
        gateway: _RecordingNotificationGateway(),
        backgroundWork: _RecordingBackgroundWork(),
      ).snapshot(profileId: profile.id);

      final rows = BackgroundDiagnosticRows.of(snapshot);
      final projected = rows
          .map((row) => '${row.$1}: ${row.$2}')
          .join('\n');

      // The projection is non-trivial, so the scan below is meaningful.
      expect(projected, contains('Recovery state'));
      expect(projected, contains('Recovery registration'));
      expect(projected, contains('Captured'));

      for (final sentinel in _sentinels) {
        expect(
          projected.contains(sentinel),
          isFalse,
          reason: 'owner content "$sentinel" must never reach diagnostics',
        );
      }
      // No identifier, work name or revision may appear either.
      for (final forbidden in <String>[
        profile.id,
        'task-sentinel',
        '3f1c9a72-5b4e-4d81-9c07-2a6e8b1d4f30',
        'reminder:task:',
        'reminder:calendarEvent:',
        ReminderRecoveryRequest.stableKeyFor(profile.id),
        token,
        'm7w_',
        'm7n_',
        'nt.reminder.',
      ]) {
        expect(
          projected.contains(forbidden),
          isFalse,
          reason: 'technical identity "$forbidden" must never be projected',
        );
      }
      // The only failure category that may appear is an allow-listed one.
      expect(snapshot.recoveryFailureCategory, 'platform_unavailable');
      expect(projected, isNot(contains('Exception')));
      expect(projected, isNot(contains('StateError')));
      expect(projected, isNot(contains('stack')));
    });

    test('T68 work counts are counts, never rows or keys', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      for (var index = 0; index < 3; index++) {
        await repository.upsertWorkRequest(
          BackgroundWorkRequest(
            stableKey: 'reminder:task:${profile.id}:task:t$index:2026-09-14:base',
            profileId: profile.id,
            category: BackgroundWorkCategory.reminderRecovery,
            ownerKind: BackgroundWorkOwnerKind.task,
            ownerId: 't$index',
            occurrenceId: 'task:t$index:2026-09-14',
            sourceRevision: 'm7n_generic',
            scheduledForUtc: DateTime.utc(2026, 9, 14, 9),
            state: BackgroundWorkState.scheduled,
            platformNotificationId: 600 + index,
            attemptCount: 0,
            snoozeCount: 0,
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
      }

      final snapshot = await diagnosticsFor(
        repository: repository,
        gateway: _RecordingNotificationGateway(),
        backgroundWork: _RecordingBackgroundWork(),
      ).snapshot(profileId: profile.id);

      expect(snapshot.workCountsByState, <BackgroundWorkState, int>{
        BackgroundWorkState.scheduled: 3,
      });
      final projected = BackgroundDiagnosticRows.of(snapshot)
          .map((row) => '${row.$1}: ${row.$2}')
          .join('\n');
      expect(projected, contains('scheduled 3'));
      expect(projected.contains(':t0'), isFalse);
      expect(projected.contains('600'), isFalse);
    });
  });

  group('T69 producing a snapshot has no side effects', () {
    test('T69 snapshot never reconciles, enqueues, requests or exports',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      final gateway = _RecordingNotificationGateway();
      final background = _RecordingBackgroundWork();
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: FixedClock(now),
        identifiers: const UuidIdentifierSource(),
      );
      await marker.mark(database, profileId: profile.id);
      final before = await marker.read(database, profileId: profile.id);
      final workBefore = await repository.readActiveReminderWork(
        profileId: profile.id,
      );

      await diagnosticsFor(
        repository: repository,
        gateway: gateway,
        backgroundWork: background,
      ).snapshot(profileId: profile.id);

      expect(background.enqueues, 0, reason: 'no work may be enqueued');
      expect(background.cancels, 0, reason: 'no work may be cancelled');
      expect(gateway.schedules, 0, reason: 'no notification may be scheduled');
      expect(gateway.cancels, 0, reason: 'no notification may be cancelled');
      expect(
        background.inspects,
        1,
        reason: 'the platform is only READ for the recovery registration',
      );
      expect(
        gateway.pendingReads,
        1,
        reason:
            'one observation of the notification platform serves both the '
            'availability and the pending count, so the snapshot cannot '
            'describe two different platform states',
      );

      // The repair marker is read, never advanced.
      final after = await marker.read(database, profileId: profile.id);
      expect(after!.state, before!.state);
      expect(after.attemptCount, before.attemptCount);
      expect(after.sourceRevision, before.sourceRevision);
      expect(after.updatedAtUtc, before.updatedAtUtc);
      expect(
        await repository.readActiveReminderWork(profileId: profile.id),
        hasLength(workBefore.length),
      );
    });
  });

  group('T70 factual unavailable / not recorded distinction', () {
    test('T70 a missing adapter is reported as unavailable, never as zero',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      final snapshot = await diagnosticsFor(
        repository: repository,
        gateway: _RecordingNotificationGateway(),
        backgroundWork: _RecordingBackgroundWork(),
        notificationsInstalled: false,
        backgroundInstalled: false,
      ).snapshot(profileId: profileId);

      expect(snapshot.notificationAdapter, BackgroundAdapterAvailability.unavailable);
      expect(snapshot.backgroundAdapter, BackgroundAdapterAvailability.unavailable);
      expect(
        snapshot.pendingNativeReminderCount,
        isNull,
        reason: 'an uninstalled adapter proves nothing, so null — not 0',
      );
      expect(
        snapshot.recoveryWorkerRegistration,
        BackgroundRegistrationState.unavailable,
      );

      final rows = BackgroundDiagnosticRows.of(snapshot);
      expect(_row(rows, 'Notification scheduler'), 'Not installed');
      expect(_row(rows, 'Background scheduler'), 'Not installed');
      expect(_row(rows, 'Pending reminders'), 'Unavailable');
      expect(
        _row(rows, 'Recovery state'),
        'Not recorded',
        reason: 'no marker exists, which is different from an unreadable one',
      );
      expect(_row(rows, 'Attempts'), 'Not recorded');
      expect(_row(rows, 'Last attempt'), 'Not recorded');
      expect(_row(rows, 'Next eligible'), 'Not recorded');
      expect(_row(rows, 'Completed'), 'Not recorded');
      expect(_row(rows, 'Failure category'), 'Not recorded');
      expect(
        rows.map((row) => row.$1),
        isNot(contains('Recorded work')),
        reason: 'an empty count set is omitted, never rendered as an invented 0',
      );
    });

    test('T70 a failed probe is UNKNOWN, not available and not absent',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      final gateway = _RecordingNotificationGateway()
        ..pendingFailure = StateError('platform unavailable');
      final background = _RecordingBackgroundWork()
        ..inspectFailure = StateError('platform unavailable');

      final snapshot = await diagnosticsFor(
        repository: repository,
        gateway: gateway,
        backgroundWork: background,
      ).snapshot(profileId: profileId);

      expect(
        snapshot.notificationAdapter,
        BackgroundAdapterAvailability.unknown,
        reason: 'a failed probe proves nothing, so it is neither yes nor no',
      );
      expect(snapshot.backgroundAdapter, BackgroundAdapterAvailability.unknown);
      expect(
        snapshot.recoveryWorkerRegistration,
        BackgroundRegistrationState.unavailable,
      );
      expect(snapshot.pendingNativeReminderCount, isNull);

      final rows = BackgroundDiagnosticRows.of(snapshot);
      expect(_row(rows, 'Notification scheduler'), 'Unavailable');
      expect(_row(rows, 'Background scheduler'), 'Unavailable');
      expect(_row(rows, 'Recovery registration'), 'Unavailable');
      expect(_row(rows, 'Pending reminders'), 'Unavailable');
    });

    test('T70 the pending count excludes the badge and dormant kinds', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      const reserved =
          DriftNotificationFoundationRepository.reservedPlatformNotificationId;
      final gateway = _RecordingNotificationGateway()
        ..pendingItems = <PendingLocalNotification>[
          const PendingLocalNotification(platformId: reserved, payload: null),
          PendingLocalNotification(
            platformId: 801,
            payload: NotificationPayloadCodec.encode(
              NotificationResponseIntent(
                profileId: profileId,
                sourceKind: NotificationSourceKind.task,
                sourceId: 'task-a',
                occurrenceId: 'task:task-a:2026-09-14',
                action: NotificationResponseAction.open,
              ),
            ),
          ),
          PendingLocalNotification(
            platformId: 802,
            payload: NotificationPayloadCodec.encode(
              NotificationResponseIntent(
                profileId: profileId,
                sourceKind: NotificationSourceKind.goalAchievement,
                sourceId: 'goal-a',
                action: NotificationResponseAction.open,
              ),
            ),
          ),
          PendingLocalNotification(
            platformId: 803,
            payload: NotificationPayloadCodec.encode(
              NotificationResponseIntent(
                profileId: profileId,
                sourceKind: NotificationSourceKind.contactFollowUp,
                sourceId: 'contact-a',
                action: NotificationResponseAction.open,
              ),
            ),
          ),
          PendingLocalNotification(
            platformId: 804,
            payload: NotificationPayloadCodec.encode(
              const NotificationResponseIntent(
                profileId: 'another-profile',
                sourceKind: NotificationSourceKind.task,
                sourceId: 'their-task',
                occurrenceId: 'their-occurrence',
                action: NotificationResponseAction.open,
              ),
            ),
          ),
        ];

      final snapshot = await diagnosticsFor(
        repository: repository,
        gateway: gateway,
        backgroundWork: _RecordingBackgroundWork(),
      ).snapshot(profileId: profileId);

      expect(
        snapshot.pendingNativeReminderCount,
        1,
        reason:
            'the launcher badge, the dormant Goal/Contact kinds and another '
            'profile\'s work are not this profile\'s reminders',
      );
    });

    test('T70 a recorded recovery registration is reported factually', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      final background = _RecordingBackgroundWork()
        ..inspectResult = BackgroundGatewayWorkState.scheduled;

      final snapshot = await diagnosticsFor(
        repository: repository,
        gateway: _RecordingNotificationGateway(),
        backgroundWork: background,
      ).snapshot(profileId: profileId);

      expect(
        snapshot.recoveryWorkerRegistration,
        BackgroundRegistrationState.pending,
      );
      final rows = BackgroundDiagnosticRows.of(snapshot);
      expect(_row(rows, 'Recovery registration'), 'Pending');
      expect(
        _row(rows, 'Recovery registration'),
        isNot('Terminal'),
        reason: 'Android exposes no finish timestamp, so nothing is fabricated',
      );
    });
  });
}

String? _row(List<(String, String)> rows, String label) =>
    rows.where((row) => row.$1 == label).map((row) => row.$2).firstOrNull;
