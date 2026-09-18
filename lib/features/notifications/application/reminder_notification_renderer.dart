/// VS16 M7 shared reminder copy renderer.
///
/// Extracts the exact baseline Event/Task copy so the native ordinary path and
/// the enriched WorkManager path render from one place.  The baseline strings
/// are unchanged; the only additions are the contract-defined conditional
/// `Follow up with <name>.` and `Location: <text>` lines, whose inputs are
/// already sanitized by [sanitizeReminderContactName] / [sanitizeReminderLocation].
abstract final class ReminderNotificationCopy {
  static const String genericTitle = '🔔 Next Transfer';
  static const String genericBody = 'You have a new notification.';
  static const String eventDetailedTitle = '📅 Event reminder';
  static const String taskDetailedTitle = '✅ Task reminder';

  static String clockLabel(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final suffix = value.hour < 12 ? 'AM' : 'PM';
    return '$hour:${value.minute.toString().padLeft(2, '0')} $suffix';
  }

  static String clockLabelForMinute(int minute) {
    final hour = minute ~/ 60;
    final minutePart = (minute % 60).toString().padLeft(2, '0');
    return '${hour % 12 == 0 ? 12 : hour % 12}:$minutePart ${hour < 12 ? 'AM' : 'PM'}';
  }

  static String eventDetailedBody({
    DateTime? start,
    DateTime? end,
    String? notes,
    String? followUpContactName,
    String? locationText,
  }) {
    final range = start == null || end == null
        ? 'Upcoming event'
        : '${clockLabel(start)}–${clockLabel(end)}';
    final lines = <String>[range];
    if (followUpContactName != null) {
      lines.add('Follow up with $followUpContactName.');
    }
    final description = notes?.trim();
    if (description != null && description.isNotEmpty) {
      lines.add(description);
    }
    if (locationText != null) {
      lines.add('Location: $locationText');
    }
    return lines.join('\n');
  }

  static String taskDetailedBody({
    int? dueMinute,
    String? notes,
    String? followUpContactName,
  }) {
    if (dueMinute == null) return 'Upcoming task';
    final lines = <String>['Due ${clockLabelForMinute(dueMinute)}'];
    if (followUpContactName != null) {
      lines.add('Follow up with $followUpContactName.');
    }
    final description = notes?.trim();
    if (description != null && description.isNotEmpty) {
      lines.add(description);
    }
    return lines.join('\n');
  }
}
