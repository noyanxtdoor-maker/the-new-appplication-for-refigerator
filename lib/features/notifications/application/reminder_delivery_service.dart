import 'package:rmplanner/core/background/background_work_request.dart';
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
import 'package:rmplanner/features/notifications/data/drift_reminder_enrichment_source.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/event_type_repository.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/privacy/application/privacy_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:timezone/timezone.dart' as tz;

enum ReminderDeliveryOutcome {
  delivered,
  alreadyActive,
  suppressedObsolete,
  retryScheduled,
  terminalFailed,
  skipped;

  bool get retryable => this == ReminderDeliveryOutcome.retryScheduled;
}

/// VS16 M7 targeted enriched delivery (contract section 32).
///
/// Owns ONLY the current Event/Task reminder projection.  It never scans the
/// whole horizon, never writes Task/Event/Contact lifecycle, and never renders
/// cached private copy: every value is re-read from canonical repositories at
/// posting time.
final class ReminderDeliveryService {
  const ReminderDeliveryService({
    required this.repository,
    required this.deliveryGateway,
    required this.notificationGateway,
    required this.events,
    required this.tasks,
    required this.eventTypes,
    required this.privacy,
    required this.permission,
    required this.enrichmentSource,
    required this.clock,
    this.deviceLocation,
    this.requestFullReconcile,
  });

  static const int maximumAttempts = 5;
  static const String _failureDbBusy = 'db_busy';
  static const String _failureRetryExhausted = 'retry_exhausted';
  static const String _failureDeliveryUncertain = 'delivery_uncertain';

  static final RegExp _safeKey = RegExp(r'^reminder:[A-Za-z0-9_.:-]{1,240}$');
  static final RegExp _safeRevision = RegExp(r'^[A-Za-z0-9_.:-]{1,256}$');

  final NotificationFoundationRepository repository;
  final CanonicalReminderDeliveryGateway deliveryGateway;
  final NotificationGateway notificationGateway;
  final CalendarEventOccurrenceIdLookup events;
  final PlannerRepository tasks;
  final EventTypeRepository eventTypes;
  final PrivacyRepository privacy;
  final PermissionGateway permission;
  final ReminderEnrichmentSource enrichmentSource;
  final AppClock clock;
  final tz.Location? deviceLocation;

  /// Injected full-reconcile trigger used when current truth moved the target
  /// away from the captured worker invocation.  Null in unit fixtures.
  final Future<void> Function()? requestFullReconcile;

