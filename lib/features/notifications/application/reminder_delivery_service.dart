import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/database/app_database.dart' hide NotificationPreferences;
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/notifications/notification_preview_policy.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_enrichment_resolver.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/application/reminder_quiet_hours.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:timezone/timezone.dart' as tz;

/// Sanitized failure categories (Astra §31 allowlist).
abstract final class ReminderFailureCategory {
  static const dbBusy = 'db_busy';
  static const platformUnavailable = 'platform_unavailable';
  static const staleSource = 'stale_source';
  static const permissionDisabled = 'permission_disabled';
  static const retryExhausted = 'retry_exhausted';
  static const deliveryUncertain = 'delivery_uncertain';
  static const runtimeUnavailable = 'runtime_unavailable';
}

/// Astra §32/P16: targeted enriched delivery for one durable m7w Event/Task
/// reminder.  Owns NO recurrence arithmetic and NO whole-horizon scan: the
/// worker input identifies one stable key, and every fact is re-read from
/// canonical current truth at execution.  Returns the value handed to the
/// WorkManager dispatcher: false ONLY for bounded, durably recorded
/// retryable work (§31); every handled/suppressed/superseded outcome is true.
final class ReminderDeliveryService {
  ReminderDeliveryService({
    required this.database,
    required this.repository,
    required this.enrichmentSource,
    required this.events,
    required this.tasks,
    required this.readPrivacySettings,
    required this.notificationPermission,
    required this.gateway,
    required this.clock,
    required this.eventDefaultOffsetMinutes,
    this.deviceLocation,
  }) : enrichmentResolver = ReminderEnrichmentResolver(source: enrichmentSource);

  final AppDatabase database;

  final NotificationFoundationRepository repository;
  final ReminderEnrichmentSource enrichmentSource;
  final CalendarEventRepository events;
  final PlannerRepository tasks;
  final Future<PrivacySettings> Function() readPrivacySettings;
  final Future<OperatingSystemPermissionState> Function()
  notificationPermission;
  final CanonicalReminderDeliveryGateway gateway;
  final AppClock clock;
  final tz.Location? deviceLocation;
  final ReminderEnrichmentResolver enrichmentResolver;

  /// Effective Event default offset source (planner settings law: Events use
  /// the Event Type/Planner default; Tasks use the notification preference).
  final Future<int?> Function() eventDefaultOffsetMinutes;

  static const int maxAttemptsPerGeneration = 5;
  static const List<Duration> retryBackoff = <Duration>[
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
    Duration(seconds: 240),
  ];

  static const Set<BackgroundWorkState> _terminalStates =
    <BackgroundWorkState>{
      BackgroundWorkState.completed,
      BackgroundWorkState.cancelledObsolete,
      BackgroundWorkState.failedActionRequired,
    };

  /// Stable key grammar (§12): Event
  /// `reminder:calendarEvent:<profileId>:<occurrenceId>:base`, Task
  /// `reminder:task:<profileId>:task:<taskId>:<projectedDate>:base`.
  static _DeliveryTarget? _parseTarget(String stableKey) {
    final parts = stableKey.split(':');
    if (parts.length == 5 &&
        parts[0] == 'reminder' &&
        parts[1] == ReminderSourceKind.calendarEvent.name &&
        parts[4] == 'base') {
      return _DeliveryTarget(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: parts[2],
        sourceId: parts[2] == '' ? '' : parts[2],
        occurrenceId: parts[3],
      );
    }
    if (parts.length == 5 &&
        parts[0] == 'reminder' &&
        parts[1] == ReminderSourceKind.task.name &&
        parts[4] == 'base') {
      // Non-recurring task key: occurrenceId encodes task:<taskId>:<date>.
      final occurrence = parts[3].split(':');
      if (occurrence.length == 3 && occurrence[0] == 'task') {
        return _DeliveryTarget(
          sourceKind: ReminderSourceKind.task,
          profileId: parts[2],
          sourceId: occurrence[1],
          occurrenceId: parts[3],
        );
      }
      return null;
    }
    if (parts.length == 7 &&
        parts[0] == 'reminder' &&
        parts[1] == ReminderSourceKind.task.name &&
        parts[3] == 'task' &&
        parts[6] == 'base') {
      return _DeliveryTarget(
        sourceKind: ReminderSourceKind.task,
        profileId: parts[2],
        sourceId: parts[4],
        occurrenceId: '${parts[3]}:${parts[4]}:${parts[5]}',
      );
    }
    return null;
  }

