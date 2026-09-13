import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/workmanager_background_work_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

import '../../../support/test_dependencies.dart';

void main() {
  for (final kind in ReminderSourceKind.values) {
    test(
      'OFF overtaking a platform schedule cancels it and ON recreates it: ${kind.name}',
      () async {
        final database = openMemoryDatabase();
        addTearDown(database.close);
        final clock = FixedClock(DateTime.utc(2026, 9, 8, 10));
        final repository = DriftNotificationFoundationRepository(
          database: database,
          clock: clock,
        );
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        final enabled = const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
          weeklyReviewRemindersEnabled: true,
          awaitingReportRemindersEnabled: true,
        );
        await repository.savePreferences(
          profileId: profile.id,
          preferences: enabled,
        );
        final gateway = _RacingGateway();
        final reconciler = ReminderReconciler(
          repository: repository,
          gateway: gateway,
          clock: clock,
        );
        Future<void> reconcile() => reconciler.reconcile(
          sourceKind: kind,
          profileId: profile.id,
          sourceId: 'race-source',
          occurrenceId: 'race-occurrence',
          startsAtUtc: DateTime.utc(2026, 9, 8, 11),
          globalOffsetMinutes: 5,
          categoryEnabled: true,
          systemEnabled: true,
          sourceActive: true,
          genericTitle: 'Reminder',
          genericBody: 'Due soon',
        );
        gateway.onSchedule = () async {
          await repository.savePreferences(
            profileId: profile.id,
            preferences: enabled.copyWith(systemNotificationsEnabled: false),
          );
        };
        await reconcile();
        final key = ReminderReconciler.stableKey(
          sourceKind: kind,
          profileId: profile.id,
          occurrenceId: 'race-occurrence',
        );
        expect(gateway.pendingIds, isEmpty);
        expect(
          (await repository.readWorkRequest(key))?.state,
          BackgroundWorkState.cancelledObsolete,
        );
        // Stale caller booleans cannot recreate notifications while durable OFF.
        gateway.onSchedule = null;
        await reconcile();
        expect(gateway.pendingIds, isEmpty);
        await repository.savePreferences(
          profileId: profile.id,
          preferences: enabled,
        );
        await reconcile();
        expect(gateway.pendingIds, hasLength(1));
        expect(
          (await repository.readWorkRequest(key))?.state,
          BackgroundWorkState.scheduled,
        );
      },
    );
  }

  test(
    'T4 timing-only policy save preserves existing purpose and Contact (F02)',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 8, 10));
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      final reconciler = ReminderReconciler(
        repository: repository,
        gateway: FakeNotificationGateway(),
        clock: clock,
      );
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();

      final followUp = await reconciler.savePolicy(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-follow-up',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 15,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );
      expect(followUp.purpose, ReminderPurpose.contactFollowUp);
      expect(followUp.contactId, 'contact-1');

      // Timing-only write: no purpose argument supplied.
      final retimed = await reconciler.savePolicy(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-follow-up',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 45,
      );
      expect(retimed.id, followUp.id, reason: 'same v46 policy row is reused');
      expect(retimed.offsetMinutes, 45);
      expect(
        retimed.purpose,
        ReminderPurpose.contactFollowUp,
        reason: 'F02: a timing-only save must not clear the follow-up purpose',
      );
      expect(retimed.contactId, 'contact-1');

      // Explicit standard clears the Contact without touching timing.
      final cleared = await reconciler.savePolicy(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-follow-up',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 45,
        purpose: ReminderPurpose.standard,
      );
      expect(cleared.purpose, ReminderPurpose.standard);
      expect(cleared.contactId, isNull);
      expect(cleared.offsetMinutes, 45);
    },
  );

  test(
    'T32 section 64: an Event reminder with a supplied end schedules normally',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 6, 10));
      final gateway = FakeNotificationGateway();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      final reconciler = ReminderReconciler(
        repository: repository,
        gateway: gateway,
        clock: clock,
      );
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await repository.savePreferences(
        profileId: profile.id,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
        ),
      );

      await reconciler.reconcile(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: profile.id,
        sourceId: 'event-64',
        occurrenceId: 'occ-64',
        startsAtUtc: DateTime.utc(2026, 9, 6, 10, 30),
        endsAtUtc: DateTime.utc(2026, 9, 6, 11, 30),
        globalOffsetMinutes: 0,
        categoryEnabled: true,
        systemEnabled: true,
        sourceActive: true,
        genericTitle: 'Event reminder',
        genericBody: 'Upcoming event',
      );

      final key = ReminderReconciler.stableKey(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: profile.id,
        occurrenceId: 'occ-64',
      );
      expect(gateway.scheduledRequests, hasLength(1));
      expect(
        (await repository.readWorkRequest(key))?.state,
        BackgroundWorkState.scheduled,
      );
      expect(
        (await repository.readWorkRequest(key))?.scheduledForUtc?.toUtc(),
        DateTime.utc(2026, 9, 6, 10, 30),
      );
    },
  );

  test(
    'T21/T22/T24 section 6 transport selection is sticky and native-exclusive',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 6, 10));
      final gateway = FakeNotificationGateway();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      final workerCalls = <Map<String, Object?>>[];
      final reconciler = ReminderReconciler(
        repository: repository,
        gateway: gateway,
        clock: clock,
        scheduleWorker:
            ({
              required String stableKey,
              required DateTime scheduledAtUtc,
              required String sourceRevision,
              required int platformNotificationId,
            }) async {
              workerCalls.add(<String, Object?>{
                'stable_key': stableKey,
                'scheduled_utc_ms': scheduledAtUtc.millisecondsSinceEpoch,
                'source_revision': sourceRevision,
                'platform_notification_id': platformNotificationId,
              });
            },
      );
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await repository.savePreferences(
        profileId: profile.id,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
        ),
      );

      Future<void> reconcile({required bool enriched}) => reconciler.reconcile(
        sourceKind: ReminderSourceKind.task,
        profileId: profile.id,
        sourceId: 'task-transport',
        occurrenceId: 'series',
        startsAtUtc: DateTime.utc(2026, 9, 6, 11),
        globalOffsetMinutes: 15,
        categoryEnabled: true,
        systemEnabled: true,
        sourceActive: true,
        genericTitle: '🔔 Next Transfer',
        genericBody: 'You have a new notification.',
        requiresEnrichment: enriched,
        renderRevision: 'generic',
      );

      final key = ReminderReconciler.stableKey(
        sourceKind: ReminderSourceKind.task,
        profileId: profile.id,
        occurrenceId: 'series',
      );

      // T21 — an enriched source takes worker transport and never native.
      await reconcile(enriched: true);
      expect(gateway.scheduledRequests, isEmpty);
      expect(workerCalls, hasLength(1));
      expect(
        (await repository.readWorkRequest(key))?.sourceRevision,
        'm7w_generic',
      );
      expect(workerCalls.single['stable_key'], key);
      expect(
        workerCalls.single.keys.toSet(),
        <String>{
          'stable_key',
          'scheduled_utc_ms',
          'source_revision',
          'platform_notification_id',
        },
      );

      // T24 — identical key/target/revision must not enqueue twice.
      await reconcile(enriched: true);
      expect(workerCalls, hasLength(1), reason: 'same dispatch is a no-op');

      // T22 — sticky: enrichment removed, the key stays on worker transport.
      await reconcile(enriched: false);
      expect(gateway.scheduledRequests, isEmpty);
      expect(
        (await repository.readWorkRequest(key))?.sourceRevision,
        'm7w_generic',
      );
    },
  );

  test(
    'section 6 one live owner: native→worker promotion cancels the old alarm, '
    'worker retarget releases the previous job, disable releases both',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 6, 10));
      final gateway = FakeNotificationGateway();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      final workerCalls = <String>[];
      final released = <String>[];
      final reconciler = ReminderReconciler(
        repository: repository,
        gateway: gateway,
        clock: clock,
        scheduleWorker:
            ({
              required String stableKey,
              required DateTime scheduledAtUtc,
              required String sourceRevision,
              required int platformNotificationId,
            }) async {
              workerCalls.add(
                CanonicalReminderWorkSpec.uniqueName(
                  platformNotificationId: platformNotificationId,
                  scheduledUtcMs: scheduledAtUtc.millisecondsSinceEpoch,
                  sourceRevision: sourceRevision,
                ),
              );
            },
        cancelWorker: (uniqueName) async => released.add(uniqueName),
      );
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await repository.savePreferences(
        profileId: profile.id,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
        ),
      );
      final key = ReminderReconciler.stableKey(
        sourceKind: ReminderSourceKind.task,
        profileId: profile.id,
        occurrenceId: 'series',
      );

      Future<void> reconcile({
        required bool enriched,
        required DateTime start,
        bool active = true,
      }) => reconciler.reconcile(
        sourceKind: ReminderSourceKind.task,
        profileId: profile.id,
        sourceId: 'task-owner',
        occurrenceId: 'series',
        startsAtUtc: start,
        globalOffsetMinutes: 15,
        categoryEnabled: true,
        systemEnabled: true,
        sourceActive: active,
        genericTitle: '🔔 Next Transfer',
        genericBody: 'You have a new notification.',
        requiresEnrichment: enriched,
        renderRevision: 'generic',
      );

      // A plain Task starts on native ordinary transport.  Section 6 requires
      // the transport choice to be persisted in the render suffix, so the
      // revision carries the m7n_ native marker.
      await reconcile(enriched: false, start: DateTime.utc(2026, 9, 6, 11));
      expect(gateway.scheduledRequests, hasLength(1));
      expect(workerCalls, isEmpty);
      final nativeRow = await repository.readWorkRequest(key);
      expect(nativeRow?.sourceRevision, 'm7n_generic');
      expect(
        ReminderReconciler.transportOf(nativeRow?.sourceRevision),
        'm7n_',
        reason: 'the durable row records native ordinary ownership',
      );
      final nativePlatformId = nativeRow!.platformNotificationId!;

      // Promotion: the ordinary alarm is cancelled BEFORE the worker is
      // registered, so the notice can never be posted by both owners.
      await reconcile(enriched: true, start: DateTime.utc(2026, 9, 6, 11));
      expect(gateway.cancelledIds, contains(nativePlatformId));
      expect(workerCalls, hasLength(1));
      expect(
        (await repository.readWorkRequest(key))?.sourceRevision,
        'm7w_generic',
      );

      // Retarget: a worker row whose target changes must release the exact
      // previous job (same three-value identity) before registering the new one.
      await reconcile(enriched: true, start: DateTime.utc(2026, 9, 6, 12));
      expect(workerCalls, hasLength(2));
      expect(released, <String>[workerCalls.first]);
      expect(workerCalls.first, isNot(workerCalls.last));

      // Ineligible: BOTH transports are retired, never just the platform ID.
      await reconcile(
        enriched: true,
        start: DateTime.utc(2026, 9, 6, 12),
        active: false,
      );
      expect(released, hasLength(2));
      expect(released.last, workerCalls.last);
      expect(
        (await repository.readWorkRequest(key))?.state,
        BackgroundWorkState.cancelledObsolete,
      );
    },
  );

  test(
    'M2/M3 reconciler schedules exactly one future eligible reminder and cancels it when inactive',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 6, 10));
      final gateway = FakeNotificationGateway();
      final reconciler = ReminderReconciler(
        repository: DriftNotificationFoundationRepository(
          database: database,
          clock: clock,
        ),
        gateway: gateway,
        clock: clock,
      );
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await reconciler.repository.savePreferences(
        profileId: profile.id,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
        ),
      );
      await reconciler.reconcile(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: profile.id,
        sourceId: 'event-1',
        occurrenceId: 'occurrence-1',
        startsAtUtc: DateTime.utc(2026, 9, 6, 11),
        globalOffsetMinutes: 15,
        categoryEnabled: true,
        systemEnabled: true,
        sourceActive: true,
        genericTitle: 'Upcoming event',
        genericBody: 'Your event starts soon.',
      );
      expect(gateway.scheduleCount, 1);
      await reconciler.reconcile(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: profile.id,
        sourceId: 'event-1',
        occurrenceId: 'occurrence-1',
        startsAtUtc: DateTime.utc(2026, 9, 6, 11),
        globalOffsetMinutes: 15,
        categoryEnabled: true,
        systemEnabled: true,
        sourceActive: true,
        genericTitle: 'Upcoming event',
        genericBody: 'Your event starts soon.',
      );
      expect(gateway.scheduleCount, 1, reason: 'same state is idempotent');
      await reconciler.reconcile(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: profile.id,
        sourceId: 'event-1',
        occurrenceId: 'occurrence-1',
        startsAtUtc: DateTime.utc(2026, 9, 6, 11),
        globalOffsetMinutes: 15,
        categoryEnabled: true,
        systemEnabled: true,
        sourceActive: false,
        genericTitle: 'Upcoming event',
        genericBody: 'Your event starts soon.',
      );
      expect(gateway.scheduleCount, 1);
    },
  );

  for (final sourceKind in ReminderSourceKind.values) {
    test(
      '${sourceKind.name} preview content refresh reuses identity and is idempotent',
      () async {
        final database = openMemoryDatabase();
        addTearDown(database.close);
        final clock = FixedClock(DateTime.utc(2026, 9, 6, 10));
        final gateway = FakeNotificationGateway();
        final repository = DriftNotificationFoundationRepository(
          database: database,
          clock: clock,
        );
        final reconciler = ReminderReconciler(
          repository: repository,
          gateway: gateway,
          clock: clock,
        );
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await repository.savePreferences(
          profileId: profile.id,
          preferences: const NotificationPreferences.defaults().copyWith(
            systemNotificationsEnabled: true,
            eventRemindersEnabled: true,
            taskRemindersEnabled: true,
            weeklyReviewRemindersEnabled: true,
            awaitingReportRemindersEnabled: true,
          ),
        );
        final sourceId = '${sourceKind.name}-source';
        final occurrenceId = '${sourceKind.name}-occurrence';

        Future<void> reconcile({
          required bool showDetails,
          required String revision,
        }) {
          return reconciler.reconcile(
            sourceKind: sourceKind,
            profileId: profile.id,
            sourceId: sourceId,
            occurrenceId: occurrenceId,
            startsAtUtc: DateTime.utc(2026, 9, 6, 12),
            globalOffsetMinutes: 15,
            categoryEnabled: true,
            systemEnabled: true,
            sourceActive: true,
            genericTitle: 'Generic title',
            genericBody: 'Generic body',
            detailedTitle: 'Private title',
            detailedBody: 'Private description',
            showDetails: showDetails,
            refreshContent: true,
            renderRevision: revision,
          );
        }

        await reconcile(showDetails: false, revision: 'generic');
        final key = ReminderReconciler.stableKey(
          sourceKind: sourceKind,
          profileId: profile.id,
          occurrenceId: occurrenceId,
        );
        final initial = await repository.readWorkRequest(key);
        expect(gateway.scheduledRequests.single.title, 'Generic title');

        await reconcile(showDetails: true, revision: 'detailed_1');
        expect(gateway.scheduledRequests.last.title, 'Private title');
        expect(gateway.scheduledRequests.last.body, 'Private description');
        expect(
          (await repository.readWorkRequest(key))?.platformNotificationId,
          initial?.platformNotificationId,
        );

        await reconcile(showDetails: true, revision: 'detailed_1');
        expect(gateway.scheduleCount, 2, reason: 'same render is idempotent');

        await reconcile(showDetails: false, revision: 'generic');
        expect(gateway.scheduleCount, 3);
        expect(gateway.scheduledRequests.last.title, 'Generic title');
        final rows = await database
            .select(database.backgroundWorkRequests)
            .get();
        expect(rows, hasLength(1));
        expect(
          rows.single.platformNotificationId,
          initial?.platformNotificationId,
        );
        // Both transports persist their ownership marker in the render suffix
        // (section 6 / section 33): native keeps m7n_, worker carries m7w_.
        expect(rows.single.sourceRevision, 'm7n_generic');
        expect(rows.single.toJson().values, isNot(contains('Private title')));
        expect(
          rows.single.toJson().values,
          isNot(contains('Private description')),
        );
      },
    );
  }
}

final class _RacingGateway implements NotificationGateway {
  Future<void> Function()? onSchedule;
  final Set<int> pendingIds = {};
  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> schedule(LocalNotificationRequest request) async {
    await onSchedule?.call();
    pendingIds.add(request.platformId);
  }

  @override
  Future<void> cancel(int platformId) async {
    pendingIds.remove(platformId);
  }

  @override
  Future<List<PendingLocalNotification>> pending() async =>
      pendingIds.map((id) => PendingLocalNotification(platformId: id)).toList();
  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}
