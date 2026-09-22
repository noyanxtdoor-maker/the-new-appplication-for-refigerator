/// P2-A (owner decision 2026-09-21, design D1) — the INDEPENDENT Event contact
/// channel, i.e. the user-facing "Contact Type".
///
/// This is deliberately NOT the Event Type. The Event Type is a taxonomy
/// (`SystemEventTypeKeys` / `activity_types`) with its own picker, mappings and
/// snapshot columns; this enum answers a different question: how did the contact
/// actually happen for this Event?
///
/// Owner-fixed law for this list:
///   - exactly these eight choices, no more and no fewer;
///   - persisted as a STABLE KEY, never as a display label, so renaming a label
///     can never corrupt stored data (the same discipline the Event Type
///     snapshots already use);
///   - never derived from the Event Type, never stored in notes/JSON, and never
///     written into a Contact address/preference enum such as
///     `ContactMethodType`.
library;

enum EventContactChannel {
  inPerson('in_person', 'In Person'),
  phoneCall('phone_call', 'Phone Call'),
  text('text', 'Text'),
  email('email', 'Email'),
  whatsApp('whatsapp', 'WhatsApp'),
  socialMedia('social_media', 'Social Media'),
  videoCall('video_call', 'Video Call'),
  other('other', 'Other');

  const EventContactChannel(this.stableKey, this.label);

  /// The persisted value. Stable forever; the product law pins these exact keys.
  final String stableKey;

  /// The human-visible label shown in the Event form and detail surfaces.
  final String label;

  /// Resolves a stored value to a channel, or `null` when it is absent or not a
  /// recognised key.
  ///
  /// Returning `null` for an unrecognised value is deliberate and is the only
  /// honest outcome: an unknown or corrupt stored key must read back as "not
  /// set" rather than silently becoming a channel the user never chose. Callers
  /// therefore render an explicit unset state for `null`.
  static EventContactChannel? fromStableKey(String? stableKey) {
    final normalized = stableKey?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    for (final channel in EventContactChannel.values) {
      if (channel.stableKey == normalized) {
        return channel;
      }
    }
    return null;
  }
}
