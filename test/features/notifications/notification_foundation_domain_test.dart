import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/notifications/notification_preview_policy.dart';
import 'package:rmplanner/core/notifications/notification_response_controller.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

void main() {
  test(
    'master notification policy keeps saved category choices but gates effective state',
    () {
      const enabled = NotificationPreferences(
        systemNotificationsEnabled: true,
        eventRemindersEnabled: true,
        taskRemindersEnabled: true,
        defaultTaskReminderMinutes: null,
        quietHours: QuietHoursSettings.disabled(),
      );

      expect(
        enabled.effectiveSystemEnabled(androidPermissionGranted: true),
        isTrue,
      );
      expect(
        enabled.effectiveEventEnabled(androidPermissionGranted: true),
        isTrue,
      );
      expect(
        enabled.effectiveTaskEnabled(androidPermissionGranted: true),
        isTrue,
      );
      expect(
        enabled.effectiveEventEnabled(androidPermissionGranted: false),
        isFalse,
      );
      expect(
        enabled
            .copyWith(systemNotificationsEnabled: false)
            .eventRemindersEnabled,
        isTrue,
        reason:
            'the saved category preference must not be erased by master Off',
      );
      expect(
        enabled
            .copyWith(systemNotificationsEnabled: false)
            .effectiveTaskEnabled(androidPermissionGranted: true),
        isFalse,
      );
    },
  );

  test('Quiet Hours validates range and interprets overnight windows', () {
    const quiet = QuietHoursSettings(
      enabled: true,
      startMinute: 1320,
      endMinute: 420,
    );
    expect(quiet.isInQuietHours(1380), isTrue);
    expect(quiet.isInQuietHours(360), isTrue);
    expect(quiet.isInQuietHours(720), isFalse);
    expect(
      const QuietHoursSettings(
        enabled: true,
        startMinute: -1,
        endMinute: 60,
      ).validate,
      throwsArgumentError,
    );
    expect(
      const NotificationPreferences(
        systemNotificationsEnabled: false,
        eventRemindersEnabled: false,
        taskRemindersEnabled: false,
        defaultTaskReminderMinutes: -1,
        quietHours: QuietHoursSettings.disabled(),
      ).validate,
      throwsArgumentError,
    );
  });

  test('payload is versioned ID-only and rejects malformed identities', () {
    const intent = NotificationResponseIntent(
      profileId: 'profile-1',
      sourceKind: NotificationSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: 'occurrence-1',
      action: NotificationResponseAction.open,
    );
    final encoded = NotificationPayloadCodec.encode(intent);
    expect(NotificationPayloadCodec.tryDecode(encoded), intent);
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    expect(json.keys.toSet(), <String>{
      'version',
      'profileId',
      'sourceKind',
      'sourceId',
      'occurrenceId',
      'action',
    });
    expect(NotificationPayloadCodec.tryDecode('{bad'), isNull);
    expect(
      NotificationPayloadCodec.tryDecode(
        jsonEncode(<String, Object?>{...json, 'version': 999}),
      ),
      isNull,
    );
    expect(
      NotificationPayloadCodec.tryDecode(
        jsonEncode(<String, Object?>{...json}..remove('sourceId')),
      ),
      isNull,
    );
    expect(
      NotificationPayloadCodec.tryDecode(
        jsonEncode(<String, Object?>{...json, 'body': 'private'}),
      ),
      isNull,
    );
  });

  test('Privacy Lock forces Generic without overwriting saved Detailed', () {
    const saved = PrivacySettings(
      lockEnabled: true,
      notificationPreviewMode: NotificationPreviewMode.showContent,
    );
    expect(
      resolveNotificationPreviewMode(
        settings: saved,
        privacyProtectionRequired: true,
      ),
      EffectiveNotificationPreviewMode.generic,
    );
    expect(saved.notificationPreviewMode, NotificationPreviewMode.showContent);
    expect(
      resolveNotificationPreviewMode(
        settings: saved,
        privacyProtectionRequired: false,
      ),
      EffectiveNotificationPreviewMode.detailed,
    );
  });

  test('response controller separates cold and warm typed responses', () async {
    final controller = NotificationResponseController();
    addTearDown(controller.dispose);
    const intent = NotificationResponseIntent(
      profileId: 'profile-1',
      sourceKind: NotificationSourceKind.task,
      sourceId: 'task-1',
      occurrenceId: 'series',
      action: NotificationResponseAction.open,
    );
    controller.capture(
      payload: NotificationPayloadCodec.encode(intent),
      initial: true,
    );
    controller.capture(payload: '{bad');
    expect(controller.takeInitial(), intent);
    expect(controller.takeInitial(), isNull);

    final warm = controller.responses.first;
    controller.capture(
      payload: NotificationPayloadCodec.encode(intent),
      actionId: 'snooze',
    );
    expect((await warm).action, NotificationResponseAction.snooze);
  });

  // T1 pin (Astra §7): an explicit contactFollowUp purpose is only valid with
  // a nonblank Contact identity. Domain validation alone is insufficient for
  // acceptance, but it remains the innermost gate and must keep holding.
  test('T1: contactFollowUp requires a nonblank contactId', () {
    ReminderPolicy policyFor(ReminderPurpose purpose, String? contactId) =>
        ReminderPolicy(
          id: 'policy-t1',
          profileId: 'profile-t1',
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: 'event-t1',
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          purpose: purpose,
          contactId: contactId,
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 10,
          createdAtUtc: DateTime.utc(2026, 9, 5, 5),
          updatedAtUtc: DateTime.utc(2026, 9, 5, 5),
        );
    expect(policyFor(ReminderPurpose.contactFollowUp, null).validate,
        throwsArgumentError);
    expect(policyFor(ReminderPurpose.contactFollowUp, '   ').validate,
        throwsArgumentError);
    expect(
      () => policyFor(ReminderPurpose.contactFollowUp, 'contact-1').validate(),
      returnsNormally,
    );
  });

  // T2 pin (Astra §7): standard reminders never store Contact identity.
  test('T2: standard purpose with a contactId is invalid', () {
    expect(
      ReminderPolicy(
        id: 'policy-t2',
        profileId: 'profile-t2',
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-t2',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.standard,
        contactId: 'contact-t2',
        mode: ReminderPolicyMode.inherit,
        createdAtUtc: DateTime.utc(2026, 9, 5, 5),
        updatedAtUtc: DateTime.utc(2026, 9, 5, 5),
      ).validate,
      throwsArgumentError,
    );
  });

  // T3 (Astra §62 T3): explicit purpose clear via the M7 API produces
  // standard/null identity and validates.  Uses the new withPurpose/clearPurpose
  // semantics so null-ambiguity can never make clearing impossible (§9).
  test('T3: explicit purpose clear produces standard/null and persists', () {
    final followUp = ReminderPolicy(
      id: 'policy-t3',
      profileId: 'profile-t3',
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-t3',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-t3',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 10,
      createdAtUtc: DateTime.utc(2026, 9, 5, 5),
      updatedAtUtc: DateTime.utc(2026, 9, 5, 5),
    );
    final cleared = followUp.clearPurpose();
    expect(cleared.purpose, ReminderPurpose.standard);
    expect(cleared.contactId, isNull);
    expect(cleared.mode, ReminderPolicyMode.offset);
    expect(cleared.offsetMinutes, 10);
    expect(() => cleared.validate(), returnsNormally);
    expect(
      followUp
          .withPurpose(
            purpose: ReminderPurpose.standard,
            contactId: 'should-be-dropped',
          )
          .contactId,
      isNull,
      reason: 'standard purpose must never retain Contact identity',
    );
  });

  // T5 (Astra §62 T5): omitted purpose argument preserves; explicit standard
  // clears contactId (verified through ReminderReconciler.savePolicy in the
  // repository suite); withPurpose set/keep semantics pinned here.
  test('T5: withPurpose set and keep semantics', () {
    final base = ReminderPolicy(
      id: 'policy-t5',
      profileId: 'profile-t5',
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-t5',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-t5',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 5,
      createdAtUtc: DateTime.utc(2026, 9, 5, 5),
      updatedAtUtc: DateTime.utc(2026, 9, 5, 5),
    );
    final retargeted = base.withPurpose(
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-t5b',
    );
    expect(retargeted.purpose, ReminderPurpose.contactFollowUp);
    expect(retargeted.contactId, 'contact-t5b');
    expect(retargeted.offsetMinutes, 5);
    expect(() => retargeted.validate(), returnsNormally);
    // Default copyWith still preserves purpose/contact (§9 preserve law).
    final retimed = base.copyWith(offsetMinutes: 7);
    expect(retimed.purpose, ReminderPurpose.contactFollowUp);
    expect(retimed.contactId, 'contact-t5');
  });
}
