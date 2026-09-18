// OWNER RULING (2026-09-18) — the global reminder defaults are 10 MINUTES.
//
// Background: the owner's restored beta profile carried NULL for BOTH global
// defaults, and `_leadLabel(null)` renders that as "Off". The previous pass
// deliberately preserved it (the restored row is a `configured` profile, so
// first-run seeding never touches it). The owner has now overridden that
// result for the beta: the Event and timed-Task defaults are 10 minutes before,
// and the selectors must say so.
//
// The ruling changes ONE thing: the value of the two global defaults. It must
// not reach past that, so these tests pin the law at exactly the three layers
// the report has to show — persisted, displayed, effective — and then pin the
// boundary the ruling must never cross.
//
// THE BOUNDARY: a Task with no due time has no `dueMinute`. A 10-minute default
// must therefore never invent a reminder time for a date-only Task. That is not
// a detail — "10 minutes before the due time" is meaningless when there is no
// due time, and fabricating one would notify the user at a time they never
// chose. `startsAtUtc` stays null for a date-only Task, `baseFireAt` resolves to
// null, and nothing is scheduled even while the global default says 10.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy_label.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/settings/presentation/notifications_settings_screen.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/test_dependencies.dart';

/// The owner's ruled lead time, in one place so every layer asserts the same
/// number and a future change cannot update one layer and forget another.
const int _ruledLeadMinutes = 10;

