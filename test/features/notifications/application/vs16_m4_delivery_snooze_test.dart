import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/database/app_database.dart'
    hide NotificationPreferences;
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import '../../../support/test_dependencies.dart';

void main() {
  // VS16 owner decision: Snooze is deferred from the current product. These
  // tests keep proving the dormant runtime contract (durable targets,
  // generation idempotency, stale-source suppression) that remains reachable
  // through the recovery/runtime boundary, without any user-facing action.
  for (final kind in ReminderSourceKind.values) {
    test('${kind.name}: durable/pending mismatch repaired once', () async {
      final h = await _Harness.create(kind);
      await h.reconcile();
      h.gateway.pendingIds.clear();
      await h.reconcile();
      await h.reconcile();
      expect(h.gateway.scheduled, hasLength(2));
      expect(
        (await h.work())!.platformNotificationId,
        h.gateway.scheduled.first.platformId,
      );
    });
    test(
      '${kind.name}: process loss after durable write recovers future work',
      () async {
        final h = await _Harness.create(kind);
        h.gateway.failSchedule = true;
        await expectLater(h.reconcile(), throwsStateError);
        expect((await h.work())!.state, BackgroundWorkState.queued);
        h.gateway.failSchedule = false;
        await h.reconcile();
        expect((await h.work())!.state, BackgroundWorkState.scheduled);
      },
    );
    test('${kind.name}: expired startup never replays', () async {
      final h = await _Harness.create(kind);
      await h.reconcile();
      h.now = h.target.add(const Duration(minutes: 1));
      h.gateway.pendingIds.clear();
      await h.reconcile();
      expect(h.gateway.shown, isEmpty);
      expect((await h.work())!.state, BackgroundWorkState.cancelledObsolete);
    });
    for (final minutes in [1, 2]) {
      test(
        '${kind.name}: native delivery survives recovery before Snooze $minutes min',
        () async {
          final h = await _Harness.create(kind);
          await h.repository.savePreferences(
            profileId: h.profileId,
            preferences: _allFamiliesEnabled(snoozeDurationMinutes: minutes),
          );
          await h.reconcile();
          final original = (await h.work())!;
          h.now = h.target.add(const Duration(seconds: 20));
          h.gateway.pendingIds.clear();
          h.gateway.displayedIds.add(original.platformNotificationId!);
          // A different reminder's Snooze worker runs the full horizon first.
          await h.reconcile();
          expect((await h.work())!.state, BackgroundWorkState.completed);
          await h.reconcile(snoozeGeneration: 0);
          final snoozed = (await h.work())!;
          expect(snoozed.snoozeCount, 1);
          expect(
            snoozed.snoozedUntilUtc!.toUtc(),
            h.now.add(Duration(minutes: minutes)),
          );
          expect(
            snoozed.platformNotificationId,
            original.platformNotificationId,
          );
          expect(
            h.gateway.scheduled.last.scheduledAtUtc,
            snoozed.snoozedUntilUtc!.toUtc(),
          );
          await h.repository.savePreferences(
            profileId: h.profileId,
            preferences: _allFamiliesEnabled(snoozeDurationMinutes: 30),
          );
          await h.reconcile(snoozeGeneration: 0);
          expect((await h.work())!.snoozedUntilUtc, snoozed.snoozedUntilUtc);
          expect((await h.work())!.snoozeCount, 1);
          expect(h.gateway.scheduled, hasLength(2));
          // Native inexact delivery is still pending after its nominal target.
          h.now = snoozed.scheduledForUtc!.add(const Duration(seconds: 30));
          await h.reconcile();
          expect((await h.work())!.state, BackgroundWorkState.scheduled);
          expect(
            h.gateway.pendingIds,
            contains(original.platformNotificationId),
          );
          expect(h.gateway.scheduled, hasLength(2));
          h.gateway.pendingIds.clear();
          h.gateway.displayedIds.add(original.platformNotificationId!);
          await h.reconcile();
          await h.reconcile(snoozeGeneration: 1);
          // Keep the second Snooze relevant for Events as well.
          expect((await h.work())!.snoozeCount, 2);
          expect(
            await h.database.select(h.database.backgroundWorkRequests).get(),
            hasLength(1),
          );
          expect(
            await h.database.select(h.database.plannerTasks).get(),
            isEmpty,
          );
          expect(
            await h.database.select(h.database.calendarEvents).get(),
            isEmpty,
          );
        },
      );
    }
    for (final reason in ['source', 'master', 'category', 'revision']) {
      test(
        '${kind.name}: native display does not bypass $reason suppression',
        () async {
          final h = await _Harness.create(kind);
          await h.reconcile();
          h.now = h.target.add(const Duration(seconds: 20));
          h.gateway.pendingIds.clear();
          h.gateway.displayedIds.add((await h.work())!.platformNotificationId!);
          if (reason == 'source') h.active = false;
          if (reason == 'master') h.system = false;
          if (reason == 'category') h.category = false;
          if (reason == 'revision') h.version++;
          await h.reconcile();
          await h.reconcile(snoozeGeneration: 0);
          expect(
            (await h.work())!.state,
            BackgroundWorkState.cancelledObsolete,
          );
          expect((await h.work())!.snoozeCount, 0);
          expect(h.gateway.displayedIds, isEmpty);
        },
      );
    }
    test('${kind.name}: delivery rechecks truth and completes once', () async {
      final h = await _Harness.create(kind);
      await h.reconcile();
      h.now = h.target.add(const Duration(seconds: 5));
      await h.reconcile(delivery: true);
      await h.reconcile(delivery: true);
      expect(h.gateway.shown, hasLength(1));
      expect((await h.work())!.state, BackgroundWorkState.completed);
    });
    test(
      '${kind.name}: Snooze is ten minutes and duplicate action is rejected',
      () async {
        final h = await _Harness.create(kind);
        await h.deliver();
        final original = await h.work();
        await h.reconcile(snoozeGeneration: 0);
        final snoozed = await h.work();
        expect(snoozed!.snoozeCount, 1);
        expect(
          snoozed.snoozedUntilUtc!.isAtSameMomentAs(
            h.now.add(const Duration(minutes: 10)),
          ),
          isTrue,
        );
        expect(
          snoozed.platformNotificationId,
          original!.platformNotificationId,
        );
        await h.reconcile(snoozeGeneration: 0);
        expect((await h.work())!.snoozeCount, 1);
        expect(
          await h.database.select(h.database.backgroundWorkRequests).get(),
          hasLength(1),
        );
        h.now = snoozed.scheduledForUtc!.toUtc();
        await h.reconcile(delivery: true);
        expect(h.gateway.shown, hasLength(2));
        await h.reconcile(snoozeGeneration: 1);
        expect((await h.work())!.snoozeCount, 2);
      },
    );
    for (final reason in ['source', 'master', 'category', 'permission']) {
      test(
        '${kind.name}: $reason disable suppresses delayed delivery and Snooze',
        () async {
          final h = await _Harness.create(kind);
          await h.deliver();
          await h.reconcile(snoozeGeneration: 0);
          if (reason == 'source') h.active = false;
          if (reason == 'master' || reason == 'permission') h.system = false;
          if (reason == 'category') h.category = false;
          h.now = (await h.work())!.scheduledForUtc!.toUtc();
          await h.reconcile(delivery: true);
          expect(h.gateway.shown, hasLength(1));
          expect(
            (await h.work())!.state,
            BackgroundWorkState.cancelledObsolete,
          );
        },
      );
    }
    test('${kind.name}: source reschedule invalidates old Snooze', () async {
      final h = await _Harness.create(kind);
      await h.deliver();
      await h.reconcile(snoozeGeneration: 0);
      h.version++;
      h.start = h.start.add(const Duration(hours: 2));
      await h.reconcile();
      expect((await h.work())!.snoozeCount, 0);
      expect((await h.work())!.snoozedUntilUtc, isNull);
      expect(
        (await h.work())!.scheduledForUtc!.isAtSameMomentAs(h.target),
        isTrue,
      );
    });
    test('${kind.name}: policy change invalidates old Snooze', () async {
      final h = await _Harness.create(kind);
      await h.deliver();
      await h.reconcile(snoozeGeneration: 0);
      await h.reconciler().savePolicy(
        profileId: h.profileId,
        sourceKind: kind,
        sourceId: 'source',
        occurrenceId: 'occurrence',
        mode: ReminderPolicyMode.off,
      );
      await h.reconcile();
      expect((await h.work())!.state, BackgroundWorkState.cancelledObsolete);
    });
    test(
      '${kind.name}: privacy rendering changes without changing Snooze identity',
      () async {
        final h = await _Harness.create(kind);
        await h.deliver();
        await h.reconcile(snoozeGeneration: 0);
        h.details = false;
        await h.reconcile();
        expect((await h.work())!.snoozeCount, 1);
        h.now = (await h.work())!.scheduledForUtc!.toUtc();
        await h.reconcile(delivery: true);
        expect(h.gateway.shown.last.title, 'Generic');
        final row =
            (await h.database.select(h.database.backgroundWorkRequests).get())
                .single;
        expect(row.sourceRevision, isNot(contains('Private')));
        expect(await h.database.select(h.database.plannerTasks).get(), isEmpty);
        expect(
          await h.database.select(h.database.calendarEvents).get(),
          isEmpty,
        );
      },
    );
    test('${kind.name}: Open never changes delivery or Snooze count', () async {
      final h = await _Harness.create(kind);
      await h.deliver();
      final before = await h.work();
      await h.reconcile(openAction: true);
      expect((await h.work())!.snoozeCount, before!.snoozeCount);
      expect(h.gateway.shown, hasLength(1));
    });
  }
  for (final kind in ReminderSourceKind.values) {
    test('${kind.name}: Quiet Hours delay while still relevant', () async {
      final h = await _Harness.create(kind);
      h.now = DateTime(2026, 9, 7, 20).toUtc();
      h.start = DateTime(2026, 9, 8, 8).toUtc();
      h.offset = 600; // 22:00 previous evening.
      await h.quiet();
      await h.reconcile();
      expect(
        (await h.work())!.scheduledForUtc!.isAtSameMomentAs(
          DateTime(2026, 9, 8, 7).toUtc(),
        ),
        isTrue,
      );
      await h.reconcile();
      expect(h.gateway.scheduled, hasLength(1));
    });
  }
  test('Event starting before Quiet Hours end is suppressed', () async {
    final h = await _Harness.create(ReminderSourceKind.calendarEvent);
    h.now = DateTime(2026, 9, 7, 20).toUtc();
    h.start = DateTime(2026, 9, 7, 23).toUtc();
    h.offset = 60;
    await h.quiet();
    await h.reconcile();
    expect(h.gateway.scheduled, isEmpty);
  });
  test(
    'Task crossing midnight retains delayed delivery while incomplete',
    () async {
      final h = await _Harness.create(ReminderSourceKind.task);
      h.now = DateTime(2026, 9, 7, 20).toUtc();
      h.start = DateTime(2026, 9, 7, 23).toUtc();
      h.offset = 60;
      await h.quiet();
      await h.reconcile();
      h.now = DateTime(2026, 9, 8, 7).toUtc();
      await h.reconcile(delivery: true);
      expect(h.gateway.shown, hasLength(1));
    },
  );
  test('obsolete Event at inexact fire is suppressed', () async {
    final h = await _Harness.create(ReminderSourceKind.calendarEvent);
    await h.reconcile();
    h.now = h.start.add(const Duration(minutes: 1));
    await h.reconcile(delivery: true);
    expect(h.gateway.shown, isEmpty);
  });
  test(
    'Snooze target in Quiet Hours is delayed without changing its ten-minute timestamp',
    () async {
      final h = await _Harness.create(ReminderSourceKind.task);
      h.now = DateTime(2026, 9, 7, 21, 30).toUtc();
      h.start = DateTime(2026, 9, 7, 22, 30).toUtc();
      h.offset = 40;
      await h.quiet();
      await h.deliver();
      await h.reconcile(snoozeGeneration: 0);
      final work = (await h.work())!;
      expect(
        work.snoozedUntilUtc!.isAtSameMomentAs(
          DateTime(2026, 9, 7, 22).toUtc(),
        ),
        isTrue,
      );
      expect(
        work.scheduledForUtc!.isAtSameMomentAs(DateTime(2026, 9, 8, 7).toUtc()),
        isTrue,
      );
    },
  );
}

