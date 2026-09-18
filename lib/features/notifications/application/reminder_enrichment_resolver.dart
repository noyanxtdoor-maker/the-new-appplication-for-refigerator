import 'package:flutter/widgets.dart';

/// VS16 M7 notification-enrichment sanitization.
///
/// This is presentation-only sanitization for the optional Contact-name and
/// Event-location lines.  Owner source data is never rewritten; an omitted
/// result simply drops the line.
const int reminderContactNameGraphemeLimit = 80;
const int reminderLocationGraphemeLimit = 120;

final RegExp _controlAndBidi = RegExp(
  r'[\u0000-\u001F\u007F-\u009F\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);
final RegExp _whitespaceRun = RegExp(r'\s+');
final RegExp _uriScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');
final RegExp _decimalCoordinatePair = RegExp(
  r'^-?\d{1,3}\.\d+\s*[,;/]\s*-?\d{1,3}\.\d+$',
);
final RegExp _degreeCoordinate = RegExp(r'\d\s*°');
final RegExp _navigationHints = RegExp(
  r'(google\.navigation|geo:|maps\.google|/maps\?|google\.com/maps)',
  caseSensitive: false,
);

String? _normalize(String? raw) {
  if (raw == null) return null;
  final stripped = raw
      .replaceAll(_controlAndBidi, ' ')
      .replaceAll(_whitespaceRun, ' ')
      .trim();
  return stripped.isEmpty ? null : stripped;
}

String _truncate(String value, int limit) {
  final graphemes = value.characters;
  if (graphemes.length <= limit) return value;
  return '${graphemes.take(limit - 1)}…';
}

/// Sanitizes a current Contact display name for the `Follow up with …` line.
/// Blank becomes absent; no coordinate/URI heuristics are applied to names.
String? sanitizeReminderContactName(String? raw) {
  final normalized = _normalize(raw);
  if (normalized == null) return null;
  return _truncate(normalized, reminderContactNameGraphemeLimit);
}

/// Sanitizes current Event `locationText` for the `Location: …` line.
///
/// URI/scheme strings and coordinate-shaped decimal pairs or degree forms are
/// rejected outright (the caller omits the line).  Normal human address text
/// keeps its numbers; only the whole-string coordinate shapes are rejected.
String? sanitizeReminderLocation(String? raw) {
  final normalized = _normalize(raw);
  if (normalized == null) return null;
  if (_uriScheme.hasMatch(normalized) ||
      _navigationHints.hasMatch(normalized) ||
      _decimalCoordinatePair.hasMatch(normalized) ||
      _degreeCoordinate.hasMatch(normalized)) {
    return null;
  }
  return _truncate(normalized, reminderLocationGraphemeLimit);
}
