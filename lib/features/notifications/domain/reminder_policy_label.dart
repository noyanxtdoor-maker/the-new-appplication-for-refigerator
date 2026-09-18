/// Astra §66 O8/P50: one shared formatter for validated nonnegative minute
/// values across picker, Event/Task summaries and Notifications Settings.
///
///   0 -> "At event time"
///   1 -> "1 minute before"
///   N >= 2 -> "N minutes before"
///
/// Callers must never pass null, the Off sentinel (-1) or other negatives:
/// those states keep their existing labels at the call sites (§66 preserves
/// Off/inherit/chevrons and the abbreviated "Default (N min before)  ›"
/// inherited form).
String formatReminderLeadMinutes(int minutes) {
  if (minutes < 0) {
    throw ArgumentError('Reminder lead must be a nonnegative minute count.');
  }
  if (minutes == 0) {
    return 'At event time';
  }
  if (minutes == 1) {
    return '1 minute before';
  }
  return '$minutes minutes before';
}
