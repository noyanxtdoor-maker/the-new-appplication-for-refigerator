enum ReminderSourceKind { calendarEvent, task, weeklyReview, awaitingReport }

enum ReminderPurpose { standard, contactFollowUp }

enum ReminderPolicyMode { inherit, off, offset }

final class ReminderPolicy {
  const ReminderPolicy({
    required this.id,
    required this.profileId,
    required this.sourceKind,
    required this.sourceId,
    required this.occurrenceId,
    required this.mode,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.purpose = ReminderPurpose.standard,
    this.contactId,
    this.offsetMinutes,
  });

  static const String seriesOccurrenceId = 'series';

  final String id;
  final String profileId;
  final ReminderSourceKind sourceKind;
  final String sourceId;
  final String occurrenceId;
  final ReminderPurpose purpose;
  final String? contactId;
  final ReminderPolicyMode mode;
  final int? offsetMinutes;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  void validate() {
    if (id.trim().isEmpty ||
        profileId.trim().isEmpty ||
        sourceId.trim().isEmpty ||
        occurrenceId.trim().isEmpty) {
      throw ArgumentError('Reminder policy identity must not be blank.');
    }
    if (mode == ReminderPolicyMode.offset) {
      if (offsetMinutes == null || offsetMinutes! < 0) {
        throw ArgumentError('Offset policy requires a non-negative duration.');
      }
    } else if (offsetMinutes != null) {
      throw ArgumentError('Only offset policy may store offset minutes.');
    }
    if (purpose == ReminderPurpose.contactFollowUp &&
        (contactId == null || contactId!.trim().isEmpty)) {
      throw ArgumentError(
        'Contact follow-up purpose requires Contact identity.',
      );
    }
    if (purpose == ReminderPurpose.standard && contactId != null) {
      throw ArgumentError('Standard reminders do not store Contact identity.');
    }
  }

  /// Astra M7 update law (§9): purpose/contactId changes must be explicit.
  /// The default [copyWith] preserves both. [withPurpose] builds an explicit
  /// set/clear variant so null-ambiguity can never make clearing impossible.
  ReminderPolicy copyWith({
    ReminderPolicyMode? mode,
    int? offsetMinutes,
    bool clearOffset = false,
    DateTime? updatedAtUtc,
  }) => ReminderPolicy(
    id: id,
    profileId: profileId,
    sourceKind: sourceKind,
    sourceId: sourceId,
    occurrenceId: occurrenceId,
    purpose: purpose,
    contactId: contactId,
    mode: mode ?? this.mode,
    offsetMinutes: clearOffset ? null : offsetMinutes ?? this.offsetMinutes,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );

  /// Explicit purpose replacement.  [contactId] is required for
  /// [ReminderPurpose.contactFollowUp] and forbidden for standard.
  ReminderPolicy withPurpose({
    required ReminderPurpose purpose,
    String? contactId,
    DateTime? updatedAtUtc,
  }) => ReminderPolicy(
    id: id,
    profileId: profileId,
    sourceKind: sourceKind,
    sourceId: sourceId,
    occurrenceId: occurrenceId,
    purpose: purpose,
    contactId: purpose == ReminderPurpose.contactFollowUp ? contactId : null,
    mode: mode,
    offsetMinutes: offsetMinutes,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );

  /// Explicit standard clearing: purpose standard and contactId null.
  ReminderPolicy clearPurpose({DateTime? updatedAtUtc}) =>
      withPurpose(
        purpose: ReminderPurpose.standard,
        updatedAtUtc: updatedAtUtc,
      );
}
