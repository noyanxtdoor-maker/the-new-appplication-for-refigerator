// OWNER REVIEW #4 STRAIGHTFIX — fail-first coverage for the notification setup
// EDGE and the SEMANTIC first-run sentinel.
//
// The straightfix audit proved two separate defects that this file pins:
//
//   1. First-run initialization lived inside `requestPermission`, which the
//      enable path SKIPS whenever Android permission is already granted. A
//      profile in that state enabled the master over an uninitialized snapshot
//      and kept all-false categories plus NULL defaults permanently. That is why
//      the Planner education and the Settings screen produced DIFFERENT setups.
//      => `pre-granted Settings enable seeds exactly like the Planner path` and
//         `Planner and Settings setups are field-for-field identical` below fail
//         against the pre-straightfix code.
//
//   2. The sentinel was raw row existence, but the Detailed content store
//      INSERTS that same `notification_preferences` row to hold its five
//      columns. A user who opened Settings and touched one Detailed switch
//      before granting the permission therefore marked the profile as
//      "configured" forever and could never receive the approved defaults.
//      => `a Detailed-content-only row does not poison setup` fails against the
//         pre-straightfix code.
//
// The law under test, in the owner's words: initialization belongs to a
// SUCCESSFUL SYSTEM-NOTIFICATIONS ENABLE, and an established or restored
// configuration is never overwritten.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
// The generated TABLE shares the domain preference class's name; the domain type
// is the one this suite means everywhere.
import 'package:rmplanner/core/database/app_database.dart'
    hide NotificationPreferences;
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/detailed_content_providers.dart';
import 'package:rmplanner/features/notifications/application/notification_first_run_setup.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/test_dependencies.dart';

