import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/next_transfer_app.dart';
import 'package:rmplanner/core/background/workmanager_background_work_gateway.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_gateway.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_launcher_badge_gateway.dart';
import 'package:rmplanner/core/notifications/notification_response_controller.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/core/security/auth_token_store.dart';
import 'package:rmplanner/core/security/privacy_gate.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/indicators/application/indicator_providers.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_provider.dart';
import 'package:rmplanner/features/maps/application/saved_place_providers.dart';
import 'package:rmplanner/features/maps/data/drift_map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/data/drift_maps_preferences_repository.dart';
import 'package:rmplanner/features/maps/data/drift_saved_place_repository.dart';
import 'package:rmplanner/features/notifications/application/launcher_badge_providers.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/task_event_link_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/data/local_auth_device_authenticator.dart';
import 'package:rmplanner/features/privacy/data/permission_handler_gateway.dart';
import 'package:rmplanner/features/settings/application/appearance_providers.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';
import 'package:rmplanner/features/settings/data/drift_appearance_repository.dart';
import 'package:rmplanner/features/settings/data/drift_start_of_week_repository.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/data/drift_weekly_planning_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Planner Polish Delta 2: the app is portrait-only on every route, sheet,
  // and dialog, regardless of the Android auto-rotate setting.  The manifest
  // `screenOrientation="portrait"` protects the native Activity before the
  // first frame; this Flutter-level lock keeps the engine portrait for the
  // whole session and prevents any rotation-driven re-layout.
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);

  final environment = AppEnvironment.fromDartDefines();
  final diagnostics = SanitizedDiagnostics(
    emitToDebugConsole: environment.name == AppEnvironmentName.local,
  );
  final database = AppDatabase.defaults();
  const clock = SystemAppClock();
  final notificationFoundationRepository =
      DriftNotificationFoundationRepository(database: database, clock: clock);
  final notificationResponseController = NotificationResponseController();
  final localNotificationsPlugin = FlutterLocalNotificationsPlugin();
  final notificationGateway = FlutterLocalNotificationsGateway(
    plugin: localNotificationsPlugin,
    responses: notificationResponseController,
  );
  final launcherBadgeGateway = FlutterLocalNotificationsLauncherBadgeGateway(
    localNotificationsPlugin,
  );
  const backgroundWorkGateway = WorkmanagerBackgroundWorkGateway();
  var notificationsAvailable = true;
  var backgroundWorkAvailable = true;
  try {
    await notificationGateway.initialize();
  } on Object {
    notificationsAvailable = false;
    diagnostics.record('notification_foundation_unavailable');
  }
  try {
    await backgroundWorkGateway.initialize();
  } on Object {
    backgroundWorkAvailable = false;
    diagnostics.record('background_foundation_unavailable');
  }
  final privacyRepository = DriftPrivacyRepository(
    database: database,
    clock: clock,
  );
  final privacyGate = SessionPrivacyGate(settingsReader: privacyRepository);
  final authTokenStore = SecureAuthTokenStore(FlutterSecureStorageDriver());
  final calendarEventTimeZones = await IanaCalendarEventTimeZones.forDevice();
  final taskEventLinkRepository = DriftTaskEventLinkRepository(
    database: database,
    clock: clock,
  );
  final outcomeReportingRepository = DriftOutcomeReportingRepository(
    database: database,
    clock: clock,
  );
  final eventTypeRepository = DriftEventTypeRepository(
    database: database,
    clock: clock,
  );
  final contactRepository = DriftContactRepository(
    database: database,
    clock: clock,
    identifiers: const UuidIdentifierSource(),
  );
  final calendarEventRepository = DriftCalendarEventRepository(
    database: database,
    clock: clock,
    timeZones: calendarEventTimeZones,
    taskContextSource: taskEventLinkRepository,
    linkContextTransfer: taskEventLinkRepository,
    duplicateContextTransfer: contactRepository,
    reportSource: outcomeReportingRepository,
  );
  final plannerRepository = DriftPlannerRepository(
    database: database,
    clock: clock,
    calendarSource: calendarEventRepository,
    taskContextSource: taskEventLinkRepository,
    historicalEffectReader: outcomeReportingRepository,
  );
  final indicatorRepository = DriftIndicatorRepository(
    database: database,
    clock: clock,
    calendarEvents: calendarEventRepository,
  );
  final goalRepository = DriftGoalRepository(
    database: database,
    clock: clock,
    identifiers: const UuidIdentifierSource(),
  );
  final weeklyPlanningRepository = DriftWeeklyPlanningRepository(
    database: database,
    clock: clock,
    identifiers: const UuidIdentifierSource(),
    timeZones: calendarEventTimeZones,
    indicators: indicatorRepository,
  );
  final taskEventLinkCoordinator = DriftTaskEventLinkCoordinator(
    database: database,
    calendarEvents: calendarEventRepository,
    links: taskEventLinkRepository,
  );
  final startOfWeekRepository = DriftStartOfWeekRepository(
    database: database,
    clock: clock,
  );
  final appearanceRepository = DriftAppearanceRepository(
    database: database,
    clock: clock,
  );
  final mapCoordinateRepository = DriftMapCoordinateRepository(
    database: database,
    clock: clock,
  );
  final savedPlaceRepository = DriftSavedPlaceRepository(
    database: database,
    clock: clock,
    identifiers: const UuidIdentifierSource(),
  );
  final mapsPreferencesRepository = DriftMapsPreferencesRepository(
    database: database,
    clock: clock,
  );
  // Pack B2: the persisted device Appearance is read BEFORE runApp so the
  // first MaterialApp build already has the correct ThemeMode (no
  // wrong-theme first frame).  B2-CORRECTION: the independent Theme Color is
  // read in the same single-row device read (no wrong-color first frame).
  // Neither read waits on profile/startup readiness.
  final initialAppearance = await appearanceRepository.readAppearance();
  final initialThemeColor = await appearanceRepository.readThemeColor();
  // VS-15 M6.2: the durable device Maps preferences are read BEFORE runApp
  // (Appearance precedent) so the first Maps render already uses the
  // persisted map type — no Road → Satellite startup flash.
  final initialMapsPreferences = await mapsPreferencesRepository
      .readPreferences();
  final startupRepository = DriftStartupRepository(
    database: database,
    clock: clock,
    identifierSource: const UuidIdentifierSource(),
    privacyGate: privacyGate,
    diagnostics: diagnostics,
  );

  runApp(
    ProviderScope(
      overrides: [
        appEnvironmentProvider.overrideWithValue(environment),
        diagnosticsProvider.overrideWithValue(diagnostics),
        startupRepositoryProvider.overrideWithValue(startupRepository),
        privacyRepositoryProvider.overrideWithValue(privacyRepository),
        privacyGateProvider.overrideWithValue(privacyGate),
        deviceAuthenticatorProvider.overrideWithValue(
          LocalAuthDeviceAuthenticator(),
        ),
        permissionGatewayProvider.overrideWithValue(
          const PermissionHandlerGateway(),
        ),
        notificationFoundationRepositoryProvider.overrideWithValue(
          notificationFoundationRepository,
        ),
        notificationGatewayProvider.overrideWithValue(notificationGateway),
        reminderBackgroundWorkGatewayProvider.overrideWithValue(
          backgroundWorkGateway,
        ),
        reminderDeviceLocationProvider.overrideWithValue(
          calendarEventTimeZones.deviceLocation,
        ),
        launcherBadgeGatewayProvider.overrideWithValue(launcherBadgeGateway),
        notificationResponseControllerProvider.overrideWithValue(
          notificationResponseController,
        ),
        backgroundWorkGatewayProvider.overrideWithValue(backgroundWorkGateway),
        notificationPlatformFoundationProvider.overrideWithValue(
          NotificationPlatformFoundation(
            notificationsAvailable: notificationsAvailable,
            backgroundWorkAvailable: backgroundWorkAvailable,
          ),
        ),
        authTokenStoreProvider.overrideWithValue(authTokenStore),
        calendarEventRepositoryProvider.overrideWithValue(
          calendarEventRepository,
        ),
        eventTypeRepositoryProvider.overrideWithValue(eventTypeRepository),
        outcomeReportingRepositoryProvider.overrideWithValue(
          outcomeReportingRepository,
        ),
        plannerRepositoryProvider.overrideWithValue(plannerRepository),
        indicatorRepositoryProvider.overrideWithValue(indicatorRepository),
        goalRepositoryProvider.overrideWithValue(goalRepository),
        contactRepositoryProvider.overrideWithValue(contactRepository),
        mapCoordinateRepositoryProvider.overrideWithValue(
          mapCoordinateRepository,
        ),
        savedPlaceRepositoryProvider.overrideWithValue(savedPlaceRepository),
        mapsPreferencesRepositoryProvider.overrideWithValue(
          mapsPreferencesRepository,
        ),
        initialMapsPreferencesProvider.overrideWithValue(
          initialMapsPreferences,
        ),
        weeklyPlanningRepositoryProvider.overrideWithValue(
          weeklyPlanningRepository,
        ),
        startOfWeekRepositoryProvider.overrideWithValue(startOfWeekRepository),
        deviceAppearanceRepositoryProvider.overrideWithValue(
          appearanceRepository,
        ),
        initialAppearanceProvider.overrideWithValue(initialAppearance),
        initialThemeColorProvider.overrideWithValue(initialThemeColor),
        taskEventLinkRepositoryProvider.overrideWithValue(
          taskEventLinkRepository,
        ),
        taskEventLinkCoordinatorProvider.overrideWithValue(
          taskEventLinkCoordinator,
        ),
      ],
      child: const NextTransferApp(),
    ),
  );
}
