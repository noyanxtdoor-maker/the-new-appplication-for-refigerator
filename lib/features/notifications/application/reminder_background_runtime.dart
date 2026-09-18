import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/workmanager_background_work_gateway.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
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
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

@pragma('vm:entry-point')
void nextTransferReminderAction(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final intent = NotificationPayloadCodec.tryDecode(
    response.payload,
    actionId: response.actionId,
  );
  if (intent?.action != NotificationResponseAction.snooze) return;
  await enqueueReminderSnooze(
    snooze: intent,
    actionAtUtc: DateTime.now().toUtc(),
  );
}

Future<void> enqueueReminderSnooze({
  required NotificationResponseIntent? snooze,
  required DateTime actionAtUtc,
  Future<bool> Function(NotificationResponseIntent, DateTime)? applySnooze,
  BackgroundWorkGateway backgroundWork =
      const WorkmanagerBackgroundWorkGateway(),
}) async {
  if (snooze == null ||
      snooze.action != NotificationResponseAction.snooze ||
      snooze.occurrenceId == null ||
      (snooze.sourceKind != NotificationSourceKind.calendarEvent &&
          snooze.sourceKind != NotificationSourceKind.task)) {
    return;
  }
  // The notification response isolate is already running. Persist and schedule
  // now: WorkManager's opportunistic startup/retry can outlast a 1-minute Snooze.
  // The same transaction and generation checks serialize simultaneous taps.
  final applied =
      await (applySnooze ??
          (intent, at) => runReminderRuntime(snooze: intent, actionAtUtc: at))(
        snooze,
        actionAtUtc,
      );
  if (applied) return;
  // Only a retryable runtime failure needs deferred background execution.
  await backgroundWork.enqueueUnique(
    BackgroundWorkSpec(
      uniqueName:
          'nt.snooze.${snooze.sourceId}.${snooze.occurrenceId}.${snooze.generation}',
      taskName: 'nt.reminder.snooze',
      inputData: {
        'profile_id': snooze.profileId,
        'source_kind': snooze.sourceKind.name,
        'source_id': snooze.sourceId,
        'occurrence_id': snooze.occurrenceId,
        'generation': snooze.generation,
        'action_utc_ms': actionAtUtc.millisecondsSinceEpoch,
      },
    ),
  );
}

