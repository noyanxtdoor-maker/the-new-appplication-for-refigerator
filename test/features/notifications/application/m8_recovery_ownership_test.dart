// VS16 M8 — recovery ownership, markers, refill and platform identity
// (contract sections 28/29/30/34/65, scenarios T41-T46).
//
// The law under test:
//  * ONE notification-domain truth path with TWO explicitly selected transports.
//    A cleanup pass for one reminder family must never cancel a sibling family's
//    row, even when the two share an occurrence token (forensic finding F03);
//  * the durable repair marker is claimed, completed and failed as ONE captured
//    generation, and a mutation landing mid-pass produces exactly ONE trailing
//    pass rather than a stale completion;
//  * repeated foreground recovery uses KEEP, so it can never cancel a running
//    job or reset a bounded retry budget;
//  * the bounded horizon refill is a single one-off that is re-armed ONLY by a
//    successful recovery, so a failing pass cannot spawn a chain;
//  * the launcher badge's reserved platform ID is never allocated to a reminder
//    and a row squatting on it is relocated transactionally;
//  * the reverse platform sweep withdraws only rows this app provably owns.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/background/workmanager_background_work_gateway.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_launcher_badge_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reconcile_reminders.dart';
import 'package:rmplanner/features/notifications/application/reminder_orphan_sweeper.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/application/reminder_recovery_coordinator.dart';
import 'package:rmplanner/features/notifications/application/reminder_registration_repair.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart'
    as domain;
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/data/drift_weekly_planning_repository.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

import '../../../support/test_dependencies.dart';

/// A clock whose value the test controls, so generation changes are provable.
final class _MutableClock implements AppClock {
  _MutableClock(this._value);

  DateTime _value;

  void advance(Duration by) => _value = _value.add(by);

  @override
  DateTime nowUtc() => _value;
}

/// Records every enqueue so KEEP/REPLACE and unique-name identity are provable.
final class _RecordingBackgroundWork implements BackgroundWorkGateway {
  final List<BackgroundWorkSpec> enqueued = <BackgroundWorkSpec>[];
  final List<String> cancelled = <String>[];
  BackgroundGatewayWorkState inspectResult = BackgroundGatewayWorkState.absent;
  Object? inspectFailure;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async =>
      enqueued.add(work);

  @override
  Future<void> cancelUnique(String uniqueName) async =>
      cancelled.add(uniqueName);

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async {
    final failure = inspectFailure;
    if (failure != null) throw failure;
    return inspectResult;
  }
}

/// Records platform cancellations and controls the pending set the OS reports.
final class _RecordingNotificationGateway implements NotificationGateway {
  final List<int> cancelled = <int>[];
  List<PendingLocalNotification> pendingItems = const <PendingLocalNotification>[];
  Object? pendingFailure;

  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {}

  @override
  Future<void> cancel(int platformId) async => cancelled.add(platformId);

