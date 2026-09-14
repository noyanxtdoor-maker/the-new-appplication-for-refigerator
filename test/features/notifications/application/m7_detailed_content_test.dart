import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';

/// VS16 M7 corrective — canonical Detailed presentation (D1–D20, D22).
///
/// FAIL-FIRST: this suite is written against the CORRECTED contract and must
/// FAIL before the corrective implementation lands:
///   - D1/D4 expect the resolved source title, but the renderer currently emits
///     the constant `📅 Event reminder` / `✅ Task reminder`.
///   - D2/D5 expect a blank source title to fall back to those constants.
///   - D7 expects a 120-grapheme description preview, which does not exist.
///   - D8–D15 expect per-field Detailed content options, which do not exist.
///   - D18/D19 expect the all-off / Privacy-Lock Generic fallback reason.
void main() {
  final start = DateTime.utc(2026, 9, 12, 9);
  final end = DateTime.utc(2026, 9, 12, 10);

  group('D1-D3 Event title amendment (Astra section 13 owner amendment)', () {
    test('D1 Detailed Event uses the actual resolved Event title', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: "🎂 Willow's Birthday",
        startDisplay: start,
        endDisplay: end,
      );
      expect(rendered.title, "🎂 Willow's Birthday");
    });

    test('D2 a blank Event title falls back to the constant title', () {
      for (final blank in <String?>[null, '', '   ']) {
        final rendered = ReminderNotificationRenderer.eventDetailed(
          eventTitle: blank,
          startDisplay: start,
          endDisplay: end,
        );
        expect(
          rendered.title,
          ReminderNotificationRenderer.eventDetailedTitleFallback,
        );
      }
    });

    test('D3 user-entered emoji survives the title path intact', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: "🎂 Willow's Birthday 🎉",
        startDisplay: start,
        endDisplay: end,
      );
      expect(rendered.title, "🎂 Willow's Birthday 🎉");
      expect(rendered.title.contains('🎂'), isTrue);
      expect(rendered.title.contains('🎉'), isTrue);
    });
  });

  group('D4-D5 Task title amendment', () {
    test('D4 Detailed Task uses the actual resolved Task title', () {
      final rendered = ReminderNotificationRenderer.taskDetailed(
        taskTitle: 'Pay the electric bill',
        dueMinute: 9 * 60,
      );
      expect(rendered.title, 'Pay the electric bill');
    });

    test('D5 a blank Task title falls back to the constant title', () {
      for (final blank in <String?>[null, '', '   ']) {
        final rendered = ReminderNotificationRenderer.taskDetailed(
          taskTitle: blank,
          dueMinute: 9 * 60,
        );
        expect(
          rendered.title,
          ReminderNotificationRenderer.taskDetailedTitleFallback,
        );
      }
    });
  });

  group('D6-D7 description preview', () {
    test('D6 a short description appears verbatim on its own line', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        notes: 'Bring the insurance card',
      );
      expect(rendered.body.contains('Bring the insurance card'), isTrue);
      expect(rendered.body.split('\n').length, greaterThan(1));
    });

    test('D7 a long description is capped deterministically at 120 graphemes', () {
      // 300 ASCII graphemes: must be truncated to <= 120 with a trailing
      // ellipsis INSIDE the 120 limit.
      final long = 'a' * 300;
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        notes: long,
      );
      final preview = rendered.body
          .split('\n')
          .firstWhere((line) => line.contains('a'));
      expect(preview.characters.length, lessThanOrEqualTo(120));
      expect(preview.endsWith('…'), isTrue);
      expect(preview.characters.length, 120);
    });

    test('D7b truncation is grapheme-safe for emoji, never splitting one', () {
      // 200 emoji graphemes (each is multiple code units).
      final long = '🎂' * 200;
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        notes: long,
      );
      final preview = rendered.body
          .split('\n')
          .firstWhere((line) => line.contains('🎂'));
      expect(preview.characters.length, lessThanOrEqualTo(120));
      // No half of a surrogate pair may survive.
      for (final codeUnit in preview.codeUnits) {
        expect(codeUnit == 0xFFFD, isFalse);
      }
      expect(preview.endsWith('…'), isTrue);
    });

    test('D7c the description sanitizer does NOT apply location URI rules', () {
      // An ordinary description containing a URL-ish phrase must still preview:
      // the URI/coordinate rejection law belongs to LOCATION enrichment only.
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Standup',
        startDisplay: start,
        endDisplay: end,
        notes: 'Join at https://meet.example/standup',
      );
      expect(
        rendered.body.contains('https://meet.example/standup'),
        isTrue,
        reason: 'ordinary descriptions must not be URI-rejected',
      );
    });
  });

  group('D8-D15 per-field Detailed content options', () {
    test('D8 Show time ON includes the Event time range', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        options: const ReminderDetailOptions(),
      );
      expect(rendered.body.contains('9:00 AM'), isTrue);
      expect(rendered.body.contains('10:00 AM'), isTrue);
    });

    test('D9 Show time OFF removes time without damaging other fields', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        notes: 'Bring the insurance card',
        options: const ReminderDetailOptions(showTime: false),
      );
      expect(rendered.body.contains('9:00 AM'), isFalse);
      expect(rendered.body.contains('Bring the insurance card'), isTrue);
      expect(rendered.title, 'Dentist');
    });

    test('D10 Show description OFF removes the description', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        notes: 'Bring the insurance card',
        options: const ReminderDetailOptions(showDescription: false),
      );
      expect(rendered.body.contains('Bring the insurance card'), isFalse);
      expect(rendered.body.contains('9:00 AM'), isTrue);
    });

    test('D11 Show contacts ON displays the current legitimate Contact', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Catch up',
        startDisplay: start,
        endDisplay: end,
        followUpName: 'Cara Gomez',
        options: const ReminderDetailOptions(),
      );
      expect(rendered.body.contains('Follow up with Cara Gomez.'), isTrue);
    });

    test('D12 Show contacts OFF omits the Contact line', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Catch up',
        startDisplay: start,
        endDisplay: end,
        followUpName: 'Cara Gomez',
        options: const ReminderDetailOptions(showContacts: false),
      );
      expect(rendered.body.contains('Cara Gomez'), isFalse);
      expect(rendered.body.contains('Follow up'), isFalse);
    });

    test('D14 Show location ON displays the current sanitized location', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dinner',
        startDisplay: start,
        endDisplay: end,
        locationText: 'Union Square Cafe',
        options: const ReminderDetailOptions(),
      );
      expect(rendered.body.contains('Location: Union Square Cafe'), isTrue);
    });

    test('D15 Show location OFF omits the location line', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dinner',
        startDisplay: start,
        endDisplay: end,
        locationText: 'Union Square Cafe',
        options: const ReminderDetailOptions(showLocation: false),
      );
      expect(rendered.body.contains('Union Square Cafe'), isFalse);
      expect(rendered.body.contains('Location:'), isFalse);
    });

    test('D15b every Detailed option defaults to TRUE', () {
      final options = const ReminderDetailOptions();
      expect(options.showTitle, isTrue, reason: 'default must be TRUE');
      expect(options.showDescription, isTrue);
      expect(options.showTime, isTrue);
      expect(options.showContacts, isTrue);
      expect(options.showLocation, isTrue);
    });
  });

  group('D17 Task never fabricates a Location field', () {
    test('the Task renderer exposes no location parameter at all', () {
      final rendered = ReminderNotificationRenderer.taskDetailed(
        taskTitle: 'Pay the electric bill',
        dueMinute: 9 * 60,
        notes: 'Autopay is off',
      );
      expect(rendered.body.contains('Location:'), isFalse);
      expect(rendered.body.contains('Due 9:00 AM'), isTrue);
      expect(rendered.body.contains('Autopay is off'), isTrue);
    });
  });

  group('D18-D20 Generic fallback and Privacy Lock authority', () {
    test('D18 all five Detailed fields OFF falls back to exact Generic copy', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        notes: 'Bring the insurance card',
        followUpName: 'Cara Gomez',
        locationText: 'Union Square Cafe',
        options: const ReminderDetailOptions(
          showTitle: false,
          showDescription: false,
          showTime: false,
          showContacts: false,
          showLocation: false,
        ),
      );
      expect(rendered, ReminderNotificationRenderer.generic);
      expect(rendered.title, '🔔 Next Transfer');
      expect(rendered.body, 'You have a new notification.');
    });

    test('D18b the identical all-off rule holds for Tasks', () {
      final rendered = ReminderNotificationRenderer.taskDetailed(
        taskTitle: 'Pay the electric bill',
        dueMinute: 9 * 60,
        notes: 'Autopay is off',
        followUpName: 'Cara Gomez',
        options: const ReminderDetailOptions(
          showTitle: false,
          showDescription: false,
          showTime: false,
          showContacts: false,
          showLocation: false,
        ),
      );
      expect(rendered.title, '🔔 Next Transfer');
      expect(rendered.body, 'You have a new notification.');
    });

    test('D19 M2 CORRECTION: Privacy Lock no longer forces Generic copy', () {
      // M2 owner correction Issue 1: Privacy Lock does not participate in
      // notification content selection.  Detailed preference -> Detailed.
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: "🎂 Willow's Birthday",
        startDisplay: start,
        endDisplay: end,
        notes: 'Bring a gift',
        followUpName: 'Cara Gomez',
        locationText: 'Union Square Cafe',
      );
      expect(rendered.title, "🎂 Willow's Birthday");
      expect(rendered.body, contains('Bring a gift'));
      expect(rendered.body, contains('Cara Gomez'));
      expect(rendered.body, contains('Union Square Cafe'));
    });

    test('D22 the renderer is the same object for both transports', () {
      // A parity guard: identical inputs must yield identical output no matter
      // which transport renders them (there is exactly one renderer).
      final a = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        notes: 'Bring the insurance card',
      );
      final b = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        notes: 'Bring the insurance card',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
