import 'dart:convert';

import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:uuid/uuid.dart';

enum CalendarEventTiming { allDay, timed }

enum CalendarEventStatus {
  scheduled,
  completedHappened,
  partiallyCompleted,
  didNotHappen,
  cancelled,
  rescheduled,
}

enum CalendarRecurrenceFrequency { none, daily, weekly, monthly, yearly }

enum CalendarRecurrenceEndMode { never, onDate, afterCount }

enum CalendarRecurrenceMonthlyMode { dayOfMonth, nthWeekday }

enum CalendarEventEditScope { occurrence, thisAndFuture, series }

enum CalendarEventMutationOutcome { changed, unchanged }

final class CalendarEventValidationException implements Exception {
  const CalendarEventValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Additive custom-repeat shape stored alongside the legacy recurrence fields.
///
/// A `null` pattern means the recurrence uses the original daily/weekly/
/// monthly/yearly behavior. This keeps every pre-Delta 4.2 record byte-for-byte
/// representable by the existing columns while allowing Custom repeat to add
/// only the shape that those columns cannot express.
final class CalendarRecurrencePattern {
  const CalendarRecurrencePattern({
    this.interval = 1,
    this.weeklyWeekdays = const <int>{},
    this.monthlyMode = CalendarRecurrenceMonthlyMode.dayOfMonth,
  });

  final int interval;

  /// ISO weekday numbers (`DateTime.monday` through `DateTime.sunday`).
  final Set<int> weeklyWeekdays;
  final CalendarRecurrenceMonthlyMode monthlyMode;

  CalendarRecurrencePattern normalizedFor(
    CalendarRecurrenceFrequency frequency,
  ) {
    if (interval < 1) {
      throw const CalendarEventValidationException(
        'Repeat interval must be at least 1.',
      );
    }
    switch (frequency) {
      case CalendarRecurrenceFrequency.daily:
        return CalendarRecurrencePattern(interval: interval);
      case CalendarRecurrenceFrequency.weekly:
        if (weeklyWeekdays.isEmpty ||
            weeklyWeekdays.any(
              (weekday) =>
                  weekday < DateTime.monday || weekday > DateTime.sunday,
            )) {
          throw const CalendarEventValidationException(
            'Weekly repeat requires at least one valid weekday.',
          );
        }
        final weekdays = weeklyWeekdays.toList()..sort();
        return CalendarRecurrencePattern(
          interval: interval,
          weeklyWeekdays: Set<int>.unmodifiable(weekdays),
        );
      case CalendarRecurrenceFrequency.monthly:
        return CalendarRecurrencePattern(
          interval: interval,
          monthlyMode: monthlyMode,
        );
      case CalendarRecurrenceFrequency.none:
      case CalendarRecurrenceFrequency.yearly:
        throw const CalendarEventValidationException(
          'Custom repeat supports Day, Week, or Month.',
        );
    }
  }

  @override
  bool operator ==(Object other) {
    return other is CalendarRecurrencePattern &&
        interval == other.interval &&
        monthlyMode == other.monthlyMode &&
        weeklyWeekdays.length == other.weeklyWeekdays.length &&
        weeklyWeekdays.containsAll(other.weeklyWeekdays);
  }

  @override
  int get hashCode {
    final weekdays = weeklyWeekdays.toList()..sort();
    return Object.hash(interval, monthlyMode, Object.hashAll(weekdays));
  }
}

/// Canonical version-1 JSON for the one nullable custom-repeat column.
String? calendarRecurrencePatternToJson(CalendarRecurrencePattern? pattern) {
  if (pattern == null) {
    return null;
  }
  final weekdays = pattern.weeklyWeekdays.toList()..sort();
  return jsonEncode(<String, Object>{
    'version': 1,
    'interval': pattern.interval,
    'weekdays': weekdays,
    'monthlyMode': pattern.monthlyMode.name,
  });
}

/// Reads a versioned custom-repeat shape without making legacy rows fragile.
///
/// Unknown versions and malformed JSON deliberately return `null`, which is
/// the legacy recurrence representation. The old frequency/end columns remain
/// readable and editable even if a future or damaged additive payload appears.
CalendarRecurrencePattern? calendarRecurrencePatternFromJson(String? value) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
      return null;
    }
    final interval = decoded['interval'];
    final weekdayValues = decoded['weekdays'];
    final monthlyModeName = decoded['monthlyMode'];
    if (interval is! int || interval < 1 || weekdayValues is! List) {
      return null;
    }
    final weekdays = <int>{};
    for (final value in weekdayValues) {
      if (value is! int || value < DateTime.monday || value > DateTime.sunday) {
        return null;
      }
      weekdays.add(value);
    }
    final monthlyMode = CalendarRecurrenceMonthlyMode.values
        .asNameMap()[monthlyModeName];
    if (monthlyMode == null) {
      return null;
    }
    return CalendarRecurrencePattern(
      interval: interval,
      weeklyWeekdays: Set<int>.unmodifiable(weekdays),
      monthlyMode: monthlyMode,
    );
  } on Object {
    return null;
  }
}

