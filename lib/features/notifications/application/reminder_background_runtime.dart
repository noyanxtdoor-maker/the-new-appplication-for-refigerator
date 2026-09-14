import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/background/workmanager_background_work_gateway.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/notifications/notification_preview_policy.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/indicators/application/indicator_providers.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_source_reader.dart';
import 'package:rmplanner/features/notifications/application/reminder_enrichment_resolver.dart';
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
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/data/drift_weekly_planning_repository.dart';

/// Snooze is DEFERRED (contract section 48).
///
/// The product exposes no Snooze action, and removing the UI is not a complete
/// runtime kill switch: a legacy or forged-but-valid Snooze intent could still
/// reach this entry point.  It is therefore handled TERMINALLY — no snooze
/// scheduling, no durable work mutation, no domain change — so an old queued
/// job terminates instead of retrying forever.
///
/// The compatibility fields/enums stay readable in storage; nothing is deleted
/// and no historical data is rewritten.
@pragma('vm:entry-point')
void nextTransferReminderAction(NotificationResponse response) {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  // Handled no-op: no decode, no scheduling, no domain mutation.
}

/// Handled no-op for a Snooze intent (contract section 48).
///
/// Returns whether the runtime handled the invocation.  Snooze is always
/// handled, and it never performs new reminder/domain behavior.
Future<bool> enqueueReminderSnooze({
  required NotificationResponseIntent? snooze,
  required DateTime actionAtUtc,
  Future<bool> Function(NotificationResponseIntent, DateTime)? applySnooze,
  BackgroundWorkGateway backgroundWork =
      const WorkmanagerBackgroundWorkGateway(),
}) async => true;

