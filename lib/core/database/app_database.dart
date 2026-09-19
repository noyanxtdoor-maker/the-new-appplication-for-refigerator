// ignore_for_file: prefer_initializing_formals

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

@DataClassName('LocalProfileRow')
class LocalProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get slot =>
      text().withDefault(const Constant('primary')).unique()();
  TextColumn get localName => text()();
  TextColumn get displayName => text().nullable()();
  TextColumn get timeZoneId => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('OnboardingCheckpointRow')
class OnboardingCheckpoints extends Table {
  TextColumn get key => text().withDefault(const Constant('primary'))();
  TextColumn get pendingProfileId => text()();
  TextColumn get stage => text()();
  TextColumn get draftDisplayName => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

/// A private, user-entered note attached to a Contact.  The column is named
/// `noteText` (not `text`) because `text()` is also the drift column builder
/// function; a getter named `text` would shadow it and silently break the
/// table generation.
@DataClassName('ContactNoteRow')
class ContactNotes extends Table {
  TextColumn get id => text()();
  TextColumn get contactId =>
      text().references(Contacts, #id, onDelete: KeyAction.restrict)();
  TextColumn get noteText => text()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'life_indicator_profile_key_unique',
  columns: <Symbol>{#profileId, #indicatorKey},
  unique: true,
)
@DataClassName('LifeIndicatorDefinitionRow')
class LifeIndicatorDefinitions extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get indicatorKey => text()();
  TextColumn get label => text()();
  TextColumn get unit => text()();
  IntColumn get position => integer()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// The canonical lifecycle record for a user-facing goal.
///
/// `role` and `activeSlotIndex` are intentionally stored as stable values
/// rather than inferred from the current WLI label.  This lets a renamed or
/// archived goal keep its identity, history, and relationships intact.
@TableIndex(
  name: 'goal_profile_active_slot_unique',
  columns: <Symbol>{#profileId, #activeSlotIndex},
  unique: true,
)
@TableIndex(
  name: 'goal_profile_status_slot',
  columns: <Symbol>{#profileId, #status, #activeSlotIndex},
)
@DataClassName('GoalRow')
class Goals extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get indicatorKey => text().nullable()();
  TextColumn get assignedEventTypeStableKey => text().nullable()();
  TextColumn get role => text()();
  IntColumn get activeSlotIndex => integer().nullable()();
  TextColumn get title => text()();
  TextColumn get iconId => text().nullable()();
  TextColumn get status => text()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();
  DateTimeColumn get archivedAtUtc => dateTime().nullable()();

  DateTimeColumn get completedAtUtc => dateTime().nullable()();
  TextColumn get completionMethod => text().nullable()();
  IntColumn get completionGeneration =>
      integer().withDefault(const Constant(0))();
  BoolColumn get completionArmed =>
      boolean().withDefault(const Constant(true))();

  /// Set when the Goal is permanently deleted from the user-facing
  /// experience.  Deleted Goals stay in the table so historical Event,
  /// outcome, ledger, contribution, and activity records keep their original
  /// Goal identity, but they are hidden from active and archived queries and
  /// can never be restored.
  DateTimeColumn get deletedAtUtc => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'goal_activity_operation_unique',
  columns: <Symbol>{#operationId},
  unique: true,
)
@TableIndex(
  name: 'goal_activity_goal_time',
  columns: <Symbol>{#goalId, #occurredAtUtc},
)
@DataClassName('GoalActivityRow')
class GoalActivities extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get goalId =>
      text().references(Goals, #id, onDelete: KeyAction.restrict)();
  TextColumn get operationId => text()();
  TextColumn get action => text()();
  TextColumn get previousValue => text().nullable()();
  TextColumn get newValue => text().nullable()();
  DateTimeColumn get occurredAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Local, idempotent outbox entries for Goal lifecycle mutations.  The app is
/// currently offline-first; keeping the operation payload by stable Goal ID
/// makes later sync/backup integration additive instead of requiring a second
/// Goal architecture.
@DataClassName('GoalOutboxOperationRow')
class GoalOutboxOperations extends Table {
  TextColumn get operationId => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get action => text()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{operationId};
}

/// Immutable receipt for one explicit Goal-completion generation.  This is
/// canonical source truth; system and in-app presentation only project it.
@TableIndex(
  name: 'goal_achievement_generation_unique',
  columns: <Symbol>{#profileId, #goalId, #completionGeneration},
  unique: true,
)
@DataClassName('GoalAchievementEventRow')
class GoalAchievementEvents extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get goalId =>
      text().references(Goals, #id, onDelete: KeyAction.restrict)();
  TextColumn get achievementType => text()();
  IntColumn get completionGeneration => integer()();
  DateTimeColumn get occurredAtUtc => dateTime()();
  DateTimeColumn get createdAtUtc => dateTime()();
  TextColumn get sourceOperationId => text()();
  BoolColumn get systemNotificationEligible =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get systemNotificationDeliveredAtUtc =>
      dateTime().nullable()();
  BoolColumn get inAppCelebrationEligible =>
      boolean().withDefault(const Constant(true))();
  DateTimeColumn get inAppCelebrationConsumedAtUtc => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('PrivacyPreferenceRow')
class PrivacyPreferences extends Table {
  TextColumn get key => text().withDefault(const Constant('primary'))();
  BoolColumn get lockEnabled => boolean().withDefault(const Constant(false))();
  TextColumn get notificationPreviewMode =>
      text().withDefault(const Constant('hidden'))();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

@DataClassName('PermissionAuditRow')
class PermissionAudits extends Table {
  TextColumn get permissionKey => text()();
  BoolColumn get requestedByApp =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get everGranted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{permissionKey};
}

/// Profile-owned notification category, Task-default, and Quiet Hours state.
/// Android permission and notification-preview privacy remain owned elsewhere.
@DataClassName('NotificationPreferenceRow')
class NotificationPreferences extends Table {
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();

  /// App-owned master switch. It deliberately does not mirror Android state.
  BoolColumn get systemNotificationsEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get eventRemindersEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get taskRemindersEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get weeklyReviewRemindersEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get awaitingReportRemindersEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get goalCompletionNotificationsEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get inAppGoalCelebrationsEnabled =>
      boolean().withDefault(const Constant(true))();
  IntColumn get defaultTaskReminderMinutes => integer().nullable()();
  IntColumn get snoozeDurationMinutes =>
      integer().withDefault(const Constant(10))();
  BoolColumn get quietHoursEnabled =>
      boolean().withDefault(const Constant(false))();
  IntColumn get quietStartMinute => integer().nullable()();
  IntColumn get quietEndMinute => integer().nullable()();
  // VS16 M7 corrective persistence repair (v47): the five per-field Detailed
  // notification content options. They were briefly stored as a namespaced key
  // inside PlannerPreferences.eventColorPreferencesJson, which was UNSAFE: the
  // planner document writers rebuild that JSON from the keys they understand
  // and silently dropped the namespaced key. Notification-specific
  // preferences therefore belong here, in typed columns, alongside every other
  // notification preference.
  //
  // v48 — the DETAILED CONTENT MASTER (owner pass 2026-09-19, item E).
  //
  // The five per-field switches below answer "which details?", but nothing
  // answered "may any detail be previewed at all?".  The saved privacy preview
  // already gates delivery, yet the screen still presented those five as live
  // choices.  This is the missing master, and it is deliberately a SEPARATE
  // column rather than "all five off": turning the master off must force the
  // generic copy while the owner's own field choices are preserved untouched,
  // and must return them when it is switched back on.  Modelling OFF as five
  // falses would destroy that configuration, which is exactly the data loss the
  // per-field columns were introduced to stop.
  //
  // DEFAULT LAW: TRUE, so a profile that never touches it keeps the richest
  // Detailed behaviour and an upgrading profile is unaffected.
  BoolColumn get detailedContentEnabled =>
      boolean().withDefault(const Constant(true))();

  // DEFAULT LAW: all five default to TRUE. A profile that has never touched
  // these settings keeps the richest Detailed behaviour and keeps the exact
  // pre-options behaviour on upgrade.
  BoolColumn get detailedShowTitle =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get detailedShowDescription =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get detailedShowTime =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get detailedShowContacts =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get detailedShowLocation =>
      boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{profileId};
}

/// Durable reminder intent. Source-level policies use the non-null `series`
/// occurrence sentinel so SQLite can enforce one row per source identity.
@TableIndex(
  name: 'reminder_policy_source_unique',
  columns: <Symbol>{#profileId, #sourceKind, #sourceId, #occurrenceId},
  unique: true,
)
@DataClassName('ReminderPolicyRow')
class ReminderPolicies extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get sourceKind => text()();
  TextColumn get sourceId => text()();
  TextColumn get occurrenceId => text()();
  TextColumn get purpose => text().withDefault(const Constant('standard'))();
  TextColumn get contactId => text().nullable()();
  TextColumn get mode => text()();
  IntColumn get offsetMinutes => integer().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Sanitized durable work/delivery projection. Workers later re-read canonical
/// source rows; private display content has no column here.
@TableIndex(
  name: 'background_work_platform_notification_unique',
  columns: <Symbol>{#platformNotificationId},
  unique: true,
)
@DataClassName('BackgroundWorkRequestRow')
class BackgroundWorkRequests extends Table {
  TextColumn get stableKey => text()();
  TextColumn get profileId => text().nullable().references(
    LocalProfiles,
    #id,
    onDelete: KeyAction.restrict,
  )();
  TextColumn get category => text()();
  TextColumn get ownerKind => text()();
  TextColumn get ownerId => text().nullable()();
  TextColumn get occurrenceId => text().nullable()();
  TextColumn get sourceRevision => text().nullable()();
  DateTimeColumn get scheduledForUtc => dateTime().nullable()();
  TextColumn get state => text()();
  IntColumn get platformNotificationId => integer().nullable()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  IntColumn get snoozeCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAttemptAtUtc => dateTime().nullable()();
  DateTimeColumn get nextEligibleAtUtc => dateTime().nullable()();
  DateTimeColumn get completedAtUtc => dateTime().nullable()();
  TextColumn get lastFailureCategory => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{stableKey};
}

@TableIndex(
  name: 'planner_task_profile_due_date',
  columns: <Symbol>{#profileId, #dueDate},
)
@DataClassName('PlannerTaskRow')
class PlannerTasks extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get dueDate => text().nullable()();
  IntColumn get dueMinute => integer().nullable()();
  TextColumn get recurrenceFrequency =>
      text().withDefault(const Constant('none'))();
  TextColumn get peopleJson => text().withDefault(const Constant('[]'))();
  TextColumn get status => text().withDefault(const Constant('incomplete'))();
  BoolColumn get requiresReport =>
      boolean().withDefault(const Constant(false))();
  // VS-11C1B.3 (v30): additive Task Backup flag, symmetric with
  // calendarEvents.isBackupAppointment. Default false: existing rows are
  // regular Tasks; NO backfill of history. Backup Tasks are controlled by
  // the Backups Planner filter and suppress reporting while enabled.
  BoolColumn get isBackup => boolean().withDefault(const Constant(false))();
  TextColumn get contributionRuleKey => text().nullable()();
  TextColumn get linkedActivityTypeId => text().nullable()();
  TextColumn get linkedActivityTypeStableKey => text().nullable()();
  TextColumn get linkedActivityTypeLabelSnapshot => text().nullable()();
  // B3.2 (v27): optional DIRECT Life Goal link.  This is the ONLY Goal
  // contribution selector for Tasks (owner lock D2); Event-Type inference
  // is removed.  Nullable + additive; historical Tasks stay unlinked (D5).
  TextColumn get goalId => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'task_status_change_operation_unique',
  columns: <Symbol>{#operationId},
  unique: true,
)
@TableIndex(
  name: 'task_status_change_task_time',
  columns: <Symbol>{#taskId, #changedAtUtc},
)
@DataClassName('TaskStatusChangeRow')
class TaskStatusChanges extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get taskId =>
      text().references(PlannerTasks, #id, onDelete: KeyAction.restrict)();
  TextColumn get operationId => text()();
  TextColumn get fromStatus => text()();
  TextColumn get toStatus => text()();
  TextColumn get reason => text().nullable()();
  TextColumn get activityTypeId => text().nullable()();
  TextColumn get activityTypeStableKeySnapshot => text().nullable()();
  TextColumn get activityTypeLabelSnapshot => text().nullable()();
  DateTimeColumn get changedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// The idempotent, reversible contribution created by a completed linked
/// Task.  It is separate from report/ledger entries because Tasks do not
/// require a report, but it still feeds the same canonical Goal indicator.
@TableIndex(
  name: 'task_goal_contribution_task_unique',
  columns: <Symbol>{#taskId},
  unique: true,
)
@TableIndex(
  name: 'task_goal_contribution_indicator_date',
  columns: <Symbol>{#profileId, #indicatorKey, #activityDate},
)
@DataClassName('TaskGoalContributionRow')
class TaskGoalContributions extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get taskId =>
      text().references(PlannerTasks, #id, onDelete: KeyAction.restrict)();
  TextColumn get activityTypeId => text().nullable()();
  TextColumn get activityTypeStableKeySnapshot => text().nullable()();
  TextColumn get activityTypeLabelSnapshot => text().nullable()();
  TextColumn get indicatorKey => text()();
  IntColumn get valueScaled => integer().withDefault(const Constant(1))();
  IntColumn get valueScale => integer().withDefault(const Constant(0))();
  TextColumn get unit => text().withDefault(const Constant('count'))();
  TextColumn get activityDate => text()();
  TextColumn get state => text().withDefault(const Constant('active'))();
  // B3.2 (v27): the Goal actually satisfied by this contribution for NEW
  // direct-Goal Tasks.  Nullable + additive; historical rows keep their
  // original identity (D5 — never rewritten just because the schema gains
  // the column).
  TextColumn get goalId => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'calendar_event_profile_start_date',
  columns: <Symbol>{#profileId, #startDate},
)
@DataClassName('CalendarEventRow')
class CalendarEvents extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get timing => text()();
  TextColumn get startDate => text()();
  IntColumn get startMinute => integer().nullable()();
  IntColumn get endMinute => integer().nullable()();
  TextColumn get timeZoneId => text().nullable()();
  TextColumn get locationText => text().nullable()();
  // MAPS V1 (v28): explicitly user-picked coordinates. Both-or-null pair;
  // coordinate_source records the provenance ('map_pick' in V1) and is null
  // whenever the pair is null. NEVER derived from locationText/address.
  RealColumn get latitude => real().nullable()();
  RealColumn get longitude => real().nullable()();
  TextColumn get coordinateSource => text().nullable()();
  BoolColumn get requiresReport =>
      boolean().withDefault(const Constant(false))();
  TextColumn get activityTypeId => text().nullable()();
  IntColumn get activityTypeMappingVersion => integer().nullable()();
  TextColumn get activityTypeStableKeySnapshot => text().nullable()();
  TextColumn get activityTypeLabelSnapshot => text().nullable()();
  IntColumn get activityTypeColorValueSnapshot => integer().nullable()();
  TextColumn get contributionRuleKey => text().nullable()();
  TextColumn get goalId => text().nullable()();
  BoolColumn get isBackupAppointment =>
      boolean().withDefault(const Constant(false))();
  TextColumn get backupForEventId => text().nullable()();
  TextColumn get backupRelationshipProvenance => text().nullable()();
  TextColumn get recurrenceFrequency =>
      text().withDefault(const Constant('none'))();
  TextColumn get recurrenceEndMode =>
      text().withDefault(const Constant('never'))();
  TextColumn get recurrenceEndDate => text().nullable()();
  IntColumn get recurrenceCount => integer().nullable()();
  TextColumn get recurrencePatternJson => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('scheduled'))();
  TextColumn get parentEventId => text().nullable()();
  TextColumn get replacementEventId => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'calendar_event_exception_occurrence_time',
  columns: <Symbol>{#eventId, #occurrenceId, #createdAtUtc},
)
@DataClassName('CalendarEventExceptionRow')
class CalendarEventExceptions extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get eventId =>
      text().references(CalendarEvents, #id, onDelete: KeyAction.restrict)();
  TextColumn get occurrenceId => text()();
  TextColumn get originalDate => text()();
  TextColumn get effectiveDate => text()();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get timing => text()();
  IntColumn get startMinute => integer().nullable()();
  IntColumn get endMinute => integer().nullable()();
  TextColumn get timeZoneId => text().nullable()();
  TextColumn get locationText => text().nullable()();
  BoolColumn get requiresReport =>
      boolean().withDefault(const Constant(false))();
  TextColumn get activityTypeId => text().nullable()();
  IntColumn get activityTypeMappingVersion => integer().nullable()();
  TextColumn get activityTypeStableKeySnapshot => text().nullable()();
  TextColumn get activityTypeLabelSnapshot => text().nullable()();
  IntColumn get activityTypeColorValueSnapshot => integer().nullable()();
  TextColumn get contributionRuleKey => text().nullable()();
  TextColumn get goalId => text().nullable()();
  BoolColumn get isBackupAppointment =>
      boolean().withDefault(const Constant(false))();
  TextColumn get backupForEventId => text().nullable()();
  TextColumn get backupRelationshipProvenance => text().nullable()();
  TextColumn get status => text()();
  TextColumn get replacementEventId => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('CalendarEventOperationRow')
class CalendarEventOperations extends Table {
  TextColumn get operationId => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get eventId => text()();
  TextColumn get occurrenceId => text().nullable()();
  TextColumn get command => text()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{operationId};
}

@TableIndex(
  name: 'task_event_link_equivalent_unique',
  columns: <Symbol>{#profileId, #taskId, #eventId, #targetKey},
  unique: true,
)
@TableIndex(
  name: 'task_event_link_task_status',
  columns: <Symbol>{#taskId, #status},
)
@TableIndex(
  name: 'task_event_link_event_status',
  columns: <Symbol>{#eventId, #status},
)
@DataClassName('TaskEventLinkRow')
class TaskEventLinks extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get taskId => text()();
  TextColumn get eventId => text()();
  TextColumn get scope => text()();
  TextColumn get targetKey => text()();
  TextColumn get occurrenceId => text().nullable()();
  TextColumn get originalDate => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get canonicalSource => text()();
  TextColumn get transferredFromLinkId => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'task_event_link_history_operation_unique',
  columns: <Symbol>{#operationId},
  unique: true,
)
@TableIndex(
  name: 'task_event_link_history_link_time',
  columns: <Symbol>{#linkId, #createdAtUtc},
)
@DataClassName('TaskEventLinkHistoryRow')
class TaskEventLinkHistory extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get linkId => text()();
  TextColumn get operationId => text()();
  TextColumn get action => text()();
  TextColumn get fromStatus => text().nullable()();
  TextColumn get toStatus => text()();
  TextColumn get relatedLinkId => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'outcome_report_effective_slot_unique',
  columns: <Symbol>{#effectiveSlotKey},
  unique: true,
)
@TableIndex(
  name: 'outcome_report_draft_slot_unique',
  columns: <Symbol>{#draftSlotKey},
  unique: true,
)
@TableIndex(
  name: 'outcome_report_operation_unique',
  columns: <Symbol>{#operationId},
  unique: true,
)
@TableIndex(
  name: 'outcome_report_profile_activity_date',
  columns: <Symbol>{#profileId, #activityDate},
)
@DataClassName('OutcomeReportRow')
class OutcomeReports extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get sourceType => text()();
  TextColumn get sourceId => text()();
  TextColumn get sourceLabel => text()();
  TextColumn get sourceSlotKey => text()();
  TextColumn get eventId => text().nullable()();
  TextColumn get occurrenceId => text().nullable()();
  TextColumn get originalDate => text().nullable()();
  TextColumn get draftSlotKey => text().nullable()();
  TextColumn get effectiveSlotKey => text().nullable()();
  TextColumn get status => text()();
  TextColumn get outcome => text().nullable()();
  TextColumn get activityDate => text()();
  IntColumn get factualValueScaled => integer().nullable()();
  IntColumn get factualValueScale => integer().withDefault(const Constant(0))();
  TextColumn get factualValueUnit => text().nullable()();
  TextColumn get privateNotes => text().nullable()();
  TextColumn get correctsReportId => text().nullable()();
  TextColumn get correctionReason => text().nullable()();
  TextColumn get operationId => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();
  DateTimeColumn get submittedAtUtc => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('OutcomeReportContributionDraftRow')
class OutcomeReportContributionDrafts extends Table {
  TextColumn get reportId =>
      text().references(OutcomeReports, #id, onDelete: KeyAction.cascade)();
  TextColumn get ruleKey => text()();
  TextColumn get indicatorKey => text()();
  IntColumn get valueScaled => integer()();
  IntColumn get valueScale => integer()();
  TextColumn get unit => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{reportId, ruleKey};
}

@TableIndex(
  name: 'ledger_entry_idempotency_unique',
  columns: <Symbol>{#idempotencyKey},
  unique: true,
)
@TableIndex(
  name: 'ledger_entry_reversal_unique',
  columns: <Symbol>{#reversalOfEntryId},
  unique: true,
)
@TableIndex(
  name: 'ledger_entry_indicator_period',
  columns: <Symbol>{#profileId, #indicatorKey, #activityDate},
)
@TableIndex(
  name: 'ledger_entry_report_rule',
  columns: <Symbol>{#sourceReportId, #ruleKey},
)
@DataClassName('ActivityLedgerEntryRow')
class ActivityLedgerEntries extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get sourceReportId =>
      text().references(OutcomeReports, #id, onDelete: KeyAction.restrict)();
  TextColumn get entryType => text()();
  TextColumn get indicatorKey => text()();
  IntColumn get valueScaled => integer()();
  IntColumn get valueScale => integer()();
  TextColumn get unit => text()();
  TextColumn get activityDate => text()();
  TextColumn get ruleKey => text()();
  TextColumn get idempotencyKey => text()();
  TextColumn get reversalOfEntryId => text().nullable()();
  TextColumn get replacesEntryId => text().nullable()();
  DateTimeColumn get recordedAtUtc => dateTime()();

  /// OPD-3-004 (v29): the explicitly confirmed meaningful Contact this
  /// contribution is attributed to. NULL keeps the classic non-Contact
  /// contribution. Never inferred from event links; set only by explicit user
  /// confirmation. Archived/merged Contacts keep this stable id so historical
  /// truth is preserved without rewriting.
  TextColumn get contactId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'weekly_indicator_target_operation_unique',
  columns: <Symbol>{#operationId},
  unique: true,
)
@TableIndex(
  name: 'weekly_indicator_target_period_history',
  columns: <Symbol>{#profileId, #indicatorKey, #periodStartDate, #createdAtUtc},
)
@DataClassName('WeeklyIndicatorTargetRevisionRow')
class WeeklyIndicatorTargetRevisions extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get indicatorKey => text()();
  TextColumn get goalId => text().nullable()();
  TextColumn get periodStartDate => text()();
  TextColumn get state => text()();
  IntColumn get valueScaled => integer().nullable()();
  IntColumn get valueScale => integer()();
  TextColumn get unit => text()();
  TextColumn get supersedesRevisionId => text().nullable()();
  TextColumn get operationId => text()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Goal revisions whose period is not necessarily weekly.  Weekly targets
/// remain in [WeeklyIndicatorTargetRevisions] for backwards compatibility;
/// this table carries the daily and monthly slots and gives every period type
/// the same idempotent, append-only semantics.
@TableIndex(
  name: 'indicator_goal_operation_unique',
  columns: <Symbol>{#operationId},
  unique: true,
)
@TableIndex(
  name: 'indicator_goal_period_history',
  columns: <Symbol>{
    #profileId,
    #indicatorKey,
    #periodType,
    #periodStartDate,
    #createdAtUtc,
  },
)
@DataClassName('IndicatorGoalRevisionRow')
class IndicatorGoalRevisions extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get goalId => text().nullable()();
  TextColumn get indicatorKey => text()();
  TextColumn get periodType => text()();
  TextColumn get periodStartDate => text()();
  TextColumn get periodEndDate => text()();
  TextColumn get state => text()();
  IntColumn get valueScaled => integer().nullable()();
  IntColumn get valueScale => integer()();
  TextColumn get unit => text()();
  TextColumn get supersedesRevisionId => text().nullable()();
  TextColumn get operationId => text()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'weekly_plan_profile_period_unique',
  columns: <Symbol>{#profileId, #periodStartDate},
  unique: true,
)
@DataClassName('WeeklyPlanRow')
class WeeklyPlans extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get periodStartDate => text()();
  TextColumn get periodEndDate => text()();
  TextColumn get timeZoneId => text()();
  TextColumn get state => text()();
  DateTimeColumn get reviewCompletedAtUtc => dateTime().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Immutable answer to "which Goals belonged to this week?"  This is separate
/// from the current Goal lifecycle: later completion, archive, or deletion
/// never rewrites a captured weekly plan.
@TableIndex(
  name: 'weekly_plan_goal_membership_unique',
  columns: <Symbol>{#weeklyPlanId, #goalId},
  unique: true,
)
@DataClassName('WeeklyPlanGoalMembershipRow')
class WeeklyPlanGoalMemberships extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get weeklyPlanId =>
      text().references(WeeklyPlans, #id, onDelete: KeyAction.restrict)();
  TextColumn get goalId =>
      text().references(Goals, #id, onDelete: KeyAction.restrict)();
  IntColumn get slotOrder => integer()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'activity_type_profile_key_unique',
  columns: <Symbol>{#profileId, #stableKey},
  unique: true,
)
@TableIndex(
  name: 'activity_type_profile_position',
  columns: <Symbol>{#profileId, #position},
)
@DataClassName('ActivityTypeRow')
class ActivityTypes extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get stableKey => text()();
  TextColumn get label => text()();
  TextColumn get iconKey => text()();
  IntColumn get colorValue => integer()();
  BoolColumn get isSystem => boolean()();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
  BoolColumn get reportRequiredDefault =>
      boolean().withDefault(const Constant(false))();
  IntColumn get defaultDurationMinutes =>
      integer().withDefault(const Constant(60))();
  IntColumn get defaultReminderMinutes => integer().nullable()();
  IntColumn get position => integer()();
  IntColumn get mappingVersion => integer().withDefault(const Constant(1))();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'activity_type_indicator_mapping_unique',
  columns: <Symbol>{#activityTypeId, #mappingVersion, #indicatorKey},
  unique: true,
)
@DataClassName('ActivityTypeIndicatorMappingRow')
class ActivityTypeIndicatorMappings extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get activityTypeId =>
      text().references(ActivityTypes, #id, onDelete: KeyAction.restrict)();
  TextColumn get indicatorKey => text()();
  IntColumn get mappingVersion => integer().withDefault(const Constant(1))();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// A private contact belonging to one Local Profile.
///
/// Lifecycle is `active` | `archived` | `merged`.  Archived preserves the
/// same ID and all historical links; merged records keep their identity so
/// historical participation remains traceable to the absorbed contact.
@TableIndex(
  name: 'contact_profile_lifecycle',
  columns: <Symbol>{#profileId, #lifecycleState},
)
@TableIndex(
  name: 'contact_profile_name',
  columns: <Symbol>{#profileId, #displayName},
)
@TableIndex(
  name: 'contact_profile_favorite',
  columns: <Symbol>{#profileId, #isFavorite},
)
@DataClassName('ContactRow')
class Contacts extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get firstName => text().nullable()();
  TextColumn get lastName => text().nullable()();
  TextColumn get displayName => text()();
  TextColumn get preferredContactMethod =>
      text().withDefault(const Constant('message'))();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  TextColumn get lifecycleState =>
      text().withDefault(const Constant('active'))();
  TextColumn get source => text().withDefault(const Constant('manual'))();
  TextColumn get addressText => text().nullable()();
  // MAPS V1 (v28): explicitly user-picked coordinates. Both-or-null pair;
  // coordinate_source records provenance ('map_pick' in V1) and is null
  // whenever the pair is null. NEVER derived from addressText.
  RealColumn get latitude => real().nullable()();
  RealColumn get longitude => real().nullable()();
  TextColumn get coordinateSource => text().nullable()();

  /// Set when this Contact is merged into another.  Historical links,
  /// methods, groups, tags, notes, and Timeline stay attached so the absorbed
  /// identity remains traceable; active/archived queries hide the row.
  TextColumn get mergedIntoContactId => text().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();
  DateTimeColumn get lastViewedAtUtc => dateTime().nullable()();
  DateTimeColumn get archivedAtUtc => dateTime().nullable()();

  /// Recoverable deletion intent only.  A recently-deleted Contact retains
  /// every restrictive relationship until a future, separately approved
  /// retention/tombstone feature exists.
  DateTimeColumn get deletedAtUtc => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'contact_method_contact_normalized_unique',
  columns: <Symbol>{#contactId, #type, #normalizedValue},
  unique: true,
)
@DataClassName('ContactMethodRow')
class ContactMethods extends Table {
  TextColumn get id => text()();
  TextColumn get contactId =>
      text().references(Contacts, #id, onDelete: KeyAction.restrict)();
  TextColumn get type => text()();
  TextColumn get label => text().nullable()();
  TextColumn get rawValue => text()();
  TextColumn get normalizedValue => text()();
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();

  /// Nullable capability facts preserve legacy rows as unknown rather than
  /// inventing a communication permission during migration.
  BoolColumn get receivesTexts => boolean().nullable()();
  BoolColumn get hasWhatsApp => boolean().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'contact_group_profile_unique_name',
  columns: <Symbol>{#profileId, #name},
  unique: true,
)
@DataClassName('ContactGroupRow')
class ContactGroups extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get name => text()();
  IntColumn get colorValue => integer()();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('ContactGroupMembershipRow')
class ContactGroupMemberships extends Table {
  TextColumn get contactId =>
      text().references(Contacts, #id, onDelete: KeyAction.cascade)();
  TextColumn get groupId =>
      text().references(ContactGroups, #id, onDelete: KeyAction.cascade)();
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{contactId, groupId};
}

@TableIndex(
  name: 'contact_tag_profile_unique_name',
  columns: <Symbol>{#profileId, #name},
  unique: true,
)
@DataClassName('ContactTagRow')
class ContactTags extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get name => text()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('ContactTagMembershipRow')
class ContactTagMemberships extends Table {
  TextColumn get contactId =>
      text().references(Contacts, #id, onDelete: KeyAction.cascade)();
  TextColumn get tagId =>
      text().references(ContactTags, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{contactId, tagId};
}

@TableIndex(
  name: 'contact_availability_contact_weekday',
  columns: <Symbol>{#contactId, #weekday},
)
@DataClassName('ContactAvailabilityRow')
class ContactAvailabilities extends Table {
  TextColumn get id => text()();
  TextColumn get contactId =>
      text().references(Contacts, #id, onDelete: KeyAction.restrict)();
  IntColumn get weekday => integer()();
  IntColumn get startMinute => integer()();
  IntColumn get endMinute => integer()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// A Contact's participation in a Calendar Event.
///
/// [occurrenceId] is the deterministic occurrence identity
/// (`CalendarEventOccurrenceIdentity.forDate`) or the literal `series` for a
/// series-level participant.  Series-level participants apply to every
/// occurrence; occurrence-level rows override for a single date.  Past
/// participation is additionally frozen into [EventOccurrenceParticipants]
/// so later series edits can never rewrite history.
@TableIndex(
  name: 'event_contact_link_equivalent_unique',
  columns: <Symbol>{#profileId, #eventId, #occurrenceId, #contactId},
  unique: true,
)
@TableIndex(
  name: 'event_contact_link_contact',
  columns: <Symbol>{#contactId, #status},
)
@DataClassName('EventContactLinkRow')
class EventContactLinks extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get eventId => text()();
  TextColumn get occurrenceId => text().withDefault(const Constant('series'))();
  TextColumn get originalDate => text().nullable()();
  TextColumn get contactId =>
      text().references(Contacts, #id, onDelete: KeyAction.restrict)();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Immutable occurrence-level participant snapshot.
///
/// Written when a past occurrence is materialized, reported, or when a
/// series-level People edit could otherwise erase history.  The Timeline and
/// event detail read snapshots for past occurrences and live links only for
/// upcoming ones, so historical participation survives recurrence edits.
@TableIndex(
  name: 'event_occurrence_participant_unique',
  columns: <Symbol>{#eventId, #occurrenceId, #contactId},
  unique: true,
)
@TableIndex(
  name: 'event_occurrence_participant_contact_date',
  columns: <Symbol>{#contactId, #originalDate},
)
@DataClassName('EventOccurrenceParticipantRow')
class EventOccurrenceParticipants extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get eventId => text()();
  TextColumn get occurrenceId => text()();
  TextColumn get originalDate => text()();
  TextColumn get contactId =>
      text().references(Contacts, #id, onDelete: KeyAction.restrict)();
  TextColumn get displayNameSnapshot => text()();
  IntColumn get groupColorValueSnapshot => integer().nullable()();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'task_contact_link_equivalent_unique',
  columns: <Symbol>{#taskId, #contactId},
  unique: true,
)
@TableIndex(name: 'task_contact_link_contact', columns: <Symbol>{#contactId})
@DataClassName('TaskContactLinkRow')
class TaskContactLinks extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get taskId => text()();
  TextColumn get contactId =>
      text().references(Contacts, #id, onDelete: KeyAction.restrict)();
  DateTimeColumn get createdAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'saved_contact_filter_profile',
  columns: <Symbol>{#profileId, #createdAtUtc},
)
@DataClassName('SavedContactFilterRow')
class SavedContactFilters extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get name => text()();
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();
  TextColumn get criteriaJson => text()();
  TextColumn get sortBy => text().withDefault(const Constant('name'))();
  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@TableIndex(
  name: 'saved_place_profile_label',
  columns: <Symbol>{#profileId, #label, #createdAtUtc, #id},
)
class SavedPlaces extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get label =>
      text().customConstraint('NOT NULL CHECK (length(trim(label)) > 0)')();
  RealColumn get latitude => real().customConstraint(
    'NOT NULL CHECK (latitude >= -90 AND latitude <= 90)',
  )();
  RealColumn get longitude => real().customConstraint(
    'NOT NULL CHECK (longitude >= -180 AND longitude <= 180)',
  )();

  /// VS-15 M3 promoted customization: marker identity becomes durable state.
  /// `standardCategory` and `customEmoji` are mutually exclusive at the value
  /// level (only one is meaningful for a given markerMode).
  TextColumn get markerMode => text().withDefault(const Constant('standard'))();
  TextColumn get standardCategory => text().nullable()();
  TextColumn get customEmoji => text().nullable()();
  TextColumn get markerColor => text().withDefault(const Constant('#175A8F'))();

  /// VS-15 M6.1 boundary foundation: the 0..1 user-drawn polygon owned by
  /// this place record. `boundaryColor` is a normalized no-alpha hex
  /// INDEPENDENT of `markerColor`; `boundaryVertices` is the ordered JSON
  /// vertex list emitted by SavedPlaceBoundary.encodeVertices. Null on both
  /// means the place has no boundary. No separate table for V1; the boundary
  /// cannot outlive its place row.
  TextColumn get boundaryColor => text().nullable()();
  TextColumn get boundaryVertices => text().nullable()();

  DateTimeColumn get createdAtUtc => dateTime()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('PlannerPreferenceRow')
class PlannerPreferences extends Table {
  TextColumn get profileId =>
      text().references(LocalProfiles, #id, onDelete: KeyAction.restrict)();
  TextColumn get defaultActivityTypeId => text().nullable()();
  // Delta 4.2R R8: the Planner default Event duration is 30 minutes (the
  // previous Delta 4.2 temporary 60-minute default is replaced). The value
  // remains a user preference; a v24 data migration resets only stored rows
  // that still hold the old temporary 60.
  IntColumn get defaultDurationMinutes =>
      integer().withDefault(const Constant(30))();
  IntColumn get defaultReminderMinutes => integer().nullable()();
  IntColumn get visibleStartHour => integer().withDefault(const Constant(6))();
  IntColumn get visibleEndHour => integer().withDefault(const Constant(22))();
  BoolColumn get use24HourTime =>
      boolean().withDefault(const Constant(false))();
  IntColumn get snapMinutes => integer().withDefault(const Constant(15))();
  BoolColumn get showCurrentTime =>
      boolean().withDefault(const Constant(true))();
  TextColumn get initialScrollBehavior =>
      text().withDefault(const Constant('currentTime'))();
  TextColumn get creationPresentation =>
      text().withDefault(const Constant('sheet'))();
  BoolColumn get quickEditEnabled =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get showCompletedItems =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get showCancelledItems =>
      boolean().withDefault(const Constant(false))();
  IntColumn get weekStartDay =>
      integer().withDefault(const Constant(DateTime.monday))();
  TextColumn get preferredPresentation =>
      text().withDefault(const Constant('day'))();
  BoolColumn get showEvents => boolean().withDefault(const Constant(true))();
  BoolColumn get showBackupEvents =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get showTasks => boolean().withDefault(const Constant(true))();
  BoolColumn get showCompletedTasks =>
      boolean().withDefault(const Constant(false))();
  IntColumn get timelineHourHeight =>
      integer().withDefault(const Constant(60))();
  TextColumn get eventColorPreferencesJson => text().nullable()();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{profileId};
}

/// Pack B1 Appearance foundation + B2-CORRECTION Theme Color: the single
/// device-scoped appearance preference (System / Light / Dark) and the
/// independent Theme Color (Rose / Blue).  One row keyed by the constant
/// 'primary', mirroring the PrivacyPreferences device scope.  Fresh v26
/// installs have no row yet (reads as DARK + BLUE, B2-FINAL-POLISH owner
/// lock); a v24 upgrade seeds 'dark' to preserve the only appearance v24
/// users ever had, and the v26 migration adds theme_color defaulting to
/// 'blue'.
class AppearancePreferences extends Table {
  TextColumn get key => text().withDefault(const Constant('primary'))();
  TextColumn get appearanceMode => text().withDefault(const Constant('dark'))();
  TextColumn get themeColor => text().withDefault(const Constant('blue'))();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

/// VS-15 M6.2 (v37): dedicated DEVICE-SCOPED Maps presentation preferences.
/// One row keyed by the constant 'primary' (Appearance/Privacy precedent).
///
/// A missing row resolves the owner-locked defaults (Satellite + all five
/// booleans true) for BOTH fresh and upgraded installs — no row is seeded,
/// no install-history sentinel exists. The first explicit user choice
/// creates the physical row; repository idempotence may skip a write only
/// when a physical row already stores the requested value.
@DataClassName('MapsPreferenceRow')
class MapsPreferences extends Table {
  TextColumn get key => text().withDefault(const Constant('primary'))();
  TextColumn get mapType => text().withDefault(const Constant('satellite'))();
  BoolColumn get groupNearbyMarkers =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get showContacts => boolean().withDefault(const Constant(true))();
  BoolColumn get showEvents => boolean().withDefault(const Constant(true))();
  BoolColumn get showSavedPlaces =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get showBoundaries =>
      boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAtUtc => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

/// Connection options for the app's single logical database file.
///
/// VS16 M7 corrective — first-launch migration race.
///
/// `AppDatabase.defaults()` is constructed from three independent sites
/// (`lib/main.dart`, and twice in
/// `lib/features/notifications/application/reminder_background_runtime.dart`).
/// With drift's default options each site opened its OWN connection to
/// `next_transfer.sqlite`. On the first launch after the upgrade, two
/// connections could therefore both decide to run the v46 -> v47 `onUpgrade`
/// at once:
///
///   * connection A acquired RESERVED (`BEGIN IMMEDIATE`) and then needed
///     EXCLUSIVE to commit, but could not get it while B held SHARED;
///   * connection B held SHARED (from reading `user_version`) and needed
///     RESERVED, but could not get it while A held RESERVED.
///
/// That is a genuine lock-upgrade deadlock, so SQLite returns
/// `SqliteException(5): database is locked` and NO timeout can rescue it.
/// Measured, not assumed: a busy timeout of 5 s, `journal_mode = WAL`, and both
/// together were each tried against a reproduced race and each still failed
/// (evidence: `.m7_frozen_audit/migration_race_probe/`). The exception was
/// unhandled on the startup path, so no frame was ever drawn and the app
/// appeared to hang on the splash screen; the second launch succeeded because
/// the schema was already 47 and `onUpgrade` was skipped.
///
/// The only correction that addresses the cause is to stop having more than one
/// connection in the first place, which is what drift's own
/// [DriftNativeOptions.shareAcrossIsolates] does: every
/// `driftDatabase(name: 'next_transfer')` in the process converges on ONE shared
/// connection. Drift documents this option as managing "concurrent access to the
/// database, preventing 'database is locked' errors due to concurrent
/// transactions" and "recommended if a drift database may be used on multiple
/// isolates".
///
/// Scope: no schema change (still exactly 47), no migration-logic change, no
/// change to `beforeOpen`/`onUpgrade`, no new dependency.
/// `AppDatabase.forTesting` is untouched, so every existing database test keeps
/// its own executor and behaviour.
///
/// Known limit, stated honestly: `shareAcrossIsolates` shares within one Flutter
/// engine (it uses `IsolateNameServer`). It removes the three same-engine
/// connections that caused this startup failure. A separate engine would need a
/// different remedy; none is introduced here.
const DriftNativeOptions kAppDatabaseNativeOptions = DriftNativeOptions(
  shareAcrossIsolates: true,
);

@DriftDatabase(
  tables: <Type>[
    LocalProfiles,
    OnboardingCheckpoints,
    LifeIndicatorDefinitions,
    Goals,
    GoalActivities,
    GoalOutboxOperations,
    GoalAchievementEvents,
    PrivacyPreferences,
    PermissionAudits,
    NotificationPreferences,
    ReminderPolicies,
    BackgroundWorkRequests,
    PlannerTasks,
    TaskStatusChanges,
    TaskGoalContributions,
    CalendarEvents,
    CalendarEventExceptions,
    CalendarEventOperations,
    TaskEventLinks,
    TaskEventLinkHistory,
    OutcomeReports,
    OutcomeReportContributionDrafts,
    ActivityLedgerEntries,
    WeeklyIndicatorTargetRevisions,
    IndicatorGoalRevisions,
    WeeklyPlans,
    WeeklyPlanGoalMemberships,
    ActivityTypes,
    ActivityTypeIndicatorMappings,
    PlannerPreferences,
    Contacts,
    ContactMethods,
    ContactGroups,
    ContactGroupMemberships,
    ContactTags,
    ContactTagMemberships,
    ContactNotes,
    ContactAvailabilities,
    EventContactLinks,
    EventOccurrenceParticipants,
    TaskContactLinks,
    SavedContactFilters,
    SavedPlaces,
    AppearancePreferences,
    MapsPreferences,
  ],
)
final class AppDatabase extends _$AppDatabase {
  AppDatabase.defaults()
    : _schemaVersionOverride = null,
      _injectMigrationFailure = false,
      _injectTaskMigrationFailure = false,
      _injectCalendarEventMigrationFailure = false,
      _injectTaskEventLinkMigrationFailure = false,
      _injectOutcomeReportingMigrationFailure = false,
      _injectIndicatorMigrationFailure = false,
      _injectWeeklyPlanningMigrationFailure = false,
      _injectPlannerCorrectionMigrationFailure = false,
      _injectPlannerExperienceMigrationFailure = false,
      _injectContactsMigrationFailure = false,
      _injectSavedPlaceMigrationFailure = false,
      _injectSavedPlaceCustomizationMigrationFailure = false,
      _injectMapsPreferencesMigrationFailure = false,
      _injectNotificationFoundationMigrationFailure = false,
      super(
        driftDatabase(name: 'next_transfer', native: kAppDatabaseNativeOptions),
      );

  AppDatabase.forTesting(
    super.executor, {
    int? schemaVersionOverride,
    bool injectMigrationFailure = false,
    bool injectTaskMigrationFailure = false,
    bool injectCalendarEventMigrationFailure = false,
    bool injectTaskEventLinkMigrationFailure = false,
    bool injectOutcomeReportingMigrationFailure = false,
    bool injectIndicatorMigrationFailure = false,
    bool injectWeeklyPlanningMigrationFailure = false,
    bool injectPlannerCorrectionMigrationFailure = false,
    bool injectPlannerExperienceMigrationFailure = false,
    bool injectContactsMigrationFailure = false,
    bool injectSavedPlaceMigrationFailure = false,
    bool injectSavedPlaceCustomizationMigrationFailure = false,
    bool injectMapsPreferencesMigrationFailure = false,
    bool injectNotificationFoundationMigrationFailure = false,
  }) : _schemaVersionOverride = schemaVersionOverride,
       _injectMigrationFailure = injectMigrationFailure,
       _injectTaskMigrationFailure = injectTaskMigrationFailure,
       _injectCalendarEventMigrationFailure =
           injectCalendarEventMigrationFailure,
       _injectTaskEventLinkMigrationFailure =
           injectTaskEventLinkMigrationFailure,
       _injectOutcomeReportingMigrationFailure =
           injectOutcomeReportingMigrationFailure,
       _injectIndicatorMigrationFailure = injectIndicatorMigrationFailure,
       _injectWeeklyPlanningMigrationFailure =
           injectWeeklyPlanningMigrationFailure,
       _injectPlannerCorrectionMigrationFailure =
           injectPlannerCorrectionMigrationFailure,
       _injectPlannerExperienceMigrationFailure =
           injectPlannerExperienceMigrationFailure,
       _injectContactsMigrationFailure = injectContactsMigrationFailure,
       _injectSavedPlaceMigrationFailure = injectSavedPlaceMigrationFailure,
       _injectSavedPlaceCustomizationMigrationFailure =
           injectSavedPlaceCustomizationMigrationFailure,
       _injectMapsPreferencesMigrationFailure =
           injectMapsPreferencesMigrationFailure,
       _injectNotificationFoundationMigrationFailure =
           injectNotificationFoundationMigrationFailure;

  final int? _schemaVersionOverride;
  final bool _injectMigrationFailure;
  final bool _injectTaskMigrationFailure;
  final bool _injectCalendarEventMigrationFailure;
  final bool _injectTaskEventLinkMigrationFailure;
  final bool _injectOutcomeReportingMigrationFailure;
  final bool _injectIndicatorMigrationFailure;
  final bool _injectWeeklyPlanningMigrationFailure;
  final bool _injectPlannerCorrectionMigrationFailure;
  final bool _injectPlannerExperienceMigrationFailure;
  final bool _injectContactsMigrationFailure;
  final bool _injectSavedPlaceMigrationFailure;
  final bool _injectSavedPlaceCustomizationMigrationFailure;
  final bool _injectMapsPreferencesMigrationFailure;
  final bool _injectNotificationFoundationMigrationFailure;

  @override
  int get schemaVersion => _schemaVersionOverride ?? 48;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (migrator) async {
        await migrator.createTable(localProfiles);
        await migrator.createTable(onboardingCheckpoints);
        await migrator.createTable(lifeIndicatorDefinitions);
        if (schemaVersion >= 2) {
          await migrator.createTable(privacyPreferences);
          await migrator.createTable(permissionAudits);
        }
        if (schemaVersion >= 3) {
          await migrator.createTable(plannerTasks);
          await migrator.createTable(taskStatusChanges);
          if (schemaVersion >= 19) {
            await migrator.createTable(taskGoalContributions);
          }
        }
        if (schemaVersion >= 4) {
          await migrator.createTable(calendarEvents);
          await migrator.createTable(calendarEventExceptions);
          await migrator.createTable(calendarEventOperations);
        }
        if (schemaVersion >= 5) {
          await migrator.createTable(taskEventLinks);
          await migrator.createTable(taskEventLinkHistory);
        }
        if (schemaVersion >= 6) {
          await migrator.createTable(outcomeReports);
          await migrator.createTable(outcomeReportContributionDrafts);
          await migrator.createTable(activityLedgerEntries);
        }
        if (schemaVersion >= 7) {
          await migrator.createTable(weeklyIndicatorTargetRevisions);
        }
        if (schemaVersion >= 8) {
          await migrator.createTable(weeklyPlans);
        }
        if (schemaVersion >= 44) {
          await migrator.createTable(weeklyPlanGoalMemberships);
          if (schemaVersion >= 45) {
            await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS '
              'weekly_plan_goal_membership_unique '
              'ON weekly_plan_goal_memberships (weekly_plan_id, goal_id)',
            );
          }
        }
        if (schemaVersion >= 9) {
          await migrator.createTable(activityTypes);
          await migrator.createTable(activityTypeIndicatorMappings);
          await migrator.createTable(plannerPreferences);
        }
        if (schemaVersion >= 17) {
          await migrator.createTable(goals);
          await migrator.createTable(goalActivities);
          await migrator.createTable(goalOutboxOperations);
        }
        if (schemaVersion >= 42) {
          await migrator.createTable(goalAchievementEvents);
        }
        if (schemaVersion >= 14) {
          await migrator.createTable(indicatorGoalRevisions);
        }
        if (schemaVersion >= 25) {
          await migrator.createTable(appearancePreferences);
        }
        if (schemaVersion >= 22) {
          await migrator.createTable(contacts);
          await migrator.createTable(contactMethods);
          await migrator.createTable(contactGroups);
          await migrator.createTable(contactGroupMemberships);
          await migrator.createTable(contactTags);
          await migrator.createTable(contactTagMemberships);
          await migrator.createTable(contactNotes);
          await migrator.createTable(contactAvailabilities);
          await migrator.createTable(eventContactLinks);
          await migrator.createTable(eventOccurrenceParticipants);
          await migrator.createTable(taskContactLinks);
          await migrator.createTable(savedContactFilters);
        }
        if (schemaVersion >= 34) {
          await migrator.createTable(savedPlaces);
        }
        if (schemaVersion >= 37) {
          await migrator.createTable(mapsPreferences);
        }
        if (schemaVersion >= 38) {
          await migrator.createTable(notificationPreferences);
          await migrator.createTable(reminderPolicies);
          await migrator.createTable(backgroundWorkRequests);
        }
      },
      onUpgrade: (migrator, from, to) async {
        await transaction(() async {
          if (from < 2 && to >= 2) {
            await migrator.createTable(privacyPreferences);
            await migrator.createTable(permissionAudits);
            if (_injectMigrationFailure) {
              throw StateError('Injected migration failure');
            }
          }
          if (from < 3 && to >= 3) {
            await migrator.createTable(plannerTasks);
            await migrator.createTable(taskStatusChanges);
            if (_injectTaskMigrationFailure) {
              throw StateError('Injected task migration failure');
            }
          }
          if (from < 4 && to >= 4) {
            await migrator.createTable(calendarEvents);
            await migrator.createTable(calendarEventExceptions);
            await migrator.createTable(calendarEventOperations);
            if (_injectCalendarEventMigrationFailure) {
              throw StateError('Injected Calendar Event migration failure');
            }
          }
          if (from < 5 && to >= 5) {
            await migrator.createTable(taskEventLinks);
            await migrator.createTable(taskEventLinkHistory);
            if (_injectTaskEventLinkMigrationFailure) {
              throw StateError('Injected Task-Event link migration failure');
            }
          }
          if (from < 6 && to >= 6) {
            await migrator.createTable(outcomeReports);
            await migrator.createTable(outcomeReportContributionDrafts);
            await migrator.createTable(activityLedgerEntries);
            if (_injectOutcomeReportingMigrationFailure) {
              throw StateError('Injected outcome reporting migration failure');
            }
          }
          if (from < 7 && to >= 7) {
            await migrator.createTable(weeklyIndicatorTargetRevisions);
            if (_injectIndicatorMigrationFailure) {
              throw StateError('Injected indicator migration failure');
            }
          }
          if (from < 8 && to >= 8) {
            if (!await _columnExists('local_profiles', 'time_zone_id')) {
              await migrator.addColumn(localProfiles, localProfiles.timeZoneId);
            }
            await migrator.createTable(weeklyPlans);
            if (_injectWeeklyPlanningMigrationFailure) {
              throw StateError('Injected weekly planning migration failure');
            }
          }
          if (from < 9 && to >= 9) {
            await migrator.createTable(activityTypes);
            await migrator.createTable(activityTypeIndicatorMappings);
            await migrator.createTable(plannerPreferences);
            if (!await _columnExists('calendar_events', 'activity_type_id')) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.activityTypeId,
              );
            }
            if (!await _columnExists(
              'calendar_events',
              'activity_type_mapping_version',
            )) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.activityTypeMappingVersion,
              );
            }
            if (!await _columnExists(
              'calendar_event_exceptions',
              'activity_type_id',
            )) {
              await migrator.addColumn(
                calendarEventExceptions,
                calendarEventExceptions.activityTypeId,
              );
            }
            if (!await _columnExists(
              'calendar_event_exceptions',
              'activity_type_mapping_version',
            )) {
              await migrator.addColumn(
                calendarEventExceptions,
                calendarEventExceptions.activityTypeMappingVersion,
              );
            }
            if (_injectPlannerCorrectionMigrationFailure) {
              throw StateError('Injected Planner correction migration failure');
            }
          }
          if (from < 10 && to >= 10) {
            if (!await _columnExists(
              'calendar_events',
              'is_backup_appointment',
            )) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.isBackupAppointment,
              );
            }
            if (!await _columnExists(
              'calendar_events',
              'backup_for_event_id',
            )) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.backupForEventId,
              );
            }
            if (!await _columnExists(
              'calendar_events',
              'backup_relationship_provenance',
            )) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.backupRelationshipProvenance,
              );
            }
            if (!await _columnExists(
              'calendar_event_exceptions',
              'is_backup_appointment',
            )) {
              await migrator.addColumn(
                calendarEventExceptions,
                calendarEventExceptions.isBackupAppointment,
              );
            }
            if (!await _columnExists(
              'calendar_event_exceptions',
              'backup_for_event_id',
            )) {
              await migrator.addColumn(
                calendarEventExceptions,
                calendarEventExceptions.backupForEventId,
              );
            }
            if (!await _columnExists(
              'calendar_event_exceptions',
              'backup_relationship_provenance',
            )) {
              await migrator.addColumn(
                calendarEventExceptions,
                calendarEventExceptions.backupRelationshipProvenance,
              );
            }
            if (!await _columnExists(
              'planner_preferences',
              'preferred_presentation',
            )) {
              await migrator.addColumn(
                plannerPreferences,
                plannerPreferences.preferredPresentation,
              );
            }
            if (!await _columnExists('planner_preferences', 'show_events')) {
              await migrator.addColumn(
                plannerPreferences,
                plannerPreferences.showEvents,
              );
            }
            if (!await _columnExists(
              'planner_preferences',
              'show_backup_events',
            )) {
              await migrator.addColumn(
                plannerPreferences,
                plannerPreferences.showBackupEvents,
              );
            }
            if (!await _columnExists('planner_preferences', 'show_tasks')) {
              await migrator.addColumn(
                plannerPreferences,
                plannerPreferences.showTasks,
              );
            }
            if (!await _columnExists(
              'planner_preferences',
              'show_completed_tasks',
            )) {
              await migrator.addColumn(
                plannerPreferences,
                plannerPreferences.showCompletedTasks,
              );
            }
            if (!await _columnExists(
              'planner_preferences',
              'timeline_hour_height',
            )) {
              await migrator.addColumn(
                plannerPreferences,
                plannerPreferences.timelineHourHeight,
              );
            }
            if (_injectPlannerExperienceMigrationFailure) {
              throw StateError('Injected Planner experience migration failure');
            }
          }
          if (from < 11 && to >= 11) {
            if (!await _columnExists(
              'planner_preferences',
              'event_color_preferences_json',
            )) {
              await migrator.addColumn(
                plannerPreferences,
                plannerPreferences.eventColorPreferencesJson,
              );
            }
          }
          if (from < 12 && to >= 12) {
            if (!await _columnExists('planner_tasks', 'due_minute')) {
              await migrator.addColumn(plannerTasks, plannerTasks.dueMinute);
            }
            if (!await _columnExists('planner_tasks', 'recurrence_frequency')) {
              await migrator.addColumn(
                plannerTasks,
                plannerTasks.recurrenceFrequency,
              );
            }
          }
          if (from < 13 && to >= 13) {
            if (!await _columnExists('planner_tasks', 'people_json')) {
              await migrator.addColumn(plannerTasks, plannerTasks.peopleJson);
            }
          }
          if (from < 14 && to >= 14) {
            await migrator.createTable(indicatorGoalRevisions);
          }
          if (from < 15 && to >= 15) {
            // Promote legacy weekly revisions into the canonical goal table.
            // IDs and operation IDs are retained so idempotency and revision
            // chains survive the migration without creating a second write.
            await customStatement('''
              INSERT OR IGNORE INTO indicator_goal_revisions
                (id, profile_id, indicator_key, period_type,
                 period_start_date, period_end_date, state, value_scaled,
                 value_scale, unit, supersedes_revision_id, operation_id,
                 created_at_utc)
              SELECT id, profile_id, indicator_key, 'weekly',
                     period_start_date,
                     date(period_start_date, '+6 days'),
                     state, value_scaled, value_scale, unit,
                     supersedes_revision_id, operation_id, created_at_utc
              FROM weekly_indicator_target_revisions
            ''');
          }
          if (from < 16 && to >= 16) {
            // Prompt A removes the legacy Commitment feature.  These tables
            // contain only links/review/carryover metadata; the canonical
            // Event, Task, report, ledger, and goal tables remain untouched.
            for (final tableName in <String>[
              'indicator_commitment_links',
              'weekly_plan_commitments',
              'weekly_plan_review_indicator_snapshots',
              'weekly_plan_reviews',
              'weekly_plan_task_carryover_decisions',
            ]) {
              await customStatement('DROP TABLE IF EXISTS $tableName');
            }
          }
          if (from < 17 && to >= 17) {
            await migrator.createTable(goals);
            await migrator.createTable(goalActivities);
            await migrator.createTable(goalOutboxOperations);
            if (!await _columnExists(
              'weekly_indicator_target_revisions',
              'goal_id',
            )) {
              await migrator.addColumn(
                weeklyIndicatorTargetRevisions,
                weeklyIndicatorTargetRevisions.goalId,
              );
            }
            if (!await _columnExists('indicator_goal_revisions', 'goal_id')) {
              await migrator.addColumn(
                indicatorGoalRevisions,
                indicatorGoalRevisions.goalId,
              );
            }

            // The six seeded WLI definitions are the only pre-canonical Goal
            // records.  Their IDs are deterministic, so reopening a partially
            // migrated database cannot create duplicate Goals.
            await customStatement('''
              INSERT OR IGNORE INTO goals
                (id, profile_id, indicator_key, role, active_slot_index,
                 title, icon_id, status, created_at_utc, updated_at_utc,
                 archived_at_utc)
              SELECT profile_id || ':goal:' || (position + 1),
                     profile_id,
                     indicator_key,
                     CASE position
                       WHEN 0 THEN 'dailyWeekly'
                       WHEN 5 THEN 'weeklyMonthly'
                       ELSE 'weekly'
                     END,
                     position + 1,
                     CASE
                       WHEN position = 3 AND label = 'Meaningful Connections'
                         THEN 'Ministering Visit'
                       ELSE label
                     END,
                     NULL,
                     'active',
                     created_at_utc,
                     created_at_utc,
                     NULL
                FROM life_indicator_definitions
            ''');
            await customStatement('''
              UPDATE life_indicator_definitions
                 SET label = 'Ministering Visit'
               WHERE indicator_key = 'meaningful_connections'
                 AND position = 3
                 AND label = 'Meaningful Connections'
            ''');
            await customStatement('''
              UPDATE indicator_goal_revisions
                 SET goal_id = (
                   SELECT g.id
                     FROM goals g
                    WHERE g.profile_id = indicator_goal_revisions.profile_id
                      AND g.indicator_key = indicator_goal_revisions.indicator_key
                    LIMIT 1
                 )
               WHERE goal_id IS NULL
            ''');
            await customStatement('''
              UPDATE weekly_indicator_target_revisions
                 SET goal_id = (
                   SELECT g.id
                     FROM goals g
                    WHERE g.profile_id = weekly_indicator_target_revisions.profile_id
                      AND g.indicator_key = weekly_indicator_target_revisions.indicator_key
                    LIMIT 1
                 )
              WHERE goal_id IS NULL
            ''');
            await customStatement('''
              INSERT OR IGNORE INTO goal_activities
                (id, profile_id, goal_id, operation_id, action,
                 previous_value, new_value, occurred_at_utc)
              SELECT profile_id || ':goal:' || (position + 1) || ':created',
                     profile_id,
                     profile_id || ':goal:' || (position + 1),
                     profile_id || ':goal:' || (position + 1) || ':created',
                     'created',
                     NULL,
                     CASE
                       WHEN position = 3 AND label = 'Meaningful Connections'
                         THEN 'Ministering Visit'
                       ELSE label
                     END,
                     created_at_utc
                FROM life_indicator_definitions
            ''');
            await customStatement('''
            INSERT OR IGNORE INTO goal_outbox_operations
                (operation_id, profile_id, entity_type, entity_id, action,
                 payload_json, created_at_utc)
              SELECT profile_id || ':goal:' || (position + 1) || ':created',
                     profile_id,
                     'goal',
                     profile_id || ':goal:' || (position + 1),
                     'created',
                     json_object(
                       'goalId', profile_id || ':goal:' || (position + 1),
                       'role', CASE
                         WHEN position = 0 THEN 'dailyWeekly'
                         WHEN position = 5 THEN 'weeklyMonthly'
                         ELSE 'weekly'
                       END,
                       'slot', position + 1,
                       'title', CASE
                         WHEN position = 3 AND label = 'Meaningful Connections'
                           THEN 'Ministering Visit'
                         ELSE label
                       END,
                       'iconId', NULL
                     ),
                     created_at_utc
                FROM life_indicator_definitions
            ''');
          }
          if (from < 18 && to >= 18) {
            if (!await _columnExists(
              'calendar_events',
              'activity_type_stable_key_snapshot',
            )) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.activityTypeStableKeySnapshot,
              );
            }
            if (!await _columnExists(
              'calendar_events',
              'activity_type_label_snapshot',
            )) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.activityTypeLabelSnapshot,
              );
            }
            if (!await _columnExists(
              'calendar_events',
              'activity_type_color_value_snapshot',
            )) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.activityTypeColorValueSnapshot,
              );
            }
            if (!await _columnExists(
              'calendar_event_exceptions',
              'activity_type_stable_key_snapshot',
            )) {
              await migrator.addColumn(
                calendarEventExceptions,
                calendarEventExceptions.activityTypeStableKeySnapshot,
              );
            }
            if (!await _columnExists(
              'calendar_event_exceptions',
              'activity_type_label_snapshot',
            )) {
              await migrator.addColumn(
                calendarEventExceptions,
                calendarEventExceptions.activityTypeLabelSnapshot,
              );
            }
            if (!await _columnExists(
              'calendar_event_exceptions',
              'activity_type_color_value_snapshot',
            )) {
              await migrator.addColumn(
                calendarEventExceptions,
                calendarEventExceptions.activityTypeColorValueSnapshot,
              );
            }

            // Events created before snapshot support are frozen to the
            // current canonical Event Type metadata once, so later renames
            // cannot rewrite their historical labels or colors.
            await customStatement('''
              UPDATE calendar_events
                 SET activity_type_stable_key_snapshot = (
                       SELECT stable_key
                         FROM activity_types
                        WHERE activity_types.profile_id = calendar_events.profile_id
                          AND activity_types.id = calendar_events.activity_type_id
                     ),
                     activity_type_label_snapshot = (
                       SELECT label
                         FROM activity_types
                        WHERE activity_types.profile_id = calendar_events.profile_id
                          AND activity_types.id = calendar_events.activity_type_id
                     ),
                     activity_type_color_value_snapshot = (
                       SELECT color_value
                         FROM activity_types
                        WHERE activity_types.profile_id = calendar_events.profile_id
                          AND activity_types.id = calendar_events.activity_type_id
                     )
               WHERE activity_type_id IS NOT NULL
            ''');
            await customStatement('''
              UPDATE calendar_event_exceptions
                 SET activity_type_stable_key_snapshot = (
                       SELECT stable_key
                         FROM activity_types
                        WHERE activity_types.profile_id = calendar_event_exceptions.profile_id
                          AND activity_types.id = calendar_event_exceptions.activity_type_id
                     ),
                     activity_type_label_snapshot = (
                       SELECT label
                         FROM activity_types
                        WHERE activity_types.profile_id = calendar_event_exceptions.profile_id
                          AND activity_types.id = calendar_event_exceptions.activity_type_id
                     ),
                     activity_type_color_value_snapshot = (
                       SELECT color_value
                         FROM activity_types
                        WHERE activity_types.profile_id = calendar_event_exceptions.profile_id
                          AND activity_types.id = calendar_event_exceptions.activity_type_id
                     )
               WHERE activity_type_id IS NOT NULL
            ''');
          }
          if (from < 19 && to >= 19) {
            if (!await _columnExists(
              'goals',
              'assigned_event_type_stable_key',
            )) {
              await migrator.addColumn(goals, goals.assignedEventTypeStableKey);
            }
            if (!await _columnExists(
              'planner_tasks',
              'linked_activity_type_id',
            )) {
              await migrator.addColumn(
                plannerTasks,
                plannerTasks.linkedActivityTypeId,
              );
            }
            if (!await _columnExists(
              'planner_tasks',
              'linked_activity_type_stable_key',
            )) {
              await migrator.addColumn(
                plannerTasks,
                plannerTasks.linkedActivityTypeStableKey,
              );
            }
            if (!await _columnExists(
              'planner_tasks',
              'linked_activity_type_label_snapshot',
            )) {
              await migrator.addColumn(
                plannerTasks,
                plannerTasks.linkedActivityTypeLabelSnapshot,
              );
            }
            if (!await _columnExists(
              'task_status_changes',
              'activity_type_id',
            )) {
              await migrator.addColumn(
                taskStatusChanges,
                taskStatusChanges.activityTypeId,
              );
            }
            if (!await _columnExists(
              'task_status_changes',
              'activity_type_stable_key_snapshot',
            )) {
              await migrator.addColumn(
                taskStatusChanges,
                taskStatusChanges.activityTypeStableKeySnapshot,
              );
            }
            if (!await _columnExists(
              'task_status_changes',
              'activity_type_label_snapshot',
            )) {
              await migrator.addColumn(
                taskStatusChanges,
                taskStatusChanges.activityTypeLabelSnapshot,
              );
            }
            await migrator.createTable(taskGoalContributions);
          }
          if (from < 20 && to >= 20) {
            // Pack 1A final correction: permanent user-facing Goal deletion is
            // a tombstone.  Existing active/archived Goals are untouched and no
            // historical record is removed by the migration itself.
            if (!await _columnExists('goals', 'deleted_at_utc')) {
              await migrator.addColumn(goals, goals.deletedAtUtc);
            }
          }
          if (from < 21 && to >= 21) {
            // Manual per-Event Goal linking (Final Planner correction): the
            // nullable goal id rides on both the Calendar Event row and its
            // occurrence exception rows so the link survives occurrence edits.
            if (!await _columnExists('calendar_events', 'goal_id')) {
              await migrator.addColumn(calendarEvents, calendarEvents.goalId);
            }
            if (!await _columnExists('calendar_event_exceptions', 'goal_id')) {
              await migrator.addColumn(
                calendarEventExceptions,
                calendarEventExceptions.goalId,
              );
            }
          }
          if (from < 22 && to >= 22) {
            // VS-11 Contacts & Follow-Ups: all Contacts tables are brand new,
            // so the migration is purely additive and safe on every path.
            await migrator.createTable(contacts);
            await migrator.createTable(contactMethods);
            await migrator.createTable(contactGroups);
            await migrator.createTable(contactGroupMemberships);
            await migrator.createTable(contactTags);
            await migrator.createTable(contactTagMemberships);
            await migrator.createTable(contactNotes);
            await migrator.createTable(contactAvailabilities);
            await migrator.createTable(eventContactLinks);
            await migrator.createTable(eventOccurrenceParticipants);
            await migrator.createTable(taskContactLinks);
            await migrator.createTable(savedContactFilters);
            if (_injectContactsMigrationFailure) {
              throw StateError('Injected Contacts migration failure');
            }
          }
          if (from < 23 && to >= 23) {
            // Delta 4.2F Custom repeat: one nullable, versioned JSON shape is
            // the smallest additive extension that can represent intervals,
            // multi-day weeks, and nth-weekday months. Existing recurrence
            // columns and every legacy row remain untouched.
            if (!await _columnExists(
              'calendar_events',
              'recurrence_pattern_json',
            )) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.recurrencePatternJson,
              );
            }
          }
          if (from < 24 && to >= 24) {
            // Delta 4.2R R8 owner override: the default new-Event duration
            // becomes 30 minutes. Rows that still hold the previous
            // temporary Delta 4.2 default of 60 minutes are updated to 30;
            // any deliberately chosen non-60 preference (45, 75, 90, ...) is
            // preserved untouched. This is a data-only migration.
            await customStatement(
              'UPDATE planner_preferences SET default_duration_minutes = 30 '
              'WHERE default_duration_minutes = 60',
            );
          }
          if (from < 25 && to >= 25) {
            // Pack B1 Appearance foundation: a brand-new, isolated,
            // device-scoped single-row table.  Fresh v25 installs create the
            // table without a row, so the repository reads SYSTEM; an
            // existing v24 install is seeded with DARK to preserve the only
            // appearance it ever had (the pre-B1 app was dark-only).
            await migrator.createTable(appearancePreferences);
            await customStatement('''
              INSERT OR IGNORE INTO appearance_preferences
                (key, appearance_mode, updated_at_utc)
              VALUES ('primary', 'dark',
                      CAST(strftime('%s', 'now') AS INTEGER))
            ''');
          }
          if (from < 26 && to >= 26) {
            // B2-CORRECTION Theme Color: an additive, device-scoped column
            // on the existing single-row AppearancePreferences table.
            // B2-FINAL-POLISH owner lock: existing v25 rows default to
            // 'blue'; no data rewrite, no history touch.  The column-exists
            // guard keeps the step idempotent for databases whose v25 table
            // was created from a later generated schema.
            if (!await _columnExists('appearance_preferences', 'theme_color')) {
              await customStatement(
                "ALTER TABLE appearance_preferences "
                "ADD COLUMN theme_color TEXT NOT NULL DEFAULT 'blue'",
              );
            }
          }
          if (from < 27 && to >= 27) {
            // B3.2 (v27): Task direct Life Goal + Task People contact links.
            // ADDITIVE and nullable only.  NO backfill of planner_tasks.goal_id
            // or task_goal_contributions.goal_id (D5 — historical Tasks stay
            // unlinked and historical contribution identity is preserved), and
            // NO peopleJson -> Contact conversion (O1 — legacy names remain
            // historical data).  Every step is guarded so the migration is
            // idempotent for databases created from a later generated schema.
            if (!await _columnExists('planner_tasks', 'goal_id')) {
              await migrator.addColumn(plannerTasks, plannerTasks.goalId);
            }
            if (!await _columnExists('task_goal_contributions', 'goal_id')) {
              await migrator.addColumn(
                taskGoalContributions,
                taskGoalContributions.goalId,
              );
            }
            // task_contact_links already exists since v22 (VS-11 Contacts)
            // and its @TableIndex definitions now also carry the contact_id
            // lookup index for fresh installs.  Existing v22+ databases get
            // the same index here; CREATE INDEX IF NOT EXISTS is naturally
            // idempotent.  No goal-targeted contribution index is added
            // because no repository query needs one today (minimal v27).
            await customStatement(
              'CREATE INDEX IF NOT EXISTS task_contact_link_contact '
              'ON task_contact_links (contact_id)',
            );
          }
          if (from < 28 && to >= 28) {
            // MAPS V1 (v28): additive nullable explicit-coordinate columns on
            // contacts + calendar_events. NO backfill; existing rows stay
            // null; free-text locationText/addressText untouched. The pair is
            // validated by the domain value type (both-or-null); the schema
            // itself is purely additive and idempotent-guarded.
            if (!await _columnExists('calendar_events', 'latitude')) {
              await migrator.addColumn(calendarEvents, calendarEvents.latitude);
            }
            if (!await _columnExists('calendar_events', 'longitude')) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.longitude,
              );
            }
            if (!await _columnExists('calendar_events', 'coordinate_source')) {
              await migrator.addColumn(
                calendarEvents,
                calendarEvents.coordinateSource,
              );
            }
            if (!await _columnExists('contacts', 'latitude')) {
              await migrator.addColumn(contacts, contacts.latitude);
            }
            if (!await _columnExists('contacts', 'longitude')) {
              await migrator.addColumn(contacts, contacts.longitude);
            }
            if (!await _columnExists('contacts', 'coordinate_source')) {
              await migrator.addColumn(contacts, contacts.coordinateSource);
            }
          }
          if (from < 29 && to >= 29) {
            // VS-11B1 OPD-3-004 (v29): additive nullable contact_id on the
            // Activity Ledger for per-explicitly-confirmed-Contact
            // meaningful-connections contributions. NO backfill: pre-v29 rows
            // stay null and remain valid; no historical per-Contact fact is
            // invented during migration. Idempotent-guarded.
            if (!await _columnExists('activity_ledger_entries', 'contact_id')) {
              await migrator.addColumn(
                activityLedgerEntries,
                activityLedgerEntries.contactId,
              );
            }
          }
          if (from < 30 && to >= 30) {
            // VS-11C1B.3 (v30): additive planner_tasks.is_backup default
            // FALSE. Existing Tasks stay regular (no backfill); Backup is an
            // opt-in per-Task flag controlled by the Backups Planner filter.
            if (!await _columnExists('planner_tasks', 'is_backup')) {
              await migrator.addColumn(plannerTasks, plannerTasks.isBackup);
            }
          }
          if (from < 31 && to >= 31) {
            // Contacts selector V1: one nullable, additive view timestamp.
            // Legacy Contacts remain unviewed (NULL); edit/update timestamps
            // and every other Contact fact are left untouched.
            if (!await _columnExists('contacts', 'last_viewed_at_utc')) {
              // Drift's DateTime columns are stored as nullable INTEGER values
              // in this SQLite database. Keep the change explicitly additive
              // because the local generated table is already newer than the
              // accepted checkpoint.
              await customStatement(
                'ALTER TABLE contacts ADD COLUMN last_viewed_at_utc INTEGER',
              );
            }
          }
          if (from < 32 && to >= 32) {
            // C5 deep behavior: nullable per-phone capabilities. Existing
            // rows intentionally remain NULL (unknown/off in active UI); no
            // value is inferred from a social label or historical content.
            if (!await _columnExists('contact_methods', 'receives_texts')) {
              await migrator.addColumn(
                contactMethods,
                contactMethods.receivesTexts,
              );
            }
            if (!await _columnExists('contact_methods', 'has_whats_app')) {
              await migrator.addColumn(
                contactMethods,
                contactMethods.hasWhatsApp,
              );
            }
          }
          if (from < 33 && to >= 33) {
            // Post-C7: recoverable Contact deletion is an additive lifecycle
            // timestamp.  Existing active, archived, and merged Contact rows
            // intentionally remain untouched; no row or relationship is ever
            // purged by this migration.
            if (!await _columnExists('contacts', 'deleted_at_utc')) {
              await migrator.addColumn(contacts, contacts.deletedAtUtc);
            }
          }
          if (from < 34 && to >= 34) {
            await migrator.createTable(savedPlaces);
            if (_injectSavedPlaceMigrationFailure) {
              throw StateError('Injected Saved Place migration failure');
            }
          }
          if (from < 35 && to >= 35) {
            // VS-15 M3 promoted customization (v35): additive durable marker
            // identity on saved_places. Existing v34 rows keep their label and
            // coordinate exactly; they are assigned the deterministic default
            // Standard / Information / Next Transfer primary blue. No category,
            // color, or emoji is inferred from anything, and no other table is
            // reopened or rewritten. Idempotently guarded because a fresh
            // install already creates the table with these columns.
            if (!await _columnExists('saved_places', 'marker_mode')) {
              await migrator.addColumn(savedPlaces, savedPlaces.markerMode);
            }
            if (!await _columnExists('saved_places', 'standard_category')) {
              await migrator.addColumn(
                savedPlaces,
                savedPlaces.standardCategory,
              );
            }
            if (!await _columnExists('saved_places', 'custom_emoji')) {
              await migrator.addColumn(savedPlaces, savedPlaces.customEmoji);
            }
            if (!await _columnExists('saved_places', 'marker_color')) {
              await migrator.addColumn(savedPlaces, savedPlaces.markerColor);
            }
            if (_injectSavedPlaceCustomizationMigrationFailure) {
              throw StateError(
                'Injected Saved Place customization migration failure',
              );
            }
          }
          if (from < 36 && to >= 36) {
            // VS-15 M6.1 boundary foundation (v36): two additive nullable
            // columns on saved_places. Existing rows keep every persisted
            // value exactly and simply have NO boundary (null/null). No other
            // table is reopened or rewritten. Idempotently guarded because a
            // fresh install already creates the table with these columns.
            if (!await _columnExists('saved_places', 'boundary_color')) {
              await migrator.addColumn(savedPlaces, savedPlaces.boundaryColor);
            }
            if (!await _columnExists('saved_places', 'boundary_vertices')) {
              await migrator.addColumn(
                savedPlaces,
                savedPlaces.boundaryVertices,
              );
            }
          }
          if (from < 37 && to >= 37) {
            // VS-15 M6.2 Maps Preferences (v37): a brand-new, isolated,
            // device-scoped single-row table. Purely additive — no existing
            // table is reopened or rewritten, and no Saved Place/domain row
            // is touched. No row is seeded: the repository's missing-row
            // fallback provides the owner-locked defaults (Satellite + all
            // five booleans true) for both fresh and upgraded installs, and
            // the first explicit choice creates the physical row.
            await migrator.createTable(mapsPreferences);
            if (_injectMapsPreferencesMigrationFailure) {
              throw StateError('Injected Maps Preferences migration failure');
            }
          }
          if (from < 38 && to >= 38) {
            await migrator.createTable(notificationPreferences);
            await migrator.createTable(reminderPolicies);
            await migrator.createTable(backgroundWorkRequests);
            if (_injectNotificationFoundationMigrationFailure) {
              throw StateError(
                'Injected Notification Foundation migration failure',
              );
            }
          }
          // A pre-v38 upgrade creates the current table definition in the
          // preceding branch, so only a genuine existing v38 table needs the
          // additive v39 column step.
          if (from >= 38 && from < 39 && to >= 39) {
            await migrator.addColumn(
              notificationPreferences,
              notificationPreferences.systemNotificationsEnabled,
            );
          }
          if (from < 40 && to >= 40) {
            if (!await _columnExists(
              'notification_preferences',
              'snooze_duration_minutes',
            )) {
              await migrator.addColumn(
                notificationPreferences,
                notificationPreferences.snoozeDurationMinutes,
              );
            }
          }
          if (from < 41 && to >= 41) {
            // An interrupted v41 attempt can commit one SQLite ALTER before
            // the app process dies, while PRAGMA user_version remains 40.
            // Restarting must finish the additive migration, not loop on a
            // duplicate-column exception and strand Startup behind loading.
            if (!await _columnExists(
              'notification_preferences',
              'weekly_review_reminders_enabled',
            )) {
              await migrator.addColumn(
                notificationPreferences,
                notificationPreferences.weeklyReviewRemindersEnabled,
              );
            }
            if (!await _columnExists(
              'notification_preferences',
              'awaiting_report_reminders_enabled',
            )) {
              await migrator.addColumn(
                notificationPreferences,
                notificationPreferences.awaitingReportRemindersEnabled,
              );
            }
          }
          if (from < 42 && to >= 42) {
            if (!await _columnExists('goals', 'completed_at_utc')) {
              await migrator.addColumn(goals, goals.completedAtUtc);
            }
            if (!await _columnExists('goals', 'completion_method')) {
              await migrator.addColumn(goals, goals.completionMethod);
            }
            if (!await _columnExists('goals', 'completion_generation')) {
              await migrator.addColumn(goals, goals.completionGeneration);
            }
            if (!await _columnExists(
              'notification_preferences',
              'goal_completion_notifications_enabled',
            )) {
              await migrator.addColumn(
                notificationPreferences,
                notificationPreferences.goalCompletionNotificationsEnabled,
              );
            }
            if (!await _columnExists(
              'notification_preferences',
              'in_app_goal_celebrations_enabled',
            )) {
              await migrator.addColumn(
                notificationPreferences,
                notificationPreferences.inAppGoalCelebrationsEnabled,
              );
            }
            await migrator.createTable(goalAchievementEvents);
          }
          if (from < 43 && to >= 43) {
            if (!await _columnExists('goals', 'completion_armed')) {
              await migrator.addColumn(goals, goals.completionArmed);
            }
          }
          if (from < 44 && to >= 44) {
            await migrator.createTable(weeklyPlanGoalMemberships);
            // Legacy weekly plans have no historical membership evidence. The
            // repository freezes exactly the pre-migration resolved Goal set
            // on first read, rather than inventing unprovable past history.
          }
          if (from < 45 && to >= 45) {
            // M6F: v44 could be reached on an install where the membership
            // table already existed without its declared unique index. In
            // that shape, INSERT OR IGNORE did not ignore anything and every
            // Home refresh appended another copy of the same relationship.
            // Keep the earliest evidence row for each relationship, then make
            // the invariant enforceable before repository reconciliation runs.
            await customStatement('''
              DELETE FROM weekly_plan_goal_memberships
               WHERE rowid NOT IN (
                 SELECT MIN(rowid)
                   FROM weekly_plan_goal_memberships
                  GROUP BY weekly_plan_id, goal_id
               )
            ''');
            await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS '
              'weekly_plan_goal_membership_unique '
              'ON weekly_plan_goal_memberships (weekly_plan_id, goal_id)',
            );
          }
          if (from < 46 && to >= 46) {
            // The historical generated index was absent on some long-lived
            // installs. Owner-data reconciliation runs before this upgrade;
            // once the database has one current owner per slot, enforce that
            // invariant so stale forms and concurrent saves cannot recreate
            // duplicate ownership.
            await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS '
              'goal_profile_active_slot_unique '
              'ON goals (profile_id, active_slot_index)',
            );
          }
          if (from < 47 && to >= 47) {
            // VS16 M7 corrective persistence repair: additive, boolean-only.
            // The five Detailed notification content options move out of the
            // shared Planner presentation JSON document (where planner writers
            // silently dropped them) into typed columns on the EXISTING
            // notification_preferences row.
            //
            // ADDITIVE ONLY. The pre-existing row is preserved as-is: there is
            // no INSERT, no UPDATE, no DELETE and no backfill of any other
            // column, so no notification value, Event, Task, Contact, Goal,
            // Planner or Privacy content can be affected. The column defaults
            // initialise every new field to TRUE, which reproduces the exact
            // pre-options behaviour for an upgrading profile.
            //
            // The guard is the established idempotency pattern: a database that
            // already carries one of these columns (for example a v47 image
            // restored as v46) must not throw a duplicate-column exception and
            // strand Startup behind loading.
            final detailedColumns = <String, GeneratedColumn<Object>>{
              'detailed_show_title': notificationPreferences.detailedShowTitle,
              'detailed_show_description':
                  notificationPreferences.detailedShowDescription,
              'detailed_show_time': notificationPreferences.detailedShowTime,
              'detailed_show_contacts':
                  notificationPreferences.detailedShowContacts,
              'detailed_show_location':
                  notificationPreferences.detailedShowLocation,
            };
            for (final entry in detailedColumns.entries) {
              if (!await _columnExists('notification_preferences', entry.key)) {
                await migrator.addColumn(notificationPreferences, entry.value);
              }
            }
            // No explicit UPDATE: ADD COLUMN with a DEFAULT gives every
            // existing row the default (TRUE) without a second write, and a
            // profile with no notification_preferences row stays absent until
            // the app first saves — exactly as before.
          }
          if (from < 48 && to >= 48) {
            // v48 — the DETAILED CONTENT MASTER. Additive and boolean-only,
            // exactly like the v47 repair: one typed column on the EXISTING
            // notification_preferences row, no INSERT/UPDATE/DELETE, no
            // backfill of any other column, so no Event, Task, Contact, Goal,
            // Planner, Privacy or other notification value can be affected.
            //
            // The default is TRUE, so an upgrading profile keeps precisely the
            // behaviour it had: detail was permitted before this column existed
            // and remains permitted.  Existing per-field choices are untouched,
            // which is the whole reason the master is its own column.
            //
            // Same idempotency guard as v47: a database that already carries
            // the column (for example a v48 image restored as v47) must not
            // throw a duplicate-column exception and strand Startup loading.
            if (!await _columnExists(
              'notification_preferences',
              'detailed_content_enabled',
            )) {
              await migrator.addColumn(
                notificationPreferences,
                notificationPreferences.detailedContentEnabled,
              );
            }
          }
        });
      },
      beforeOpen: (details) async {
        await customStatement('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<bool> _columnExists(String tableName, String columnName) async {
    final rows = await customSelect('PRAGMA table_info($tableName)').get();
    return rows.any((row) => row.read<String>('name') == columnName);
  }
}
