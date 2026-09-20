/// VS16-M7 P17 — the exact reminder copy contract (contract section 13).
///
/// This extracts the baseline Event/Task copy without changing ordinary
/// templates, and adds the M7 conditional lines.  It is the SINGLE canonical
/// Detailed presentation source shared by the native ordinary path and the
/// targeted worker post so both render identically.
///
/// Owner amendment to contract section 13 (VS16 M7 corrective round):
/// - Detailed uses the ACTUAL resolved source title of the Event/Task, keeping
///   any user emoji intact, and falls back to the constant
///   `📅 Event reminder` / `✅ Task reminder` ONLY when the source title is
///   null or blank.
/// - Description is shown as a deterministic, grapheme-safe PREVIEW of at most
///   120 graphemes with the ellipsis INSIDE the limit.
/// - Five per-field Detailed content options gate each line independently.
///   All five default to TRUE.
/// - When every Detailed field is off the renderer falls back to the exact
///   Generic copy; it must never emit a blank notification.
/// - M2 OWNER CORRECTION (Issue 1): Privacy Lock no longer forces Generic at
///   render time.  Notification content follows ONLY the saved Detailed
///   preference and per-field options; Privacy Lock stays authoritative for
///   app-entry authentication and pending-OPEN handling exclusively.
///
/// Frozen rules:
/// - Generic / Privacy Lock: ONLY the neutral title and body, never any time,
///   name, notes or location.
/// - Detailed: the baseline template first, then at most one "Follow up with
///   [name]." line, then existing notes, then at most one "Location: [text]"
///   line (Event only).
/// - Contact unavailable/invalid -> omit the Follow up line, keep the normal
///   current body.
/// - Location absent/invalid -> omit the Location line.  No filler text.
///
/// Presentation only: this file must never influence transport ownership,
/// `m7n_`/`m7w_` identity, generation CAS, retry rules, Event relevance,
/// `sourceRevision`, targets or ownership rules.
library;

import 'package:characters/characters.dart';

/// A rendered title/body pair ready for either transport.
final class RenderedReminder {
  const RenderedReminder({required this.title, required this.body});

  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is RenderedReminder && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  @override
  String toString() => 'RenderedReminder($title | $body)';
}

/// The five per-field Detailed content toggles.
///
/// All five default to TRUE: a profile that has never touched these settings
/// keeps the pre-existing richest Detailed behaviour.  This type is pure
/// presentation; it is never a scheduling input.
final class ReminderDetailOptions {
  const ReminderDetailOptions({
    this.showTitle = true,
    this.showDescription = true,
    this.showTime = true,
    this.showContacts = true,
    this.showLocation = true,
  });

  /// The five-option "everything on" preset (the default).
  static const ReminderDetailOptions all = ReminderDetailOptions();

  final bool showTitle;
  final bool showDescription;
  final bool showTime;
  final bool showContacts;
  final bool showLocation;

  /// True when no Detailed field would be shown, which forces Generic copy.
  bool get isEmpty =>
      !showTitle &&
      !showDescription &&
      !showTime &&
      !showContacts &&
      !showLocation;

  /// A deterministic, RUN-STABLE token for the five fields.
  ///
  /// This exists so the per-field choices can enter a persisted render revision
  /// (owner pass 2026-09-19, defect N1-G): changing a Detailed field must refresh
  /// an ALREADY-SCHEDULED reminder's copy in place, otherwise the pre-rendered
  /// native body would keep whatever was chosen when it was scheduled.
  ///
  /// Deliberately NOT [hashCode]: `Object.hash` is seeded per isolate, so a hash
  /// in a persisted revision would differ after every app launch and needlessly
  /// cancel and recreate still-pending platform alarms.
  String get revisionToken =>
      '${showTitle ? 1 : 0}${showDescription ? 1 : 0}${showTime ? 1 : 0}'
      '${showContacts ? 1 : 0}${showLocation ? 1 : 0}';

  ReminderDetailOptions copyWith({
    bool? showTitle,
    bool? showDescription,
    bool? showTime,
    bool? showContacts,
    bool? showLocation,
  }) => ReminderDetailOptions(
    showTitle: showTitle ?? this.showTitle,
    showDescription: showDescription ?? this.showDescription,
    showTime: showTime ?? this.showTime,
    showContacts: showContacts ?? this.showContacts,
    showLocation: showLocation ?? this.showLocation,
  );

  @override
  bool operator ==(Object other) =>
      other is ReminderDetailOptions &&
      other.showTitle == showTitle &&
      other.showDescription == showDescription &&
      other.showTime == showTime &&
      other.showContacts == showContacts &&
      other.showLocation == showLocation;

  @override
  int get hashCode => Object.hash(
    showTitle,
    showDescription,
    showTime,
    showContacts,
    showLocation,
  );

  @override
  String toString() =>
      'ReminderDetailOptions(title: $showTitle, description: $showDescription, '
      'time: $showTime, contacts: $showContacts, location: $showLocation)';
}

abstract final class ReminderNotificationRenderer {
  static const String genericTitle = '🔔 Next Transfer';
  static const String genericBody = 'You have a new notification.';

  /// The constant fallback used only when the source title is null or blank.
  static const String eventDetailedTitleFallback = '📅 Event reminder';
  static const String taskDetailedTitleFallback = '✅ Task reminder';

  /// Retained aliases: pre-amendment call sites and older tests refer to these
  /// exact constant names.  They remain the fallback titles.
  static const String eventDetailedTitle = eventDetailedTitleFallback;
  static const String taskDetailedTitle = taskDetailedTitleFallback;

  /// The deterministic Detailed description preview budget, in graphemes.
  static const int maxDescriptionGraphemes = 120;