/// VS16 M4 harness preconditions.
///
/// The reconciler gates every reminder family on its OWN persisted category
/// flag ([NotificationPreferences.weeklyReviewRemindersEnabled] and
/// [NotificationPreferences.awaitingReportRemindersEnabled] for the two
/// planning families). A harness that enables only the Event/Task flags makes
/// the planning families permanently ineligible, so the reconciler correctly
/// writes no durable row for them and every planning assertion observes an
/// empty contract. Enable every family the enum defines so the family under
/// test is eligible for the reason each test intends, and so a later
/// suppression test still suppresses through its own explicit flag.
NotificationPreferences _allFamiliesEnabled({
  int snoozeDurationMinutes = 10,
  QuietHoursSettings? quietHours,
}) => NotificationPreferences.defaults().copyWith(
  systemNotificationsEnabled: true,
  eventRemindersEnabled: true,
  taskRemindersEnabled: true,
  weeklyReviewRemindersEnabled: true,
  awaitingReportRemindersEnabled: true,
  snoozeDurationMinutes: snoozeDurationMinutes,
  quietHours: quietHours,
);

final class _Harness {
  _Harness(this.kind, this.database, this.repository, this.profileId);
  final ReminderSourceKind kind;
  final AppDatabase database;
  final DriftNotificationFoundationRepository repository;
  final String profileId;
  final gateway = _Gateway();
  DateTime now = DateTime.utc(2026, 9, 7, 9);
  DateTime start = DateTime.utc(2026, 9, 7, 12);
  int offset = 60;
  int version = 1;
  bool active = true, system = true, category = true, details = true;
  DateTime get target => start.subtract(Duration(minutes: offset));
  String get key => ReminderReconciler.stableKey(
    sourceKind: kind,
    profileId: profileId,
    occurrenceId: 'occurrence',
  );
  static Future<_Harness> create(ReminderSourceKind kind) async {
    final db = openMemoryDatabase();
    addTearDown(db.close);
    final profile = await buildTestRepository(
      database: db,
    ).completeOnboarding();
    final harness = _Harness(
      kind,
      db,
      DriftNotificationFoundationRepository(
        database: db,
        clock: FixedClock(DateTime.utc(2026, 9, 7)),
      ),
      profile.id,
    );
    await harness.repository.savePreferences(
      profileId: profile.id,
      preferences: _allFamiliesEnabled(),
    );
    return harness;
  }