/// Targeted enriched delivery entry point (contract section 32).
///
/// Unlike [runReminderRuntime], this does NOT run the whole-horizon
/// reconciliation.  It composes the narrow delivery dependencies, delegates to
/// [ReminderDeliveryService] for the one durable reminder the dispatcher handed
/// us, and returns the outcome so the dispatcher can decide whether the OS
/// should retry.
///
/// No onboarding, authentication, navigation or domain mutation occurs, and the
/// worker never depends on `StartupReady` or any UI provider side effect.
Future<ReminderDeliveryOutcome> runCanonicalReminderDelivery(
  CanonicalReminderWorkSpec spec,
) async {
  final database = AppDatabase.defaults();
  try {
    const clock = SystemAppClock();
    final profiles = await (database.select(
      database.localProfiles,
    )..where((table) => table.slot.equals('primary'))).get();
    // No primary profile means there is nothing this key could own.  Terminal.
    if (profiles.length != 1) return ReminderDeliveryOutcome.handledObsolete;
    final profileId = profiles.single.id;
    final zones = await IanaCalendarEventTimeZones.forDevice();
    final repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    // Profile isolation: a key owned by another profile is never read, and its
    // private source is never touched (contract section 35).
    final durable = await repository.readWorkRequest(spec.stableKey);
    if (durable == null) return ReminderDeliveryOutcome.handledObsolete;
    if (durable.profileId != null && durable.profileId != profileId) {
      return ReminderDeliveryOutcome.handledObsolete;
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
    final privacyRepository = DriftPrivacyRepository(
      database: database,
      clock: clock,
    );
    final service = ReminderDeliveryService(
      repository: repository,
      gateway: gateway,
      source: DriftReminderDeliverySourceReader(
        database: database,
        clock: clock,
        events: events,
        zones: zones,
        enrichment: ReminderEnrichmentResolver(
          DriftReminderEnrichmentSource(database: database),
        ),
        tasks: DriftPlannerRepository(
          database: database,
          clock: clock,
          calendarSource: events,
        ),
        // The worker renders the SAME canonical Detailed content as the UI, so
        // it must honour the profile's saved per-field toggles.  The read is
        // fail-closed inside the reader: any read failure falls back to the
        // all-TRUE default rather than degrading the notification.
        detailedContent: (profileId) =>
            repository.readDetailedContent(profileId: profileId),
        privacy: () async {
          // M2 OWNER CORRECTION (Issue 1): re-read the CURRENT notification
          // preview preference only.  Privacy Lock is no longer an input to
          // notification content selection, so the worker never forces
          // Generic from the lock.  The worker still never requests
          // authentication in the background (contract section 16).
          final settings = await privacyRepository.readSettings();
          return resolveNotificationPreviewMode(settings: settings) ==
                  EffectiveNotificationPreviewMode.detailed
              ? NotificationDeliveryPrivacy.detailed
              : NotificationDeliveryPrivacy.generic;
        },
      ),
      clock: clock,
    );
    return await service.deliver(
      stableKey: spec.stableKey,
      scheduledUtcMs: spec.scheduledUtcMs,
      sourceRevision: spec.sourceRevision,
    );
  } on Object {
    // Runtime composition failed: report conservatively without fabricating a
    // delivery.  A later real trigger re-initializes.
    return ReminderDeliveryOutcome.retryable;
  } finally {
    await database.close();
  }
}

/// Uses the same source-specific application reconciliation paths as the UI.
/// No onboarding, authentication, navigation, or source-domain mutation occurs.
Future<bool> runReminderRuntime({
  String? deliveryKey,
  DateTime? scheduledAtUtc,
  NotificationResponseIntent? snooze,
  DateTime? actionAtUtc,
}) async {
  // Snooze is DEFERRED (contract section 48).  A legacy or dormant Snooze
  // invocation is handled terminally: no durable work transition, no reminder
  // scheduling and no domain mutation.  Returning true stops the OS from
  // retrying an intent the product no longer supports.
  if (snooze != null) return true;
  if (deliveryKey != null &&
      scheduledAtUtc != null &&
      scheduledAtUtc.isAfter(DateTime.now().toUtc())) {
    return false; // WorkManager retry after a backward clock adjustment.
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
    // The headless isolate is a second caller of the SAME transport ports.  It
    // must use the one real WorkManager gateway so a recovery pass can neither
    // double-register nor silently orphan a queued worker job (section 6/65).
    const work = WorkmanagerBackgroundWorkGateway();
    try {
      await work.initialize();
    } on Object {
      // Without a usable background gateway recovery still runs, but no key is
      // marked `m7w_` — an unbacked marker would claim a transport that does
      // not exist and could suppress the native reminder entirely.
      return true;
    }
    final gateway = FlutterLocalNotificationsGateway(
      runningDeliveryPlatformId: deliveryWork?.platformNotificationId,
    );
    await gateway.initialize();
    final events = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: zones,
    );
    // The headless runtime composes the SAME canonical planning dependencies as
    // main.dart (contract section 26): the real WeeklyPlanning repository with
    // the same clock, identifier source, time zones and Indicator repository.
    // Planning recovery therefore reads canonical truth instead of skipping.
    final indicators = DriftIndicatorRepository(
      database: database,
      clock: clock,
      calendarEvents: events,
    );
    final weeklyPlans = DriftWeeklyPlanningRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
      timeZones: zones,
      indicators: indicators,
    );
    final reminderRepair = ReminderRecoveryRequest(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
    container = ProviderContainer(
      overrides: [
        reminderRuntimeProfileIdProvider.overrideWithValue(profileId),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(gateway),
        backgroundWorkGatewayProvider.overrideWithValue(work),
        reminderRecoveryRequestProvider.overrideWithValue(reminderRepair),
        weeklyPlanningRepositoryProvider.overrideWithValue(weeklyPlans),
        indicatorRepositoryProvider.overrideWithValue(indicators),
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
            // Recovery can itself gain or lose enrichment eligibility, so the
            // headless pass owns the same transport ports as the app root.
            // Section 6 keeps exactly one live delivery owner per key across
            // both isolates.
            scheduleWorker:
                ({required stableKey,
                  required scheduledAtUtc,
                  required sourceRevision,
                  required platformNotificationId}) async {
                  final spec = CanonicalReminderWorkSpec(
                    stableKey: stableKey,
                    scheduledUtcMs: scheduledAtUtc.millisecondsSinceEpoch,
                    sourceRevision: sourceRevision,
                  );
                  await work.enqueueUnique(
                    spec.toWorkSpec(
                      platformNotificationId: platformNotificationId,
                      nowUtc: clock.nowUtc(),
                    ),
                  );
                },
            cancelWorker: (uniqueName) => work.cancelUnique(uniqueName),
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
        // VS16 M7 corrective — inherited headless defect.
        //
        // `startupRepositoryProvider` and `diagnosticsProvider` are declared in
        // startup_providers.dart to THROW until an app root overrides them.
        // `StartupController.build()` reads `_diagnostics` before its first
        // await, so any headless read that reaches StartupController raises
        // `ProviderException: ... SanitizedDiagnostics must be overridden at
        // the app root` and the whole reconciliation fails closed.
        //
        // Only `diagnosticsProvider` is required here. `SanitizedDiagnostics`
        // is pure Dart with no UI, plugin or profile dependency, so it is
        // trivially safe in a WorkManager isolate.
        //
        // `startupRepositoryProvider` is deliberately NOT overridden:
        // CalendarEventController._profileId reads
        // `reminderRuntimeProfileIdProvider` FIRST and only falls back to the
        // startup controller, which this container already overrides above.
        // Overriding the startup repository would pull UI startup semantics
        // (opening a profile, migrating, seeding) into the worker isolate,
        // which this correction must not do.
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
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
