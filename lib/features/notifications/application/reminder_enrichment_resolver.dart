import 'package:characters/characters.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

/// VS16-M7 P18 — enrichment sanitization (contract section 15).
///
/// Sanitizes the ONLY two pieces of M7 enrichment text that may ever reach a
/// notification body: the current Contact display name and the current Event
/// location text.
///
/// Rules:
/// - trim, collapse CR/LF/whitespace runs to a single space, and strip Unicode
///   bidi controls and other control characters;
/// - blank becomes absent (null);
/// - names are limited to 80 Unicode grapheme clusters, locations to 120,
///   truncated with an ellipsis inside the limit;
/// - a location that looks like a URI/scheme string or a coordinate pair is
///   rejected outright (omit the line) rather than guessed at.
///
/// This is enrichment sanitization only — it never rewrites owner source text.
abstract final class ReminderEnrichmentSanitizer {
  static const int maxNameGraphemes = 80;
  static const int maxLocationGraphemes = 120;

  /// C0/C1 controls plus DEL.
  static final RegExp _control = RegExp(r'[\u0000-\u001F\u007F-\u009F]');

  /// Bidi/format controls that can visually reorder rendered text.
  static final RegExp _bidiControls = RegExp(
    r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]',
  );

  static final RegExp _whitespaceRun = RegExp(r'\s+');

  /// `scheme:` prefixes such as `https:`, `geo:`, `google.navigation:`.
  static final RegExp _uriScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:');

  /// A bare decimal lat/lon pair, e.g. `14.5995, 120.9842`.
  static final RegExp _decimalPair = RegExp(
    r'^-?\d{1,3}(?:\.\d+)?\s*,\s*-?\d{1,3}(?:\.\d+)?$',
  );

  /// Degree-symbol coordinate forms, e.g. `14.5995° N`.
  static final RegExp _degreeCoordinate = RegExp(
    r'^\s*-?\d{1,3}(?:\.\d+)?\s*°',
  );

  /// Map/geo URL fragments.
  static final RegExp _geoFragment = RegExp(
    r'geo:|google\.navigation:|maps\.google\.|goo\.gl/maps',
    caseSensitive: false,
  );

  /// Sanitized Contact display name, or null when unusable.
  static String? sanitizeName(String? raw) => _sanitize(raw, maxNameGraphemes);

  /// Sanitized Event location, or null when blank or coordinate/URI-shaped.
  static String? sanitizeLocation(String? raw) {
    final value = _sanitize(raw, maxLocationGraphemes);
    if (value == null) return null;
    // Classification is deliberately conservative: if it looks like a
    // coordinate or a link, omit the line instead of printing it.
    if (_uriScheme.hasMatch(value) ||
        _decimalPair.hasMatch(value) ||
        _degreeCoordinate.hasMatch(value) ||
        _geoFragment.hasMatch(value)) {
      return null;
    }
    return value;
  }

  static String? _sanitize(String? raw, int maxGraphemes) {
    if (raw == null) return null;
    final cleaned = raw
        .replaceAll(_bidiControls, '')
        .replaceAll(_control, ' ')
        .replaceAll(_whitespaceRun, ' ')
        .trim();
    if (cleaned.isEmpty) return null;
    final graphemes = cleaned.characters;
    if (graphemes.length <= maxGraphemes) return cleaned;
    return '${graphemes.take(maxGraphemes - 1)}…';
  }
}

/// Narrow, read-only data port for current Contact enrichment
/// (contract section 15).
///
/// Implementations MUST read only the CURRENT Contact identity and the
/// EFFECTIVE LIVE link for the requested source/occurrence.  Historical
/// snapshots (`readTimeline`, `readContactDetail`, occurrence-participant
/// history) are explicitly forbidden: a read must never resurrect a stale name
/// and must never repair data.
abstract interface class ReminderEnrichmentSource {
  /// Current display name for [contactId], or null when the Contact is
  /// missing, inactive, in another profile, not currently linked to the source,
  /// or the read fails.
  Future<String?> currentContactDisplayName({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required String contactId,
  });
}

/// Application service that resolves and sanitizes M7 enrichment.
///
/// Any failure path yields "no enrichment" so the caller falls back to the
/// normal current source copy; enrichment never suppresses a reminder.
final class ReminderEnrichmentResolver {
  const ReminderEnrichmentResolver(this.source);

  final ReminderEnrichmentSource source;

  /// Sanitized current Contact name for the follow-up line, or null to omit it.
  Future<String?> followUpName({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required String contactId,
  }) async {
    if (contactId.trim().isEmpty) return null;
    try {
      final raw = await source.currentContactDisplayName(
        profileId: profileId,
        sourceKind: sourceKind,
        sourceId: sourceId,
        occurrenceId: occurrenceId,
        contactId: contactId,
      );
      return ReminderEnrichmentSanitizer.sanitizeName(raw);
    } on Object {
      // Read failure means no enrichment, never a cached or stale value.
      return null;
    }
  }
}
