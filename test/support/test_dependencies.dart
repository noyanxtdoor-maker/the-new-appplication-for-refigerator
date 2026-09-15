import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:rmplanner/app/m5_app_splash.dart';
import 'package:rmplanner/app/next_transfer_app.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/notifications/notification_response_controller.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/core/security/auth_token_store.dart';
import 'package:rmplanner/core/security/privacy_gate.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/application/contact_repository.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/application/indicator_providers.dart';
import 'package:rmplanner/features/indicators/application/indicator_repository.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_repository.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/application/task_event_link_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/settings/application/appearance_providers.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';
import 'package:rmplanner/features/settings/application/start_of_week_repository.dart';
import 'package:rmplanner/features/settings/data/drift_appearance_repository.dart';
import 'package:rmplanner/features/settings/data/drift_start_of_week_repository.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_repository.dart';
import 'package:rmplanner/features/weekly_planning/data/drift_weekly_planning_repository.dart';

final class FixedClock implements AppClock {
  const FixedClock(this.value);

  final DateTime value;

  @override
  DateTime nowUtc() => value;
}

final class SequenceIdentifierSource implements IdentifierSource {
  SequenceIdentifierSource(this._values);

  final List<String> _values;
  int _index = 0;

  @override
  String nextUuid() {
    if (_index >= _values.length) {
      throw StateError('No test identifier remains');
    }
    return _values[_index++];
  }
}

final class FixedPlannerDateSource implements PlannerDateSource {
  const FixedPlannerDateSource(this.value);

  final PlannerDate value;

  @override
  PlannerDate today() => value;
}

final class MemoryPlannerCalendarSource implements PlannerCalendarSource {
  MemoryPlannerCalendarSource([this.items = const <PlannerCalendarItem>[]]);

  List<PlannerCalendarItem> items;

  @override
  Future<List<PlannerCalendarItem>> readDay({
    required String profileId,
    required PlannerDate date,
  }) async {
    return items.where((item) => item.date == date).toList(growable: false);
  }
}

final class FailingTaskWriteGuard implements TaskWriteGuard {
  const FailingTaskWriteGuard();

  @override
  Future<void> beforeCommit() async {
    throw StateError('Injected task write failure');
  }
}

final class MemoryPlannerTaskContextSource implements PlannerTaskContextSource {
  const MemoryPlannerTaskContextSource(this.contexts);

  final Map<String, PlannerTaskContext> contexts;

  @override
  Future<PlannerTaskContext> readContext(String taskId) async {
    return contexts[taskId] ?? const PlannerTaskContext();
  }
}

final class FixedHistoricalEffectReader implements TaskHistoricalEffectReader {
  const FixedHistoricalEffectReader(this.hasEffects);

  final bool hasEffects;

  @override
  Future<bool> hasReportOrLedgerEffect(String taskId) async => hasEffects;
}

final class FixedPrivacyGate implements PrivacyGate {
  FixedPrivacyGate({this.unlockRequired = false});

  bool unlockRequired;

  @override
  Future<bool> isUnlockRequired() async => unlockRequired;

  @override
  void markLocked() {
    unlockRequired = true;
  }

  @override
  void markUnlocked() {
    unlockRequired = false;
  }
}

final class FakeDeviceAuthenticator implements DeviceAuthenticator {
  FakeDeviceAuthenticator({
    this.availabilityResult = DeviceAuthenticationAvailability.available,
    this.authenticationResult = DeviceAuthenticationResult.authenticated,
  });

  DeviceAuthenticationAvailability availabilityResult;
  DeviceAuthenticationResult authenticationResult;
  int authenticationAttempts = 0;

  @override
  Future<DeviceAuthenticationResult> authenticate() async {
    authenticationAttempts += 1;
    return authenticationResult;
  }

  @override
  Future<DeviceAuthenticationAvailability> availability() async {
    return availabilityResult;
  }
}