  Future<ReminderDeliveryOutcome> deliver({
    required String stableKey,
    required DateTime scheduledAtUtc,
    required String sourceRevision,
  }) async {
    if (!_safeKey.hasMatch(stableKey) ||
        !_safeRevision.hasMatch(sourceRevision)) {
      return ReminderDeliveryOutcome.terminalFailed;
    }
    final BackgroundWorkRequest? work;
    try {
      work = await repository.readWorkRequest(stableKey);
    } on Object {
      return ReminderDeliveryOutcome.retryScheduled;
    }
    if (work == null || work.profileId == null) {
      return ReminderDeliveryOutcome.skipped;
    }
    if (work.sourceRevision != sourceRevision ||
        !(work.sourceRevision?.contains(
              ReminderReconciler.workerTransportMarker,
            ) ??
            false)) {
      return ReminderDeliveryOutcome.skipped;
    }
    if (work.occurrenceId == null || work.ownerId == null) {
      return ReminderDeliveryOutcome.skipped;
    }
    if (work.scheduledForUtc != null &&
        !_sameInstant(work.scheduledForUtc, scheduledAtUtc)) {
      return ReminderDeliveryOutcome.skipped;
    }
    if (work.state == BackgroundWorkState.completed ||
        work.state == BackgroundWorkState.cancelledObsolete ||
        work.state == BackgroundWorkState.failedActionRequired) {
      return ReminderDeliveryOutcome.skipped;
    }
    final profileId = work.profileId!;
    final sourceKind = _sourceKindFor(stableKey);
    if (sourceKind == null) return ReminderDeliveryOutcome.skipped;

    if (work.state == BackgroundWorkState.running &&
        work.platformNotificationId != null) {
      try {
        final pending = await notificationGateway.pending();
        final active = pending.any(
          (item) => item.platformId == work!.platformNotificationId,
        );
        if (active) {
          await _markCompleted(work);
          return ReminderDeliveryOutcome.alreadyActive;
        }
      } on Object {
        await _markFailed(work, _failureDeliveryUncertain);
        return ReminderDeliveryOutcome.terminalFailed;
      }
      await _markFailed(work, _failureDeliveryUncertain);
      return ReminderDeliveryOutcome.terminalFailed;
    }

    if (work.attemptCount >= maximumAttempts) {
      await _markFailed(work, _failureRetryExhausted);
      return ReminderDeliveryOutcome.terminalFailed;
    }

    try {
      await repository.recordClaim(stableKey: stableKey);
    } on Object {
      return ReminderDeliveryOutcome.retryScheduled;
    }

    final _ResolvedSource resolved;
    try {
      resolved = await _resolveSource(
        work: work,
        sourceKind: sourceKind,
        profileId: profileId,
      );
    } on Object {
      return _recordTransient(work, _failureDbBusy);
    }
    if (resolved.status == _SourceStatus.invalid) {
      await _markCancelled(work);
      return ReminderDeliveryOutcome.suppressedObsolete;
    }

    final NotificationPreferences preferences;
    final PrivacySettings privacySettings;
    final OperatingSystemPermissionState permissionState;
    try {
      preferences = await repository.readPreferences(profileId: profileId);
      privacySettings = await privacy.readSettings();
      permissionState = await permission.status(
        OptionalPermission.notifications,
      );
    } on Object {
      return _recordTransient(work, _failureDbBusy);
    }
    if (!preferences.systemNotificationsEnabled ||
        permissionState != OperatingSystemPermissionState.granted ||
        !_categoryEnabled(preferences, sourceKind)) {
      await _cancelPlatform(work);
      await _markCancelled(work);
      return ReminderDeliveryOutcome.suppressedObsolete;
    }

    final target = await _currentTarget(
      resolved: resolved,
      sourceKind: sourceKind,
      profileId: profileId,
      preferences: preferences,
    );
    if (target == null) {
      await _markCancelled(work);
      return ReminderDeliveryOutcome.suppressedObsolete;
    }
    final now = clock.nowUtc();
    if (target.isAfter(now)) {
      await _triggerReconcile();
      await _markCompleted(work);
      return ReminderDeliveryOutcome.suppressedObsolete;
    }
    if (resolved.obsoleteNow(now)) {
      await _cancelPlatform(work);
      await _markCancelled(work);
      return ReminderDeliveryOutcome.suppressedObsolete;
    }

    final enrichment = await _resolveEnrichment(
      sourceKind: sourceKind,
      profileId: profileId,
      resolved: resolved,
    );

    final showDetails =
        resolveNotificationPreviewMode(
          settings: privacySettings,
          privacyProtectionRequired: privacySettings.lockEnabled,
        ) ==
        EffectiveNotificationPreviewMode.detailed;
    final request = _buildRequest(
      work: work,
      resolved: resolved,
      sourceKind: sourceKind,
      showDetails: showDetails,
      enrichment: enrichment,
    );

    try {
      await deliveryGateway.showCanonicalReminder(request);
    } on Object {
      // Platform show and SQLite commit are not atomic: an ambiguous post
      // outcome prefers preventing a duplicate alert over an unproven replay.
      await _markFailed(work, _failureDeliveryUncertain);
      return ReminderDeliveryOutcome.terminalFailed;
    }

    try {
      final latest = await repository.readPreferences(profileId: profileId);
      if (!latest.systemNotificationsEnabled ||
          !_categoryEnabled(latest, sourceKind)) {
        await _cancelPlatform(work);
        await _markCancelled(work);
        return ReminderDeliveryOutcome.suppressedObsolete;
      }
    } on Object {
      // Cannot re-verify after post; the posted alert stays recorded.
    }
    await _markCompleted(work);
    return ReminderDeliveryOutcome.delivered;
  }