/// Rebuilds one rule from the legacy columns plus the nullable additive shape.
CalendarRecurrenceRule calendarRecurrenceRuleFromStorage({
  required String frequencyName,
  required String endModeName,
  String? endDateIso,
  int? occurrenceCount,
  String? patternJson,
}) {
  final frequency = CalendarRecurrenceFrequency.values.byName(frequencyName);
  var pattern = calendarRecurrencePatternFromJson(patternJson);
  if (pattern != null) {
    try {
      pattern = pattern.normalizedFor(frequency);
    } on CalendarEventValidationException {
      pattern = null;
    }
  }
  return CalendarRecurrenceRule(
    frequency: frequency,
    endMode: CalendarRecurrenceEndMode.values.byName(endModeName),
    endDate: endDateIso == null ? null : PlannerDate.parse(endDateIso),
    occurrenceCount: occurrenceCount,
    pattern: pattern,
  );
}

final class CalendarRecurrenceRule {
  const CalendarRecurrenceRule({
    this.frequency = CalendarRecurrenceFrequency.none,
    this.endMode = CalendarRecurrenceEndMode.never,
    this.endDate,
    this.occurrenceCount,
    this.pattern,
  });

  final CalendarRecurrenceFrequency frequency;
  final CalendarRecurrenceEndMode endMode;
  final PlannerDate? endDate;
  final int? occurrenceCount;
  final CalendarRecurrencePattern? pattern;

  bool get isRecurring => frequency != CalendarRecurrenceFrequency.none;

  CalendarRecurrenceRule normalizedFor(PlannerDate startDate) {
    if (!isRecurring) {
      return const CalendarRecurrenceRule();
    }
    final normalizedPattern = pattern?.normalizedFor(frequency);
    switch (endMode) {
      case CalendarRecurrenceEndMode.never:
        return CalendarRecurrenceRule(
          frequency: frequency,
          pattern: normalizedPattern,
        );
      case CalendarRecurrenceEndMode.onDate:
        final value = endDate;
        if (value == null || value.compareTo(startDate) < 0) {
          throw const CalendarEventValidationException(
            'Recurrence end date cannot be before the first occurrence.',
          );
        }
        return CalendarRecurrenceRule(
          frequency: frequency,
          endMode: endMode,
          endDate: value,
          pattern: normalizedPattern,
        );
      case CalendarRecurrenceEndMode.afterCount:
        final value = occurrenceCount;
        if (value == null || value < 1) {
          throw const CalendarEventValidationException(
            'Recurrence count must be at least 1.',
          );
        }
        return CalendarRecurrenceRule(
          frequency: frequency,
          endMode: endMode,
          occurrenceCount: value,
          pattern: normalizedPattern,
        );
    }
  }

  int? occurrenceIndexOn({
    required PlannerDate startDate,
    required PlannerDate targetDate,
  }) {
    if (targetDate.compareTo(startDate) < 0) {
      return null;
    }
    final normalizedPattern = pattern?.normalizedFor(frequency);
    final index = normalizedPattern == null
        ? switch (frequency) {
            CalendarRecurrenceFrequency.none =>
              targetDate == startDate ? 0 : null,
            CalendarRecurrenceFrequency.daily => _dayDifference(
              startDate,
              targetDate,
            ),
            CalendarRecurrenceFrequency.weekly => _weeklyIndex(
              startDate,
              targetDate,
            ),
            CalendarRecurrenceFrequency.monthly => _monthlyIndex(
              startDate,
              targetDate,
            ),
            CalendarRecurrenceFrequency.yearly => _yearlyIndex(
              startDate,
              targetDate,
            ),
          }
        : _customOccurrenceIndex(
            startDate: startDate,
            targetDate: targetDate,
            pattern: normalizedPattern,
          );
    if (index == null) {
      return null;
    }
    if (endMode == CalendarRecurrenceEndMode.onDate &&
        targetDate.compareTo(endDate!) > 0) {
      return null;
    }
    if (endMode == CalendarRecurrenceEndMode.afterCount &&
        index >= occurrenceCount!) {
      return null;
    }
    return index;
  }

  PlannerDate occurrenceAt({
    required PlannerDate startDate,
    required int index,
  }) {
    if (index < 0) {
      throw RangeError.range(index, 0, null, 'index');
    }
    final normalizedPattern = pattern?.normalizedFor(frequency);
    if (normalizedPattern != null) {
      return _customOccurrenceAt(
        startDate: startDate,
        index: index,
        pattern: normalizedPattern,
      );
    }
    return switch (frequency) {
      CalendarRecurrenceFrequency.none when index == 0 => startDate,
      CalendarRecurrenceFrequency.none => throw RangeError.range(
        index,
        0,
        0,
        'index',
      ),
      CalendarRecurrenceFrequency.daily => startDate.addDays(index),
      CalendarRecurrenceFrequency.weekly => startDate.addDays(index * 7),
      CalendarRecurrenceFrequency.monthly => _addMonths(startDate, index),
      CalendarRecurrenceFrequency.yearly => _addYears(startDate, index),
    };
  }

