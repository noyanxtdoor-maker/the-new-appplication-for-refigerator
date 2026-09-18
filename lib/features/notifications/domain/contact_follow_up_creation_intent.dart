/// VS16 M7 explicit Contact follow-up creation provenance.
///
/// The ONLY producer is the existing Contact Detail "Create Follow-Up"
/// chooser.  It is ephemeral route metadata (GoRouter extra) and is never
/// serialized to durable storage or to a notification payload.  Forms treat an
/// unknown/malformed extra as ordinary creation, so this class stays a plain
/// typed value with equality.
final class ContactFollowUpCreationIntent {
  const ContactFollowUpCreationIntent(this.contactId);

  final String contactId;

  bool get isValid => contactId.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ContactFollowUpCreationIntent && other.contactId == contactId;

  @override
  int get hashCode => contactId.hashCode;

  @override
  String toString() => 'ContactFollowUpCreationIntent($contactId)';
}