  ReminderSourceKind? _sourceKindFor(String stableKey) {
    if (stableKey.startsWith('reminder:calendarEvent:')) {
      return ReminderSourceKind.calendarEvent;
    }
    if (stableKey.startsWith('reminder:task:')) {
      return ReminderSourceKind.task;
    }
    return null;
  }

  Future<_ResolvedSource> _resolveSource({
    required BackgroundWorkRequest work,
    required ReminderSourceKind sourceKind,
    required String profileId,
  }) async {
    switch (sourceKind) {
      case ReminderSourceKind.calendarEvent:
        final occurrence = await events.readOccurrenceById(
          profileId: profileId,
          eventId: work.ownerId!,
          occurrenceId: work.occurrenceId!,
        );
        if (occurrence == null ||
            occurrence.status != CalendarEventStatus.scheduled ||
            occurrence.startUtc == null) {
          return const _ResolvedSource.invalid();
        }
        return _ResolvedSource.event(occurrence);
      case ReminderSourceKind.task:
        final task = await tasks.readTask(
          profileId: profileId,
          taskId: work.ownerId!,
        );
        final date = _parseTaskOccurrenceDate(
          work.occurrenceId!,
          work.ownerId!,
        );
        if (task == null ||
            task.status != PlannerTaskStatus.incomplete ||
            date == null ||
            task.dueMinute == null ||
            !task.projectsOn(date)) {
          return const _ResolvedSource.invalid();
        }
        return _ResolvedSource.task(task, date);
      case ReminderSourceKind.weeklyReview:
      case ReminderSourceKind.awaitingReport:
        return const _ResolvedSource.invalid();
    }
  }

  PlannerDate? _parseTaskOccurrenceDate(String occurrenceId, String taskId) {
    final prefix = 'task:$taskId:';
    if (!occurrenceId.startsWith(prefix)) return null;
    final raw = occurrenceId.substring(prefix.length);
    if (raw.isEmpty) return null;
    try {
      return PlannerDate.parse(raw);
    } on Object {
      return null;
    }
  }

  Future<DateTime?> _currentTarget({
    required _ResolvedSource resolved,
    required ReminderSourceKind sourceKind,
    required String profileId,
    required NotificationPreferences preferences,
  }) async {
    final policies = await repository.readPolicies(
      profileId: profileId,
      sourceKind: sourceKind,
      sourceId: resolved.sourceId,
    );
    final exact = policies
        .where((policy) => policy.occurrenceId == resolved.occurrenceId)
        .firstOrNull;
    final series = policies
        .where(
          (policy) => policy.occurrenceId == ReminderPolicy.seriesOccurrenceId,
        )
        .firstOrNull;
    final policy = exact ?? series;
    int? globalOffset;
    if (sourceKind == ReminderSourceKind.calendarEvent) {
      try {
        final settings = await eventTypes.readPlannerSettings(
          profileId: profileId,
        );
        globalOffset = settings.defaultReminderMinutes;
      } on Object {
        return null;
      }
    } else {
      globalOffset = preferences.defaultTaskReminderMinutes;
    }
    final offset = switch (policy?.mode) {
      ReminderPolicyMode.offset => policy!.offsetMinutes,
      ReminderPolicyMode.off => null,
      _ => globalOffset,
    };
    final start = resolved.startUtc;
    if (start == null || offset == null) return null;
    return ReminderQuietHours.delayUntilEnd(
      targetUtc: start.subtract(Duration(minutes: offset)),
      settings: preferences.quietHours,
      location: deviceLocation,
    );
  }

