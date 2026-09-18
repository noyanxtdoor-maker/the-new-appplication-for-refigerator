/// Astra §8/P3: typed, ephemeral provenance for M7 Contact follow-up creation.
/// Only ContactDetailScreen._createFollowUp constructs it; it travels in the
/// GoRouter `extra` for the existing Event/Task create routes and is never
/// serialized to durable storage.
final class ContactFollowUpCreationIntent {
  const ContactFollowUpCreationIntent({required this.contactId});

  /// The ONE explicitly selected stable Contact ID (§7).
  final String contactId;

  @override
  bool operator ==(Object other) =>
      other is ContactFollowUpCreationIntent && other.contactId == contactId;

  @override
  int get hashCode => contactId.hashCode;
}