void main() {
  late ProviderContainer container;
  late FakePermissionGateway permissionGateway;
  late NotificationFoundationRepository repository;
  late AppDatabase database;
  late String profileId;

  /// Builds a container whose notification graph is REAL Drift storage, so every
  /// assertion below reads PERSISTED truth rather than an in-memory fake.
  Future<void> buildContainer({
    Map<OptionalPermission, OperatingSystemPermissionState>? states,
    OperatingSystemPermissionState requestResult =
        OperatingSystemPermissionState.granted,
  }) async {
    database = openMemoryDatabase();
    addTearDown(database.close);
    final startupRepository = buildTestRepository(database: database);
    profileId = (await startupRepository.completeOnboarding()).id;
    repository = DriftNotificationFoundationRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 18, 12)),
    );
    final privacy = TestPrivacyDependencies(
      database: database,
      permissionGateway: FakePermissionGateway(
        states: states,
        requestResult: requestResult,
      ),
    );
    permissionGateway = privacy.permissionGateway;
    container = ProviderContainer(
      overrides: <Override>[
        startupRepositoryProvider.overrideWithValue(startupRepository),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        privacyRepositoryProvider.overrideWithValue(privacy.repository),
        permissionGatewayProvider.overrideWithValue(privacy.permissionGateway),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(_FakeNotificationGateway()),
        backgroundWorkGatewayProvider.overrideWithValue(
          _FakeBackgroundGateway(),
        ),
        // The Event-side default is a Planner setting; the REAL repository is
        // wired so the production seeding seam runs unmodified.
        eventTypeRepositoryProvider.overrideWithValue(
          DriftEventTypeRepository(
            database: database,
            clock: FixedClock(DateTime.utc(2026, 9, 18, 12)),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(startupControllerProvider.notifier).initialize();
  }

  NotificationSettingsController controller() =>
      container.read(notificationSettingsControllerProvider.notifier);

  Future<NotificationPreferenceRow?> readRow() {
    return (database.select(database.notificationPreferences)
          ..where((table) => table.profileId.equals(profileId)))
        .getSingleOrNull();
  }

  Future<int?> readPlannerEventDefault() async {
    // A brand-new profile has no Planner settings row at all: absence already
    // means "no Event default", which is precisely what must not be overwritten.
    final row =
        await (database.select(database.plannerPreferences)
              ..where((table) => table.profileId.equals(profileId)))
            .getSingleOrNull();
    return row?.defaultReminderMinutes;
  }

  /// Every field the owner's parity law names, read from SQLite.
  Future<Map<String, Object?>> persistedConfiguration() async {
    final stored = await repository.readPreferences(profileId: profileId);
    final row = await readRow();
    return <String, Object?>{
      'master': stored.systemNotificationsEnabled,
      'event': stored.eventRemindersEnabled,
      'task': stored.taskRemindersEnabled,
      'weekly': stored.weeklyReviewRemindersEnabled,
      'awaitingReport': stored.awaitingReportRemindersEnabled,
      'goal': stored.goalCompletionNotificationsEnabled,
      'taskDefault': stored.defaultTaskReminderMinutes,
      'quietHours': stored.quietHours.enabled,
      'detailedTitle': row?.detailedShowTitle,
      'detailedDescription': row?.detailedShowDescription,
      'detailedTime': row?.detailedShowTime,
      'detailedContacts': row?.detailedShowContacts,
      'detailedLocation': row?.detailedShowLocation,
      'eventDefault': await readPlannerEventDefault(),
    };
  }

  group('the semantic first-run sentinel', () {
    test('a brand-new profile is neverConfigured, and reading never writes',
        () async {
      await buildContainer();
      expect(
        await repository.readSetupState(profileId: profileId),
        NotificationSetupState.neverConfigured,
      );
      expect(await repository.hasPreferences(profileId: profileId), isFalse);
      // The read must not have created the row it just classified.
      expect(await readRow(), isNull);
    });

    test('a Detailed-content-only row is STILL neverConfigured', () async {
      await buildContainer();
      // Exactly what the Settings screen does today when the user touches one
      // Detailed switch before granting anything: the shared row is INSERTED
      // with only the five Detailed columns set.
      await container
          .read(detailedContentControllerProvider)
          .setField(
            current: DetailedContentPreferences.defaults,
            showTitle: false,
          );

      expect(
        await repository.hasPreferences(profileId: profileId),
        isTrue,
        reason: 'the row really does exist — that is the whole trap',
      );
      expect(
        await repository.readSetupState(profileId: profileId),
        NotificationSetupState.neverConfigured,
        reason: 'nothing about notification DELIVERY has been configured',
      );
    });

    test('the Review #4 partial row is reported, never auto-repaired',
        () async {
      await buildContainer();
      // The buggy build's fingerprint: master on, every delivery category and
      // both selectors left at their untouched defaults.
      await repository.savePreferences(
        profileId: profileId,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
        ),
      );

      expect(
        await repository.readSetupState(profileId: profileId),
        NotificationSetupState.partiallyInitialized,
      );
      expect(
        await container
            .read(notificationFirstRunSetupProvider)
            .seedIfNeverConfigured(profileId: profileId),
        isFalse,
        reason:
            '"master on with every category off" could be a real user choice, '
            'so it is preserved and reported rather than guessed at',
      );
    });

    test('a restored/established configuration is configured, not new',
        () async {
      await buildContainer();
      // The owner's own restored row: master on, categories on, Quiet Hours on,
      // a deliberately unset Task default.
      await repository.savePreferences(
        profileId: profileId,
        preferences: const NotificationPreferences(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
          weeklyReviewRemindersEnabled: true,
          awaitingReportRemindersEnabled: true,
          goalCompletionNotificationsEnabled: false,
          inAppGoalCelebrationsEnabled: true,
          defaultTaskReminderMinutes: null,
          snoozeDurationMinutes: 10,
          quietHours: QuietHoursSettings(
            enabled: true,
            startMinute: 1320,
            endMinute: 420,
          ),
        ),
      );

      expect(
        await repository.readSetupState(profileId: profileId),
        NotificationSetupState.configured,
      );
    });
  });

  group('the enable edge owns first-run initialization', () {
    test(
      'a PRE-GRANTED Android permission still seeds on enable (FAIL-FIRST)',
      () async {
        // The straightfix's central case. Android permission is already granted
        // before the user ever touches the master, so `requestPermission` is
        // skipped entirely — which is exactly why seeding used to be skipped.
        await buildContainer(
          states: <OptionalPermission, OperatingSystemPermissionState>{
            OptionalPermission.notifications:
                OperatingSystemPermissionState.granted,
          },
        );

        await controller().setSystemNotificationsEnabled(true);

        expect(
          permissionGateway.requestCount,
          0,
          reason: 'a granted permission must not be re-requested',
        );
        final stored = await repository.readPreferences(profileId: profileId);
        expect(stored.systemNotificationsEnabled, isTrue);
        expect(stored.eventRemindersEnabled, isTrue);
        expect(stored.taskRemindersEnabled, isTrue);
        expect(stored.weeklyReviewRemindersEnabled, isTrue);
        expect(stored.awaitingReportRemindersEnabled, isTrue);
        expect(stored.goalCompletionNotificationsEnabled, isTrue);
        expect(stored.quietHours.enabled, isFalse);
        expect(stored.defaultTaskReminderMinutes, 10);
        expect(
          stored,
          NotificationFirstRunSetup.ownerApprovedDefaults,
          reason: 'the whole approved set, not just the master',
        );
      },
    );

    test('the fresh setup also persists the 10-minute reminder defaults',
        () async {
      await buildContainer(
        states: <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.notifications:
              OperatingSystemPermissionState.granted,
        },
      );
      await controller().setSystemNotificationsEnabled(true);
      // Layer 1 of the owner's proof: the DB row itself.
      expect(await readPlannerEventDefault(), 10);
      expect(
        (await repository.readPreferences(profileId: profileId))
            .defaultTaskReminderMinutes,
        10,
      );
    });

    test('a detailed-only row does NOT poison a later successful enable',
        () async {
      await buildContainer();
      await container
          .read(detailedContentControllerProvider)
          .setField(
            current: DetailedContentPreferences.defaults,
            showLocation: false,
          );

      // Later the user enables notifications for real.
      await controller().setSystemNotificationsEnabled(true);

      final stored = await repository.readPreferences(profileId: profileId);
      expect(stored.systemNotificationsEnabled, isTrue);
      expect(
        stored.eventRemindersEnabled,
        isTrue,
        reason: 'the approved defaults must still seed exactly once',
      );
      expect(stored.defaultTaskReminderMinutes, 10);
      expect(await readPlannerEventDefault(), 10);
      expect(
        (await readRow())?.detailedShowLocation,
        isFalse,
        reason: "the user's own Detailed choice is not ours to overwrite",
      );
    });

    test('an established user is preserved through revoke and re-grant',
        () async {
      await buildContainer(
        states: <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.notifications:
              OperatingSystemPermissionState.granted,
        },
      );
      const deliberate = NotificationPreferences(
        systemNotificationsEnabled: true,
        eventRemindersEnabled: true,
        taskRemindersEnabled: false,
        weeklyReviewRemindersEnabled: false,
        awaitingReportRemindersEnabled: false,
        goalCompletionNotificationsEnabled: false,
        inAppGoalCelebrationsEnabled: false,
        defaultTaskReminderMinutes: null,
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

      await controller().setSystemNotificationsEnabled(true);

      expect(
        await repository.readPreferences(profileId: profileId),
        deliberate,
        reason:
            'a deliberate NULL Task default and deliberate Quiet Hours survive '
            'a granted permission byte-for-byte',
      );
      expect(await readPlannerEventDefault(), isNull);
    });

    test('Planner and Settings setups are field-for-field IDENTICAL',
        () async {
      // PROFILE A — the Planner education path: the request itself grants.
      await buildContainer();
      await controller().setSystemNotificationsEnabled(true);
      final plannerPath = await persistedConfiguration();

      // PROFILE B — the Settings path on a brand-new profile whose Android
      // permission is ALREADY granted. Same user intent, different entry point.
      await buildContainer(
        states: <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.notifications:
              OperatingSystemPermissionState.granted,
        },
      );
      await controller().setSystemNotificationsEnabled(true);
      final settingsPath = await persistedConfiguration();

      expect(settingsPath, plannerPath);
      expect(plannerPath['master'], isTrue);
      expect(plannerPath['taskDefault'], 10);
      expect(plannerPath['eventDefault'], 10);
      expect(plannerPath['quietHours'], isFalse);
    });
  });

  group('a deferred refresh is never silently dropped', () {
    test('refresh requested while a master write is in flight still lands',
        () async {
      await buildContainer(
        states: <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.notifications:
              OperatingSystemPermissionState.granted,
        },
      );

      // Start the enable and ask for fresh truth WHILE it is still running: the
      // old `load()` returned without publishing and the caller kept a stale
      // snapshot (which is what let the Planner education reappear and let the
      // Settings screen show OFF while SQLite and Android both said ON).
      final enabling = controller().setSystemNotificationsEnabled(true);
      await controller().refreshWhenIdle();
      await enabling;
      await controller().refreshWhenIdle();

      final state = container.read(notificationSettingsControllerProvider);
      expect(state.loading, isFalse);
      expect(state.permission, OperatingSystemPermissionState.granted);
      expect(state.preferences.systemNotificationsEnabled, isTrue);
      expect(state.preferences.defaultTaskReminderMinutes, 10);
    });

    test('refreshWhenIdle publishes truth written by someone else', () async {
      await buildContainer();
      // Simulate a restore or an out-of-band write landing after the controller
      // had already published its snapshot.
      await repository.savePreferences(
        profileId: profileId,
        preferences: NotificationFirstRunSetup.ownerApprovedDefaults,
      );
      await controller().refreshWhenIdle();

      final state = container.read(notificationSettingsControllerProvider);
      expect(state.preferences, NotificationFirstRunSetup.ownerApprovedDefaults);
    });
  });
}


final class _FakeNotificationGateway implements NotificationGateway {
  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {}

  @override
  Future<void> cancel(int platformId) async {}

  @override
  Future<List<PendingLocalNotification>> pending() async => const [];

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

final class _FakeBackgroundGateway implements BackgroundWorkGateway {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async {}

  @override
  Future<void> cancelUnique(String uniqueName) async {}

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async =>
      BackgroundGatewayWorkState.absent;
}
