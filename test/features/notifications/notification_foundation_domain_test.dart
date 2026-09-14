import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/notifications/notification_preview_policy.dart';
import 'package:rmplanner/core/notifications/notification_response_controller.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

void main() {
  ReminderPolicy policy({
    ReminderPurpose purpose = ReminderPurpose.standard,
    String? contactId,
  }) => ReminderPolicy(
    id: 'policy-1',
    profileId: 'profile-1',
    sourceKind: ReminderSourceKind.task,
    sourceId: 'task-1',
    occurrenceId: ReminderPolicy.seriesOccurrenceId,
    mode: ReminderPolicyMode.offset,
    offsetMinutes: 15,
    purpose: purpose,
    contactId: contactId,
    createdAtUtc: DateTime.utc(2026, 9, 1),
    updatedAtUtc: DateTime.utc(2026, 9, 1),
  );

  test('T1/T2 contact follow-up purpose requires exactly one Contact id', () {
    expect(
      () => policy(purpose: ReminderPurpose.contactFollowUp).validate(),
      throwsArgumentError,
      reason: 'contactFollowUp without a Contact id is invalid',
    );
    expect(
      () => policy(
        purpose: ReminderPurpose.contactFollowUp,
        contactId: '   ',
      ).validate(),
      throwsArgumentError,
      reason: 'a blank Contact id is not a Contact identity',
    );
    expect(
      () => policy(contactId: 'contact-1').validate(),
      throwsArgumentError,
      reason: 'standard purpose must not store a Contact id',
    );
    expect(
      policy(
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      ).validate,
      returnsNormally,
    );
  });

  test('T3/T5 omitted purpose preserves; explicit standard clears Contact', () {
    final followUp = policy(
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-1',
    );

    final timingOnly = followUp.copyWith(
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 30,
      updatedAtUtc: DateTime.utc(2026, 9, 2),
    );
    expect(timingOnly.purpose, ReminderPurpose.contactFollowUp);
    expect(timingOnly.contactId, 'contact-1');
    expect(timingOnly.offsetMinutes, 30);

    final cleared = followUp.copyWith(purpose: ReminderPurpose.standard);
    expect(cleared.purpose, ReminderPurpose.standard);
    expect(cleared.contactId, isNull);

    final explicitlyCleared = followUp.copyWith(clearPurpose: true);
    expect(explicitlyCleared.purpose, ReminderPurpose.standard);
    expect(explicitlyCleared.contactId, isNull);

    final retargeted = followUp.copyWith(
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-2',
    );
    expect(retargeted.contactId, 'contact-2');

    final kept = followUp.copyWith(purpose: ReminderPurpose.contactFollowUp);
    expect(kept.contactId, 'contact-1');
  });

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

  test('M2 CORRECTION: content follows saved mode; lock is irrelevant', () {
    // M2 owner correction Issue 1: Privacy Lock no longer forces Generic.
    const saved = PrivacySettings(
      lockEnabled: true,
      notificationPreviewMode: NotificationPreviewMode.showContent,
    );
    expect(
      resolveNotificationPreviewMode(settings: saved),
      EffectiveNotificationPreviewMode.detailed,
    );
    expect(saved.notificationPreviewMode, NotificationPreviewMode.showContent);
    const lockedHidden = PrivacySettings(
      lockEnabled: true,
      notificationPreviewMode: NotificationPreviewMode.hidden,
    );
    expect(
      resolveNotificationPreviewMode(settings: lockedHidden),
      EffectiveNotificationPreviewMode.generic,
    );
    const unlockedDetailed = PrivacySettings(
      lockEnabled: false,
      notificationPreviewMode: NotificationPreviewMode.showContent,
    );
    expect(
      resolveNotificationPreviewMode(settings: unlockedDetailed),
      EffectiveNotificationPreviewMode.detailed,
    );
    const unlockedHidden = PrivacySettings.defaults();
    expect(
      resolveNotificationPreviewMode(settings: unlockedHidden),
      EffectiveNotificationPreviewMode.generic,
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
}