  Future<_EnrichmentResult> _resolveEnrichment({
    required ReminderSourceKind sourceKind,
    required String profileId,
    required _ResolvedSource resolved,
  }) async {
    String? followUpName;
    String? locationText;
    try {
      final policies = await repository.readPolicies(
        profileId: profileId,
        sourceKind: sourceKind,
        sourceId: resolved.sourceId,
      );
      final exact = policies
          .where((policy) => policy.occurrenceId == resolved.occurrenceId)
          .firstOrNull;
      final series = policies
          .where(
            (policy) =>
                policy.occurrenceId == ReminderPolicy.seriesOccurrenceId,
          )
          .firstOrNull;
      final policy = exact ?? series;
      if (policy?.purpose == ReminderPurpose.contactFollowUp &&
          policy?.contactId != null) {
        final contact = await enrichmentSource.readFollowUpContact(
          profileId: profileId,
          sourceKind: sourceKind,
          sourceId: resolved.sourceId,
          occurrenceId: resolved.occurrenceId,
          contactId: policy!.contactId!,
        );
        followUpName = sanitizeReminderContactName(contact?.displayName);
      }
      if (sourceKind == ReminderSourceKind.calendarEvent) {
        locationText = sanitizeReminderLocation(resolved.locationText);
      }
    } on Object {
      followUpName = null;
      locationText = null;
    }
    return _EnrichmentResult(
      followUpName: followUpName,
      locationText: locationText,
    );
  }

  LocalNotificationRequest _buildRequest({
    required BackgroundWorkRequest work,
    required _ResolvedSource resolved,
    required ReminderSourceKind sourceKind,
    required bool showDetails,
    required _EnrichmentResult enrichment,
  }) {
    final platformId = work.platformNotificationId!;
    final intent = NotificationResponseIntent(
      profileId: work.profileId!,
      sourceKind: sourceKind == ReminderSourceKind.calendarEvent
          ? NotificationSourceKind.calendarEvent
          : NotificationSourceKind.task,
      sourceId: resolved.sourceId,
      occurrenceId: resolved.occurrenceId,
      action: NotificationResponseAction.open,
      generation: work.snoozeCount,
    );
    final title = showDetails
        ? switch (sourceKind) {
            ReminderSourceKind.calendarEvent =>
              ReminderNotificationCopy.eventDetailedTitle,
            _ => ReminderNotificationCopy.taskDetailedTitle,
          }
        : ReminderNotificationCopy.genericTitle;
    final body = showDetails
        ? switch (sourceKind) {
            ReminderSourceKind.calendarEvent =>
              ReminderNotificationCopy.eventDetailedBody(
                start: resolved.event?.startDisplay,
                end: resolved.event?.endDisplay,
                notes: resolved.notes,
                followUpContactName: enrichment.followUpName,
                locationText: enrichment.locationText,
              ),
            _ => ReminderNotificationCopy.taskDetailedBody(
              dueMinute: resolved.dueMinute,
              notes: resolved.notes,
              followUpContactName: enrichment.followUpName,
            ),
          }
        : ReminderNotificationCopy.genericBody;
    return LocalNotificationRequest(
      platformId: platformId,
      stableKey: work.stableKey,
      channel: NotificationChannelKind.reminders,
      scheduledAtUtc: work.scheduledForUtc ?? clock.nowUtc(),
      title: title,
      body: body,
      responseIntent: intent,
      onlyAlertOnce: true,
    );
  }

  Future<ReminderDeliveryOutcome> _recordTransient(
    BackgroundWorkRequest work,
    String failure,
  ) async {
    final attempts = work.attemptCount + 1;
    if (attempts >= maximumAttempts) {
      await _markFailed(work, _failureRetryExhausted);
      return ReminderDeliveryOutcome.terminalFailed;
    }
    final now = clock.nowUtc();
    final backoff = Duration(seconds: 30 * (1 << (attempts - 1).clamp(0, 3)));
    try {
      await repository.recordAttempt(
        stableKey: work.stableKey,
        nextState: BackgroundWorkState.retryScheduled,
        failureCategory: failure,
        nextEligibleAtUtc: now.add(backoff),
      );
    } on Object {
      return ReminderDeliveryOutcome.retryScheduled;
    }
    return ReminderDeliveryOutcome.retryScheduled;
  }

