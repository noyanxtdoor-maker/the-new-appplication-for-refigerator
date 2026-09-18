import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/background/workmanager_background_work_gateway.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_gateway.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_launcher_badge_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/data/drift_reminder_enrichment_source.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/data/permission_handler_gateway.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/data/drift_weekly_planning_repository.dart';

@pragma('vm:entry-point')
void nextTransferReminderAction(NotificationResponse response) async {
  // VS16 M7/M8: notifications carry no actions and Snooze is deferred.  The
  // background response entry point terminates without any work or domain
  // mutation so legacy/forged action payloads can never execute Snooze.
}

/// Snooze is deferred from the current product.  The legacy entry point stays
/// source-compatible but performs no scheduling and no domain/work mutation.
Future<void> enqueueReminderSnooze({
  required NotificationResponseIntent? snooze,
  required DateTime actionAtUtc,
  Future<bool> Function(NotificationResponseIntent, DateTime)? applySnooze,
  BackgroundWorkGateway backgroundWork =
      const WorkmanagerBackgroundWorkGateway(),
}) async {
  return;
}

/// Uses the same source-specific application reconciliation paths as the UI.
/// No onboarding, authentication, navigation, or source-domain mutation occurs.
///
/// The override parameters exist ONLY for deterministic runtime tests; every
/// production dispatcher calls this function without them so the real plugin
/// adapters and the canonical database are always used.
Future<bool> runReminderRuntime({
  String? deliveryKey,
  DateTime? scheduledAtUtc,
  String? sourceRevision,
  NotificationResponseIntent? snooze,
  DateTime? actionAtUtc,
  BackgroundWorkGateway? backgroundGatewayOverride,
  AppDatabase? databaseOverride,
  NotificationGateway? gatewayOverride,
  Future<void> Function()? reconcileOverride,
  List<Override> containerOverrides = const <Override>[],
}) async {
  if (snooze != null) return true; // Snooze deferred: handled no-op.
  if (deliveryKey != null &&
      scheduledAtUtc != null &&
      scheduledAtUtc.isAfter(DateTime.now().toUtc())) {
    return false; // WorkManager retry after a backward clock adjustment.
  }
  // A test-owned database is never closed here; its fixture owns the
  // lifecycle. Production always uses the canonical AppDatabase.defaults().
  final database = databaseOverride ?? AppDatabase.defaults();
  final ownsDatabase = databaseOverride == null;
  ProviderContainer? container;
  try {
    const clock = SystemAppClock();
    final profiles = await (database.select(
      database.localProfiles,
    )..where((table) => table.slot.equals('primary'))).get();
    if (profiles.length != 1) return true;
    final profileId = profiles.single.id;
    final zones = await IanaCalendarEventTimeZones.forDevice();
    final repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    final deliveryWork = deliveryKey == null
        ? null
        : await repository.readWorkRequest(deliveryKey);
    final gateway =
        gatewayOverride ??
        FlutterLocalNotificationsGateway(
          runningDeliveryPlatformId: deliveryWork?.platformNotificationId,
        );
    if (gatewayOverride == null) {
      await gateway.initialize();
    }
    final backgroundGateway =
        backgroundGatewayOverride ?? const WorkmanagerBackgroundWorkGateway();
    final events = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: zones,
    );
    final planner = DriftPlannerRepository(
      database: database,
      clock: clock,
      calendarSource: events,
    );
    final eventTypes = DriftEventTypeRepository(
      database: database,
      clock: clock,
    );
    final privacyRepository = DriftPrivacyRepository(
      database: database,
      clock: clock,
    );
    final weeklyPlanningRepository = DriftWeeklyPlanningRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
      timeZones: zones,
      indicators: DriftIndicatorRepository(
        database: database,
        clock: clock,
        calendarEvents: events,
      ),
    );
    container = ProviderContainer(
      overrides: [
        reminderRuntimeProfileIdProvider.overrideWithValue(profileId),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(gateway),
        reminderBackgroundWorkGatewayProvider.overrideWithValue(
          backgroundGateway,
        ),
        reminderDeviceLocationProvider.overrideWithValue(zones.deviceLocation),
        reminderReconcilerProvider.overrideWithValue(
          ReminderReconciler(
            repository: repository,
            gateway: gateway,
            clock: clock,
            deliveryKey: deliveryKey,
            deliveryScheduledAtUtc: scheduledAtUtc,
            snoozeIntent: snooze,
            actionAtUtc: actionAtUtc,
            deviceLocation: zones.deviceLocation,
            backgroundWorkGateway: backgroundGateway,
          ),
        ),
        calendarEventRepositoryProvider.overrideWithValue(events),
        eventTypeRepositoryProvider.overrideWithValue(eventTypes),
        plannerRepositoryProvider.overrideWithValue(planner),
        privacyRepositoryProvider.overrideWithValue(privacyRepository),
        permissionGatewayProvider.overrideWithValue(
          const PermissionHandlerGateway(),
        ),
        weeklyPlanningRepositoryProvider.overrideWithValue(
          weeklyPlanningRepository,
        ),
        ...containerOverrides,
      ],
    );
    if (deliveryKey != null && sourceRevision != null) {
      if (deliveryWork == null) return true;
      if (gateway is! CanonicalReminderDeliveryGateway) return false;
      final service = ReminderDeliveryService(
        repository: repository,
        deliveryGateway: gateway as CanonicalReminderDeliveryGateway,
        notificationGateway: gateway,
        events: events,
        tasks: planner,
        eventTypes: eventTypes,
        privacy: privacyRepository,
        permission: const PermissionHandlerGateway(),
        enrichmentSource: DriftReminderEnrichmentSource(database: database),
        clock: clock,
        deviceLocation: zones.deviceLocation,
        requestFullReconcile: () =>
            reconcileOverride?.call() ??
            container!.read(reconcileRemindersProvider)(),
      );
      final outcome = await service.deliver(
        stableKey: deliveryKey,
        scheduledAtUtc: scheduledAtUtc!,
        sourceRevision: sourceRevision,
      );
      return !outcome.retryable;
    }
    if (deliveryKey != null) {
      // Legacy two-key delivery input has no authoritative revision: terminal.
      return true;
    }
    final nowUtc = clock.nowUtc();
    final hadMarker = await ReminderRecoveryRequest.markRunning(
      database: database,
      profileId: profileId,
      nowUtc: nowUtc,
    );
    try {
      await database.transaction(() async {
        // Acquire the SQLite writer lock without modifying any source row.
        // Concurrent headless recovery/actions retry instead of double-delivering.
        await database.customStatement(
          'UPDATE background_work_requests SET attempt_count = attempt_count WHERE 0',
        );
        await (reconcileOverride?.call() ??
            container!.read(reconcileRemindersProvider)());
      });
      if (hadMarker) {
        await ReminderRecoveryRequest.markCompleted(
          database: database,
          profileId: profileId,
          nowUtc: clock.nowUtc(),
        );
      }
      // VS16 M8 (contract section 28): bounded reminder horizon-refill.
      // Exactly one unique one-off (nt.reminder.refill) re-arms ONLY after a
      // successful recovery pass so the 42-day projection is rebuilt even if
      // the app stays closed. Empty input, KEEP policy, no network/charging
      // constraint; a failed arm simply waits for the next recovery trigger
      // and never spawns a chain or a second refill name.
      try {
        await backgroundGateway.enqueueUnique(
          const BackgroundWorkSpec(
            uniqueName: 'nt.reminder.refill',
            taskName: 'nt.reminder.recovery',
            initialDelay: Duration(hours: 24),
            existingPolicy: BackgroundExistingWorkPolicy.keep,
          ),
        );
      } on Object {
        // Refill is maintenance, never owner truth.
      }
    } on Object {
      if (hadMarker) {
        await ReminderRecoveryRequest.markFailed(
          database: database,
          profileId: profileId,
          nowUtc: clock.nowUtc(),
          failureCategory: 'runtime_unavailable',
        );
      }
      rethrow;
    }
    // Reverse platform sweep: cancel a pending owned reminder that no durable
    // row or an obsolete durable row claims.  The badge ID and foreign
    // payloads are never touched.
    await _sweepOrphanedPendingReminders(
      gateway: gateway,
      repository: repository,
      profileId: profileId,
    );
    return true;
  } on Object {
    return false;
  } finally {
    container?.dispose();
    if (ownsDatabase) {
      await database.close();
    }
  }
}

Future<void> _sweepOrphanedPendingReminders({
  required NotificationGateway gateway,
  required DriftNotificationFoundationRepository repository,
  required String profileId,
}) async {
  try {
    final pending = await gateway.pending();
    for (final item in pending) {
      if (item.platformId ==
          FlutterLocalNotificationsLauncherBadgeGateway.notificationId) {
        continue;
      }
      final row = await repository.readWorkRequestByPlatformId(item.platformId);
      if (row == null) {
        final payload = NotificationPayloadCodec.tryDecode(item.payload);
        if (payload != null && payload.profileId == profileId) {
          await gateway.cancel(item.platformId);
        }
        continue;
      }
      if (row.profileId != profileId) continue;
      if (row.state == BackgroundWorkState.cancelledObsolete ||
          row.state == BackgroundWorkState.failedActionRequired) {
        await gateway.cancel(item.platformId);
      }
    }
  } on Object {
    // Sweep is best-effort repair, never source truth.
  }
}
