/// Astra §13/P17: shared copy for ordinary native and targeted worker
/// delivery.  Baseline source truth (verified at 7b1395c):
/// generic '🔔 Next Transfer' / 'You have a new notification.' at
/// calendar_event_providers 198-199, planner_providers 654-655/773-774 and
/// planning 106/174; detailed '📅 Event reminder' at calendar_event_providers
/// 205, '✅ Task reminder' at planner_providers 656/775; Event range body from
/// calendar_event_providers _eventReminderBody (h:mm AM/PM dash range, then
/// trimmed notes); Task 'Due h:mm AM/PM' from planner_providers
/// _taskReminderBody.  Ordinary templates are byte-identical.
///
/// Enriched worker bodies follow the exact §13 order:
///   Event: time range, `Follow up with <name>.`, notes, `Location: <text>`
///   Task:  `Due <time>`, `Follow up with <name>.`, notes
/// A null/blank validated enrichment input omits its line; no filler.
/// Enrichment inputs must already be sanitized by the §15 resolver.
final class ReminderNotificationRenderer {
  const ReminderNotificationRenderer();

  static const String genericTitle = '🔔 Next Transfer';
  static const String genericBody = 'You have a new notification.';
  static const String eventDetailedTitle = '📅 Event reminder';
  static const String taskDetailedTitle = '✅ Task reminder';
  static const String eventFallbackBody = 'Upcoming event';
  static const String taskFallbackBody = 'Upcoming task';

  /// Baseline Event detailed body (range + optional trimmed notes), byte-
  /// identical to calendar_event_providers._eventReminderBody.
  String eventBody({
    required String? startDisplay,
    required String? endDisplay,
    required String? notes,
  }) {
    final range = startDisplay == null || endDisplay == null
        ? eventFallbackBody
        : '$startDisplay–$endDisplay';
    return _appendNotes(range, notes);
  }

  /// Baseline Task detailed body ('Due h:mm AM/PM' + optional trimmed notes),
  /// byte-identical to planner_providers._taskReminderBody (12-hour form).
  String taskBody({required String? dueDisplay, required String? notes}) {
    final due = dueDisplay == null || dueDisplay.isEmpty
        ? taskFallbackBody
        : 'Due $dueDisplay';
    return _appendNotes(due, notes);
  }

  /// Enriched Event body per §13 FOLLOW-UP EVENT Detailed + EVENT LOCATION.
  String eventWorkerBody({
    required String? startDisplay,
    required String? endDisplay,
    required String? notes,
    String? followUpDisplayName,
    String? locationText,
  }) {
    final range = startDisplay == null || endDisplay == null
        ? eventFallbackBody
        : '$startDisplay–$endDisplay';
    final buffer = StringBuffer(range);
    final name = followUpDisplayName?.trim() ?? '';
    if (name.isNotEmpty) {
      buffer
        ..writeln()
        ..write('Follow up with $name.');
    }
    final description = notes?.trim();
    if (description != null && description.isNotEmpty) {
      buffer
        ..writeln()
        ..write(description);
    }
    final location = locationText?.trim() ?? '';
    if (location.isNotEmpty) {
      buffer
        ..writeln()
        ..write('Location: $location');
    }
    return buffer.toString();
  }

  /// Enriched Task body per §13 FOLLOW-UP TASK Detailed (no Task location).
  String taskWorkerBody({
    required String? dueDisplay,
    required String? notes,
    String? followUpDisplayName,
  }) {
    final due = dueDisplay == null || dueDisplay.isEmpty
        ? taskFallbackBody
        : 'Due $dueDisplay';
    final buffer = StringBuffer(due);
    final name = followUpDisplayName?.trim() ?? '';
    if (name.isNotEmpty) {
      buffer
        ..writeln()
        ..write('Follow up with $name.');
    }
    final description = notes?.trim();
    if (description != null && description.isNotEmpty) {
      buffer
        ..writeln()
        ..write(description);
    }
    return buffer.toString();
  }

  static String _appendNotes(String base, String? notes) {
    final description = notes?.trim();
    return description == null || description.isEmpty
        ? base
        : '$base\n$description';
  }
}
