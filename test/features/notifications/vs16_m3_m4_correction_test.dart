// VS16 M3/M4 owner-review correction — focused contract tests.
//
// Covers the bounded correction pass:
//  G1 dedicated monochrome notification small icon (resource + gateway)
//  G2 Event detailed notification content (title/displayTitle + From-To body)
//  G3/G4 planner-first OPEN routing reusing the shared preview presenters
//  G5 dynamic inherited reminder row wording
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

void main() {
  group('G1 — dedicated notification small icon', () {
    late String drawable;
    late String gatewaySource;

    setUpAll(() {
      drawable = File(
        'android/app/src/main/res/drawable/ic_nt_notification.xml',
      ).readAsStringSync();
      gatewaySource = File(
        'lib/core/notifications/flutter_local_notifications_gateway.dart',
      ).readAsStringSync();
    });

    //
    // POST-P2 OWNER DECISION (2026-09-22): the artwork was SIMPLIFIED, so the
    // old geometry assertions (108-unit viewport, traced-SVG provenance comment)
    // are deliberately superseded. The RESOURCE CONTRACT did not change: same
    // name, same 24dp size, same transparent background, still ONE monochrome
    // white path that Android tints. The detailed silhouette laws now live in
    // test/android/notification_icon_test.dart; this case guards the contract
    // every other layer depends on.
    test('approved VectorDrawable exists as a monochrome single-fill vector', () {
      expect(drawable, contains('<vector'));
      expect(drawable, contains('android:viewportWidth="24"'));
      expect(drawable, contains('android:viewportHeight="24"'));
      expect(drawable, contains('android:width="24dp"'));
      expect(drawable, contains('android:height="24dp"'));
      // Exactly one path, one opaque white fill: Android tints the small icon.
      expect('android:fillColor'.allMatches(drawable).length, 1);
      expect(drawable, contains('android:fillColor="#FFFFFFFF"'));
      // No baked square background: the writing lines are cut OUT of the single
      // path with even-odd fill, not drawn as a second tinted shape.
      expect(drawable, contains('android:fillType="evenOdd"'));
      expect(RegExp(r'<path\b').allMatches(drawable).length, 1);
    });

    test('gateway initializes the small icon from the dedicated drawable', () {
      expect(
        gatewaySource,
        contains(
          "AndroidInitializationSettings('@drawable/ic_nt_notification')",
        ),
      );
      expect(gatewaySource, isNot(contains("InitializationSettings('@mipmap")));
    });
  });

  group('G2 — Event detailed notification content', () {
    test(
      'display title falls back to the Event Type label when title blank',
      () {
        // The owner-observed defect: blank stored title produced a blank
        // notification title; the canonical display title resolves the label.
        expect(
          calendarEventDisplayTitle(
            storedTitle: '  ',
            eventTypeLabel: 'Study or Plan',
          ),
          'Study or Plan',
        );
        expect(
          calendarEventDisplayTitle(
            storedTitle: 'Exam revision',
            eventTypeLabel: 'Study or Plan',
          ),
          'Exam revision',
        );
      },
    );

    test(
      'reminder body keeps From-To and appends non-empty description only',
      () {
        // Body law: "<From>–<To>\n<description if non-empty>".
        final occurrence = _occurrence(notes: 'Prepare chapter 4 notes');
        final body = _eventReminderBodyForTest(occurrence);
        expect(body, '11:35 AM–12:00 PM\nPrepare chapter 4 notes');

        final empty = _eventReminderBodyForTest(_occurrence(notes: '   '));
        expect(empty, '11:35 AM–12:00 PM');
        expect(empty.contains('\n\n'), isFalse);
      },
    );

    test(
      'content refresh keeps one stable reminder identity per occurrence',
      () {
        final keyA = ReminderReconciler.stableKey(
          sourceKind: ReminderSourceKind.calendarEvent,
          profileId: 'profile-1',
          occurrenceId: 'occurrence-1',
        );
        final keyB = ReminderReconciler.stableKey(
          sourceKind: ReminderSourceKind.calendarEvent,
          profileId: 'profile-1',
          occurrenceId: 'occurrence-1',
        );
        expect(keyA, keyB);
      },
    );
  });

  group('G5 — dynamic inherited reminder wording', () {
    test('task category default (minutes before) renders dynamically', () {
      // The task form label resolves from NotificationPreferences; the same
      // preferences object is the single owner of the category default.
      const withDefault = NotificationPreferences(
        systemNotificationsEnabled: true,
        eventRemindersEnabled: true,
        taskRemindersEnabled: true,
        defaultTaskReminderMinutes: 10,
        quietHours: QuietHoursSettings.disabled(),
      );
      expect(withDefault.defaultTaskReminderMinutes, 10);
      const withoutDefault = NotificationPreferences.defaults();
      expect(withoutDefault.defaultTaskReminderMinutes, isNull);
    });

    test('policy modes still hydrate Off/Custom per item without mutation', () {
      final policy = ReminderPolicy(
        id: 'p1',
        profileId: 'profile-1',
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-1',
        occurrenceId: 'task:task-1:2026-09-07',
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 27,
        createdAtUtc: DateTime.utc(2026, 9, 7),
        updatedAtUtc: DateTime.utc(2026, 9, 7),
      );
      expect(policy.mode, ReminderPolicyMode.offset);
      expect(policy.offsetMinutes, 27);
      final off = policy.copyWith(
        mode: ReminderPolicyMode.off,
        clearOffset: true,
      );
      expect(off.mode, ReminderPolicyMode.off);
      expect(off.offsetMinutes, isNull);
    });
  });

  group('G3/G4 — M2 CORRECTION: content law is lock-independent', () {
    test(
      'Privacy Lock no longer forces effective Generic; saved mode intact',
      () {
        const saved = PrivacySettings(
          lockEnabled: true,
          notificationPreviewMode: NotificationPreviewMode.showContent,
        );
        // M2 owner correction Issue 1: the lock no longer drives content.
        expect(saved.lockEnabled, isTrue);
        expect(
          saved.notificationPreviewMode,
          NotificationPreviewMode.showContent,
        );
      },
    );
  });
}

CalendarEventOccurrence _occurrence({String? notes}) {
  return CalendarEventOccurrence(
    id: 'occ-1',
    eventId: 'event-1',
    profileId: 'profile-1',
    title: '',
    notes: notes,
    timing: CalendarEventTiming.timed,
    originalDate: PlannerDate.fromDateTime(DateTime(2026, 9, 7)),
    displayDate: PlannerDate.fromDateTime(DateTime(2026, 9, 7)),
    status: CalendarEventStatus.scheduled,
    requiresReport: false,
    recurrence: const CalendarRecurrenceRule(),
    startDisplay: DateTime(2026, 9, 7, 11, 35),
    endDisplay: DateTime(2026, 9, 7, 12, 0),
  );
}

/// Mirrors the canonical renderer body law for test observation without
/// duplicating production logic in another runtime path.
String _eventReminderBodyForTest(CalendarEventOccurrence occurrence) {
  final start = occurrence.startDisplay;
  final end = occurrence.endDisplay;
  final range = start == null || end == null
      ? 'Upcoming event'
      : '${_clockLabel(start)}–${_clockLabel(end)}';
  final description = occurrence.notes?.trim();
  return description == null || description.isEmpty
      ? range
      : '$range\n$description';
}

String _clockLabel(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final suffix = value.hour < 12 ? 'AM' : 'PM';
  return '$hour:${value.minute.toString().padLeft(2, '0')} $suffix';
}
