import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:workmanager_platform_interface/workmanager_platform_interface.dart';

/// VS16 M7 corrective — D23/D24 BigText presentation at the common choke point.
///
/// FAIL-FIRST: before the corrective implementation `_detailsFor` returned
/// `AndroidNotificationDetails` with no `styleInformation` at all, so a
/// multiline Detailed body collapsed to the single-line collapsed layout and
/// nothing here could see a big-text style.
///
/// The style is asserted at the PLATFORM MESSAGE level (the real serialized
/// arguments the plugin sends to Android), not by inspecting private state, so
/// this test genuinely proves what the device will receive.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const intent = NotificationResponseIntent(
    profileId: 'profile',
    sourceKind: NotificationSourceKind.calendarEvent,
    sourceId: 'event',
    occurrenceId: 'event:event:2026-09-12',
    action: NotificationResponseAction.open,
  );

  /// Installs a mock handler that records every platform call.
  ///
  /// `schedule()` also calls WorkManager (to cancel the retired job tag), which
  /// has no implementation in a plain VM test. A no-op WorkManager platform is
  /// installed so the test exercises the NOTIFICATION seam only.
  List<MethodCall> installRecorder() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    WorkmanagerPlatform.instance = _NoopWorkmanagerPlatform();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    return calls;
  }

  /// Pulls the android `platformSpecifics` map out of a recorded call.
  Map<Object?, Object?> androidOf(MethodCall call) {
    final args = call.arguments as Map<Object?, Object?>;
    return args['platformSpecifics'] as Map<Object?, Object?>;
  }

  test('D23 showCanonicalReminder carries a big-text style with the full body',
      () async {
    final calls = installRecorder();
    final rendered = ReminderNotificationRenderer.eventDetailed(
      eventTitle: "🎂 Willow's Birthday",
      startDisplay: DateTime.utc(2026, 9, 12, 9),
      endDisplay: DateTime.utc(2026, 9, 12, 10),
      notes: 'Bring the insurance card',
      followUpName: 'Cara Gomez',
      locationText: 'Union Square Cafe',
    );
    // The body is genuinely multiline: without a style it would be clipped.
    expect(rendered.body.contains('\n'), isTrue);

    await FlutterLocalNotificationsGateway().showCanonicalReminder(
      LocalNotificationRequest(
        platformId: 501,
        stableKey: 'reminder:event:profile:occurrence:base',
        channel: NotificationChannelKind.reminders,
        scheduledAtUtc: DateTime.utc(2026, 9, 12, 8, 30),
        title: rendered.title,
        body: rendered.body,
        responseIntent: intent,
      ),
    );

    final call = calls.singleWhere((c) => c.method == 'show');
    final android = androidOf(call);
    // The plugin writes `style` and `styleInformation` as SIBLINGS on
    // platformSpecifics, and serializes the style as an enum INDEX.
    expect(
      android['style'],
      AndroidNotificationStyle.bigText.index,
      reason: 'the Detailed body must be presented as expandable big text',
    );
    final payload = android['styleInformation'] as Map<Object?, Object?>?;
    expect(
      payload,
      isNotNull,
      reason: 'the big-text payload must be present on the wire',
    );
    expect(
      payload!['bigText'],
      rendered.body,
      reason: 'the expanded body must be the exact rendered Detailed body',
    );
    expect(
      payload['contentTitle'],
      rendered.title,
      reason: 'the expanded title must match the collapsed title',
    );
  });

  test('D24 the native scheduled transport gets the identical big-text style',
      () async {
    final calls = installRecorder();
    const body = '9:00 AM–10:00 AM\nBring the insurance card';
    await FlutterLocalNotificationsGateway().schedule(
      LocalNotificationRequest(
        platformId: 502,
        stableKey: 'reminder:event:profile:occurrence:base',
        channel: NotificationChannelKind.reminders,
        // The plugin rejects a past scheduledDate, so use a real future instant.
        scheduledAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        title: 'Dentist',
        body: body,
        responseIntent: intent,
      ),
    );

    final call = calls.singleWhere((c) => c.method == 'zonedSchedule');
    final android = androidOf(call);
    expect(android['style'], AndroidNotificationStyle.bigText.index);
    final payload = android['styleInformation'] as Map<Object?, Object?>;
    expect(payload['bigText'], body);
    expect(payload['contentTitle'], 'Dentist');
  });

  test('D24b the style never changes channel identity or importance', () async {
    final calls = installRecorder();
    await FlutterLocalNotificationsGateway().showCanonicalReminder(
      LocalNotificationRequest(
        platformId: 503,
        stableKey: 'reminder:event:profile:occurrence:base',
        channel: NotificationChannelKind.reminders,
        scheduledAtUtc: DateTime.utc(2026, 9, 12, 8, 30),
        title: 'Dentist',
        body: 'Upcoming event',
        responseIntent: intent,
      ),
    );
    final android = androidOf(calls.singleWhere((c) => c.method == 'show'));
    // Presentation must not leak into channel selection: the M7 corrective
    // changes copy only, never the channel a reminder is posted on.
    expect(android['channelId'], NotificationChannelKind.reminders.id);
    expect(
      android['channelAction'],
      AndroidNotificationChannelAction.createIfNotExists.index,
      reason: 'channel creation semantics must be unchanged',
    );
    // Importance is inherited from the channel; the corrective adds no override.
    // The plugin's own defaults must be untouched (priority has no importance
    // override on a channel-based notification).
    expect(android['priority'], Priority.defaultPriority.value);
  });
}

/// `schedule()` cancels the retired WorkManager tag before handing delivery to
/// Android's own notification scheduler. WorkManager has no VM implementation,
/// so only that single call needs neutralising; every other platform method
/// already has a safe default on the base class.
final class _NoopWorkmanagerPlatform extends WorkmanagerPlatform {
  @override
  Future<void> cancelByTag(String tag) async {}
}