  /// Largest recurrence index whose date is not after [targetDate].
  ///
  /// This monotonic lookup lets bounded consumers start near "today" without
  /// guessing from the legacy frequency alone (which is incorrect for custom
  /// intervals and multi-day weeks).
  int occurrenceIndexAtOrBefore({
    required PlannerDate startDate,
    required PlannerDate targetDate,
  }) {
    if (targetDate.compareTo(startDate) <= 0) {
      return 0;
    }
    var low = 0;
    var high = 1;
    while (occurrenceAt(
          startDate: startDate,
          index: high,
        ).compareTo(targetDate) <=
        0) {
      low = high;
      high *= 2;
    }
    while (low + 1 < high) {
      final middle = low + (high - low) ~/ 2;
      if (occurrenceAt(
            startDate: startDate,
            index: middle,
          ).compareTo(targetDate) <=
          0) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low;
  }

  int? _customOccurrenceIndex({
    required PlannerDate startDate,
    required PlannerDate targetDate,
    required CalendarRecurrencePattern pattern,
  }) {
    if (targetDate == startDate) {
      return 0;
    }
    return switch (frequency) {
      CalendarRecurrenceFrequency.daily => _customDailyIndex(
        startDate,
        targetDate,
        pattern.interval,
      ),
      CalendarRecurrenceFrequency.weekly => _customWeeklyIndex(
        startDate,
        targetDate,
        pattern,
      ),
      CalendarRecurrenceFrequency.monthly => _customMonthlyIndex(
        startDate,
        targetDate,
        pattern,
      ),
      CalendarRecurrenceFrequency.none ||
      CalendarRecurrenceFrequency.yearly => null,
    };
  }

  PlannerDate _customOccurrenceAt({
    required PlannerDate startDate,
    required int index,
    required CalendarRecurrencePattern pattern,
  }) {
    if (index == 0) {
      return startDate;
    }
    return switch (frequency) {
      CalendarRecurrenceFrequency.daily => startDate.addDays(
        index * pattern.interval,
      ),
      CalendarRecurrenceFrequency.weekly => _customWeeklyOccurrenceAt(
        startDate,
        index,
        pattern,
      ),
      CalendarRecurrenceFrequency.monthly => _customMonthlyOccurrenceAt(
        startDate,
        index,
        pattern,
      ),
      CalendarRecurrenceFrequency.none || CalendarRecurrenceFrequency.yearly =>
        throw StateError('Unsupported custom recurrence frequency.'),
    };
  }

  static int? _customDailyIndex(
    PlannerDate start,
    PlannerDate target,
    int interval,
  ) {
    final days = _dayDifference(start, target);
    return days % interval == 0 ? days ~/ interval : null;
  }

  static int? _customWeeklyIndex(
    PlannerDate start,
    PlannerDate target,
    CalendarRecurrencePattern pattern,
  ) {
    final weekdays = pattern.weeklyWeekdays.toList()..sort();
    final weekStart = start.addDays(DateTime.monday - start.weekday);
    final targetWeek = _dayDifference(weekStart, target) ~/ 7;
    if (targetWeek % pattern.interval != 0 ||
        !pattern.weeklyWeekdays.contains(target.weekday)) {
      return null;
    }
    final firstWeekdays = weekdays
        .where(
          (weekday) =>
              weekStart.addDays(weekday - DateTime.monday) != start &&
              weekStart.addDays(weekday - DateTime.monday).compareTo(start) > 0,
        )
        .toList(growable: false);
    if (targetWeek == 0) {
      final position = firstWeekdays.indexOf(target.weekday);
      return position < 0 ? null : position + 1;
    }
    final activeCycle = targetWeek ~/ pattern.interval;
    final weekdayPosition = weekdays.indexOf(target.weekday);
    final occurrencesBefore =
        firstWeekdays.length +
        (activeCycle - 1) * weekdays.length +
        weekdayPosition;
    return occurrencesBefore + 1;
  }

  static PlannerDate _customWeeklyOccurrenceAt(
    PlannerDate start,
    int index,
    CalendarRecurrencePattern pattern,
  ) {
    final weekdays = pattern.weeklyWeekdays.toList()..sort();
    final weekStart = start.addDays(DateTime.monday - start.weekday);
    final firstWeekdays = weekdays
        .where(
          (weekday) =>
              weekStart.addDays(weekday - DateTime.monday).compareTo(start) > 0,
        )
        .toList(growable: false);
    var remaining = index - 1;
    if (remaining < firstWeekdays.length) {
      return weekStart.addDays(firstWeekdays[remaining] - DateTime.monday);
    }
    remaining -= firstWeekdays.length;
    final activeCycle = remaining ~/ weekdays.length + 1;
    final weekday = weekdays[remaining % weekdays.length];
    return weekStart.addDays(
      activeCycle * pattern.interval * DateTime.daysPerWeek +
          weekday -
          DateTime.monday,
    );
  }

  static int? _customMonthlyIndex(
    PlannerDate start,
    PlannerDate target,
    CalendarRecurrencePattern pattern,
  ) {
    final months = (target.year - start.year) * 12 + target.month - start.month;
    if (months <= 0 || months % pattern.interval != 0) {
      return null;
    }
    if (pattern.monthlyMode == CalendarRecurrenceMonthlyMode.dayOfMonth) {
      return _addMonths(start, months) == target
          ? months ~/ pattern.interval
          : null;
    }
    final expected = _nthWeekdayInMonth(
      year: target.year,
      month: target.month,
      weekday: start.weekday,
      occurrence: (start.day - 1) ~/ DateTime.daysPerWeek + 1,
    );
    if (expected != target) {
      return null;
    }
    var index = 0;
    for (
      var offset = pattern.interval;
      offset <= months;
      offset += pattern.interval
    ) {
      final month = _addMonths(
        PlannerDate(year: start.year, month: start.month, day: 1),
        offset,
      );
      if (_nthWeekdayInMonth(
            year: month.year,
            month: month.month,
            weekday: start.weekday,
            occurrence: (start.day - 1) ~/ DateTime.daysPerWeek + 1,
          ) !=
          null) {
        index++;
      }
    }
    return index;
  }

  static PlannerDate _customMonthlyOccurrenceAt(
    PlannerDate start,
    int index,
    CalendarRecurrencePattern pattern,
  ) {
    if (pattern.monthlyMode == CalendarRecurrenceMonthlyMode.dayOfMonth) {
      return _addMonths(start, index * pattern.interval);
    }
    final nth = (start.day - 1) ~/ DateTime.daysPerWeek + 1;
    var found = 0;
    for (var offset = pattern.interval; ; offset += pattern.interval) {
      final month = _addMonths(
        PlannerDate(year: start.year, month: start.month, day: 1),
        offset,
      );
      final candidate = _nthWeekdayInMonth(
        year: month.year,
        month: month.month,
        weekday: start.weekday,
        occurrence: nth,
      );
      if (candidate == null) {
        continue;
      }
      found++;
      if (found == index) {
        return candidate;
      }
    }
  }

  static PlannerDate? _nthWeekdayInMonth({
    required int year,
    required int month,
    required int weekday,
    required int occurrence,
  }) {
    final firstWeekday = DateTime(year, month).weekday;
    final offset = (weekday - firstWeekday) % DateTime.daysPerWeek;
    final day = 1 + offset + (occurrence - 1) * DateTime.daysPerWeek;
    if (day > _daysInMonth(year, month)) {
      return null;
    }
    return PlannerDate(year: year, month: month, day: day);
  }

  static int _dayDifference(PlannerDate start, PlannerDate target) {
    return target.asLocalDate.difference(start.asLocalDate).inDays;
  }

  static int? _weeklyIndex(PlannerDate start, PlannerDate target) {
    final days = _dayDifference(start, target);
    return days % 7 == 0 ? days ~/ 7 : null;
  }

  static int? _monthlyIndex(PlannerDate start, PlannerDate target) {
    final months = (target.year - start.year) * 12 + target.month - start.month;
    return _addMonths(start, months) == target ? months : null;
  }

  static int? _yearlyIndex(PlannerDate start, PlannerDate target) {
    final years = target.year - start.year;
    return _addYears(start, years) == target ? years : null;
  }

  static PlannerDate _addMonths(PlannerDate start, int months) {
    final absoluteMonth = start.year * 12 + start.month - 1 + months;
    final year = absoluteMonth ~/ 12;
    final month = absoluteMonth % 12 + 1;
    final day = start.day.clamp(1, _daysInMonth(year, month));
    return PlannerDate(year: year, month: month, day: day);
  }

  static PlannerDate _addYears(PlannerDate start, int years) {
    final year = start.year + years;
    final day = start.day.clamp(1, _daysInMonth(year, start.month));
    return PlannerDate(year: year, month: start.month, day: day);
  }

  static int _daysInMonth(int year, int month) {
    return DateTime(year, month + 1, 0).day;
  }
}

/// Concrete default end dates for newly configured recurrence.
PlannerDate calendarDefaultRecurrenceEndDate(
  PlannerDate startDate,
  CalendarRecurrenceFrequency frequency,
) {
  return switch (frequency) {
    CalendarRecurrenceFrequency.daily => CalendarRecurrenceRule._addMonths(
      startDate,
      2,
    ),
    CalendarRecurrenceFrequency.weekly => CalendarRecurrenceRule._addMonths(
      startDate,
      3,
    ),
    CalendarRecurrenceFrequency.monthly => CalendarRecurrenceRule._addMonths(
      startDate,
      6,
    ),
    CalendarRecurrenceFrequency.yearly => CalendarRecurrenceRule._addYears(
      startDate,
      2,
    ),
    CalendarRecurrenceFrequency.none => throw ArgumentError.value(
      frequency,
      'frequency',
      'A non-repeating Event has no default repeat end date.',
    ),
  };
}

final class CalendarEventDraft {
  const CalendarEventDraft({
    required this.id,
    required this.title,
    required this.timing,
    required this.startDate,
    required this.requiresReport,
    this.status = CalendarEventStatus.scheduled,
    this.notes,
    this.startMinute,
    this.endMinute,
    this.timeZoneId,
    this.locationText,
    this.activityTypeId,
    this.activityTypeMappingVersion,
    this.activityTypeStableKeySnapshot,
    this.activityTypeLabelSnapshot,
    this.activityTypeColorValueSnapshot,
    this.contactChannel,
    this.contributionRuleKey,
    this.goalId,
    this.isBackupAppointment = false,
    this.backupForEventId,
    this.backupRelationshipProvenance,
    this.recurrence = const CalendarRecurrenceRule(),
  });

