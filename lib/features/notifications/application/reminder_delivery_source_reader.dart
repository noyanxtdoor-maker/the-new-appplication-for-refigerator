import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:rmplanner/features/notifications/application/reminder_enrichment_resolver.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

/// VS16-M7 — the CURRENT canonical source truth used at delivery time
/// (contract sections 16/18/32).
///
/// This reader exists so the worker never posts a scheduled snapshot.  Every
/// field is reread from the canonical repositories at the moment of delivery:
/// the Event/Task lifecycle, its current timing, the effective reminder policy
/// (including the selected Contact), the current privacy preview permission and
/// the current Event location.  A rename, unlink, archive, location change or
/// cancellation that committed before this read is therefore reflected.
///
/// It performs NO writes and never repairs data.  A read failure propagates so
/// the caller applies the bounded-retry law instead of inventing content.
final class DriftReminderDeliverySourceReader
    implements ReminderDeliverySourceReader {
  const DriftReminderDeliverySourceReader({
    required this.database,
    required this.clock,
    required this.events,
    required this.zones,
    required this.enrichment,
    required this.tasks,
    required this.privacy,
    this.detailedContent,
  });

  final AppDatabase database;
  final AppClock clock;
  final DriftCalendarEventRepository events;
  final IanaCalendarEventTimeZones zones;
  final ReminderEnrichmentResolver enrichment;

  /// Task source.  M7 Contact follow-up applies to Event and Task sources, so a
  /// Task delivery must reread its canonical row too.
  final DriftPlannerRepository tasks;

  /// Resolved CURRENT privacy preview permission.  Absent or failing means
  /// Detailed is not permitted and the neutral Generic copy is used.
  final Future<NotificationDeliveryPrivacy> Function() privacy;

  /// VS16 M7 corrective — the profile's saved per-field Detailed content
  /// options.  Optional so existing constructions keep the all-TRUE default.
  final Future<DetailedContentPreferences> Function(String profileId)?
  detailedContent;

  @override
  Future<ReminderDeliverySnapshot?> read({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
  }) async {
    // Read the effective policy so the explicitly selected Contact is known
    // before any Contact read happens.
    final policy = await _effectivePolicy(
      profileId: profileId,
      sourceKind: sourceKind,
      sourceId: sourceId,
      occurrenceId: occurrenceId,
    );
    final showDetails =
        await _privacyMode() == NotificationDeliveryPrivacy.detailed;
    // VS16 M7 corrective: resolve the profile's saved per-field Detailed
    // content options.  A read failure falls back to the all-TRUE default so a
    // preferences read problem can never empty a notification.
    final detailOptions = await _detailOptions(profileId);

    return switch (sourceKind) {
      ReminderSourceKind.calendarEvent => await _readEvent(
        profileId: profileId,
        sourceId: sourceId,
        occurrenceId: occurrenceId,
        policy: policy,
        showDetails: showDetails,
        detailOptions: detailOptions,
      ),
      ReminderSourceKind.task => await _readTask(
        profileId: profileId,
        sourceId: sourceId,
        policy: policy,
        showDetails: showDetails,
        detailOptions: detailOptions,
      ),
      // Planning families never carry M7 enrichment and never use the M7 worker
      // transport; they are not this reader's concern.
      ReminderSourceKind.weeklyReview ||
      ReminderSourceKind.awaitingReport => null,
    };
  }

  /// M2 OWNER CORRECTION (Issue 1): the delivery content mode follows ONLY
  /// the saved notification preview preference.  Privacy Lock is not an
  /// input to notification content selection.  A settings read failure is
  /// never permission for Detailed: it degrades to the neutral Generic copy.
  Future<NotificationDeliveryPrivacy> _privacyMode() async {
    try {
      return await privacy();
    } on Object {
      return NotificationDeliveryPrivacy.generic;
    }
  }

  /// The profile's saved per-field Detailed content options.
  ///
  /// Fail-closed TOWARD CONTENT: a read failure yields the all-TRUE default,
  /// never "everything off". Privacy Lock still forces Generic downstream
  /// regardless of these values, and the saved values are not cleared.
  Future<ReminderDetailOptions> _detailOptions(String profileId) async {
    final read = detailedContent;
    if (read == null) return ReminderDetailOptions.all;
    try {
      final stored = await read(profileId);
      return stored.toOptions();
    } on Object {
      return ReminderDetailOptions.all;
    }
  }

  /// Exact-occurrence policy first, then the series policy — the same
  /// precedence the reconciler uses, so scheduling and delivery agree.
  Future<ReminderPolicy?> _effectivePolicy({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
  }) async {
    final rows =
        await (database.select(database.reminderPolicies)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.sourceKind.equals(sourceKind.name) &
                  table.sourceId.equals(sourceId),
            ))
            .get();
    ReminderPolicy map(ReminderPolicyRow row) => ReminderPolicy(
      id: row.id,
      profileId: row.profileId,
      sourceKind: ReminderSourceKind.values.byName(row.sourceKind),
      sourceId: row.sourceId,
      occurrenceId: row.occurrenceId,
      purpose: ReminderPurpose.values.byName(row.purpose),
      contactId: row.contactId,
      mode: ReminderPolicyMode.values.byName(row.mode),
      offsetMinutes: row.offsetMinutes,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
    );
    final policies = rows.map(map).toList(growable: false);
    return policies.where((p) => p.occurrenceId == occurrenceId).firstOrNull ??
        policies
            .where((p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId)
            .firstOrNull;
  }

  /// The ONE explicitly selected Contact for this source, or null.  The policy
  /// decides the target; a linked Contact never infers a follow-up.
  Future<String?> _followUpName({
    required ReminderPolicy? policy,
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
  }) async {
    if (policy?.purpose != ReminderPurpose.contactFollowUp) return null;
    final contactId = policy?.contactId;
    if (contactId == null || contactId.trim().isEmpty) return null;
    return enrichment.followUpName(
      profileId: profileId,
      sourceKind: sourceKind,
      sourceId: sourceId,
      occurrenceId: occurrenceId,
      contactId: contactId,
    );
  }

  Future<ReminderDeliverySnapshot?> _readEvent({
    required String profileId,
    required String sourceId,
    required String occurrenceId,
    required ReminderPolicy? policy,
    required bool showDetails,
    required ReminderDetailOptions detailOptions,
  }) async {
    final occurrence = await events.readOccurrenceById(
      profileId: profileId,
      eventId: sourceId,
      occurrenceId: occurrenceId,
    );
    if (occurrence == null) return null;
    // Profile isolation: suppress rather than post another profile's source.
    if (occurrence.profileId != profileId) return null;
    final active = occurrence.status == CalendarEventStatus.scheduled;

    final followUpName = active
        ? await _followUpName(
            policy: policy,
            profileId: profileId,
            sourceKind: ReminderSourceKind.calendarEvent,
            sourceId: sourceId,
            occurrenceId: occurrenceId,
          )
        : null;

    return ReminderDeliverySnapshot(
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: sourceId,
      occurrenceId: occurrenceId,
      sourceActive: active,
      categoryEnabled: true,
      showDetails: showDetails,
      // VS16 M7 corrective (Astra section 13 owner amendment): the live
      // Planner-visible Event title, so the worker post and the native post
      // present the same resolved source title.
      sourceTitle: occurrence.displayTitle,
      detailOptions: detailOptions,
      startUtc: occurrence.startUtc,
      endUtc: occurrence.endUtc,
      notes: occurrence.notes,
      followUpName: followUpName,
      // Sanitized here so the renderer can never receive a raw coordinate/URI.
      locationText: ReminderEnrichmentSanitizer.sanitizeLocation(
        occurrence.locationText,
      ),
    );
  }

  Future<ReminderDeliverySnapshot?> _readTask({
    required String profileId,
    required String sourceId,
    required ReminderPolicy? policy,
    required bool showDetails,
    required ReminderDetailOptions detailOptions,
  }) async {
    final task = await tasks.readTask(profileId: profileId, taskId: sourceId);
    if (task == null) return null;
    if (task.profileId != profileId) return null;
    final active = task.status != PlannerTaskStatus.completed;

    final followUpName = active
        ? await _followUpName(
            policy: policy,
            profileId: profileId,
            sourceKind: ReminderSourceKind.task,
            sourceId: sourceId,
            occurrenceId: ReminderPolicy.seriesOccurrenceId,
          )
        : null;

    return ReminderDeliverySnapshot(
      sourceKind: ReminderSourceKind.task,
      sourceId: sourceId,
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      sourceActive: active,
      categoryEnabled: true,
      showDetails: showDetails,
      // VS16 M7 corrective (Astra section 13 owner amendment): the live Task
      // title, so the worker post and the native post agree.
      sourceTitle: task.title,
      detailOptions: detailOptions,
      // A Task's due fields are device/profile-local wall time; construct that
      // local instant and convert, exactly as the Task scheduler does.
      startUtc: task.dueDate == null || task.dueMinute == null
          ? null
          : DateTime(
              task.dueDate!.year,
              task.dueDate!.month,
              task.dueDate!.day,
              task.dueMinute! ~/ 60,
              task.dueMinute! % 60,
            ).toUtc(),
      endUtc: null,
      notes: task.notes,
      followUpName: followUpName,
      // Tasks never gain a location line (contract section 13).
      locationText: null,
    );
  }
}

/// Resolved privacy preview permission for one delivery attempt.
enum NotificationDeliveryPrivacy { generic, detailed }

/// Keeps [zones] referenced for callers that resolve device-local Task time
/// without importing the planner zone helper directly.
typedef ReminderDeliveryTimeZones = IanaCalendarEventTimeZones;
