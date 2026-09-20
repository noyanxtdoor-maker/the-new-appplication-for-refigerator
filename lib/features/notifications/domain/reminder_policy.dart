enum ReminderSourceKind { calendarEvent, task, weeklyReview, awaitingReport }

/// The stable-key family prefix owned by one reminder source kind.
///
/// Forensic finding F03: `weeklyReview` and `awaitingReport` both persist
/// `ownerKind = planning`, so a profile + category + owner-kind filter cannot
/// tell the two planning families apart.  A cleanup pass for one family could
/// therefore retrieve the other family's durable rows and rebuild a
/// cancellation under the WRONG family key from a shared occurrence token.
///
/// Durable-work queries and cancellations consequently also match this prefix.
/// This is the single derivation; no caller re-spells the literal.
extension ReminderSourceKindFamily on ReminderSourceKind {
  String get stableKeyFamilyPrefix => switch (this) {
    ReminderSourceKind.weeklyReview => 'planning:weekly-review:',
    ReminderSourceKind.awaitingReport => 'planning:awaiting-report:',
    ReminderSourceKind.calendarEvent => 'reminder:calendarEvent:',
    ReminderSourceKind.task => 'reminder:task:',
  };

  bool ownsStableKey(String stableKey) =>
      stableKey.startsWith(stableKeyFamilyPrefix);
}

/// The ONE reminder-policy resolution law.
///
/// OWNER HOTFIX (2026-09-19). `ReminderReconciler` has always resolved an
/// occurrence's policy as "this occurrence's own row, else the series row". The
/// Event form did NOT: it matched the occurrence key alone, so a reminder stored at
/// series scope — which is what the create path and an "All events" edit write —
/// was invisible and the row rendered the global default instead of the user's own
/// choice. Reading the policy through this single extension keeps every caller on
/// the same law.
///
/// Callers still apply the global default themselves when this returns null, or
/// when the resolved policy's mode is [ReminderPolicyMode.inherit].
extension ReminderPolicyResolution on Iterable<ReminderPolicy> {
  ReminderPolicy? resolveForOccurrence(String occurrenceId) {
    for (final policy in this) {
      if (policy.occurrenceId == occurrenceId) return policy;
    }
    for (final policy in this) {
      if (policy.occurrenceId == ReminderPolicy.seriesOccurrenceId) {
        return policy;
      }
    }
    return null;
  }
}

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

  /// Sentinel used by purpose-update APIs to distinguish "argument omitted"
  /// from "explicitly set to null".
  static const Object unsetContactId = Object();

  /// Purpose/Contact law (contract section 9): an omitted [purpose] preserves
  /// the current value; an explicit [ReminderPurpose.standard] clears
  /// [contactId]; [ReminderPurpose.contactFollowUp] sets the supplied Contact,
  /// or keeps the existing one when [contactId] is omitted.  [clearPurpose] is
  /// an explicit escape hatch so null-ambiguity can never make clearing
  /// impossible.
  ReminderPolicy copyWith({
    ReminderPolicyMode? mode,
    int? offsetMinutes,
    bool clearOffset = false,
    DateTime? updatedAtUtc,
    ReminderPurpose? purpose,
    Object? contactId = unsetContactId,
    bool clearPurpose = false,
  }) {
    final resolvedPurpose = clearPurpose
        ? ReminderPurpose.standard
        : (purpose ?? this.purpose);
    final resolvedContactId = switch (resolvedPurpose) {
      ReminderPurpose.standard => null,
      ReminderPurpose.contactFollowUp =>
        identical(contactId, unsetContactId)
            ? this.contactId
            : contactId as String?,
    };
    return ReminderPolicy(
      id: id,
      profileId: profileId,
      sourceKind: sourceKind,
      sourceId: sourceId,
      occurrenceId: occurrenceId,
      purpose: resolvedPurpose,
      contactId: resolvedContactId,
      mode: mode ?? this.mode,
      offsetMinutes: clearOffset ? null : offsetMinutes ?? this.offsetMinutes,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    );
  }
}