  Future<bool> deliver({
    required String stableKey,
    required DateTime scheduledForUtc,
    required String sourceRevision,
  }) async {
    final DateTime now;
    try {
      now = clock.nowUtc();
    } on Object {
      return true; // clock unavailable: terminate, no invented bookkeeping.
    }
    // §32 step 1: exact three technical fields (parsed by the dispatcher).
    final target = _parseTarget(stableKey);
    if (target == null) {
      return true; // malformed/foreign key: handled no-op.
    }
    // §32 step 2/§35: primary profile resolution and input/durable ownership.
    final String profileId;
    try {
      profileId = await _resolvePrimaryProfileId();
    } on Object {
      return true; // §31: cannot resolve runtime — report via diagnostics.
    }
    if (profileId.isEmpty || profileId != target.profileId) {
      return true; // §35: wrong-profile input terminates without reading.
    }
    BackgroundWorkRequest? row;
    try {
      row = await repository.readWorkRequest(stableKey);
    } on Object {
      return _recordRuntimeUnavailable(stableKey, sourceRevision);
    }
    if (row == null) {
      return true; // no durable owner: orphan, owned sweep cleans up.
    }
    if (row.profileId != profileId) {
      return true; // §35 isolation.
    }
    if (!_inputMatchesDurableGeneration(
      input: sourceRevision,
      inputScheduledForUtc: scheduledForUtc,
      durable: row,
    )) {
      return true; // superseded generation: zero effect on the newer row.
    }
    if (ReminderReconciler.transportGenerationPrefix(row.sourceRevision) ==
        null) {
      return true; // no transport generation: legacy/planning row; not ours.
    }
    if (!ReminderReconciler.hasWorkerTransport(row.sourceRevision)) {
      return true; // m7n/native owns this row; the worker must not post.
    }
    if (_terminalStates.contains(row.state) ||
        row.state == BackgroundWorkState.running) {
      return true; // terminal/concurrent: no replay, no competing post.
    }

    try {
      return await _deliverGeneration(
        target: target,
        stableKey: stableKey,
        scheduledForUtc: scheduledForUtc,
        sourceRevision: sourceRevision,
        row: row,
        profileId: profileId,
        now: now,
      );
    } on Object {
      // Known transient source/platform failure AFTER the durable claim is
      // bounded by the generation attempt budget (§31).
      return _recordRetryOrExhaust(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: scheduledForUtc,
        now: clock.nowUtc(),
        failureCategory: ReminderFailureCategory.staleSource,
      );
    }
  }

  /// §32 step 3 law refined by §18/§33 G3: input must match the durable row
  /// on key, target and TRANSPORT generation; a content-only fingerprint
  /// difference at the identical target is NOT supersession — the worker
  /// renders live current truth anyway.
  static bool _inputMatchesDurableGeneration({
    required String input,
    required DateTime inputScheduledForUtc,
    required BackgroundWorkRequest durable,
  }) {
    if (durable.scheduledForUtc == null ||
        !durable.scheduledForUtc!.isAtSameMomentAs(inputScheduledForUtc)) {
      return false;
    }
    final durableTiming = ReminderReconciler.transportGenerationPrefix(
      durable.sourceRevision,
    );
    final inputTiming = ReminderReconciler.transportGenerationPrefix(input);
    return durableTiming != null && durableTiming == inputTiming;
  }

  Future<String> _resolvePrimaryProfileId() async {
    final rows = await (database.select(
      database.localProfiles,
    )..where((table) => table.slot.equals('primary'))).get();
    return rows.length == 1 ? rows.single.id : '';
  }