  Future<BackgroundWorkRequest?> work() => repository.readWorkRequest(key);
  ReminderReconciler reconciler({
    bool delivery = false,
    int? snoozeGeneration,
    bool openAction = false,
    DateTime? scheduled,
  }) => ReminderReconciler(
    repository: repository,
    gateway: gateway,
    clock: FixedClock(now),
    deliveryKey: delivery ? key : null,
    deliveryScheduledAtUtc: scheduled,
    actionAtUtc: now,
    snoozeIntent: snoozeGeneration != null || openAction
        ? NotificationResponseIntent(
            profileId: profileId,
            // The persisted intent must name the SAME source family the
            // reconciler is reconciling: its Snooze/Open guard compares
            // `action.sourceKind.name` with the reconciled `sourceKind.name`.
            // Production derives this from the delivered payload and maps the
            // two enums one-to-one (reminder_reconciler Section 6/64 transport
            // mapping), so a collapsed two-way test mapping silently rejected
            // every planning-family Snooze and the durable row never advanced.
            sourceKind: switch (kind) {
              ReminderSourceKind.calendarEvent =>
                NotificationSourceKind.calendarEvent,
              ReminderSourceKind.task => NotificationSourceKind.task,
              ReminderSourceKind.weeklyReview =>
                NotificationSourceKind.weeklyReview,
              ReminderSourceKind.awaitingReport =>
                NotificationSourceKind.awaitingReport,
            },
            sourceId: 'source',
            occurrenceId: 'occurrence',
            generation: snoozeGeneration ?? 0,
            action: openAction
                ? NotificationResponseAction.open
                : NotificationResponseAction.snooze,
          )
        : null,
  );
  Future<void> reconcile({
    bool delivery = false,
    int? snoozeGeneration,
    bool openAction = false,
  }) async {
    final worker = reconciler(
      delivery: delivery,
      snoozeGeneration: snoozeGeneration,
      openAction: openAction,
      scheduled: (await work())?.scheduledForUtc?.toUtc(),
    );
    await worker.reconcile(
      sourceKind: kind,
      profileId: profileId,
      sourceId: 'source',
      occurrenceId: 'occurrence',
      startsAtUtc: start,
      globalOffsetMinutes: offset,
      categoryEnabled: category,
      systemEnabled: system,
      sourceActive: active,
      sourceVersion: version,
      genericTitle: 'Generic',
      genericBody: 'Generic body',
      detailedTitle: 'Private title',
      detailedBody: 'Private notes',
      showDetails: details,
      renderRevision: details ? 'detailed' : 'generic',
    );
  }