final class FakePermissionGateway implements PermissionGateway {
  FakePermissionGateway({
    Map<OptionalPermission, OperatingSystemPermissionState>? states,
    this.settingsOpened = true,
    this.requestResult,
  }) : states =
           states ?? <OptionalPermission, OperatingSystemPermissionState>{};

  final Map<OptionalPermission, OperatingSystemPermissionState> states;
  bool settingsOpened;
  OperatingSystemPermissionState? requestResult;
  int requestCount = 0;

  @override
  Future<bool> openSystemSettings() async => settingsOpened;

  @override
  Future<OperatingSystemPermissionState> status(
    OptionalPermission permission,
  ) async {
    return states[permission] ?? OperatingSystemPermissionState.denied;
  }

  @override
  Future<OperatingSystemPermissionState> request(
    OptionalPermission permission,
  ) async {
    requestCount += 1;
    final result =
        requestResult ??
        states[permission] ??
        OperatingSystemPermissionState.denied;
    states[permission] = result;
    return result;
  }
}

final class FakeNotificationGateway implements NotificationGateway {
  int scheduleCount = 0;
  final List<LocalNotificationRequest> scheduledRequests =
      <LocalNotificationRequest>[];
  final List<int> cancelledIds = <int>[];

  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {
    scheduleCount += 1;
    scheduledRequests.add(request);
  }

  @override
  Future<void> cancel(int platformId) async {
    cancelledIds.add(platformId);
  }

  @override
  Future<List<PendingLocalNotification>> pending() async => const [];

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

final class FakeBackgroundWorkGateway implements BackgroundWorkGateway {
  int enqueueCount = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async {
    enqueueCount += 1;
  }

  @override
  Future<void> cancelUnique(String uniqueName) async {}

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async =>
      BackgroundGatewayWorkState.absent;
}

final class MemorySecureStorageDriver implements SecureStorageDriver {
  final Map<String, String> values = <String, String>{};
  Object? writeFailure;

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    final failure = writeFailure;
    if (failure != null) {
      throw failure;
    }
    values[key] = value;
  }
}

final class TestPrivacyDependencies {
  TestPrivacyDependencies({
    required AppDatabase database,
    FakeDeviceAuthenticator? authenticator,
    FakePermissionGateway? permissionGateway,
  }) : repository = DriftPrivacyRepository(
         database: database,
         clock: FixedClock(DateTime.utc(2026, 7, 26, 12)),
       ),
       authenticator = authenticator ?? FakeDeviceAuthenticator(),
       permissionGateway = permissionGateway ?? FakePermissionGateway(),
       secureStorage = MemorySecureStorageDriver() {
    gate = SessionPrivacyGate(settingsReader: repository);
  }

  final DriftPrivacyRepository repository;
  late final SessionPrivacyGate gate;
  final FakeDeviceAuthenticator authenticator;
  final FakePermissionGateway permissionGateway;
  final MemorySecureStorageDriver secureStorage;

  ProviderContainer createContainer({
    List<Override> extraOverrides = const <Override>[],
  }) {
    return ProviderContainer(
      overrides: [
        privacyRepositoryProvider.overrideWithValue(repository),
        privacyGateProvider.overrideWithValue(gate),
        deviceAuthenticatorProvider.overrideWithValue(authenticator),
        permissionGatewayProvider.overrideWithValue(permissionGateway),
        authTokenStoreProvider.overrideWithValue(
          SecureAuthTokenStore(secureStorage),
        ),
        ...extraOverrides,
      ],
    );
  }

