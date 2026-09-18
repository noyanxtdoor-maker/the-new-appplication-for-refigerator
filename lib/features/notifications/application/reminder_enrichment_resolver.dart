import 'package:characters/characters.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

/// Astra §15/P18: narrow read-only data port for enrichment validation.  The
/// implementation (P19) reads ONLY current Contact identity/profile/lifecycle
/// and effective LIVE links — never readTimeline, readContactDetail, or
/// readEventPeople's historical fallback.
abstract interface class ReminderEnrichmentSource {
  /// Current validated Contact identity for [contactId] or null when the row
  /// is missing, belongs to another profile, or is not active (archived /
  /// recentlyDeleted / merged).  Returns the row even when blank-named so the
  /// caller can distinguish 'omit line' from 'suppress'.
  Future<EnrichmentContactIdentity?> readActiveContact({
    required String profileId,
    required String contactId,
  });

  /// Effective LIVE link check (Astra §15): active series links plus exact
  /// active/removed occurrence overlay, no historical snapshot fallback.
  /// Must verify BOTH endpoints (source exists, Contact linked).
  Future<bool> hasLiveEventLink({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required String contactId,
  });

  /// Task link lookup explicitly filtered by profile and taskId, verifying
  /// both endpoints.
  Future<bool> hasLiveTaskLink({
    required String profileId,
    required String taskId,
    required String contactId,
  });

  /// Current canonical occurrence locationText (override-aware through the
  /// canonical Event repository).  Null when the source/occurrence is absent
  /// or the text is blank.
  Future<String?> readEventLocationText({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  });
}

/// Validated current Contact identity (current truth only; no snapshots).
final class EnrichmentContactIdentity {
  const EnrichmentContactIdentity({
    required this.contactId,
    required this.displayName,
    required this.updatedAtUtc,
  });

  final String contactId;
  final String displayName;
  final DateTime updatedAtUtc;
}

/// Enrichment output for the delivery renderer: null lines mean omit.
final class ReminderEnrichment {
  const ReminderEnrichment({this.followUpDisplayName, this.locationText});

  final String? followUpDisplayName;
  final String? locationText;
}

/// Astra §15 validation + sanitization.  Pure function over validated
/// inputs; no repository access, no global rewriting of owner source text.
final class ReminderEnrichmentResolver {
  const ReminderEnrichmentResolver({required this.source});

  final ReminderEnrichmentSource source;

  static const int maxNameClusters = 80;
  static const int maxLocationClusters = 120;

  /// Validates the selected Contact for a follow-up purpose and returns the
  /// sanitized current display name, or null when enrichment must be omitted
  /// (unlinked / inactive / missing / blank name / read failure handled by
  /// caller).  Never throws for absent data: absence means omit.
  Future<ReminderEnrichment> resolve({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required String? contactId,
  }) async {
    final contact = contactId == null || contactId.trim().isEmpty
        ? null
        : await _guard(() => source.readActiveContact(
              profileId: profileId,
              contactId: contactId,
            ));
    if (contact == null) {
      return const ReminderEnrichment();
    }
    final bool linked = contactId == null
        ? false
        : switch (sourceKind) {
            ReminderSourceKind.calendarEvent =>
              (await _guard(() => source.hasLiveEventLink(
                    profileId: profileId,
                    eventId: sourceId,
                    occurrenceId: occurrenceId,
                    contactId: contactId,
                  ))) ??
                  false,
            ReminderSourceKind.task =>
              (await _guard(() => source.hasLiveTaskLink(
                    profileId: profileId,
                    taskId: sourceId,
                    contactId: contactId,
                  ))) ??
                  false,
            _ => false,
          };
    if (!linked) {
      return const ReminderEnrichment();
    }
    final name = sanitizeLine(contact.displayName, maxNameClusters);
    String? location;
    if (sourceKind == ReminderSourceKind.calendarEvent) {
      final rawLocation = await _guard(() => source.readEventLocationText(
            profileId: profileId,
            eventId: sourceId,
            occurrenceId: occurrenceId,
          ));
      location = sanitizeLocation(rawLocation);
    }
    return ReminderEnrichment(
      followUpDisplayName: name == null || name.isEmpty ? null : name,
      locationText: location,
    );
  }

  /// §15 line sanitizer: trim, collapse CR/LF/whitespace to one space, strip
  /// control/bidi characters, limit to [maxClusters] grapheme clusters with
  /// ellipsis.  Blank input yields null.
  static String? sanitizeLine(String? raw, int maxClusters) {
    if (raw == null) return null;
    final flattened = raw.replaceAll(_bidiOrControl, ' ').trim();
    if (flattened.isEmpty) return null;
    final collapsed = flattened.replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isEmpty) return null;
    final clusters = collapsed.characters.toList(growable: false);
    if (clusters.length <= maxClusters) {
      return collapsed;
    }
    final kept = clusters.take(maxClusters).join();
    return '$kept…';
  }

  /// §15 location law: rejects URI/scheme strings, coordinate-shaped decimal
  /// lat/lon pairs and degree-symbol coordinate forms; normal address text
  /// (digits included) is preserved.  Uncertain classification omits the line.
  static String? sanitizeLocation(String? raw) {
    final line = sanitizeLine(raw, maxLocationClusters);
    if (line == null) return null;
    final lowered = line.toLowerCase();
    if (RegExp(r'^[a-z][a-z0-9+.\-]*:').hasMatch(lowered)) {
      return null;
    }
    if (lowered.contains('google.navigation') || lowered.contains('geo:')) {
      return null;
    }
    final coordinatePair = RegExp(
      r'^\s*-?\d{1,3}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?\s*$',
    );
    if (coordinatePair.hasMatch(line)) {
      return null;
    }
    final degreeForm = RegExp(
      r'^\s*-?\d{1,3}(\.\d+)?\s*°\s*[NS]?[, ]\s*-?\d{1,3}(\.\d+)?\s*°?\s*[EW]?\s*$',
    );
    if (degreeForm.hasMatch(line)) {
      return null;
    }
    return line;
  }

  static final RegExp _bidiOrControl = RegExp(
    r'[\u0000-\u001F\u007F-\u009F\u200E\u200F\u202A-\u202E\u2066-\u2069]',
  );

  /// §15: no data repair from a read — read failure degrades to omitted
  /// enrichment, never an exception that suppresses the reminder.
  static Future<T?> _guard<T>(Future<T> Function() read) async {
    try {
      return await read();
    } on Object {
      return null;
    }
  }
}