  Future<void> deliver() async {
    await reconcile();
    now = target;
    await reconcile(delivery: true);
  }

  Future<void> quiet() => repository.savePreferences(
    profileId: profileId,
    preferences: _allFamiliesEnabled(
      quietHours: const QuietHoursSettings(
        enabled: true,
        startMinute: 1320,
        endMinute: 420,
      ),
    ),
  );
}

final class _Gateway
    implements NotificationGateway, CanonicalReminderDeliveryGateway {
  final scheduled = <LocalNotificationRequest>[];
  final shown = <LocalNotificationRequest>[];
  final pendingIds = <int>{};
  final displayedIds = <int>{};
  bool failSchedule = false;
  @override
  Future<void> initialize() async {}
  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();
  @override
  NotificationResponseIntent? takeInitialResponse() => null;
  @override
  Future<List<PendingLocalNotification>> pending() async => [];
  @override
  Future<bool> hasPendingReminder(int id, DateTime at) async =>
      pendingIds.contains(id);
  @override
  Future<bool> hasDisplayedReminder(int id) async => displayedIds.contains(id);
  @override
  Future<void> schedule(LocalNotificationRequest request) async {
    if (failSchedule) throw StateError('process loss before scheduling');
    scheduled.add(request);
    pendingIds.add(request.platformId);
  }

  @override
  Future<void> cancel(int id) async {
    displayedIds.remove(id);
    pendingIds.remove(id);
  }

  @override
  Future<void> showCanonicalReminder(LocalNotificationRequest request) async {
    shown.add(request);
    pendingIds.remove(request.platformId);
  }
}