  final String id;
  final String title;
  final String? notes;
  final CalendarEventTiming timing;
  final PlannerDate startDate;
  final CalendarEventStatus status;
  final int? startMinute;
  final int? endMinute;
  final String? timeZoneId;
  final String? locationText;
  final String? activityTypeId;
  final int? activityTypeMappingVersion;
  final String? activityTypeStableKeySnapshot;
  final String? activityTypeLabelSnapshot;
  final int? activityTypeColorValueSnapshot;

  /// P2-A: the INDEPENDENT Event contact channel (user-facing "Contact Type").
  ///
  /// Nullable and optional: an Event that never had one reads back as null,
  /// which every surface renders as an honest unset state. It is never derived
  /// from [activityTypeStableKeySnapshot] or [activityTypeLabelSnapshot].
  final EventContactChannel? contactChannel;

  final bool requiresReport;
  final String? contributionRuleKey;

  /// The Goal this Event is manually linked to, when any.
  ///
  /// The locked Goal-reporting invariant (`goalId != null` implies
  /// `requiresReport == true`) is enforced in [normalized] so every entry
  /// path — form, import, sync, repository call — converges on a persisted
  /// state where a Goal-linked Event always requires a report.
  final String? goalId;

  final bool isBackupAppointment;
  final String? backupForEventId;
  final String? backupRelationshipProvenance;
  final CalendarRecurrenceRule recurrence;

