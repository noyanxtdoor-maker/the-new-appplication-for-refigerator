import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rmplanner/app/m5_app_splash.dart';
import 'package:rmplanner/app/next_transfer_app.dart';
import 'package:rmplanner/app/startup_bootstrap.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
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
import 'package:rmplanner/features/backup/application/backup_providers.dart';
import 'package:rmplanner/features/backup/data/backup_document_gateway.dart';
import 'package:rmplanner/features/backup/data/backup_downloads_writer.dart';
import 'package:rmplanner/features/backup/data/secure_checkpoint_key_store.dart';
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
  // M5 P2: one deferral starts before the root can submit an unbranded Flutter
  // frame. NextTransferApp releases this exact gate after it has incorporated
  // the identical splash ImageProvider or an explicit failure surface.
  final splashFirstFrameGate = SplashFirstFrameGate();
  splashFirstFrameGate.defer();
  // PRE-BETA RESPONSIVE (owner law, 2026-09-16): Next Transfer no longer forces
  // portrait.  The empty list is the documented "defer to the operating system
  // default" contract, so the app follows the device's rotation state: it
  // rotates when the user's auto-rotate setting allows it, and stays put when
  // the user has locked rotation at the system level.  The matching runtime
  // restriction in the manifest (android:screenOrientation) was removed in the
  // same change, and no conditional phone-only re-lock is installed.
  //
  // Historical note: the previous `[DeviceOrientation.portraitUp]` lock was
  // inherited Planner polish from before the M1-M7 program.  It was also a
  // guarantee the app could not keep: Android 16+ ignores runtime and manifest
  // orientation restrictions entirely on displays at least 600 dp wide, so
  // tablets, unfolded foldables and desktop-windowing windows were already
  // rotating regardless.
  await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);

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
  // M7 section 27: ONE repair-marker writer shared by every canonical mutation
  // site, so a burst of source changes collapses into a single pending
  // reconciliation instead of restarting a repair episode per repository.
  final reminderRecoveryRequest = ReminderRecoveryRequest(
    database: database,
    clock: clock,
    identifiers: const UuidIdentifierSource(),
  );
  final privacyRepository = DriftPrivacyRepository(
    database: database,
    clock: clock,
    // M7 section 27: Privacy Lock / preview-mode changes alter how registered
    // reminders may render, so they schedule a reconciliation.
    reminderRepair: reminderRecoveryRequest,
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
    // M7 section 27: submitting/clearing a Report changes Awaiting Report
    // reminder eligibility, so the repair intent commits with the report.
    reminderRepair: reminderRecoveryRequest,
  );
  final eventTypeRepository = DriftEventTypeRepository(
    database: database,
    clock: clock,
    // M7 section 27: only a change to the global reminder default needs a
    // reconciliation; Event Type/colour/name architecture is untouched.
    reminderRepair: reminderRecoveryRequest,
  );
  final contactRepository = DriftContactRepository(
    database: database,
    clock: clock,
    identifiers: const UuidIdentifierSource(),
    // M7 section 27: archive / recently-delete / merge / rename mutations
    // invalidate follow-up purposes and commit the repair intent in the same
    // transaction, so a later platform failure cannot lose the need to
    // re-resolve reminders against current Contact truth.
    reminderRepair: reminderRecoveryRequest,
  );
  final calendarEventRepository = DriftCalendarEventRepository(
    database: database,
    clock: clock,
    timeZones: calendarEventTimeZones,
    taskContextSource: taskEventLinkRepository,
    linkContextTransfer: taskEventLinkRepository,
    duplicateContextTransfer: contactRepository,
    reportSource: outcomeReportingRepository,
    // M7 section 27: save/edit/cancel/reschedule/duplicate all commit the
    // repair intent with the Event write.
    reminderRepair: reminderRecoveryRequest,
  );
  final plannerRepository = DriftPlannerRepository(
    database: database,
    clock: clock,
    calendarSource: calendarEventRepository,
    taskContextSource: taskEventLinkRepository,
    historicalEffectReader: outcomeReportingRepository,
    // M7 section 27: Task mutations persist the reminder reconciliation marker
    // in the same transaction, so a later platform failure cannot lose the
    // committed intent to reconcile.
    reminderRepair: reminderRecoveryRequest,
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
    // M7 section 27: completing a Weekly Review retires that period's
    // weekly-review reminder, so the repair intent commits with the review.
    reminderRepair: reminderRecoveryRequest,
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
  // M2 P04: resolve the existing device seeds once before runApp.  A read
  // failure is an explicit recovery result, never a private Home frame built
  // from fallback appearance or Maps values.
  final bootstrap = await StartupBootstrap(
    appearanceRepository: appearanceRepository,
    mapsPreferencesRepository: mapsPreferencesRepository,
  ).resolve();
  final startupRepository = DriftStartupRepository(
    database: database,
    clock: clock,
    identifierSource: const UuidIdentifierSource(),
    privacyGate: privacyGate,
    diagnostics: diagnostics,
  );

  // M7 section 6 transport ownership.  The app root is the one composition that
  // owns the strict three-key worker spec (sections 12/14), so it supplies the
  // real WorkManager enqueue and release.  Both are derived from the SAME
  // unique-name helper, which is what guarantees a release can never miss the
  // job it was registered for and leave two live delivery owners behind.
  //
  // When background work is unavailable the ports stay null, so no key is ever
  // marked `m7w_` without a real worker registration behind it.
  Future<void> scheduleCanonicalReminderWork({
    required String stableKey,
    required DateTime scheduledAtUtc,
    required String sourceRevision,
    required int platformNotificationId,
  }) async {
    if (!backgroundWorkAvailable) return;
    final spec = CanonicalReminderWorkSpec(
      stableKey: stableKey,
      scheduledUtcMs: scheduledAtUtc.millisecondsSinceEpoch,
      sourceRevision: sourceRevision,
    );
    await backgroundWorkGateway.enqueueUnique(
      spec.toWorkSpec(
        platformNotificationId: platformNotificationId,
        nowUtc: clock.nowUtc(),
      ),
    );
  }

  Future<void> cancelCanonicalReminderWork(String uniqueName) async {
    if (!backgroundWorkAvailable) return;
    await backgroundWorkGateway.cancelUnique(uniqueName);
  }

  runApp(
    ProviderScope(
      overrides: [
        appEnvironmentProvider.overrideWithValue(environment),
        diagnosticsProvider.overrideWithValue(diagnostics),
        // VS-18 Backup & Restore: the database, one-tap saving straight to
        // Downloads (MediaStore, no storage permission) with the Storage
        // Access Framework picker as the fallback destination, and the
        // device-bound recovery checkpoint key/directory.
        appDatabaseProvider.overrideWithValue(database),
        backupDocumentGatewayProvider.overrideWithValue(
          const FileSelectorBackupDocumentGateway(),
        ),
        backupDownloadsWriterProvider.overrideWithValue(
          const MethodChannelBackupDownloadsWriter(),
        ),
        checkpointKeyStoreProvider.overrideWithValue(
          SecureStorageCheckpointKeyStore(),
        ),
        checkpointDirectoryProvider.overrideWithValue(
          () async => getApplicationSupportDirectory(),
        ),
        startupRepositoryProvider.overrideWithValue(
          bootstrap.isReady
              ? startupRepository
              : BootstrapFailureStartupRepository(delegate: startupRepository),
        ),
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
        // OWNER correction #3: Backup & Restore operation feedback reaches the
        // notification shade through this same plugin instance and the same
        // granted notification permission. No second plugin, no scheduler and
        // no additional Android permission.
        transientNotificationGatewayProvider.overrideWithValue(
          notificationGateway,
        ),
        reminderDeviceLocationProvider.overrideWithValue(
          calendarEventTimeZones.deviceLocation,
        ),
        launcherBadgeGatewayProvider.overrideWithValue(launcherBadgeGateway),
        notificationResponseControllerProvider.overrideWithValue(
          notificationResponseController,
        ),
        backgroundWorkGatewayProvider.overrideWithValue(backgroundWorkGateway),
        // M8 section 28/30: the ONE repair-marker writer is shared with every
        // canonical mutation site, so the foreground recovery pass consumes the
        // exact rows those mutations committed.
        reminderRecoveryRequestProvider.overrideWithValue(
          reminderRecoveryRequest,
        ),
        reminderWorkerTransportProvider.overrideWithValue(
          scheduleCanonicalReminderWork,
        ),
        reminderWorkerReleaseProvider.overrideWithValue(
          cancelCanonicalReminderWork,
        ),
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
          bootstrap.mapsPreferences,
        ),
        weeklyPlanningRepositoryProvider.overrideWithValue(
          weeklyPlanningRepository,
        ),
        startOfWeekRepositoryProvider.overrideWithValue(startOfWeekRepository),
        deviceAppearanceRepositoryProvider.overrideWithValue(
          appearanceRepository,
        ),
        initialAppearanceProvider.overrideWithValue(bootstrap.appearance),
        initialThemeColorProvider.overrideWithValue(bootstrap.themeColor),
        taskEventLinkRepositoryProvider.overrideWithValue(
          taskEventLinkRepository,
        ),
        taskEventLinkCoordinatorProvider.overrideWithValue(
          taskEventLinkCoordinator,
        ),
      ],
      child: NextTransferApp(splashFirstFrameGate: splashFirstFrameGate),
    ),
  );
}