  Future<void> _markCancelled(BackgroundWorkRequest work) async {
    try {
      await repository.recordAttempt(
        stableKey: work.stableKey,
        nextState: BackgroundWorkState.cancelledObsolete,
      );
    } on Object {
      // Source truth remains authoritative even if the row update fails.
    }
  }

  Future<void> _markCompleted(BackgroundWorkRequest work) async {
    try {
      await repository.recordAttempt(
        stableKey: work.stableKey,
        nextState: BackgroundWorkState.completed,
      );
      final latest = await repository.readWorkRequest(work.stableKey);
      if (latest != null) {
        await repository.upsertWorkRequest(
          latest.copyWith(completedAtUtc: clock.nowUtc()),
        );
      }
    } on Object {
      // Delivery bookkeeping only; the notification was already posted.
    }
  }

  Future<void> _markFailed(BackgroundWorkRequest work, String failure) async {
    try {
      await repository.recordAttempt(
        stableKey: work.stableKey,
        nextState: BackgroundWorkState.failedActionRequired,
        failureCategory: failure,
      );
    } on Object {
      // Technical status only; never rolls back owner source.
    }
  }

  Future<void> _cancelPlatform(BackgroundWorkRequest work) async {
    final id = work.platformNotificationId;
    if (id == null) return;
    try {
      await notificationGateway.cancel(id);
    } on Object {
      // Platform cleanup is best-effort; the durable state is authoritative.
    }
  }

  Future<void> _triggerReconcile() async {
    final reconcile = requestFullReconcile;
    if (reconcile == null) return;
    try {
      await reconcile();
    } on Object {
      // The durable marker/mutation path retries repair later.
    }
  }

  static bool _sameInstant(DateTime? a, DateTime? b) =>
      a == null ? b == null : b != null && a.isAtSameMomentAs(b);

  static bool _categoryEnabled(
    NotificationPreferences preferences,
    ReminderSourceKind sourceKind,
  ) => switch (sourceKind) {
    ReminderSourceKind.calendarEvent => preferences.eventRemindersEnabled,
    ReminderSourceKind.task => preferences.taskRemindersEnabled,
    ReminderSourceKind.weeklyReview => preferences.weeklyReviewRemindersEnabled,
    ReminderSourceKind.awaitingReport =>
      preferences.awaitingReportRemindersEnabled,
  };
}

enum _SourceStatus { ready, invalid }

final class _EnrichmentResult {
  const _EnrichmentResult({this.followUpName, this.locationText});

  final String? followUpName;
  final String? locationText;
}

final class _ResolvedSource {
  const _ResolvedSource._({
    required this.status,
    this.sourceId = '',
    this.occurrenceId = '',
    this.startUtc,
    this.locationText,
    this.notes,
    this.dueMinute,
    this.event,
  });

  const _ResolvedSource.invalid() : this._(status: _SourceStatus.invalid);

  factory _ResolvedSource.event(CalendarEventOccurrence occurrence) =>
      _ResolvedSource._(
        status: _SourceStatus.ready,
        sourceId: occurrence.eventId,
        occurrenceId: occurrence.id,
        startUtc: occurrence.startUtc,
        locationText: occurrence.locationText,
        notes: occurrence.notes,
        event: occurrence,
      );

  factory _ResolvedSource.task(PlannerTask task, PlannerDate date) {
    final minute = task.dueMinute!;
    return _ResolvedSource._(
      status: _SourceStatus.ready,
      sourceId: task.id,
      occurrenceId: 'task:${task.id}:${date.iso8601}',
      startUtc: DateTime(
        date.year,
        date.month,
        date.day,
        minute ~/ 60,
        minute % 60,
      ).toUtc(),
      notes: task.notes,
      dueMinute: minute,
    );
  }

  final _SourceStatus status;
  final String sourceId;
  final String occurrenceId;
  final DateTime? startUtc;
  final String? locationText;
  final String? notes;
  final int? dueMinute;
  final CalendarEventOccurrence? event;

  bool obsoleteNow(DateTime now) {
    final isEvent = event != null;
    final start = startUtc;
    if (!isEvent || start == null) return false;
    return !start.isAfter(now);
  }
}
