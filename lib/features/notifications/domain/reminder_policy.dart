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

  /// Explicit purpose/contact mutation law (VS16 M7).
  ///
  /// Nullable fields alone cannot express "clear": [purpose] and [contactId]
  /// omitted means preserve, [clearPurpose] forces standard/null, and
  /// [clearContact] clears only the Contact identity while keeping the purpose
  /// the caller sets (which must then be standard).  Timing writes that pass
  /// neither argument therefore never erase provenance accidentally.
  ReminderPolicy copyWith({
    ReminderPolicyMode? mode,
    int? offsetMinutes,
    bool clearOffset = false,
    DateTime? updatedAtUtc,
    ReminderPurpose? purpose,
    String? contactId,
    bool clearPurpose = false,
    bool clearContact = false,
  }) {
    final nextPurpose = clearPurpose
        ? ReminderPurpose.standard
        : purpose ?? this.purpose;
    final nextContactId = clearPurpose || clearContact
        ? null
        : contactId ?? this.contactId;
    final policy = ReminderPolicy(
      id: id,
      profileId: profileId,
      sourceKind: sourceKind,
      sourceId: sourceId,
      occurrenceId: occurrenceId,
      purpose: nextPurpose,
      contactId: nextContactId,
      mode: mode ?? this.mode,
      offsetMinutes: clearOffset ? null : offsetMinutes ?? this.offsetMinutes,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    );
    policy.validate();
    return policy;
  }
}