  CalendarEventDraft normalized() {
    if (!Uuid.isValidUUID(fromString: id)) {
      throw const CalendarEventValidationException(
        'Calendar Events require stable UUID identifiers.',
      );
    }
    final normalizedTitle = _normalizeOptional(title);
    final normalizedNotes = _normalizeOptional(notes);
    final normalizedLocation = _normalizeOptional(locationText);
    final normalizedActivityTypeStableKey = _normalizeOptional(
      activityTypeStableKeySnapshot,
    );
    final normalizedActivityTypeLabel = _normalizeOptional(
      activityTypeLabelSnapshot,
    );
    final normalizedContribution = _normalizeOptional(contributionRuleKey);
    final normalizedGoalId = _normalizeOptional(goalId);
    final normalizedRecurrence = recurrence.normalizedFor(startDate);
    // Locked Goal-reporting invariant (Final Planner correction): an Event is
    // Report Required when it is linked to a Goal (manual `goalId`) OR when
    // its Event Type is one of the six fixed Goal-linked types.  Planner
    // Polish Delta 2 adds the Contact rule: the Contact Event Type always
    // requires a Current Status report, independent of Life Goal linkage.
    // The normalization runs on EVERY save path so a Goal-linked or Contact
    // Event can never be persisted with reporting disabled.
    final mandatoryContactType =
        normalizedActivityTypeStableKey == SystemEventTypeKeys.contact;
    final goalLinked =
        normalizedGoalId != null ||
        mandatoryContactType ||
        (normalizedActivityTypeStableKey != null &&
            SystemEventTypeKeys.lockedWliTypeKeys.contains(
              normalizedActivityTypeStableKey,
            ));
    final normalizedRequiresReport = goalLinked || requiresReport;
    if (timing == CalendarEventTiming.allDay) {
      return CalendarEventDraft(
        id: id,
        title: normalizedTitle ?? '',
        notes: normalizedNotes,
        timing: timing,
        startDate: startDate,
        requiresReport: normalizedRequiresReport,
        status: status,
        locationText: normalizedLocation,
        activityTypeId: activityTypeId,
        activityTypeMappingVersion: activityTypeMappingVersion,
        activityTypeStableKeySnapshot: normalizedActivityTypeStableKey,
        activityTypeLabelSnapshot: normalizedActivityTypeLabel,
        activityTypeColorValueSnapshot: activityTypeColorValueSnapshot,
        // P2-A: the independent Event contact channel is carried through
        // normalization.  Without this the field would be silently dropped on
        // EVERY save path (`_validateDraft` normalizes before the write), so a
        // chosen Contact Type could never be persisted nor could an existing
        // one survive an unrelated edit.
        contactChannel: contactChannel,
        contributionRuleKey: normalizedContribution,
        goalId: normalizedGoalId,
        isBackupAppointment: isBackupAppointment,
        backupForEventId: isBackupAppointment
            ? _normalizeOptional(backupForEventId)
            : null,
        backupRelationshipProvenance: isBackupAppointment
            ? _normalizeOptional(backupRelationshipProvenance)
            : null,
        recurrence: normalizedRecurrence,
      );
    }
    final start = startMinute;
    final end = endMinute;
    if (start == null ||
        end == null ||
        start < 0 ||
        start > 1439 ||
        end < 1 ||
        end > 1440 ||
        end <= start) {
      throw const CalendarEventValidationException(
        'Timed events need a valid end time after the start time.',
      );
    }
    final zone = _normalizeOptional(timeZoneId);
    if (zone == null) {
      throw const CalendarEventValidationException(
        'Timed events require an IANA time-zone identity.',
      );
    }
    return CalendarEventDraft(
      id: id,
      title: normalizedTitle ?? '',
      notes: normalizedNotes,
      timing: timing,
      startDate: startDate,
      startMinute: start,
      endMinute: end,
      timeZoneId: zone,
      locationText: normalizedLocation,
      activityTypeId: activityTypeId,
      activityTypeMappingVersion: activityTypeMappingVersion,
      activityTypeStableKeySnapshot: normalizedActivityTypeStableKey,
      activityTypeLabelSnapshot: normalizedActivityTypeLabel,
      activityTypeColorValueSnapshot: activityTypeColorValueSnapshot,
      // P2-A: see the all-day branch above — normalization must preserve the
      // independent contact channel on the timed path too.
      contactChannel: contactChannel,
      requiresReport: normalizedRequiresReport,
      status: status,
      contributionRuleKey: normalizedContribution,
      goalId: normalizedGoalId,
      isBackupAppointment: isBackupAppointment,
      backupForEventId: isBackupAppointment
          ? _normalizeOptional(backupForEventId)
          : null,
      backupRelationshipProvenance: isBackupAppointment
          ? _normalizeOptional(backupRelationshipProvenance)
          : null,
      recurrence: normalizedRecurrence,
    );
  }

