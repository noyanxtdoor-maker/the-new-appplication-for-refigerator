// OWNER REVIEW #4 — fail-first coverage for first-ever notification setup.
//
// The forensic audit proved the largest real cause of a beta user receiving
// nothing was not the Android permission at all: a new profile had
// `defaultTaskReminderMinutes == null` and EVERY delivery category `false`, and
// `ReminderReconciler` resolves a null offset to no reminder at all. A correct
// permission and a correct master toggle therefore still produced zero
// notifications, because nothing had ever been configured to notify about.
//
// This file pins the two halves of the owner's decision:
//   * a profile that has NEVER been configured receives the owner-approved
//     defaults once, and
//   * a profile that HAS been configured keeps every deliberate choice, even
//     when the Android permission is later revoked and re-granted.
//
// The sentinel is the absence of the `notification_preferences` row, so the
// second half is proven by writing a partial configuration first and showing the
// seeding refuses to touch it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/notifications/application/notification_first_run_setup.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/test_dependencies.dart';

void main() {
  late ProviderContainer container;
  late NotificationFoundationRepository repository;
  late String profileId;
  late List<int> seededEventDefaults;

  Future<void> buildContainer() async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startupRepository = buildTestRepository(database: database);
    profileId = (await startupRepository.completeOnboarding()).id;
    repository = DriftNotificationFoundationRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 18, 12)),
    );
    seededEventDefaults = <int>[];
    container = ProviderContainer(
      overrides: <Override>[
        startupRepositoryProvider.overrideWithValue(startupRepository),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        // The Event default is a Planner setting, so the seam records the write
        // instead of standing up the whole Planner graph.
        eventDefaultReminderSeederProvider.overrideWithValue(
          (int minutes) async => seededEventDefaults.add(minutes),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  test('a brand-new profile has no stored preferences', () async {
    await buildContainer();
    expect(await repository.hasPreferences(profileId: profileId), isFalse);
    expect(
      await repository.readPreferences(profileId: profileId),
      const NotificationPreferences.defaults(),
      reason: 'reading must never create a row, so the sentinel stays absent',
    );
    expect(await repository.hasPreferences(profileId: profileId), isFalse);
  });

  test('first-ever setup seeds every owner-approved default exactly once',
      () async {
    await buildContainer();
    final seeded = await container
        .read(notificationFirstRunSetupProvider)
        .seedIfNeverConfigured(profileId: profileId);

    expect(seeded, isTrue);
    final stored = await repository.readPreferences(profileId: profileId);
    expect(stored.systemNotificationsEnabled, isTrue);
    expect(stored.eventRemindersEnabled, isTrue);
    expect(stored.taskRemindersEnabled, isTrue);
    expect(stored.weeklyReviewRemindersEnabled, isTrue);
    expect(stored.awaitingReportRemindersEnabled, isTrue);
    expect(stored.goalCompletionNotificationsEnabled, isTrue);
    expect(stored.inAppGoalCelebrationsEnabled, isTrue);
    // The owner's 10-minute law. The audit proved the previous value was NULL
    // ("no default reminder"), not 5 minutes.
    expect(stored.defaultTaskReminderMinutes, 10);
    expect(NotificationFirstRunSetup.defaultReminderLeadMinutes, 10);
    // Quiet Hours OFF for a new user.
    expect(stored.quietHours.enabled, isFalse);
    // The Event-side default is seeded through the Planner seam.
    expect(seededEventDefaults, <int>[10]);
    // runApp-free: the seeded value must match the published constant exactly.
    expect(stored, NotificationFirstRunSetup.ownerApprovedDefaults);
  });

  test('an already-configured profile is never overwritten', () async {
    await buildContainer();
    // A returning user who deliberately turned Goal notifications off and
    // configured quiet hours, then lost and re-granted the OS permission.
    const deliberate = NotificationPreferences(
      systemNotificationsEnabled: true,
      eventRemindersEnabled: true,
      taskRemindersEnabled: false,
      weeklyReviewRemindersEnabled: false,
      awaitingReportRemindersEnabled: false,
      goalCompletionNotificationsEnabled: false,
      inAppGoalCelebrationsEnabled: true,
      defaultTaskReminderMinutes: 30,
      snoozeDurationMinutes: 20,
      quietHours: QuietHoursSettings(
        enabled: true,
        startMinute: 1320,
        endMinute: 420,
      ),
    );
    await repository.savePreferences(
      profileId: profileId,
      preferences: deliberate,
    );

    final seeded = await container
        .read(notificationFirstRunSetupProvider)
        .seedIfNeverConfigured(profileId: profileId);

    expect(seeded, isFalse, reason: 'nothing may be re-seeded');
    expect(await repository.readPreferences(profileId: profileId), deliberate);
    expect(
      seededEventDefaults,
      isEmpty,
      reason: 'the Event default must not be touched either',
    );
  });

  test('seeding is idempotent across repeated first-run attempts', () async {
    await buildContainer();
    final setup = container.read(notificationFirstRunSetupProvider);
    expect(await setup.seedIfNeverConfigured(profileId: profileId), isTrue);
    expect(await setup.seedIfNeverConfigured(profileId: profileId), isFalse);
    expect(await setup.seedIfNeverConfigured(profileId: profileId), isFalse);
    expect(seededEventDefaults, <int>[10]);
  });

  test(
    'a 10-minute default still cannot invent a time for a date-only Task',
    () async {
      // The suppression law itself is pinned end-to-end by
      // `m8_task_recurrence_test.dart` T55 ("a date-only Task never projects")
      // and `task_reminder_source_test.dart` ("pending reminder source excludes
      // date-only and out-of-range Tasks"). Both exclude on `dueMinute == null`
      // BEFORE any offset is resolved, so the seeded default cannot fabricate a
      // reminder time: it is applied to `startsAtUtc` only after an occurrence
      // already exists. This test pins the value the offset is seeded to.
      await buildContainer();
      await container
          .read(notificationFirstRunSetupProvider)
          .seedIfNeverConfigured(profileId: profileId);
      final stored = await repository.readPreferences(profileId: profileId);
      expect(stored.defaultTaskReminderMinutes, 10);
      expect(
        stored.defaultTaskReminderMinutes,
        greaterThan(0),
        reason: 'a zero offset would fire at the due minute, never "before"',
      );
    },
  );
}