void main() {
  group('EFFECTIVE — the 10 minute default resolves against the source time', () {
    late DriftNotificationFoundationRepository repository;
    late FakeNotificationGateway gateway;
    late ReminderReconciler reconciler;
    late String profileId;

    setUp(() async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 18, 12));
      repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
      await repository.savePreferences(
        profileId: profileId,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
          defaultTaskReminderMinutes: _ruledLeadMinutes,
        ),
      );
      gateway = FakeNotificationGateway();
      reconciler = ReminderReconciler(
        repository: repository,
        gateway: gateway,
        clock: clock,
      );
    });

    Future<void> reconcile({
      required ReminderSourceKind kind,
      required DateTime? startsAtUtc,
      required String occurrenceId,
    }) => reconciler.reconcile(
      sourceKind: kind,
      profileId: profileId,
      sourceId: 'ruling-source',
      occurrenceId: occurrenceId,
      startsAtUtc: startsAtUtc,
      // This is the value the Planner settings and the notification
      // preferences publish as the profile's global default.
      globalOffsetMinutes: _ruledLeadMinutes,
      categoryEnabled: true,
      systemEnabled: true,
      sourceActive: true,
      genericTitle: 'Reminder',
      genericBody: 'Due soon',
    );

    test('a timed Event inheriting the default fires 10 minutes before start',
        () async {
      final start = DateTime.utc(2026, 9, 18, 15);
      await reconcile(
        kind: ReminderSourceKind.calendarEvent,
        startsAtUtc: start,
        occurrenceId: 'event-occurrence',
      );
      expect(gateway.scheduledRequests, hasLength(1));
      expect(
        gateway.scheduledRequests.single.scheduledAtUtc,
        start.subtract(const Duration(minutes: _ruledLeadMinutes)),
      );
    });

    test('a timed Task inheriting the default fires 10 minutes before due',
        () async {
      // A TIMED Task hands the reconciler its resolved due instant as
      // `startsAtUtc` (due date + due minute).
      final due = DateTime.utc(2026, 9, 18, 14, 30);
      await reconcile(
        kind: ReminderSourceKind.task,
        startsAtUtc: due,
        occurrenceId: 'task-occurrence',
      );
      expect(gateway.scheduledRequests, hasLength(1));
      expect(
        gateway.scheduledRequests.single.scheduledAtUtc,
        due.subtract(const Duration(minutes: _ruledLeadMinutes)),
      );
    });

    test(
      'a DATE-ONLY Task schedules nothing even while the default says 10',
      () async {
        // The date-only Task reaches the reconciler with NO instant at all,
        // because the source reader excludes tasks without a `dueMinute`. The
        // 10-minute default must not manufacture one.
        await reconcile(
          kind: ReminderSourceKind.task,
          startsAtUtc: null,
          occurrenceId: 'date-only-task-occurrence',
        );
        expect(
          gateway.scheduledRequests,
          isEmpty,
          reason: 'a date-only Task has no due time to be 10 minutes before',
        );
        expect(
          await repository.readWorkRequest(
            ReminderReconciler.stableKey(
              sourceKind: ReminderSourceKind.task,
              profileId: profileId,
              occurrenceId: 'date-only-task-occurrence',
            ),
          ),
          isNull,
          reason: 'no durable work may be written for a date-only Task',
        );
      },
    );

    test('the offset is genuinely read from the default, not hard coded',
        () async {
      // Guards the previous test from passing for the wrong reason: with a
      // different global default the same timed Task moves by that amount.
      final due = DateTime.utc(2026, 9, 18, 14, 30);
      await reconciler.reconcile(
        sourceKind: ReminderSourceKind.task,
        profileId: profileId,
        sourceId: 'ruling-source',
        occurrenceId: 'other-offset',
        startsAtUtc: due,
        globalOffsetMinutes: 30,
        categoryEnabled: true,
        systemEnabled: true,
        sourceActive: true,
        genericTitle: 'Reminder',
        genericBody: 'Due soon',
      );
      expect(
        gateway.scheduledRequests.single.scheduledAtUtc,
        due.subtract(const Duration(minutes: 30)),
      );
    });
  });

  group('DISPLAYED — the two selectors read the ruled lead time', () {
    late ProviderContainer container;
    late NotificationFoundationRepository repository;
    late DriftEventTypeRepository eventTypes;
    late String profileId;

    Future<void> buildContainer({
      required int? storedEventMinutes,
      required int? storedTaskMinutes,
    }) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 18, 12));
      final startupRepository = buildTestRepository(database: database);
      profileId = (await startupRepository.completeOnboarding()).id;
      repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      await repository.savePreferences(
        profileId: profileId,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
          defaultTaskReminderMinutes: storedTaskMinutes,
        ),
      );
      eventTypes = DriftEventTypeRepository(database: database, clock: clock);
      if (storedEventMinutes != null) {
        final settings = await eventTypes.readPlannerSettings(
          profileId: profileId,
        );
        await eventTypes.savePlannerSettings(
          profileId: profileId,
          settings: settings.copyWith(
            defaultReminderMinutes: storedEventMinutes,
          ),
        );
      }
      final privacy = TestPrivacyDependencies(
        database: database,
        permissionGateway: FakePermissionGateway(
          states: <OptionalPermission, OperatingSystemPermissionState>{
            OptionalPermission.notifications:
                OperatingSystemPermissionState.granted,
          },
        ),
      );
      container = ProviderContainer(
        overrides: <Override>[
          startupRepositoryProvider.overrideWithValue(startupRepository),
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
          privacyRepositoryProvider.overrideWithValue(privacy.repository),
          privacyGateProvider.overrideWithValue(privacy.gate),
          deviceAuthenticatorProvider.overrideWithValue(privacy.authenticator),
          permissionGatewayProvider.overrideWithValue(privacy.permissionGateway),
          notificationFoundationRepositoryProvider.overrideWithValue(repository),
          notificationGatewayProvider.overrideWithValue(FakeNotificationGateway()),
          backgroundWorkGatewayProvider.overrideWithValue(
            FakeBackgroundWorkGateway(),
          ),
          eventTypeRepositoryProvider.overrideWithValue(eventTypes),
        ],
      );
      addTearDown(container.dispose);
      await container.read(startupControllerProvider.notifier).initialize();
    }

    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(431, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: NotificationsSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('both global default rows show the ruled lead time',
        (tester) async {
      await buildContainer(
        storedEventMinutes: _ruledLeadMinutes,
        storedTaskMinutes: _ruledLeadMinutes,
      );
      await pumpScreen(tester);

      final label = ReminderPolicyLabel.offsetMinutes(_ruledLeadMinutes);
      expect(label, '10 minutes before');
      expect(
        find.text(label),
        findsNWidgets(2),
        reason: 'the Event and the Task default must both read 10 minutes',
      );
      expect(
        find.text('Off'),
        findsNothing,
        reason: 'the owner does not want the beta selectors showing Off',
      );
    });

    testWidgets(
      'an UNSET default still reads Off — the value this ruling replaces',
      (tester) async {
        // Documents exactly why the owner's profile needed a write rather than
        // a rendering change: NULL is a real, user-selectable choice ("Off"),
        // so it cannot be silently reinterpreted as 10.
        await buildContainer(storedEventMinutes: null, storedTaskMinutes: null);
        await pumpScreen(tester);
        expect(find.text('Off'), findsNWidgets(2));
      },
    );
  });

  group('PERSISTED — the values are durable, not derived at render time', () {
    test('both defaults survive a restart-equivalent reopen', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 18, 12));
      final profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;

      final first = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      await first.savePreferences(
        profileId: profileId,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          defaultTaskReminderMinutes: _ruledLeadMinutes,
        ),
      );
      final eventTypes = DriftEventTypeRepository(
        database: database,
        clock: clock,
      );
      final settings = await eventTypes.readPlannerSettings(
        profileId: profileId,
      );
      await eventTypes.savePlannerSettings(
        profileId: profileId,
        settings: settings.copyWith(
          defaultReminderMinutes: _ruledLeadMinutes,
        ),
      );

      // A fresh repository over the same database is the "restart" boundary:
      // nothing is cached in the object graph, so a value that only existed in
      // memory would read back null here.
      final reopened = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      expect(
        (await reopened.readPreferences(
          profileId: profileId,
        )).defaultTaskReminderMinutes,
        _ruledLeadMinutes,
      );
      expect(
        (await DriftEventTypeRepository(
          database: database,
          clock: clock,
        ).readPlannerSettings(profileId: profileId)).defaultReminderMinutes,
        _ruledLeadMinutes,
      );
    });

    test('a restored row carrying 10 is left exactly as restored', () async {
      // Restore must not corrupt the values: the restored payload is what the
      // profile reads afterwards.
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 18, 12));
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      final profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
      final restored = const NotificationPreferences.defaults().copyWith(
        systemNotificationsEnabled: true,
        eventRemindersEnabled: true,
        quietHours: const QuietHoursSettings(
          enabled: true,
          startMinute: 1320,
          endMinute: 420,
        ),
        defaultTaskReminderMinutes: _ruledLeadMinutes,
      );
      await repository.savePreferences(
        profileId: profileId,
        preferences: restored,
      );
      expect(
        await repository.readPreferences(profileId: profileId),
        restored,
        reason: 'a genuine 10 must survive a restore round trip intact',
      );
    });
  });
}
