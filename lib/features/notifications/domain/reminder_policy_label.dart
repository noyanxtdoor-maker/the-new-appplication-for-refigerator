/// VS16-M7 O8 — one shared formatter for validated reminder offset labels.
///
/// Contract section 66 (O8 final law):
///   0      -> "At event time"
///   1      -> "1 minute before"
///   N >= 2 -> `"<N> minutes before"`
///
/// Callers keep their own Off / inherit wording; the numeric formatter must
/// never receive a null or a negative (Off) sentinel.  Existing chevrons,
/// spacing and typography are owned by the call sites and are not changed here.
abstract final class ReminderPolicyLabel {
  /// Canonical full-length label for a validated non-negative offset.
  ///
  /// [zeroLabel] preserves the existing Task wording ("At due time") without
  /// changing the singular/plural law; it defaults to the Event wording.
  static String offsetMinutes(int minutes, {String zeroLabel = 'At event time'}) {
    if (minutes < 0) {
      throw ArgumentError.value(
        minutes,
        'minutes',
        'Reminder offset labels require a validated non-negative value.',
      );
    }
    return switch (minutes) {
      0 => zeroLabel,
      1 => '1 minute before',
      _ => '$minutes minutes before',
    };
  }

  /// Abbreviated inner text used by the Event/Task "Default (…)  ›" summary
  /// rows.  Positive inherited values keep the existing "min before" suffix.
  static String inheritedOffsetMinutes(
    int minutes, {
    String zeroLabel = 'At event time',
  }) {
    if (minutes < 0) {
      throw ArgumentError.value(
        minutes,
        'minutes',
        'Reminder offset labels require a validated non-negative value.',
      );
    }
    return switch (minutes) {
      0 => zeroLabel,
      1 => '1 min before',
      _ => '$minutes min before',
    };
  }
}