  CalendarEventDraft copyWith({
    String? id,
    String? title,
    String? notes,
    CalendarEventTiming? timing,
    PlannerDate? startDate,
    CalendarEventStatus? status,
    int? startMinute,
    int? endMinute,
    String? timeZoneId,
    String? locationText,
    String? activityTypeId,
    int? activityTypeMappingVersion,
    String? activityTypeStableKeySnapshot,
    String? activityTypeLabelSnapshot,
    int? activityTypeColorValueSnapshot,
    EventContactChannel? contactChannel,
    bool? requiresReport,
    String? contributionRuleKey,
    String? goalId,
    bool? isBackupAppointment,
    String? backupForEventId,
    String? backupRelationshipProvenance,
    CalendarRecurrenceRule? recurrence,
  }) {
    return CalendarEventDraft(
      id: id ?? this.id,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      timing: timing ?? this.timing,
      startDate: startDate ?? this.startDate,
      status: status ?? this.status,
      startMinute: startMinute ?? this.startMinute,
      endMinute: endMinute ?? this.endMinute,
      timeZoneId: timeZoneId ?? this.timeZoneId,
      locationText: locationText ?? this.locationText,
      activityTypeId: activityTypeId ?? this.activityTypeId,
      activityTypeMappingVersion:
          activityTypeMappingVersion ?? this.activityTypeMappingVersion,
      activityTypeStableKeySnapshot:
          activityTypeStableKeySnapshot ?? this.activityTypeStableKeySnapshot,
      activityTypeLabelSnapshot:
          activityTypeLabelSnapshot ?? this.activityTypeLabelSnapshot,
      activityTypeColorValueSnapshot:
          activityTypeColorValueSnapshot ?? this.activityTypeColorValueSnapshot,
      contactChannel: contactChannel ?? this.contactChannel,
      requiresReport: requiresReport ?? this.requiresReport,
      contributionRuleKey: contributionRuleKey ?? this.contributionRuleKey,
      goalId: goalId ?? this.goalId,
      isBackupAppointment: isBackupAppointment ?? this.isBackupAppointment,
      backupForEventId: backupForEventId ?? this.backupForEventId,
      backupRelationshipProvenance:
          backupRelationshipProvenance ?? this.backupRelationshipProvenance,
      recurrence: recurrence ?? this.recurrence,
    );
  }