  /// The single trailing ellipsis used by the description preview.
  static const String ellipsis = '…';

  /// The only permitted copy for Generic / Privacy Lock.
  static const RenderedReminder generic = RenderedReminder(
    title: genericTitle,
    body: genericBody,
  );

  /// Baseline 12-hour clock label (`h:mm AM/PM`).  Unchanged from baseline.
  static String clockLabel(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final suffix = value.hour < 12 ? 'AM' : 'PM';
    return '$hour:${value.minute.toString().padLeft(2, '0')} $suffix';
  }

  /// Baseline Event time range.  `Upcoming event` stays for incomplete
  /// renderer-only fixtures; an actual all-day source never schedules.
  static String eventRange({DateTime? startDisplay, DateTime? endDisplay}) =>
      startDisplay == null || endDisplay == null
      ? 'Upcoming event'
      : '${clockLabel(startDisplay)}–${clockLabel(endDisplay)}';

  /// Baseline Task due line.  `Upcoming task` stays for an untimed source.
  static String taskDue(int? dueMinute, {bool use24HourTime = false}) {
    if (dueMinute == null) return 'Upcoming task';
    final hour = dueMinute ~/ 60;
    final minutePart = (dueMinute % 60).toString().padLeft(2, '0');
    final time = use24HourTime
        ? '${hour.toString().padLeft(2, '0')}:$minutePart'
        : '${hour % 12 == 0 ? 12 : hour % 12}:$minutePart '
              '${hour < 12 ? 'AM' : 'PM'}';
    return 'Due $time';
  }

  /// Resolves the Detailed notification title from the actual source title.
  ///
  /// User emoji is preserved verbatim; only surrounding whitespace is trimmed.
  /// [fallback] is used when [sourceTitle] is null, empty or whitespace only.
  static String resolveDetailedTitle({
    required String? sourceTitle,
    required String fallback,
  }) {
    final trimmed = sourceTitle?.trim();
    if (trimmed == null || trimmed.isEmpty) return fallback;
    return trimmed;
  }

  /// Deterministic grapheme-safe description preview.
  ///
  /// When the trimmed description fits within [maxDescriptionGraphemes] it is
  /// returned unchanged.  Otherwise it is truncated so the result is EXACTLY
  /// [maxDescriptionGraphemes] graphemes including the trailing ellipsis, which
  /// therefore falls inside the limit.  No grapheme is ever split.
  ///
  /// This deliberately does NOT apply the location URI-scheme / coordinate
  /// rejection law: that law belongs to LOCATION enrichment only.  An ordinary
  /// description containing a URL previews normally.
  static String descriptionPreview(
    String? description, {
    int maxGraphemes = maxDescriptionGraphemes,
  }) {
    final trimmed = description?.trim();
    if (trimmed == null || trimmed.isEmpty) return '';
    final graphemes = trimmed.characters;
    if (graphemes.length <= maxGraphemes) return trimmed;
    final keep = maxGraphemes - ellipsis.characters.length;
    return '${graphemes.take(keep)}$ellipsis';
  }

  /// Detailed Event copy.  [followUpName] and [locationText] must already be
  /// sanitized by the enrichment resolver; null means "omit the line".
  ///
  /// [eventTitle] is the ACTUAL resolved Event title (emoji preserved).  A
  /// null/blank title falls back to [eventDetailedTitleFallback].
  /// [options] gates each field independently; when every field is off the
  /// renderer returns the exact [generic] copy.
  static RenderedReminder eventDetailed({
    String? eventTitle,
    DateTime? startDisplay,
    DateTime? endDisplay,
    String? notes,
    String? followUpName,
    String? locationText,
    ReminderDetailOptions options = ReminderDetailOptions.all,
  }) {
    if (options.isEmpty) return generic;

    final title = options.showTitle
        ? resolveDetailedTitle(
            sourceTitle: eventTitle,
            fallback: eventDetailedTitleFallback,
          )
        : genericTitle;

    final lines = <String>[];
    if (options.showTime) {
      lines.add(eventRange(startDisplay: startDisplay, endDisplay: endDisplay));
    }
    if (options.showContacts && followUpName != null) {
      lines.add('Follow up with $followUpName.');
    }
    if (options.showDescription) {
      final preview = descriptionPreview(notes);
      if (preview.isNotEmpty) lines.add(preview);
    }
    if (options.showLocation && locationText != null) {
      lines.add('Location: $locationText');
    }

    return RenderedReminder(
      title: title,
      body: lines.isEmpty ? genericBody : lines.join('\n'),
    );
  }

  /// Detailed Task copy.  Tasks never receive a location line.
  ///
  /// [taskTitle] is the ACTUAL resolved Task title (emoji preserved).  A
  /// null/blank title falls back to [taskDetailedTitleFallback].
  static RenderedReminder taskDetailed({
    String? taskTitle,
    int? dueMinute,
    String? notes,
    String? followUpName,
    bool use24HourTime = false,
    ReminderDetailOptions options = ReminderDetailOptions.all,
  }) {
    if (options.isEmpty) return generic;

    final title = options.showTitle
        ? resolveDetailedTitle(
            sourceTitle: taskTitle,
            fallback: taskDetailedTitleFallback,
          )
        : genericTitle;

    final lines = <String>[];
    if (options.showTime) {
      lines.add(taskDue(dueMinute, use24HourTime: use24HourTime));
    }
    if (options.showContacts && followUpName != null) {
      lines.add('Follow up with $followUpName.');
    }
    if (options.showDescription) {
      final preview = descriptionPreview(notes);
      if (preview.isNotEmpty) lines.add(preview);
    }

    return RenderedReminder(
      title: title,
      body: lines.isEmpty ? genericBody : lines.join('\n'),
    );
  }
}