  Widget buildApp({
    required AppEnvironment environment,
    required SanitizedDiagnostics diagnostics,
    required StartupRepository startupRepository,
    PlannerRepository? plannerRepository,
    CalendarEventRepository? calendarEventRepository,
    PlannerDateSource plannerDateSource = const FixedPlannerDateSource(
      PlannerDate(year: 2026, month: 7, day: 27),
    ),
    IdentifierSource? plannerIdentifierSource,
    WeeklyPlanningRepository? weeklyPlanningRepository,
    StartOfWeekRepository? startOfWeekRepository,
    EventTypeRepository? eventTypeRepository,
    ContactRepository? contactRepository,

    /// MP-18: optional IndicatorRepository override for deterministic
    /// Temple Visit schedule tests (staged/pending reads).  Defaults to the
    /// real Drift repository exactly as before.
    IndicatorRepository? indicatorRepository,

    /// Pack B2: the appearance mode this app build starts in.  Defaults to
    /// DARK so every existing dark-golden/widget test keeps rendering the
    /// exact pre-B2 dark appearance; light tests pass Light explicitly.
    AppearanceMode? initialAppearance = AppearanceMode.dark,

    /// B2-CORRECTION: the independent Theme Color this app build starts in.
    /// Defaults to Rose (the compatibility/fresh default).
    ThemeColorMode? initialThemeColor = ThemeColorMode.rose,

    /// NX pack: extra Riverpod overrides appended AFTER the defaults so they
    /// take precedence (used by deterministic pending-read contract tests).
    List<Override> extraOverrides = const <Override>[],

    /// M6: opt-in real-splash coverage for front-door hand-off tests.
    /// Defaults to the established disabled presentation so every existing
    /// journey keeps its exact behavior.
    bool enableAppSplash = false,
  }) {
    final resolvedContactRepository =
        contactRepository ??
        DriftContactRepository(
          database: repository.database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
          identifiers: const UuidIdentifierSource(),
        );
    final linkRepository = DriftTaskEventLinkRepository(
      database: repository.database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final outcomeReportingRepository = DriftOutcomeReportingRepository(
      database: repository.database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final resolvedEventTypeRepository =
        eventTypeRepository ??
        DriftEventTypeRepository(
          database: repository.database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        );
    final resolvedCalendarEventRepository =
        calendarEventRepository ??
        DriftCalendarEventRepository(
          database: repository.database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
          timeZones: IanaCalendarEventTimeZones(
            displayTimeZoneId: 'Asia/Manila',
          ),
          taskContextSource: linkRepository,
          linkContextTransfer: linkRepository,
          reportSource: outcomeReportingRepository,
        );
    final resolvedPlannerRepository =
        plannerRepository ??
        DriftPlannerRepository(
          database: repository.database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
          calendarSource: resolvedCalendarEventRepository,
          taskContextSource: linkRepository,
          historicalEffectReader: outcomeReportingRepository,
        );
    final linkCoordinator = DriftTaskEventLinkCoordinator(
      database: repository.database,
      calendarEvents: resolvedCalendarEventRepository,
      links: linkRepository,
    );
    final resolvedIndicatorRepository =
        indicatorRepository ??
        DriftIndicatorRepository(
          database: repository.database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
          calendarEvents: resolvedCalendarEventRepository,
        );
    final goalRepository = DriftGoalRepository(
      database: repository.database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      identifiers: const UuidIdentifierSource(),
    );
    final resolvedStartOfWeekRepository =
        startOfWeekRepository ??
        DriftStartOfWeekRepository(
          database: repository.database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        );
    final resolvedWeeklyPlanningRepository =
        weeklyPlanningRepository ??
        DriftWeeklyPlanningRepository(
          database: repository.database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
          identifiers: const UuidIdentifierSource(),
          timeZones: IanaCalendarEventTimeZones(
            displayTimeZoneId: 'Asia/Manila',
          ),
          indicators: resolvedIndicatorRepository,
        );
    final defaultOverrides = <Override>[
      appEnvironmentProvider.overrideWithValue(environment),
      diagnosticsProvider.overrideWithValue(diagnostics),
      startupRepositoryProvider.overrideWithValue(startupRepository),
      privacyRepositoryProvider.overrideWithValue(repository),
      privacyGateProvider.overrideWithValue(gate),
      deviceAuthenticatorProvider.overrideWithValue(authenticator),
      permissionGatewayProvider.overrideWithValue(permissionGateway),
      notificationFoundationRepositoryProvider.overrideWithValue(
        DriftNotificationFoundationRepository(
          database: repository.database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
      ),
      notificationGatewayProvider.overrideWithValue(FakeNotificationGateway()),
      notificationResponseControllerProvider.overrideWithValue(
        NotificationResponseController(),
      ),
      backgroundWorkGatewayProvider.overrideWithValue(
        FakeBackgroundWorkGateway(),
      ),
      notificationPlatformFoundationProvider.overrideWithValue(
        const NotificationPlatformFoundation(
          notificationsAvailable: true,
          backgroundWorkAvailable: true,
        ),
      ),
      authTokenStoreProvider.overrideWithValue(
        SecureAuthTokenStore(secureStorage),
      ),
      calendarEventRepositoryProvider.overrideWithValue(
        resolvedCalendarEventRepository,
      ),
      eventTypeRepositoryProvider.overrideWithValue(
        resolvedEventTypeRepository,
      ),
      outcomeReportingRepositoryProvider.overrideWithValue(
        outcomeReportingRepository,
      ),
      plannerRepositoryProvider.overrideWithValue(resolvedPlannerRepository),
      indicatorRepositoryProvider.overrideWithValue(
        resolvedIndicatorRepository,
      ),
      goalRepositoryProvider.overrideWithValue(goalRepository),
      weeklyPlanningRepositoryProvider.overrideWithValue(
        resolvedWeeklyPlanningRepository,
      ),
      startOfWeekRepositoryProvider.overrideWithValue(
        resolvedStartOfWeekRepository,
      ),
      contactRepositoryProvider.overrideWithValue(resolvedContactRepository),
      taskEventLinkRepositoryProvider.overrideWithValue(linkRepository),
      taskEventLinkCoordinatorProvider.overrideWithValue(linkCoordinator),
      deviceAppearanceRepositoryProvider.overrideWithValue(
        DriftAppearanceRepository(
          database: repository.database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
      ),
      initialAppearanceProvider.overrideWithValue(initialAppearance),
      initialThemeColorProvider.overrideWithValue(initialThemeColor),
      plannerDateSourceProvider.overrideWithValue(plannerDateSource),
      // M5: the shared harness mounts the real app so journeys can assert on
      // the real startup and Privacy Lock surfaces. The branded startup
      // overlay is a presentation window in front of those, so it is
      // switched off here rather than shifting every existing journey; the
      // splash itself is covered by test/app/m5_app_splash_test.dart and,
      // with [enableAppSplash], by the M6 front-door hand-off tests.
      if (!enableAppSplash) appSplashEnabledProvider.overrideWithValue(false),
      if (plannerIdentifierSource != null)
        plannerIdentifierSourceProvider.overrideWithValue(
          plannerIdentifierSource,
        ),
    ];
    // NX pack: extra overrides take precedence, and any provider they cover
    // is dropped from the defaults so the same provider is never overridden
    // twice within one container (Riverpod forbids duplicate overrides).
    final extraOrigins = extraOverrides
        .map((override) => override.origin)
        .whereType<Object>()
        .toSet();
    return ProviderScope(
      overrides: [
        ...defaultOverrides.where(
          (override) => !extraOrigins.contains(override.origin),
        ),
        ...extraOverrides,
      ],
      child: const NextTransferApp(),
    );
  }
}

final class FailingStartupRepository implements StartupRepository {
  const FailingStartupRepository();

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() async {
    throw StateError('Injected startup failure');
  }

  @override
  Future<LocalProfile> completeOnboarding() async {
    throw StateError('Injected startup failure');
  }

  @override
  Future<StartupSnapshot> resolveStartup() async {
    throw StateError('Injected startup failure');
  }

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) async {
    throw StateError('Injected startup failure');
  }

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) async {
    throw StateError('Injected startup failure');
  }
}

/// Simulates a pre-M6 (legacy) install for tests that describe an EXISTING
/// user rather than a brand-new one.
///
/// The M6 zero-goal law removed automatic Goal creation, so a profile that just
/// completed onboarding now owns ZERO Goals.  Every profile created before that
/// law, however, already owns the canonical six — exactly the state these tests
/// were written against.  This helper writes the bootstrap's own canonical seed
/// signature for the first slot and then lets the PRODUCTION bootstrap converge
/// the remaining slots, the same way a real upgraded install does.  The fixture
/// therefore cannot drift from production behaviour, and the convergence /
/// repair path stays covered.
///
/// Tests that assert the new zero-goal law must NOT call this.
Future<void> seedLegacyCanonicalGoals(
  AppDatabase database,
  String profileId, {
  AppClock? clock,
  bool convergeRemainingSlots = true,
}) async {
  final resolvedClock =
      clock ?? FixedClock(DateTime.utc(2026, 7, 27, 12));
  final now = resolvedClock.nowUtc();
  final slot = CanonicalGoalSlot.all.first;
  await database
      .into(database.goals)
      .insert(
        GoalsCompanion.insert(
          id: '$profileId:goal:${slot.slotIndex}',
          profileId: profileId,
          indicatorKey: Value<String?>(slot.indicatorKey),
          assignedEventTypeStableKey: Value<String?>(
            slot.eventTypeStableKey,
          ),
          role: slot.role.storageName,
          activeSlotIndex: Value<int?>(slot.slotIndex),
          title: slot.defaultTitle,
          status: GoalStatus.active.name,
          createdAtUtc: now,
          updatedAtUtc: now,
        ),
        mode: InsertMode.insertOrIgnore,
      );
  if (!convergeRemainingSlots) {
    // Only the slot-1 row (the bootstrap's own stable-ID seed signature) is
    // written: passes that need a *partially seeded* legacy profile can then
    // prove the production repair path converges the remaining slots.
    return;
  }
  await DriftGoalRepository(
    database: database,
    clock: resolvedClock,
    identifiers: const UuidIdentifierSource(),
  ).ensureCanonicalGoals(profileId);
}

AppDatabase openMemoryDatabase() {
  return AppDatabase.forTesting(NativeDatabase.memory());
}

/// Establishes the exact WeeklyPlans row for [date] under [startDay] so widget
/// tests can render an ESTABLISHED Home (cards + Goal Planning pill) without
/// navigating.  Uses the same construction the app wires in production.
Future<void> establishWeeklyPlan({
  required AppDatabase database,
  required String profileId,
  required PlannerDate date,
  int startDay = DateTime.monday,
}) async {
  final clock = FixedClock(DateTime.utc(2026, 7, 27, 12));
  final timeZones = IanaCalendarEventTimeZones(
    displayTimeZoneId: 'Asia/Manila',
  );
  final reporting = DriftOutcomeReportingRepository(
    database: database,
    clock: clock,
  );
  final calendar = DriftCalendarEventRepository(
    database: database,
    clock: clock,
    timeZones: timeZones,
    reportSource: reporting,
  );
  final indicators = DriftIndicatorRepository(
    database: database,
    clock: clock,
    calendarEvents: calendar,
  );
  final repository = DriftWeeklyPlanningRepository(
    database: database,
    clock: clock,
    identifiers: const UuidIdentifierSource(),
    timeZones: timeZones,
    indicators: indicators,
  );
  await repository.openOrCreate(
    profileId: profileId,
    date: date,
    startDay: startDay,
  );
}

DriftStartupRepository buildTestRepository({
  required AppDatabase database,
  PrivacyGate? privacyGate,
  SanitizedDiagnostics? diagnostics,
  IdentifierSource? identifierSource,
}) {
  return DriftStartupRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 26, 12)),
    identifierSource:
        identifierSource ??
        SequenceIdentifierSource(<String>[
          '11111111-1111-4111-8111-111111111111',
        ]),
    privacyGate: privacyGate ?? FixedPrivacyGate(),
    diagnostics: diagnostics ?? SanitizedDiagnostics(),
  );
}