  @override
  Future<List<PendingLocalNotification>> pending() async {
    final failure = pendingFailure;
    if (failure != null) throw failure;
    return pendingItems;
  }

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

void main() {
  setUpAll(data.initializeTimeZones);

  const profileId = '11111111-1111-4111-8111-111111111111';
  final base = DateTime.utc(2026, 9, 12, 9);

  DriftNotificationFoundationRepository repositoryFor(
    AppDatabase database,
    AppClock clock, {
    int Function(String)? platformIdSeed,
  }) => DriftNotificationFoundationRepository(
    database: database,
    clock: clock,
    platformIdSeed: platformIdSeed ?? (_) => 41,
  );

  group('T41 F03 — sibling planning families never cancel each other', () {
    test('T41 the family prefix separates the two planning kinds at the query '
        'level even when they share an occurrence token', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = repositoryFor(database, FixedClock(base));
      const sharedToken = 'shared-occurrence-token';

      // Both rows are `ownerKind = planning` and carry the SAME occurrence
      // token.  Only the stable-key family prefix tells them apart.
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: ReminderReconciler.stableKey(
            sourceKind: ReminderSourceKind.weeklyReview,
            profileId: profileId,
            occurrenceId: sharedToken,
          ),
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.planning,
          ownerId: sharedToken,
          occurrenceId: sharedToken,
          scheduledForUtc: base.add(const Duration(days: 2)),
          state: BackgroundWorkState.scheduled,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: ReminderReconciler.stableKey(
            sourceKind: ReminderSourceKind.awaitingReport,
            profileId: profileId,
            occurrenceId: sharedToken,
          ),
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.planning,
          ownerId: sharedToken,
          occurrenceId: sharedToken,
          scheduledForUtc: base.add(const Duration(days: 2)),
          state: BackgroundWorkState.scheduled,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );

      Future<List<String>> keysFor(ReminderSourceKind kind) async => (
        await repository.readReminderWork(
          profileId: profileId,
          sourceKind: kind,
          windowStartUtc: DateTime.utc(2026),
          windowEndUtc: DateTime.utc(2030),
        )
      ).map((row) => row.stableKey).toList();

      // FAIL pre-fix: the owner-kind filter alone returned BOTH rows.
      expect(await keysFor(ReminderSourceKind.weeklyReview), <String>[
        'planning:weekly-review:$profileId:$sharedToken',
      ]);
      expect(await keysFor(ReminderSourceKind.awaitingReport), <String>[
        'planning:awaiting-report:$profileId:$sharedToken',
      ]);
    });

    test('T41 an owned-key guard rejects the sibling family', () {
      const weeklyKey = 'planning:weekly-review:p:token';
      const awaitingKey = 'planning:awaiting-report:p:token';
      expect(
        ReminderReconciler.belongsToFamily(
          sourceKind: ReminderSourceKind.weeklyReview,
          stableKey: weeklyKey,
        ),
        isTrue,
      );
      expect(
        ReminderReconciler.belongsToFamily(
          sourceKind: ReminderSourceKind.weeklyReview,
          stableKey: awaitingKey,
        ),
        isFalse,
        reason: 'a weekly-review pass must never claim a report-family row',
      );
      expect(
        ReminderSourceKind.awaitingReport.ownsStableKey(awaitingKey),
        isTrue,
      );
      expect(ReminderSourceKind.awaitingReport.ownsStableKey(weeklyKey), isFalse);
    });

    test('T41 cancellation targets the retrieved row, not a key rebuilt from a '
        'shared occurrence token', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final gateway = _RecordingNotificationGateway();
      final repository = repositoryFor(database, FixedClock(base));
      final reconciler = ReminderReconciler(
        repository: repository,
        gateway: gateway,
        clock: FixedClock(base),
      );
      const sharedToken = 'shared-occurrence-token';
      final weeklyKey = ReminderReconciler.stableKey(
        sourceKind: ReminderSourceKind.weeklyReview,
        profileId: profileId,
        occurrenceId: sharedToken,
      );
      final awaitingKey = ReminderReconciler.stableKey(
        sourceKind: ReminderSourceKind.awaitingReport,
        profileId: profileId,
        occurrenceId: sharedToken,
      );
      for (final key in <String>[weeklyKey, awaitingKey]) {
        await repository.upsertWorkRequest(
          BackgroundWorkRequest(
            stableKey: key,
            profileId: profileId,
            category: BackgroundWorkCategory.reminderRecovery,
            ownerKind: BackgroundWorkOwnerKind.planning,
            ownerId: sharedToken,
            occurrenceId: sharedToken,
            scheduledForUtc: base.add(const Duration(days: 2)),
            state: BackgroundWorkState.scheduled,
            attemptCount: 0,
            snoozeCount: 0,
            createdAtUtc: base,
            updatedAtUtc: base,
          ),
        );
      }

      // The report family retires its OWN row by its actual key.
      await reconciler.cancel(
        sourceKind: ReminderSourceKind.awaitingReport,
        profileId: profileId,
        occurrenceId: sharedToken,
        exactStableKey: awaitingKey,
      );

      expect(
        (await repository.readWorkRequest(awaitingKey))!.state,
        BackgroundWorkState.cancelledObsolete,
      );
      expect(
        (await repository.readWorkRequest(weeklyKey))!.state,
        BackgroundWorkState.scheduled,
        reason: 'the sibling family must be untouched',
      );
    });
  });

  group('T42 recovery marker generation lifecycle', () {
    test('T42 queued -> running -> completed for one captured generation',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );

      await marker.mark(database, profileId: profileId);
      final queued = await marker.read(database, profileId: profileId);
      expect(queued!.state, BackgroundWorkState.queued);
      expect(queued.category, BackgroundWorkCategory.reminderRecovery);
      expect(queued.ownerKind, BackgroundWorkOwnerKind.profile);
      expect(queued.ownerId, profileId);
      expect(queued.occurrenceId, isNull);
      expect(queued.platformNotificationId, isNull);
      expect(queued.scheduledForUtc, isNull);
      expect(queued.attemptCount, 0);
      expect(queued.snoozeCount, 0);
      expect(queued.completedAtUtc, isNull);
      expect(queued.lastFailureCategory, isNull);
      expect(queued.sourceRevision, isNotNull);
      expect(
        queued.stableKey,
        ReminderRecoveryRequest.stableKeyFor(profileId),
      );

      final token = await marker.claimRunning(database, profileId: profileId);
      expect(token, isNotNull);
      expect(
        (await marker.read(database, profileId: profileId))!.state,
        BackgroundWorkState.running,
      );

      expect(
        await marker.completeIfUnchanged(
          database,
          profileId: profileId,
          capturedToken: token!,
        ),
        isTrue,
      );
      final completed = await marker.read(database, profileId: profileId);
      expect(completed!.state, BackgroundWorkState.completed);
      expect(completed.completedAtUtc, isNotNull);
    });

    test('T42 a mutation during the pass triggers exactly one trailing pass',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );
      await marker.mark(database, profileId: profileId);

      var eventsPasses = 0;
      var trailingMutated = false;
      final reconcile = ReconcileReminders(
        reconcileEvents: () async {
          eventsPasses++;
          // Canonical truth changes WHILE the first pass is running.
          if (!trailingMutated) {
            trailingMutated = true;
            clock.advance(const Duration(seconds: 5));
            await marker.mark(database, profileId: profileId);
          }
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

      await reconcile();

      expect(
        eventsPasses,
        2,
        reason: 'the mid-pass mutation must produce exactly ONE trailing pass',
      );
      final row = await marker.read(database, profileId: profileId);
      expect(
        row!.state,
        BackgroundWorkState.completed,
        reason: 'the trailing pass reconciles and completes the NEW generation',
      );
    });

    test('T42 an older result never completes a newer generation', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );
      await marker.mark(database, profileId: profileId);
      final staleToken = (await marker.claimRunning(
        database,
        profileId: profileId,
      ))!;

      // A newer mutation arrives after the pass captured its generation.
      clock.advance(const Duration(seconds: 3));
      await marker.mark(database, profileId: profileId);
      final newer = await marker.read(database, profileId: profileId);
      expect(newer!.sourceRevision, isNot(staleToken));

      expect(
        await marker.completeIfUnchanged(
          database,
          profileId: profileId,
          capturedToken: staleToken,
        ),
        isFalse,
        reason: 'a stale result must not stamp newer truth completed',
      );
      expect(
        (await marker.read(database, profileId: profileId))!.state,
        isNot(BackgroundWorkState.completed),
      );
      expect(
        (await marker.read(database, profileId: profileId))!.completedAtUtc,
        isNull,
      );
    });

    test('T42 a live episode keeps its bounded budget across a burst', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );
      await marker.mark(database, profileId: profileId);
      final token = (await marker.claimRunning(database, profileId: profileId))!;
      await marker.recordRepairFailure(
        database,
        profileId: profileId,
        capturedToken: token,
        failureCategory: 'platform_unavailable',
      );

      for (var burst = 0; burst < 4; burst++) {
        clock.advance(const Duration(seconds: 1));
        await marker.mark(database, profileId: profileId);
      }
      final row = await marker.read(database, profileId: profileId);
      expect(
        row!.attemptCount,
        1,
        reason: 'a burst must never restart or discard retry progress',
      );
      expect(row.createdAtUtc, isNotNull);
    });

    test('T42 a terminal episode is never resurrected by claim', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = _MutableClock(base);
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );
      await marker.mark(database, profileId: profileId);
      final token = (await marker.claimRunning(database, profileId: profileId))!;
      await marker.completeIfUnchanged(
        database,
        profileId: profileId,
        capturedToken: token,
      );
      expect(
        await marker.claimRunning(database, profileId: profileId),
        isNull,
        reason: 'a completed repair must not be re-claimed',
      );
    });
  });

  group('T43 KEEP policy for repeated foreground recovery', () {
    test('T43 recovery enqueue is KEEP and never cancels running work', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final gateway = _RecordingBackgroundWork();
      final coordinator = ReminderRecoveryCoordinator(
        repository: repositoryFor(database, FixedClock(base)),
        backgroundWork: gateway,
        clock: FixedClock(base),
      );
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: FixedClock(base),
        identifiers: const UuidIdentifierSource(),
      );

      // No marker means nothing to repair, so no OS work is scheduled at all.
      expect(await coordinator.enqueueIfDirty(profileId: profileId), isFalse);
      expect(gateway.enqueued, isEmpty);

      await marker.mark(database, profileId: profileId);
      expect(await coordinator.enqueueIfDirty(profileId: profileId), isTrue);
      expect(await coordinator.enqueueIfDirty(profileId: profileId), isTrue);
      expect(
        await coordinator.enqueueIfDirty(profileId: profileId),
        isTrue,
      );

      expect(gateway.enqueued, hasLength(3));
      for (final spec in gateway.enqueued) {
        expect(
          spec.existingPolicy,
          BackgroundExistingWorkPolicy.keep,
          reason: 'a repeated trigger must never cancel a running recovery',
        );
        expect(spec.uniqueName, ReminderRecoveryCoordinator.recoveryUniqueName);
        expect(spec.taskName, ReminderRecoveryCoordinator.recoveryTaskName);
        expect(spec.inputData, isEmpty);
        spec.validate();
      }
      expect(
        gateway.cancelled,
        isEmpty,
        reason: 'recovery never cancels another job',
      );
    });

    test('T43 a terminal marker does not schedule new work', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final gateway = _RecordingBackgroundWork();
      final coordinator = ReminderRecoveryCoordinator(
        repository: repositoryFor(database, FixedClock(base)),
        backgroundWork: gateway,
        clock: FixedClock(base),
      );
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: FixedClock(base),
        identifiers: const UuidIdentifierSource(),
      );
      await marker.mark(database, profileId: profileId);
      final token = (await marker.claimRunning(database, profileId: profileId))!;
      await marker.completeIfUnchanged(
        database,
        profileId: profileId,
        capturedToken: token,
      );

      expect(await coordinator.enqueueIfDirty(profileId: profileId), isFalse);
      expect(gateway.enqueued, isEmpty);
    });
  });

  group('T44 bounded horizon refill', () {
    test('T44 refill is one unique one-off re-armed only after success',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final gateway = _RecordingBackgroundWork();
      final coordinator = ReminderRecoveryCoordinator(
        repository: repositoryFor(database, FixedClock(base)),
        backgroundWork: gateway,
        clock: FixedClock(base),
      );

      await coordinator.armRefill();
      expect(gateway.enqueued, hasLength(1));
      final refill = gateway.enqueued.single;
      expect(refill.uniqueName, ReminderRecoveryCoordinator.refillUniqueName);
      expect(refill.taskName, ReminderRecoveryCoordinator.recoveryTaskName);
      expect(
        refill.initialDelay,
        const Duration(hours: 24),
        reason: 'the bounded horizon refill runs at most once a day',
      );
      expect(refill.existingPolicy, BackgroundExistingWorkPolicy.keep);
      expect(
        refill.constraints.network,
        BackgroundNetworkConstraint.notRequired,
        reason: 'local reminder maintenance needs no network',
      );
      expect(refill.constraints.requiresCharging, isFalse);
      expect(refill.inputData, isEmpty);
      refill.validate();
    });

    test('T44 a failing pass never arms the refill, a successful one does',
        () async {
      // The refill is armed from the provider's `completeRepair` closure, i.e.
      // only when the captured generation was actually consumed.  Drive the REAL
      // provider so the wiring itself is under test.
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final clock = _MutableClock(base);
      final gateway = _RecordingBackgroundWork();
      final repository = repositoryFor(database, clock);
      final marker = ReminderRecoveryRequest(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );
      await repository.savePreferences(
        profileId: profile.id,
        preferences: const domain.NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
          weeklyReviewRemindersEnabled: true,
          awaitingReportRemindersEnabled: true,
        ),
      );
      await marker.mark(database, profileId: profile.id);

      var failEvents = false;
      final container = ProviderContainer(
        overrides: [
          reminderRuntimeProfileIdProvider.overrideWithValue(profile.id),
          reminderRecoveryRequestProvider.overrideWithValue(marker),
          notificationFoundationRepositoryProvider.overrideWithValue(repository),
          notificationGatewayProvider.overrideWithValue(
            _RecordingNotificationGateway(),
          ),
          backgroundWorkGatewayProvider.overrideWithValue(gateway),
          reminderDeviceLocationProvider.overrideWithValue(tz.UTC),
          reminderReconcilerProvider.overrideWithValue(
            ReminderReconciler(
              repository: repository,
              gateway: _RecordingNotificationGateway(),
              clock: clock,
              deviceLocation: tz.UTC,
            ),
          ),
          permissionGatewayProvider.overrideWithValue(
            _GrantedPermissionGateway(),
          ),
          privacyRepositoryProvider.overrideWithValue(
            DriftPrivacyRepository(database: database, clock: clock),
          ),
          calendarEventRepositoryProvider.overrideWithValue(
            DriftCalendarEventRepository(
              database: database,
              clock: clock,
              timeZones: IanaCalendarEventTimeZones(
                displayTimeZoneId: 'Asia/Manila',
              ),
            ),
          ),
          weeklyPlanningRepositoryProvider.overrideWithValue(
            DriftWeeklyPlanningRepository(
              database: database,
              clock: clock,
              identifiers: const UuidIdentifierSource(),
              timeZones: IanaCalendarEventTimeZones(
                displayTimeZoneId: 'Asia/Manila',
              ),
              indicators: DriftIndicatorRepository(
                database: database,
                clock: clock,
                calendarEvents: DriftCalendarEventRepository(
                  database: database,
                  clock: clock,
                  timeZones: IanaCalendarEventTimeZones(
                    displayTimeZoneId: 'Asia/Manila',
                  ),
                ),
              ),
            ),
          ),
          eventReminderHorizonOverrideProvider.overrideWithValue(
            (eventId, refreshContent) async {
              if (failEvents) throw StateError('Injected horizon failure');
            },
          ),
          taskReminderHorizonOverrideProvider.overrideWithValue(
            (refreshContent) async {},
          ),
        ],
      );
      addTearDown(container.dispose);

      // FAILING pass: the marker records the attempt, and no refill is armed.
      failEvents = true;
      await expectLater(
        container.read(reconcileRemindersProvider)(),
        throwsA(isA<StateError>()),
      );
      expect(
        gateway.enqueued.where(
          (spec) => spec.uniqueName == ReminderRecoveryCoordinator.refillUniqueName,
        ),
        isEmpty,
        reason: 'a failing pass must not spawn a refill chain',
      );
      final afterFailure = await marker.read(
        database,
        profileId: profile.id,
      );
      expect(afterFailure!.attemptCount, 1);
      expect(afterFailure.state, BackgroundWorkState.retryScheduled);

      // SUCCESSFUL pass: the marker is consumed and the refill is armed once.
      failEvents = false;
      await container.read(reconcileRemindersProvider)();
      final refills = gateway.enqueued
          .where(
            (spec) =>
                spec.uniqueName == ReminderRecoveryCoordinator.refillUniqueName,
          )
          .toList();
      expect(refills, hasLength(1));
      expect(refills.single.initialDelay, const Duration(hours: 24));
      expect(
        (await marker.read(database, profileId: profile.id))!.state,
        BackgroundWorkState.completed,
      );
    });
  });

  group('T45 reserved platform notification ID', () {
    test('T45 the allocator skips the launcher badge ID', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      const reserved =
          DriftNotificationFoundationRepository.reservedPlatformNotificationId;
      expect(
        reserved,
        FlutterLocalNotificationsLauncherBadgeGateway.notificationId,
        reason: 'the allocator and the badge must agree on ONE reserved ID',
      );
      // A seed that lands exactly on the reserved ID must be probed past.
      final repository = repositoryFor(
        database,
        FixedClock(base),
        platformIdSeed: (_) => reserved,
      );
      const key = 'reminder:task:p:o:base';
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: key,
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.task,
          ownerId: 'o',
          occurrenceId: 'o',
          state: BackgroundWorkState.queued,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );

      final allocated = await repository.allocatePlatformNotificationId(key);
      expect(
        allocated,
        isNot(reserved),
        reason: 'FAIL pre-fix: the badge ID could be handed to a reminder',
      );
      expect(allocated, greaterThan(0));
    });

    test('T45 a row squatting on the reserved ID is relocated transactionally',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      const reserved =
          DriftNotificationFoundationRepository.reservedPlatformNotificationId;
      final repository = repositoryFor(
        database,
        FixedClock(base),
        platformIdSeed: (_) => 500,
      );
      const key = 'reminder:calendarEvent:p:o:base';
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: key,
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.occurrence,
          ownerId: 'o',
          occurrenceId: 'o',
          sourceRevision: 'm7n_generic',
          scheduledForUtc: base,
          state: BackgroundWorkState.scheduled,
          platformNotificationId: reserved,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );

      final relocated = await repository.allocatePlatformNotificationId(key);
      expect(relocated, isNot(reserved));
      final row = await repository.readWorkRequest(key);
      expect(row!.platformNotificationId, relocated);
      expect(
        row.state,
        BackgroundWorkState.scheduled,
        reason: 'relocation is a technical identity repair, not a state change',
      );
    });

    test('T45 the allocator never reuses an ID already held by another row',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = repositoryFor(
        database,
        FixedClock(base),
        platformIdSeed: (_) => 77,
      );
      for (final key in <String>[
        'reminder:task:p:o1:base',
        'reminder:task:p:o2:base',
        'reminder:task:p:o3:base',
      ]) {
        await repository.upsertWorkRequest(
          BackgroundWorkRequest(
            stableKey: key,
            profileId: profileId,
            category: BackgroundWorkCategory.reminderRecovery,
            ownerKind: BackgroundWorkOwnerKind.task,
            ownerId: 'o',
            occurrenceId: 'o',
            state: BackgroundWorkState.queued,
            attemptCount: 0,
            snoozeCount: 0,
            createdAtUtc: base,
            updatedAtUtc: base,
          ),
        );
      }
      final ids = <int>[
        await repository.allocatePlatformNotificationId(
          'reminder:task:p:o1:base',
        ),
        await repository.allocatePlatformNotificationId(
          'reminder:task:p:o2:base',
        ),
        await repository.allocatePlatformNotificationId(
          'reminder:task:p:o3:base',
        ),
      ];
      expect(ids, <int>[77, 78, 79]);
      expect(
        ids,
        isNot(contains(
          DriftNotificationFoundationRepository.reservedPlatformNotificationId,
        )),
      );
    });
  });

  group('T46 reverse platform sweep ownership', () {
    test('T46 only provably owned stale items are withdrawn', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = FixedClock(base);
      final repository = repositoryFor(database, clock);
      final gateway = _RecordingNotificationGateway();
      const reserved =
          DriftNotificationFoundationRepository.reservedPlatformNotificationId;

      // (a) A row-less orphan owned by this profile.
      const orphanKey = 'reminder:task:$profileId:task:orphan:2026-09-12:base';
      final orphanIntent = NotificationResponseIntent(
        profileId: profileId,
        sourceKind: NotificationSourceKind.task,
        sourceId: 'orphan',
        occurrenceId: 'task:orphan:2026-09-12',
        action: NotificationResponseAction.open,
      );
      // (b) A live owned row whose platform ID is CURRENT and still pending.
      const liveKey = 'reminder:calendarEvent:$profileId:occ-live:base';
      final liveIntent = NotificationResponseIntent(
        profileId: profileId,
        sourceKind: NotificationSourceKind.calendarEvent,
        sourceId: 'event-live',
        occurrenceId: 'occ-live',
        action: NotificationResponseAction.open,
      );
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: liveKey,
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.occurrence,
          ownerId: 'event-live',
          occurrenceId: 'occ-live',
          sourceRevision: 'm7n_generic',
          scheduledForUtc: base.add(const Duration(hours: 3)),
          state: BackgroundWorkState.scheduled,
          platformNotificationId: 601,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );

      gateway.pendingItems = <PendingLocalNotification>[
        // The launcher badge must never be touched.
        const PendingLocalNotification(platformId: reserved, payload: null),
        // A foreign / undecodable payload is diagnostic unknown, not ours.
        const PendingLocalNotification(platformId: 700, payload: 'not-a-payload'),
        // Another profile's reminder is never read, let alone cancelled.
        PendingLocalNotification(
          platformId: 701,
          payload: NotificationPayloadCodec.encode(
            const NotificationResponseIntent(
              profileId: 'someone-else',
              sourceKind: NotificationSourceKind.task,
              sourceId: 'their-task',
              occurrenceId: 'their-occurrence',
              action: NotificationResponseAction.open,
            ),
          ),
        ),
        // This profile's orphan: durable row is missing -> withdraw.
        PendingLocalNotification(
          platformId: 702,
          payload: NotificationPayloadCodec.encode(orphanIntent),
        ),
        // This profile's LIVE row: keep, because the row is active and holds
        // exactly this platform ID.
        PendingLocalNotification(
          platformId: 601,
          payload: NotificationPayloadCodec.encode(liveIntent),
        ),
      ];

      final sweeper = ReminderOrphanSweeper(
        repository: repository,
        clock: clock,
        reminders: ReminderReconciler(
          repository: repository,
          gateway: gateway,
          clock: clock,
        ),
        readPlatformPending: gateway.pending,
        platformPendingIds: () async => gateway.pendingItems
            .map((item) => item.platformId)
            .toSet(),
        cancelPlatform: gateway.cancel,
        reservedPlatformId: reserved,
      );

      await sweeper.sweep(profileId: profileId);

      expect(
        gateway.cancelled,
        <int>[702],
        reason:
            'only this profile\'s genuinely orphaned item may be withdrawn; '
            'the badge, foreign payloads and other profiles are untouched',
      );
      expect(
        (await repository.readWorkRequest(liveKey))!.state,
        BackgroundWorkState.scheduled,
      );
      expect(await repository.readWorkRequest(orphanKey), isNull);
    });

    test('T46 an unreadable platform truth withdraws nothing', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = FixedClock(base);
      final repository = repositoryFor(database, clock);
      final gateway = _RecordingNotificationGateway();
      const key = 'reminder:task:$profileId:task:expired:2026-09-01:base';
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: key,
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.task,
          ownerId: 'expired',
          occurrenceId: 'task:expired:2026-09-01',
          sourceRevision: 'm7n_generic',
          scheduledForUtc: DateTime.utc(2026, 9, 1),
          state: BackgroundWorkState.scheduled,
          platformNotificationId: 611,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );

      final sweeper = ReminderOrphanSweeper(
        repository: repository,
        clock: clock,
        reminders: ReminderReconciler(
          repository: repository,
          gateway: gateway,
          clock: clock,
        ),
        readPlatformPending: gateway.pending,
        // The platform query failed: null means UNKNOWN, never "nothing".
        platformPendingIds: () async => null,
        cancelPlatform: gateway.cancel,
        reservedPlatformId:
            DriftNotificationFoundationRepository.reservedPlatformNotificationId,
      );

      await sweeper.sweep(profileId: profileId);
      expect(
        gateway.cancelled,
        isEmpty,
        reason: 'an unreadable platform proves nothing and changes nothing',
      );
      expect(
        (await repository.readWorkRequest(key))!.state,
        BackgroundWorkState.scheduled,
      );
    });

    test('T46 a row with no target and no registration is a real orphan',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = FixedClock(base);
      final repository = repositoryFor(database, clock);
      final gateway = _RecordingNotificationGateway();
      const key = 'reminder:calendarEvent:$profileId:occ-null:base';
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: key,
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.occurrence,
          ownerId: 'event-null',
          occurrenceId: 'occ-null',
          sourceRevision: 'm7n_generic',
          state: BackgroundWorkState.queued,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );

      final sweeper = ReminderOrphanSweeper(
        repository: repository,
        clock: clock,
        reminders: ReminderReconciler(
          repository: repository,
          gateway: gateway,
          clock: clock,
        ),
        readPlatformPending: gateway.pending,
        platformPendingIds: () async => <int>{},
        cancelPlatform: gateway.cancel,
        reservedPlatformId:
            DriftNotificationFoundationRepository.reservedPlatformNotificationId,
      );

      await sweeper.sweep(profileId: profileId);
      expect(
        (await repository.readWorkRequest(key))!.state,
        BackgroundWorkState.cancelledObsolete,
      );
    });
  });

  group('T36/T41 registration repair uses the exact generation identity', () {
    test('T41 a worker row whose registration is gone is re-registered KEEP',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = FixedClock(base);
      final repository = repositoryFor(database, clock);
      final gateway = _RecordingBackgroundWork();
      const key = 'reminder:task:$profileId:task:repair:2026-09-14:base';
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: key,
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.task,
          ownerId: 'repair',
          occurrenceId: 'task:repair:2026-09-14',
          sourceRevision: 'm7w_task_generic',
          scheduledForUtc: base.add(const Duration(days: 2)),
          state: BackgroundWorkState.scheduled,
          platformNotificationId: 321,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );

      final repair = ReminderRegistrationRepair(
        repository: repository,
        backgroundWork: gateway,
        clock: clock,
        uniqueNameFor: (row) => CanonicalReminderWorkSpec.uniqueName(
          platformNotificationId: row.platformNotificationId!,
          scheduledUtcMs: row.scheduledForUtc!.millisecondsSinceEpoch,
          sourceRevision: row.sourceRevision!,
        ),
        enqueueWorker: (row) async {
          await gateway.enqueueUnique(
            CanonicalReminderWorkSpec(
              stableKey: row.stableKey,
              scheduledUtcMs: row.scheduledForUtc!.millisecondsSinceEpoch,
              sourceRevision: row.sourceRevision!,
            ).toWorkSpec(
              platformNotificationId: row.platformNotificationId!,
              nowUtc: clock.nowUtc(),
              existingPolicy: BackgroundExistingWorkPolicy.keep,
            ),
          );
        },
      );

      // ABSENT registration + still-eligible current generation -> repair KEEP.
      gateway.inspectResult = BackgroundGatewayWorkState.absent;
      expect(await repair.repair(profileId: profileId), 1);
      expect(gateway.enqueued, hasLength(1));
      expect(gateway.enqueued.single.existingPolicy,
          BackgroundExistingWorkPolicy.keep);
      expect(gateway.enqueued.single.inputData.keys, <String>{
        'stable_key',
        'scheduled_utc_ms',
        'source_revision',
      });

      // ENQUEUED registration -> keep, never duplicate the enqueue.
      gateway.inspectResult = BackgroundGatewayWorkState.scheduled;
      expect(await repair.repair(profileId: profileId), 0);
      expect(gateway.enqueued, hasLength(1));

      // Unreadable platform -> change nothing at all.
      gateway.inspectFailure = StateError('platform unavailable');
      expect(await repair.repair(profileId: profileId), 0);
      expect(gateway.enqueued, hasLength(1));
    });

    test('T41 native-transport rows are left to the source pass', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final clock = FixedClock(base);
      final repository = repositoryFor(database, clock);
      final gateway = _RecordingBackgroundWork();
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: 'reminder:task:$profileId:task:native:2026-09-14:base',
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.task,
          ownerId: 'native',
          occurrenceId: 'task:native:2026-09-14',
          sourceRevision: 'm7n_task_generic',
          scheduledForUtc: base.add(const Duration(days: 2)),
          state: BackgroundWorkState.scheduled,
          platformNotificationId: 322,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: base,
          updatedAtUtc: base,
        ),
      );
      final repair = ReminderRegistrationRepair(
        repository: repository,
        backgroundWork: gateway,
        clock: clock,
        uniqueNameFor: (row) => 'unused',
        enqueueWorker: (row) async =>
            throw StateError('a native row must never be worker-registered'),
      );
      expect(await repair.repair(profileId: profileId), 0);
      expect(gateway.enqueued, isEmpty);
    });
  });
}

final class _GrantedPermissionGateway implements PermissionGateway {
  @override
  Future<OperatingSystemPermissionState> status(
    OptionalPermission permission,
  ) async => OperatingSystemPermissionState.granted;

  @override
  Future<OperatingSystemPermissionState> request(
    OptionalPermission permission,
  ) async => OperatingSystemPermissionState.granted;

  @override
  Future<bool> openSystemSettings() async => true;
}