  Future<bool> _deliverGeneration({
    required _DeliveryTarget target,
    required String stableKey,
    required DateTime scheduledForUtc,
    required String sourceRevision,
    required BackgroundWorkRequest row,
    required String profileId,
    required DateTime now,
  }) async {
    // §32 step 4: canonical source resolution (no recurrence fork).
    final policies = await repository.readPolicies(
      profileId: profileId,
      sourceKind: target.sourceKind,
      sourceId: target.sourceId,
    );
    final policy =
        policies.where((p) => p.occurrenceId == target.occurrenceId).firstOrNull ??
        policies
            .where((p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId)
            .firstOrNull;
    final preferences = await repository.readPreferences(profileId: profileId);
    final effectiveOffset = switch (policy?.mode) {
      ReminderPolicyMode.offset => policy!.offsetMinutes,
      ReminderPolicyMode.off => null, // Off != zero (§64).
      _ => target.sourceKind == ReminderSourceKind.task
          ? preferences.defaultTaskReminderMinutes
          : await eventDefaultOffsetMinutes(),
    };
    if (effectiveOffset == null || effectiveOffset < 0) {
      return _suppressObsolete(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: scheduledForUtc,
        reason: ReminderFailureCategory.staleSource,
      );
    }

    String? followUpName;
    String? locationText;
    String detailedBody;

    switch (target.sourceKind) {
      case ReminderSourceKind.calendarEvent:
        final occurrence = await (events is CalendarEventOccurrenceIdLookup
            ? (events as CalendarEventOccurrenceIdLookup).readOccurrenceById(
                profileId: profileId,
                eventId: target.sourceId,
                occurrenceId: target.occurrenceId,
              )
            : Future<CalendarEventOccurrence?>.value());
        if (occurrence == null ||
            occurrence.status != CalendarEventStatus.scheduled ||
            occurrence.timing != CalendarEventTiming.timed ||
            occurrence.startUtc == null ||
            occurrence.endUtc == null) {
          return _suppressObsolete(
            stableKey: stableKey,
            expectedRevision: sourceRevision,
            expectedScheduledForUtc: scheduledForUtc,
            reason: ReminderFailureCategory.staleSource,
          );
        }
        final startUtc = occurrence.startUtc!;
        final endUtc = occurrence.endUtc!;
        // §64 Event-end relevance window; zero offset stays valid.
        final eligibility = ReminderDeliveryEligibility.compute(
          nowUtc: now,
          startUtc: startUtc,
          endUtc: endUtc,
          offsetMinutes: effectiveOffset,
          quietHours: preferences.quietHours,
          deviceLocation: deviceLocation,
        );
        if (eligibility.outcome ==
            ReminderDeliveryEligibilityOutcome.expired) {
          return _suppressObsolete(
            stableKey: stableKey,
            expectedRevision: sourceRevision,
            expectedScheduledForUtc: scheduledForUtc,
            reason: ReminderFailureCategory.staleSource,
          );
        }
        if (eligibility.outcome ==
            ReminderDeliveryEligibilityOutcome.beforeWindow) {
          return true; // future target: reconciler owns registration.
        }
        // §64 step 5: never post during current Quiet Hours.
        final quietRearm = await _quietHoursRearmOrSuppress(
          now: now,
          relevanceStartUtc: startUtc,
          stableKey: stableKey,
          expectedRevision: sourceRevision,
          expectedScheduledForUtc: scheduledForUtc,
          preferences: preferences,
        );
        if (quietRearm != null) {
          return quietRearm;
        }
        final enrichment = await _resolveEnrichment(
          target: target,
          profileId: profileId,
          policy: policy,
          now: now,
        );
        followUpName = enrichment.followUpDisplayName;
        locationText = enrichment.locationText;
        detailedBody = ReminderNotificationRenderer().eventWorkerBody(
          startDisplay: _clockLabel(occurrence.startDisplay),
          endDisplay: _clockLabel(occurrence.endDisplay),
          notes: occurrence.notes,
          followUpDisplayName: followUpName,
          locationText: locationText,
        );
      case ReminderSourceKind.task:
        final task = await tasks.readTask(
          profileId: profileId,
          taskId: target.sourceId,
        );
        if (task == null || task.status != PlannerTaskStatus.incomplete) {
          return _suppressObsolete(
            stableKey: stableKey,
            expectedRevision: sourceRevision,
            expectedScheduledForUtc: scheduledForUtc,
            reason: ReminderFailureCategory.staleSource,
          );
        }
        final minute = task.dueMinute;
        if (minute == null) {
          return _suppressObsolete(
            stableKey: stableKey,
            expectedRevision: sourceRevision,
            expectedScheduledForUtc: scheduledForUtc,
            reason: ReminderFailureCategory.staleSource,
          );
        }
        final due = task.dueDate!;
        final dueUtc = DateTime(
          due.year,
          due.month,
          due.day,
          minute ~/ 60,
          minute % 60,
        ).toUtc();
        final targetUtc = dueUtc.subtract(
          Duration(minutes: effectiveOffset),
        );
        if (now.isBefore(targetUtc)) {
          return true; // future Task target: reconciler owns registration.
        }
        // Task relevance: current incomplete timed occurrence + Quiet Hours
        // (§64: E is NOT applied to Task/planning).
        final quietRearm = await _quietHoursRearmOrSuppress(
          now: now,
          relevanceStartUtc: null,
          stableKey: stableKey,
          expectedRevision: sourceRevision,
          expectedScheduledForUtc: scheduledForUtc,
          preferences: preferences,
        );
        if (quietRearm != null) {
          return quietRearm;
        }
        final enrichment = await _resolveEnrichment(
          target: target,
          profileId: profileId,
          policy: policy,
          now: now,
        );
        followUpName = enrichment.followUpDisplayName;
        detailedBody = ReminderNotificationRenderer().taskWorkerBody(
          dueDisplay: _dueLabel(dueUtc),
          notes: task.notes,
          followUpDisplayName: followUpName,
        );
      case ReminderSourceKind.weeklyReview:
      case ReminderSourceKind.awaitingReport:
        return true; // planning remains native; never a targeted worker row.
    }

    // §32 step 4/5 gates: master, category, permission (authoritative).
    if (!preferences.systemNotificationsEnabled ||
        !_categoryEnabled(preferences, target.sourceKind)) {
      return _suppressObsolete(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: scheduledForUtc,
        reason: ReminderFailureCategory.permissionDisabled,
      );
    }
    bool permissionGranted;
    try {
      permissionGranted =
          await notificationPermission() ==
          OperatingSystemPermissionState.granted;
    } on Object {
      return _recordRetryOrExhaust(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: scheduledForUtc,
        now: clock.nowUtc(),
        failureCategory: ReminderFailureCategory.platformUnavailable,
      );
    }
    if (!permissionGranted) {
      return _suppressObsolete(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: scheduledForUtc,
        reason: ReminderFailureCategory.permissionDisabled,
      );
    }

    // §32 step 6: current privacy (failure degrades to Generic).
    bool detailed;
    try {
      final privacy = await readPrivacySettings();
      detailed =
          resolveNotificationPreviewMode(
            settings: privacy,
            privacyProtectionRequired: privacy.lockEnabled,
          ) ==
          EffectiveNotificationPreviewMode.detailed;
    } on Object {
      detailed = false;
    }

    // §32 step 7: durable claim with expected generation CAS.  Attempt is
    // persisted before any show; rollback cannot erase it.
    final claimed = await repository.claimForDelivery(
      stableKey: stableKey,
      expectedRevision: sourceRevision,
      expectedScheduledForUtc: scheduledForUtc,
      nowUtc: clock.nowUtc(),
    );
    if (claimed == null) {
      return true; // newer generation won; this invocation never posts.
    }
    if (claimed.attemptCount > maxAttemptsPerGeneration) {
      await repository.recordDeliveryFailure(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: scheduledForUtc,
        nextState: BackgroundWorkState.failedActionRequired,
        failureCategory: ReminderFailureCategory.retryExhausted,
        nowUtc: clock.nowUtc(),
      );
      return true;
    }

    // Final current-source snapshot immediately before show (§32 step 7):
    // a completed/uncertain same alert episode cannot replay (§65 G3) — the
    // durable completed check happened pre-claim; recheck generation now.
    final latest = await repository.readWorkRequest(stableKey);
    if (latest == null ||
        latest.sourceRevision != sourceRevision ||
        (latest.scheduledForUtc != null &&
            !latest.scheduledForUtc!.isAtSameMomentAs(scheduledForUtc)) ||
        latest.state == BackgroundWorkState.cancelledObsolete) {
      return true;
    }

    final platformId = row.platformNotificationId;
    if (platformId == null) {
      return _recordRetryOrExhaust(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: scheduledForUtc,
        now: clock.nowUtc(),
        failureCategory: ReminderFailureCategory.platformUnavailable,
      );
    }
    // Already-active same ID from THIS generation is a receipt (§36); an
    // earlier generation's active notification is not (G4 CAS below).
    if (await gateway.hasDisplayedReminder(platformId)) {
      await repository.completeDelivery(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: scheduledForUtc,
        nowUtc: clock.nowUtc(),
      );
      return true; // handled either way; no duplicate alert.
    }

    final request = LocalNotificationRequest(
      platformId: platformId,
      stableKey: stableKey,
      channel: NotificationChannelKind.reminders,
      scheduledAtUtc: scheduledForUtc,
      title: detailed
          ? (target.sourceKind == ReminderSourceKind.task
              ? ReminderNotificationRenderer.taskDetailedTitle
              : ReminderNotificationRenderer.eventDetailedTitle)
          : ReminderNotificationRenderer.genericTitle,
      body: detailed ? detailedBody : ReminderNotificationRenderer.genericBody,
      responseIntent: NotificationResponseIntent(
        profileId: profileId,
        sourceKind: target.sourceKind == ReminderSourceKind.task
            ? NotificationSourceKind.task
            : NotificationSourceKind.calendarEvent,
        sourceId: target.sourceId,
        occurrenceId: target.occurrenceId,
        action: NotificationResponseAction.open,
      ),
    );
    try {
      await gateway.showCanonicalReminder(request);
    } on Object {
      // §32 step 10/§36: ambiguous post — prefer no duplicate alert over
      // unproven replay; never blind-retry.
      await repository.recordDeliveryFailure(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: scheduledForUtc,
        nextState: BackgroundWorkState.failedActionRequired,
        failureCategory: ReminderFailureCategory.deliveryUncertain,
        nowUtc: clock.nowUtc(),
      );
      return true;
    }
    // §32 step 9: conditional receipt under expected-generation CAS.
    await repository.completeDelivery(
      stableKey: stableKey,
      expectedRevision: sourceRevision,
      expectedScheduledForUtc: scheduledForUtc,
      nowUtc: clock.nowUtc(),
    );
    return true;
  }

  /// §64 step 5: if `now` lies inside current Quiet Hours, let R be its end.
  /// R >= relevance start suppresses (Events, not extended by the window);
  /// otherwise re-arm to R as a same-generation transition.  Returns the
  /// dispatcher result when handled here, null to continue delivery.
  Future<bool?> _quietHoursRearmOrSuppress({
    required DateTime now,
    required DateTime? relevanceStartUtc,
    required String stableKey,
    required String expectedRevision,
    required DateTime expectedScheduledForUtc,
    required NotificationPreferences preferences,
  }) async {
    if (!preferences.quietHours.enabled) {
      return null;
    }
    final delayed = ReminderQuietHours.delayUntilEnd(
      targetUtc: now,
      settings: preferences.quietHours,
      location: deviceLocation,
    );
    if (!delayed.isAfter(now)) {
      return null; // not currently inside a quiet interval.
    }
    if (relevanceStartUtc != null && !delayed.isBefore(relevanceStartUtc)) {
      await repository.recordDeliveryFailure(
        stableKey: stableKey,
        expectedRevision: expectedRevision,
        expectedScheduledForUtc: expectedScheduledForUtc,
        nextState: BackgroundWorkState.cancelledObsolete,
        failureCategory: ReminderFailureCategory.staleSource,
        nowUtc: clock.nowUtc(),
      );
      return true;
    }
    // Same-generation re-arm to R (generation-safe: exact-name replacement).
    final rearmOk = await repository.recordDeliveryFailure(
      stableKey: stableKey,
      expectedRevision: expectedRevision,
      expectedScheduledForUtc: expectedScheduledForUtc,
      nextState: BackgroundWorkState.scheduled,
      failureCategory: ReminderFailureCategory.platformUnavailable,
      nextEligibleAtUtc: delayed,
      nowUtc: clock.nowUtc(),
    );
    return rearmOk;
  }

  static Future<T?> _guard<T>(Future<T> Function() read) async {
    try {
      return await read();
    } on Object {
      return null;
    }
  }

  Future<ReminderEnrichment> _resolveEnrichment({
    required _DeliveryTarget target,
    required String profileId,
    required ReminderPolicy? policy,
    required DateTime now,
  }) async {
    if (policy?.purpose != ReminderPurpose.contactFollowUp) {
      // Location enrichment is independent of Contact purpose (§13/§17).
      if (target.sourceKind == ReminderSourceKind.calendarEvent) {
        final location = await _guard(
          () => enrichmentSource.readEventLocationText(
            profileId: profileId,
            eventId: target.sourceId,
            occurrenceId: target.occurrenceId,
          ),
        );
        return ReminderEnrichment(
          locationText: ReminderEnrichmentResolver.sanitizeLocation(location),
        );
      }
      return const ReminderEnrichment();
    }
    return enrichmentResolver.resolve(
      profileId: profileId,
      sourceKind: target.sourceKind,
      sourceId: target.sourceId,
      occurrenceId: target.occurrenceId,
      contactId: policy?.contactId,
    );
  }

  Future<bool> _suppressObsolete({
    required String stableKey,
    required String expectedRevision,
    required DateTime expectedScheduledForUtc,
    required String reason,
  }) async {
    await repository.recordDeliveryFailure(
      stableKey: stableKey,
      expectedRevision: expectedRevision,
      expectedScheduledForUtc: expectedScheduledForUtc,
      nextState: BackgroundWorkState.cancelledObsolete,
      failureCategory: reason,
      nowUtc: clock.nowUtc(),
    );
    return true;
  }

  Future<bool> _recordRetryOrExhaust({
    required String stableKey,
    required String expectedRevision,
    required DateTime expectedScheduledForUtc,
    required DateTime now,
    required String failureCategory,
  }) async {
    final row = await repository.readWorkRequest(stableKey);
    if (row == null ||
        row.sourceRevision != expectedRevision ||
        row.attemptCount >= maxAttemptsPerGeneration) {
      await repository.recordDeliveryFailure(
        stableKey: stableKey,
        expectedRevision: expectedRevision,
        expectedScheduledForUtc: expectedScheduledForUtc,
        nextState: BackgroundWorkState.failedActionRequired,
        failureCategory: ReminderFailureCategory.retryExhausted,
        nowUtc: now,
      );
      return true;
    }
    final delay = retryBackoff[
        (row.attemptCount - 1).clamp(0, retryBackoff.length - 1)];
    await repository.recordDeliveryFailure(
      stableKey: stableKey,
      expectedRevision: expectedRevision,
      expectedScheduledForUtc: expectedScheduledForUtc,
      nextState: BackgroundWorkState.retryScheduled,
      failureCategory: failureCategory,
      nextEligibleAtUtc: now.add(delay),
      nowUtc: now,
    );
    // Bounded, durably recorded retry: the ONLY false return (§31).
    return false;
  }

  Future<bool> _recordRuntimeUnavailable(
    String stableKey,
    String sourceRevision,
  ) async {
    // §31: if metadata cannot be durably written, do not invent an attempt
    // row or loop forever; terminate that invocation truthfully.
    try {
      await repository.recordDeliveryFailure(
        stableKey: stableKey,
        expectedRevision: sourceRevision,
        expectedScheduledForUtc: clock.nowUtc(),
        nextState: BackgroundWorkState.failedActionRequired,
        failureCategory: ReminderFailureCategory.runtimeUnavailable,
        nowUtc: clock.nowUtc(),
      );
    } on Object {
      // Observability limit: report through sanitized diagnostics only.
    }
    return true;
  }

  static bool _categoryEnabled(
    NotificationPreferences preferences,
    ReminderSourceKind sourceKind,
  ) => switch (sourceKind) {
    ReminderSourceKind.calendarEvent => preferences.eventRemindersEnabled,
    ReminderSourceKind.task => preferences.taskRemindersEnabled,
    ReminderSourceKind.weeklyReview ||
    ReminderSourceKind.awaitingReport => false,
  };

  static String? _clockLabel(DateTime? value) {
    if (value == null) return null;
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final suffix = value.hour < 12 ? 'AM' : 'PM';
    return '$hour:${value.minute.toString().padLeft(2, '0')} $suffix';
  }

  static String _dueLabel(DateTime dueUtc) => _clockLabel(dueUtc) ?? '';
}

final class _DeliveryTarget {
  const _DeliveryTarget({
    required this.sourceKind,
    required this.profileId,
    required this.sourceId,
    required this.occurrenceId,
  });

  final ReminderSourceKind sourceKind;
  final String profileId;
  final String sourceId;
  final String occurrenceId;
}
