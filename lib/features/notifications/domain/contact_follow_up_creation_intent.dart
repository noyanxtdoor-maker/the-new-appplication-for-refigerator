/// VS16-M7 — typed, ephemeral provenance for an explicit Contact follow-up
/// creation.
///
/// Contract section 8 / P3: the only M7 entry action is
/// `ContactDetailScreen._createFollowUp`, which forwards this immutable intent
/// through the existing Event/Task create routes in `GoRouter` `extra`.
///
/// The intent is deliberately NOT serializable to durable storage: it carries
/// no timing, no reminder policy and no persistence identity.  Reminder intent
/// becomes durable only through the explicit source-level policy write that the
/// form performs after its canonical source + People commits (section 8).
final class ContactFollowUpCreationIntent {
  const ContactFollowUpCreationIntent({required this.contactId});

  /// The ONE explicitly selected stable Contact id.  Never a display name.
  final String contactId;

  /// A malformed/blank intent is not a valid provenance object; callers fail
  /// closed to ordinary creation rather than crashing (section 8).
  bool get isValid => contactId.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ContactFollowUpCreationIntent && other.contactId == contactId;

  @override
  int get hashCode => contactId.hashCode;

  @override
  String toString() => 'ContactFollowUpCreationIntent(contactId: $contactId)';
}