/// Uses the same source-specific application reconciliation paths as the UI.
/// No onboarding, authentication, navigation, or source-domain mutation occurs.
/// Astra §48: [snoozeIgnored] handles the deferred Snooze intent as a no-op;
/// [legacyDeliveryIgnored] terminates legacy two-key delivery input; targeted
/// delivery threads [deliverySourceRevision] for §32 generation comparison.
Future<bool> runReminderRuntime({
  String? deliveryKey,
  DateTime? scheduledAtUtc,
  String? deliverySourceRevision,
  NotificationResponseIntent? snooze,
  DateTime? actionAtUtc,
  bool snoozeIgnored = false,
  bool legacyDeliveryIgnored = false,
}) async {
  if (snoozeIgnored || legacyDeliveryIgnored) {
    // Handled no-op: legacy Snooze jobs and legacy delivery input terminate
    // without scheduling, retrying or mutating any domain/work row (§32/§48).
    return true;
  }
  if (deliveryKey != null &&
      scheduledAtUtc != null &&
      scheduledAtUtc.isAfter(DateTime.now().toUtc())) {
    return false; // WorkManager retry after a backward clock adjustment.
  }
  // Astra §48: a targeted delivery whose registration never posted (m7w_ row
  // absent/terminal in the durable store) is a NOT-YET-POSTED reminder, not
  // a replay.  It is delivered through the targeted service without any
  // whole-horizon recovery pass, then recovery proceeds normally.
  if (deliveryKey != null &&
      deliverySourceRevision != null &&
      scheduledAtUtc != null &&
      await _deliverUnpostedTargetedGeneration(
        deliveryKey: deliveryKey,
        scheduledAtUtc: scheduledAtUtc,
        sourceRevision: deliverySourceRevision,
      )) {
    return true;
  }
  final database = AppDatabase.defaults();
  ProviderContainer? container;
  try {
    const clock = SystemAppClock();
    final profiles = await (database.select(
      database.localProfiles,
    )..where((table) => table.slot.equals('primary'))).get();
    if (profiles.length != 1) return true;
    final profileId = profiles.single.id;
    if (snooze != null && snooze.profileId != profileId) return true;
    final zones = await IanaCalendarEventTimeZones.forDevice();
    final repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    final deliveryWork = deliveryKey == null
        ? null
        : await repository.readWorkRequest(deliveryKey);
    final gateway = FlutterLocalNotificationsGateway(
      runningDeliveryPlatformId: deliveryWork?.platformNotificationId,
    );
    await gateway.initialize();
    final events = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: zones,
    );
    container = ProviderContainer(
      overrides: [
        reminderRuntimeProfileIdProvider.overrideWithValue(profileId),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(gateway),
        reminderReconcilerProvider.overrideWithValue(
          ReminderReconciler(
            repository: repository,
            gateway: gateway,
            clock: clock,
            backgroundWork: const WorkmanagerBackgroundWorkGateway(),
            deliveryKey: deliveryKey,
            deliveryScheduledAtUtc: scheduledAtUtc,
            deliverySourceRevision: deliverySourceRevision,
            snoozeIntent: snooze,
            actionAtUtc: actionAtUtc,
            deviceLocation: zones.deviceLocation,
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
        permissionGatewayProvider.overrideWithValue(
          const PermissionHandlerGateway(),
        ),
      ],
    );
    await database.transaction(() async {
      // Acquire the SQLite writer lock without modifying any source row.
      // Concurrent headless recovery/actions retry instead of double-delivering.
      await database.customStatement(
        'UPDATE background_work_requests SET attempt_count = attempt_count WHERE 0',
      );
      await container!.read(reconcileRemindersProvider)();
    });
    return true;
  } on Object {
    return false;
  } finally {
    container?.dispose();
    await database.close();
  }
}

/// §48 targeted delivery for a not-yet-posted m7w generation.  Returns true
/// when the invocation was HANDLED (delivered/suppressed/superseded, or the
/// row turned out to be natively owned/absent so the full pass may proceed);
/// false when the caller must run the standard runtime (registration repair
/// and whole-horizon reconciliation).
Future<bool> _deliverUnpostedTargetedGeneration({
  required String deliveryKey,
  required DateTime scheduledAtUtc,
  required String sourceRevision,
}) async {
  final database = AppDatabase.defaults();
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
    final durable = await repository.readWorkRequest(deliveryKey);
    // Absent durable row: registration was lost before its first post.  The
    // reminder has NOT been posted; repair runs below, never a silent drop.
    if (durable == null || durable.profileId != profileId) return false;
    if (ReminderReconciler.transportGenerationPrefix(
          durable.sourceRevision,
        ) ==
        null) {
      return true; // legacy/planning row: not a targeted delivery.
    }
    if (!ReminderReconciler.hasWorkerTransport(durable.sourceRevision)) {
      return true; // native owns this key: worker must not post.
    }
    final gateway = FlutterLocalNotificationsGateway(
      runningDeliveryPlatformId: durable.platformNotificationId,
    );
    await gateway.initialize();
    final events = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: zones,
    );
    final eventTypeRepository = DriftEventTypeRepository(
      database: database,
      clock: clock,
    );
    final settings = await eventTypeRepository.readPlannerSettings(
      profileId: profileId,
    );
    final plannerRepository = DriftPlannerRepository(
      database: database,
      clock: clock,
      calendarSource: events,
    );
    final permissionGateway = const PermissionHandlerGateway();
    final service = ReminderDeliveryService(
      database: database,
      repository: repository,
      enrichmentSource: DriftReminderEnrichmentSource(database: database),
      events: events,
      tasks: plannerRepository,
      readPrivacySettings: () => DriftPrivacyRepository(
        database: database,
        clock: clock,
      ).readSettings(),
      notificationPermission:
          () => permissionGateway.status(OptionalPermission.notifications),
      gateway: gateway,
      clock: clock,
      eventDefaultOffsetMinutes: () async => settings.defaultReminderMinutes,
      deviceLocation: zones.deviceLocation,
    );
    final handled = await service.deliver(
      stableKey: deliveryKey,
      scheduledForUtc: scheduledAtUtc,
      sourceRevision: sourceRevision,
    );
    if (!handled) return false;
    // Guard the just-completed generation against a recovery pass that could
    // otherwise reclassify it mid-flight (§32/§36 serialization boundary).
    container = ProviderContainer(
      overrides: [
        reminderRuntimeProfileIdProvider.overrideWithValue(profileId),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(gateway),
        reminderReconcilerProvider.overrideWithValue(
          ReminderReconciler(
            repository: repository,
            gateway: gateway,
            clock: clock,
            backgroundWork: const WorkmanagerBackgroundWorkGateway(),
            deliveryKey: deliveryKey,
            deliveryScheduledAtUtc: scheduledAtUtc,
            deliverySourceRevision: sourceRevision,
            deviceLocation: zones.deviceLocation,
          ),
        ),
        calendarEventRepositoryProvider.overrideWithValue(events),
        eventTypeRepositoryProvider.overrideWithValue(eventTypeRepository),
        plannerRepositoryProvider.overrideWithValue(plannerRepository),
        privacyRepositoryProvider.overrideWithValue(
          DriftPrivacyRepository(database: database, clock: clock),
        ),
        permissionGatewayProvider.overrideWithValue(permissionGateway),
      ],
    );
    await database.transaction(() async {
      await database.customStatement(
        'UPDATE background_work_requests SET attempt_count = attempt_count WHERE 0',
      );
      await container!.read(reconcileRemindersProvider)();
    });
    return true;
  } on Object {
    return false; // standard runtime below records truthful retry evidence.
  } finally {
    container?.dispose();
    await database.close();
  }
}