  static String? _normalizeOptional(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

/// Returns the human-visible title for a stored Calendar Event.
///
/// Prefers the user-entered title; falls back to the Event Type label
/// when the user left the title blank. Callers should never substitute
/// a generic placeholder string here.
String calendarEventDisplayTitle({
  required String? storedTitle,
  required String? eventTypeLabel,
}) {
  final trimmed = storedTitle?.trim();
  if (trimmed != null && trimmed.isNotEmpty) {
    return trimmed;
  }
  final label = eventTypeLabel?.trim();
  if (label != null && label.isNotEmpty) {
    return label;
  }
  return '';
}

/// Returns the human-visible title for a Planner display item.
String plannerItemDisplayTitle({
  required String storedTitle,
  required String? eventTypeLabel,
}) {
  final resolved = calendarEventDisplayTitle(
    storedTitle: storedTitle,
    eventTypeLabel: eventTypeLabel,
  );
  return resolved.isEmpty ? 'Calendar Event' : resolved;
}

final class CalendarEventOccurrence {
  const CalendarEventOccurrence({
    required this.id,
    required this.eventId,
    required this.profileId,
    required this.title,
    required this.timing,
    required this.originalDate,
    required this.displayDate,
    required this.status,
    required this.requiresReport,
    required this.recurrence,
    this.notes,
    this.startUtc,
    this.endUtc,
    this.startDisplay,
    this.endDisplay,
    this.timeZoneId,
    this.displayTimeZoneId,
    this.locationText,
    this.activityTypeId,
    this.activityTypeMappingVersion,
    this.activityTypeStableKey,
    this.activityTypeLabel,
    this.activityTypeColorValue,
    this.contactChannel,
    this.contributionRuleKey,
    this.isBackupAppointment = false,
    this.backupForEventId,
    this.backupRelationshipProvenance,
    this.replacementEventId,
    this.linkedTaskIds = const <String>[],
    this.isStructurallyCancelled = false,
    this.reportedStatus,
    this.createdAtUtc,
    this.updatedAtUtc,
  });

  final String id;
  final String eventId;
  final String profileId;
  final String title;
  final String? notes;
  final CalendarEventTiming timing;
  final PlannerDate originalDate;
  final PlannerDate displayDate;
  final DateTime? startUtc;
  final DateTime? endUtc;
  final DateTime? startDisplay;
  final DateTime? endDisplay;
  final String? timeZoneId;
  final String? displayTimeZoneId;
  final String? locationText;
  final String? activityTypeId;
  final int? activityTypeMappingVersion;
  final String? activityTypeStableKey;
  final String? activityTypeLabel;
  final int? activityTypeColorValue;

  /// P2-A: the INDEPENDENT Event contact channel, null when unset or when a
  /// stored value is not one of the eight canonical keys.
  final EventContactChannel? contactChannel;

  final CalendarEventStatus status;
  final bool requiresReport;
  final String? contributionRuleKey;
  final bool isBackupAppointment;
  final String? backupForEventId;
  final String? backupRelationshipProvenance;
  final CalendarRecurrenceRule recurrence;
  final String? replacementEventId;
  final List<String> linkedTaskIds;
  final bool isStructurallyCancelled;
  final CalendarEventStatus? reportedStatus;
  final DateTime? createdAtUtc;
  final DateTime? updatedAtUtc;

  bool get isRecurring => recurrence.isRecurring;

  /// Human-visible title with the Event Type label fallback.
  String get displayTitle => calendarEventDisplayTitle(
    storedTitle: title,
    eventTypeLabel: activityTypeLabel,
  );

  bool get isChange =>
      status == CalendarEventStatus.cancelled ||
      status == CalendarEventStatus.rescheduled;

  bool isAwaitingReport({
    required DateTime nowUtc,
    required PlannerDate displayToday,
  }) {
    if (status != CalendarEventStatus.scheduled || !requiresReport) {
      return false;
    }
    if (timing == CalendarEventTiming.allDay) {
      return displayDate.compareTo(displayToday) < 0;
    }
    final end = endUtc;
    return end != null && end.isBefore(nowUtc);
  }
}

final class CalendarEventReportSnapshot {
  const CalendarEventReportSnapshot({
    required this.occurrenceId,
    required this.originalDate,
    required this.status,
  }) : assert(
         status == CalendarEventStatus.completedHappened ||
             status == CalendarEventStatus.partiallyCompleted ||
             status == CalendarEventStatus.didNotHappen,
       );

  final String occurrenceId;
  final PlannerDate originalDate;
  final CalendarEventStatus status;
}

abstract final class CalendarEventOccurrenceIdentity {
  static const Uuid _uuid = Uuid();

  static String forDate({
    required String eventId,
    required PlannerDate originalDate,
  }) {
    return _uuid.v5(
      Namespace.url.value,
      'com.nexttransfer.rmplanner:event:$eventId:${originalDate.iso8601}',
    );
  }
}

abstract final class CalendarEventExceptionIdentity {
  static const Uuid _uuid = Uuid();

  static String forOperation({
    required String operationId,
    required String occurrenceId,
  }) {
    return _uuid.v5(
      Namespace.url.value,
      'com.nexttransfer.rmplanner:event-exception:'
      '$operationId:$occurrenceId',
    );
  }
}

/// Concise user-facing recurrence description for the Event detail row.
///
/// Examples: 'Daily', 'Weekly • Until Aug 31, 2026', 'Monthly • 5
/// occurrences'.  The end-rule suffix is shown only when one exists; a
/// never-ending recurrence reads as the bare frequency.
String calendarRecurrenceRuleLabel(CalendarRecurrenceRule rule) {
  if (!rule.isRecurring) {
    return 'Does not repeat';
  }
  final frequency = _calendarRecurrenceBaseLabel(rule);
  if (rule.endMode == CalendarRecurrenceEndMode.onDate) {
    final end = rule.endDate;
    if (end != null) {
      const months = <String>[
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '$frequency • Until ${months[end.month - 1]} ${end.day}, '
          '${end.year}';
    }
  }
  if (rule.endMode == CalendarRecurrenceEndMode.afterCount) {
    final count = rule.occurrenceCount;
    if (count != null) {
      final plural = count == 1 ? '' : 's';
      return '$frequency • $count occurrence$plural';
    }
  }
  return frequency;
}

String _calendarRecurrenceBaseLabel(CalendarRecurrenceRule rule) {
  final pattern = rule.pattern;
  if (pattern == null) {
    return switch (rule.frequency) {
      CalendarRecurrenceFrequency.daily => 'Daily',
      CalendarRecurrenceFrequency.weekly => 'Weekly',
      CalendarRecurrenceFrequency.monthly => 'Monthly',
      CalendarRecurrenceFrequency.yearly => 'Yearly',
      CalendarRecurrenceFrequency.none => 'Does not repeat',
    };
  }
  final interval = pattern.interval;
  return switch (rule.frequency) {
    CalendarRecurrenceFrequency.daily =>
      interval == 1 ? 'Every day' : 'Every $interval days',
    CalendarRecurrenceFrequency.weekly => _customWeeklyLabel(pattern),
    CalendarRecurrenceFrequency.monthly =>
      interval == 1 ? 'Every month' : 'Every $interval months',
    CalendarRecurrenceFrequency.yearly => 'Yearly',
    CalendarRecurrenceFrequency.none => 'Does not repeat',
  };
}

String _customWeeklyLabel(CalendarRecurrencePattern pattern) {
  const weekdayLabels = <int, String>{
    DateTime.monday: 'Monday',
    DateTime.tuesday: 'Tuesday',
    DateTime.wednesday: 'Wednesday',
    DateTime.thursday: 'Thursday',
    DateTime.friday: 'Friday',
    DateTime.saturday: 'Saturday',
    DateTime.sunday: 'Sunday',
  };
  final weekdays = pattern.weeklyWeekdays.toList()..sort();
  final labels = weekdays.map((weekday) => weekdayLabels[weekday]!).toList();
  final days = switch (labels.length) {
    0 => '',
    1 => labels.single,
    2 => '${labels.first} and ${labels.last}',
    _ => '${labels.take(labels.length - 1).join(', ')}, and ${labels.last}',
  };
  final cadence = pattern.interval == 1
      ? 'Every week'
      : 'Every ${pattern.interval} weeks';
  return days.isEmpty ? cadence : '$cadence on $days';
}

String calendarEventStatusLabel(
  CalendarEventStatus status, {
  bool isContactEvent = false,
}) {
  return switch (status) {
    CalendarEventStatus.scheduled => 'Unreported',
    CalendarEventStatus.completedHappened => 'Completed',
    // NX-03: the user-facing partial outcome is 'Missed' for Contact and
    // generic Events alike; the stored MISSED_ATTEMPTED value is internal.
    CalendarEventStatus.partiallyCompleted => 'Missed',
    CalendarEventStatus.didNotHappen => 'Did Not Attempt',
    CalendarEventStatus.cancelled => 'Cancelled',
    CalendarEventStatus.rescheduled => 'Rescheduled',
  };
}

String calendarEventOutcomeLabel({
  required CalendarEventStatus status,
  required bool isContactEvent,
}) {
  return switch (status) {
    CalendarEventStatus.scheduled => 'Unreported',
    // Planner Polish Delta 2 final matrix: the success state reads
    // 'Completed' for BOTH Contact and generic Events.
    CalendarEventStatus.completedHappened => 'Completed',
    // NX-03: the internal partial outcome stores as MISSED_ATTEMPTED; the
    // user-facing label is 'Missed' for Contact and generic Events alike.
    // Storage never changes, so historical reports stay readable.
    CalendarEventStatus.partiallyCompleted => 'Missed',
    // Legacy non-Contact Did Not Attempt records remain historically true
    // and readable (Delta 2 preserves them; the choice is only no longer
    // offered to new non-Contact reports).
    CalendarEventStatus.didNotHappen => 'Did Not Attempt',
    CalendarEventStatus.cancelled => 'Cancelled',
    CalendarEventStatus.rescheduled => 'Rescheduled',
  };
}

String calendarEventScopeLabel(CalendarEventEditScope scope) {
  return switch (scope) {
    CalendarEventEditScope.occurrence => 'This occurrence',
    CalendarEventEditScope.thisAndFuture => 'This and future',
    CalendarEventEditScope.series => 'Entire series',
  };
}
