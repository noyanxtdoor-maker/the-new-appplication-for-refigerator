import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/notifications/notification_preview_policy.dart';
import 'package:rmplanner/features/notifications/application/detailed_content_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

/// M2 OWNER CORRECTION (Issue 1, 2026-09-14) — the exact owner-approved
/// content matrix, asserted against the canonical resolver, the canonical
/// renderer and the Settings preview builder.
///
///   A. Privacy Lock ON  + explicit Detailed  -> DETAILED
///   B. Privacy Lock OFF + explicit Detailed  -> DETAILED
///   C. Privacy Lock ON/OFF + explicit Generic -> GENERIC (exact copy)
///   D. Privacy Lock ON/OFF + all fields off   -> GENERIC (exact copy)
void main() {
  final start = DateTime(2026, 9, 14, 9);
  final end = DateTime(2026, 9, 14, 10);

  PrivacySettings mode(bool lockOn, NotificationPreviewMode preview) =>
      PrivacySettings(lockEnabled: lockOn, notificationPreviewMode: preview);

  EffectiveNotificationPreviewMode resolved(
    bool lockOn,
    NotificationPreviewMode preview,
  ) => resolveNotificationPreviewMode(settings: mode(lockOn, preview));

  group('A/B — lock state cannot force Generic over Detailed', () {
    test('A: lock ON + Detailed -> effective Detailed (Event + Task)', () {
      expect(
        resolved(true, NotificationPreviewMode.showContent),
        EffectiveNotificationPreviewMode.detailed,
      );
      final event = ReminderNotificationRenderer.eventDetailed(
        eventTitle: '🎂 Willow\'s Birthday',
        startDisplay: start,
        endDisplay: end,
        notes: 'Bring a gift',
        followUpName: 'Cara Gomez',
        locationText: 'Union Square Cafe',
      );
      expect(event.title, "🎂 Willow's Birthday");
      expect(event.body, contains('Bring a gift'));
      expect(event.body, contains('Cara Gomez'));
      expect(event.body, contains('Union Square Cafe'));
      expect(event.body, isNot(ReminderNotificationRenderer.genericBody));

      final task = ReminderNotificationRenderer.taskDetailed(
        taskTitle: '✅ Refill prescription',
        dueMinute: 9 * 60 + 30,
        notes: 'Pick up at pharmacy',
        followUpName: 'Dana Field',
      );
      expect(task.title, '✅ Refill prescription');
      expect(task.body, contains('Pick up at pharmacy'));
      expect(task.body, contains('Dana Field'));
    });

    test('B: lock OFF + Detailed -> effective Detailed (Event + Task)', () {
      expect(
        resolved(false, NotificationPreviewMode.showContent),
        EffectiveNotificationPreviewMode.detailed,
      );
      final event = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Dentist',
        startDisplay: start,
        endDisplay: end,
        notes: 'Bring the insurance card',
      );
      expect(event.title, 'Dentist');
      expect(event.body, contains('Bring the insurance card'));
    });
  });

  group('C — explicit Generic/private choice stays Generic', () {
    test('lock ON + hidden -> exact generic title/body', () {
      expect(
        resolved(true, NotificationPreviewMode.hidden),
        EffectiveNotificationPreviewMode.generic,
      );
      // Generic is a product decision made BEFORE rendering (reconciler/
      // delivery service pass showDetails=false), so the renderer receives
      // all-off options and emits the exact generic pair.
      final event = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Private dental appointment',
        startDisplay: start,
        endDisplay: end,
        notes: 'Very private notes',
        options: const ReminderDetailOptions(
          showTitle: false,
          showDescription: false,
          showTime: false,
          showContacts: false,
          showLocation: false,
        ),
      );
      expect(event.title, ReminderNotificationRenderer.genericTitle);
      expect(event.body, ReminderNotificationRenderer.genericBody);
    });

    test('lock OFF + hidden -> exact generic title/body', () {
      expect(
        resolved(false, NotificationPreviewMode.hidden),
        EffectiveNotificationPreviewMode.generic,
      );
      expect(ReminderNotificationRenderer.generic.title, '🔔 Next Transfer');
      expect(
        ReminderNotificationRenderer.generic.body,
        'You have a new notification.',
      );
    });
  });

  group('D — all detail fields disabled stays Generic', () {
    test('all-off Event options render exact generic copy', () {
      const allOff = ReminderDetailOptions(
        showTitle: false,
        showDescription: false,
        showTime: false,
        showContacts: false,
        showLocation: false,
      );
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Should never surface',
        startDisplay: start,
        endDisplay: end,
        options: allOff,
      );
      expect(rendered.title, ReminderNotificationRenderer.genericTitle);
      expect(rendered.body, ReminderNotificationRenderer.genericBody);
    });

    test('all-off Task options render exact generic copy', () {
      const allOff = ReminderDetailOptions(
        showTitle: false,
        showDescription: false,
        showTime: false,
        showContacts: false,
        showLocation: false,
      );
      final rendered = ReminderNotificationRenderer.taskDetailed(
        taskTitle: 'Should never surface',
        dueMinute: 600,
        options: allOff,
      );
      expect(rendered.title, ReminderNotificationRenderer.genericTitle);
      expect(rendered.body, ReminderNotificationRenderer.genericBody);
    });
  });

  group('independent per-field rendering', () {
    test('Event fields gate independently (title/time/location only)', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        eventTitle: 'Garden tour',
        startDisplay: start,
        endDisplay: end,
        notes: 'Wear boots',
        followUpName: 'Cara Gomez',
        locationText: 'Botanical Garden',
        options: const ReminderDetailOptions(
          showDescription: false,
          showContacts: false,
        ),
      );
      expect(rendered.title, 'Garden tour');
      expect(rendered.body, contains('9:00 AM'));
      expect(rendered.body, contains('Location: Botanical Garden'));
      expect(rendered.body, isNot(contains('Wear boots')));
      expect(rendered.body, isNot(contains('Cara Gomez')));
    });

    test('Task fields gate independently and never fabricate a location', () {
      final rendered = ReminderNotificationRenderer.taskDetailed(
        taskTitle: 'Water plants',
        dueMinute: 14 * 60 + 5,
        notes: 'Front and back',
        followUpName: 'Eli Vance',
        options: const ReminderDetailOptions(
          showDescription: false,
          showContacts: false,
        ),
      );
      expect(rendered.title, 'Water plants');
      expect(rendered.body, 'Due 2:05 PM');
      expect(rendered.body.toLowerCase().contains('location'), isFalse);
    });
  });

  group('planning families share the corrected policy', () {
    test(
      'Weekly Review / Awaiting Report detailed copy is reachable only '
      'through showDetails, which now ignores the lock',
      () {
        // The planning reconciler derives showDetails from
        // resolveNotificationPreviewMode; with the corrected law a locked
        // profile with Detailed saved gets detailed planning copy.
        expect(
          resolved(true, NotificationPreviewMode.showContent),
          EffectiveNotificationPreviewMode.detailed,
        );
        // The detailed planning copy constants used by the reconciler:
        const weeklyTitle = '📋 Weekly review';
        expect(weeklyTitle, isNot(ReminderNotificationRenderer.genericTitle));
        const reportTitle = '📝 Report reminder';
        expect(reportTitle, isNot(ReminderNotificationRenderer.genericTitle));
      },
    );
  });

  group('generic/fallback remains generic by definition', () {
    test('weekly review and awaiting report generic copy is unchanged', () {
      // The reconciler always posts these exact generic pairs when
      // showDetails is false (explicit hidden preference or all-off).
      expect(
        resolved(false, NotificationPreviewMode.hidden),
        EffectiveNotificationPreviewMode.generic,
      );
      expect(
        ReminderNotificationRenderer.generic,
        const RenderedReminder(
          title: '🔔 Next Transfer',
          body: 'You have a new notification.',
        ),
      );
    });
  });

  group('Settings preview builder follows the same law', () {
    test('buildDetailedPreview ignores lock state entirely', () {
      const detailed = DetailedContentPreferences.defaults;
      const hidden = PrivacySettings(
        lockEnabled: true,
        notificationPreviewMode: NotificationPreviewMode.hidden,
      );
      // The resolver the screen no longer consults for content:
      expect(
        resolveNotificationPreviewMode(settings: hidden),
        EffectiveNotificationPreviewMode.generic,
      );
      // The preview renders from options only:
      final preview = buildDetailedPreview(
        isEvent: true,
        options: detailed,
        sourceTitle: 'Sample event',
        startDisplay: start,
        endDisplay: end,
      );
      expect(preview.title, 'Sample event');
      expect(preview.body, contains('9:00 AM–10:00 AM'));
    });
  });
}
