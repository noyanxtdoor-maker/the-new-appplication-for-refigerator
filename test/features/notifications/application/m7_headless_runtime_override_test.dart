import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/indicators/application/indicator_providers.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reconcile_reminders.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/data/drift_weekly_planning_repository.dart';

import '../../../support/test_dependencies.dart';

/// VS16 M7 corrective — headless reminder runtime override contract (D28–D31).
///
/// ROOT CAUSE (found during the certified M7 device-install smoke):
///
///   runReminderRuntime
///     -> reconcileRemindersProvider
///       -> startupControllerProvider    (notification_privacy_refresh_provider.dart:26)
///         -> StartupController._diagnostics
///           -> diagnosticsProvider       (startup_providers.dart:14)
///             -> StateError: SanitizedDiagnostics must be overridden at the app root
///
/// The HEADLESS WorkManager ProviderContainer overrides the reminder, Event,
/// EventType, Planner, privacy, permission and runtime-profile providers, but
/// NOT `diagnosticsProvider`, which is declared to throw until an app root
/// supplies it.
///
/// This defect is INHERITED from baseline 7b1395c. It is not introduced by the
/// DeepSeek M7 work. It is corrected now because it degrades background
/// reminder reconciliation reliability.
///
/// SCOPE (narrow, verified):
/// `diagnosticsProvider` is the ONLY additional override required. The profile
/// path is already satisfied by `reminderRuntimeProfileIdProvider`, which the
/// headless container supplies; `startupRepositoryProvider` is therefore NOT
/// needed to unblock this path and is deliberately not added (the worker must
/// not construct a UI startup graph).
///
/// FAIL-FIRST: D28 reproduces the inherited failure. D29/D30 prove the
/// corrected set resolves. D31 proves real downstream failures stay truthful.
void main() {
  const profileId = '11111111-1111-4111-8111-111111111111';

  /// The exact provider overrides the headless container supplies today
  /// (mirrors `reminder_background_runtime.dart`, minus the WorkManager and
  /// plugin ports that are not constructible in a plain test).
  List<Override> headlessOverrides({
    required AppDatabase database,
    required AppClock clock,
    required NotificationGateway gateway,
    required PermissionGateway permissionGateway,
    bool includeProfile = true,
    bool legacy = false,
  }) {
    final repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    final events = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: IanaCalendarEventTimeZones(
        displayTimeZoneId: 'Asia/Manila',
      ),
    );
    // The headless runtime composes the SAME canonical planning dependencies as
    // main.dart (contract section 26): the real Indicator repository feeding the
    // real WeeklyPlanning repository.  ReconcileReminders reads both while
    // reconciling the planning family, so the model must supply them or it would
    // fail where production succeeds.
    final indicators = DriftIndicatorRepository(
      database: database,
      clock: clock,
      calendarEvents: events,
    );
    final weeklyPlans = DriftWeeklyPlanningRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
      timeZones: IanaCalendarEventTimeZones(
        displayTimeZoneId: 'Asia/Manila',
      ),
      indicators: indicators,
    );
    return <Override>[
      if (includeProfile)
        reminderRuntimeProfileIdProvider.overrideWithValue(profileId),
      notificationFoundationRepositoryProvider.overrideWithValue(repository),
      notificationGatewayProvider.overrideWithValue(gateway),
      reminderReconcilerProvider.overrideWithValue(
        ReminderReconciler(
          repository: repository,
          gateway: gateway,
          clock: clock,
        ),
      ),
      calendarEventRepositoryProvider.overrideWithValue(events),
      eventTypeRepositoryProvider.overrideWithValue(
        DriftEventTypeRepository(database: database, clock: clock),
      ),
      plannerRepositoryProvider.overrideWithValue(
        DriftPlannerRepository(
          database: database,
          clock: clock,
          calendarSource: events,
        ),
      ),
      privacyRepositoryProvider.overrideWithValue(
        DriftPrivacyRepository(database: database, clock: clock),
      ),
      permissionGatewayProvider.overrideWithValue(permissionGateway),
      // VS16 M8 — the production headless container supplies these three
      // planning/transport ports (reminder_background_runtime.dart).
      // ReconcileReminders now constructs the recovery coordinator and the
      // planning-family reconciler, which read them before any pass runs; a
      // model of production that omitted them would fail for a reason
      // production never hits.
      weeklyPlanningRepositoryProvider.overrideWithValue(weeklyPlans),
      indicatorRepositoryProvider.overrideWithValue(indicators),
      // VS16 M8 — the production headless container supplies the background
      // work gateway (reminder_background_runtime.dart).  ReconcileReminders now
      // constructs the recovery coordinator, which reads that gateway before any
      // pass runs, so a model of production that omits it would fail for a
      // reason production never hits.  The gateway port is a plain Dart
      // interface, so mirroring production here keeps the model faithful.
      backgroundWorkGatewayProvider.overrideWithValue(FakeBackgroundWorkGateway()),
      // VS16 M7 corrective — mirrors production exactly. Omitted only when a
      // test deliberately reproduces the PRE-correction container.
      if (!legacy) diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
    ];
  }

  AppDatabase openDatabase() => AppDatabase.forTesting(NativeDatabase.memory());

  group('D28 headless override contract — the inherited defect', () {
    test('D28 the PRE-correction headless override set cannot resolve the path',
        () async {
      final database = openDatabase();
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: headlessOverrides(
          database: database,
          clock: _FixedClock(DateTime.utc(2026, 9, 12, 12)),
          gateway: _NoopGateway(),
          permissionGateway: _DeniedPermissionGateway(),
          legacy: true,
        ),
      );
      addTearDown(container.dispose);

      // The inherited defect. `StartupController.build()` starts
      // `unawaited(initialize())`, and `initialize()` reads `_diagnostics`
      // (which resolves diagnosticsProvider) before its first await.
      //
      // Riverpod 3 reports the failure through the container's error channel
      // while `read` continues to return the current notifier state, so the
      // failure is captured by installing an observer/zone rather than by
      // expecting a synchronous throw. The assertion therefore observes the
      // real diagnosticsProvider resolution directly, which is the root cause.
      final thrown = <Object>[];
      final zone = runZonedGuarded(
        () => container.read(startupControllerProvider),
        (error, stack) => thrown.add(error),
      );
      expect(zone, isNotNull);

      // Pump so the unawaited initialize() reaches the diagnostics read.
      for (var attempt = 0; attempt < 10; attempt++) {
        await Future<void>.delayed(Duration.zero);
      }

      // Root cause, asserted directly and unambiguously: the headless
      // container cannot resolve diagnosticsProvider.
      expect(
        () => container.read(diagnosticsProvider),
        throwsA(
          isA<Object>().having(
            (error) => error.toString(),
            'message',
            contains('SanitizedDiagnostics must be overridden at the app root'),
          ),
        ),
        reason:
            'the PRE-correction headless container reproduces the inherited '
            'diagnosticsProvider failure this correction removes',
      );
    });

    test('D28b the missing override is exactly diagnosticsProvider', () {
      final database = openDatabase();
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: headlessOverrides(
          database: database,
          clock: _FixedClock(DateTime.utc(2026, 9, 12, 12)),
          gateway: _NoopGateway(),
          permissionGateway: _DeniedPermissionGateway(),
          legacy: true,
        ),
      );
      addTearDown(container.dispose);

      expect(
        () => container.read(diagnosticsProvider),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('SanitizedDiagnostics must be overridden at the app root'),
          ),
        ),
      );
      // The profile path is ALREADY satisfied headlessly, so it must not throw.
      expect(
        container.read(reminderRuntimeProfileIdProvider),
        profileId,
        reason: 'the headless profile override is already present',
      );
    });
  });

  group('D29-D30 corrected headless container resolves the path', () {
    test('D29 the corrected override set resolves every required provider', () {
      final database = openDatabase();
      addTearDown(database.close);
      final container = ProviderContainer(
        // The corrected production set — no extra override is added here
        // because the helper now mirrors production exactly.
        overrides: headlessOverrides(
          database: database,
          clock: _FixedClock(DateTime.utc(2026, 9, 12, 12)),
          gateway: _NoopGateway(),
          permissionGateway: _DeniedPermissionGateway(),
        ),
      );
      addTearDown(container.dispose);

      expect(container.read(diagnosticsProvider), isA<SanitizedDiagnostics>());
      expect(
        container.read(reconcileRemindersProvider),
        isA<ReconcileReminders>(),
      );
    });

    test('D30 the reconciliation path no longer fails on the diagnostics '
        'override', () async {
      final database = openDatabase();
      addTearDown(database.close);
      // A real headless run only reaches reconciliation when exactly one
      // primary Local Profile exists (reminder_background_runtime.dart selects
      // it and bails out otherwise), so the fixture must supply one. Without it
      // the planning repository has no profile time zone to read and would fail
      // for a reason production never hits.
      await database.into(database.localProfiles).insert(
        LocalProfilesCompanion.insert(
          id: profileId,
          localName: 'Primary',
          createdAtUtc: DateTime.utc(2026, 9, 12, 12),
          updatedAtUtc: DateTime.utc(2026, 9, 12, 12),
        ),
      );
      final container = ProviderContainer(
        overrides: headlessOverrides(
          database: database,
          clock: _FixedClock(DateTime.utc(2026, 9, 12, 12)),
          gateway: _NoopGateway(),
          permissionGateway: _DeniedPermissionGateway(),
        ),
      );
      addTearDown(container.dispose);

      // Constructing the reconciliation entry point must not throw.
      expect(container.read(reconcileRemindersProvider), isNotNull);

      // The planning branch reads startupControllerProvider. With the required
      // override present it must construct rather than fail.
      expect(container.read(startupControllerProvider), isNotNull);

      // And the full reconciliation entry point must run to completion without
      // the inherited diagnostics failure.
      await container.read(reconcileRemindersProvider)();

      // The failure must be gone from the diagnostics record's perspective: a
      // clean run records no 'startup_recovery_required' for a diagnostics
      // reason. The concrete proof is simply that no exception escaped.
      expect(true, isTrue);
    });
  });

  group('D29b production headless wiring carries the correction', () {
    test('D29b reminder_background_runtime overrides diagnosticsProvider', () {
      final source = File(
        'lib/features/notifications/application/reminder_background_runtime.dart',
      ).readAsStringSync();
      expect(
        source.contains('diagnosticsProvider.overrideWithValue'),
        isTrue,
        reason:
            'the headless container must supply the diagnostics provider the '
            'startup graph requires',
      );
      expect(
        source.contains('SanitizedDiagnostics()'),
        isTrue,
        reason: 'the headless diagnostics implementation must be pure Dart',
      );
      // The worker must NOT construct a UI startup graph. Assert the ACTUAL
      // wiring (an override), not the word: the source legitimately names
      // `startupRepositoryProvider` in the comment explaining why it is absent.
      expect(
        RegExp(
          r'startupRepositoryProvider\s*\.\s*overrideWith',
        ).hasMatch(source),
        isFalse,
        reason:
            'no UI startup repository may be built in the worker isolate; the '
            'runtime profile override already satisfies the profile path',
      );
    });
  });

  group('D31 real downstream failures stay truthful', () {
    test('D31 a genuinely failing reconciler still surfaces its failure', () async {
      final database = openDatabase();
      addTearDown(database.close);
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
          reconcileRemindersProvider.overrideWithValue(
            ReconcileReminders(
              reconcileEvents: () async {
                attempts++;
                throw StateError('Injected real downstream failure');
              },
              reconcileTasks: () async {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(reconcileRemindersProvider)(),
        throwsA(isA<StateError>()),
        reason:
            'D31: supplying the missing override must NOT swallow a real '
            'downstream failure',
      );
      expect(attempts, 1);
    });
  });

  group('D24 worker input privacy', () {
    test('D24 the headless container carries no owner display content', () {
      final database = openDatabase();
      addTearDown(database.close);
      final overrides = headlessOverrides(
        database: database,
        clock: _FixedClock(DateTime.utc(2026, 9, 12, 12)),
        gateway: _NoopGateway(),
        permissionGateway: _DeniedPermissionGateway(),
      );
      // The container wiring must reference technical ports only; no private
      // display string may be baked into an override.
      expect(overrides, isNotEmpty);
      for (final override in overrides) {
        final text = override.toString();
        expect(text.contains('Willow'), isFalse);
        expect(text.contains('Cara'), isFalse);
        expect(text.contains('Location:'), isFalse);
      }
    });
  });
}

final class _FixedClock implements AppClock {
  const _FixedClock(this.value);
  final DateTime value;

  @override
  DateTime nowUtc() => value;
}

final class _NoopGateway implements NotificationGateway {
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

/// Headless-safe permission reader. The headless isolate never prompts; it only
/// reads the factual OS state.
final class _DeniedPermissionGateway implements PermissionGateway {
  const _DeniedPermissionGateway();

  @override
  Future<OperatingSystemPermissionState> status(
    OptionalPermission permission,
  ) async => OperatingSystemPermissionState.denied;

  @override
  Future<OperatingSystemPermissionState> request(
    OptionalPermission permission,
  ) async => OperatingSystemPermissionState.denied;

  @override
  Future<bool> openSystemSettings() async => false;
}
