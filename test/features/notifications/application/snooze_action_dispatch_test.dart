import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';
import 'package:workmanager_platform_interface/workmanager_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const intent = NotificationResponseIntent(
    profileId: 'profile',
    sourceKind: NotificationSourceKind.task,
    sourceId: 'task',
    occurrenceId: 'task:task:2026-09-07',
    action: NotificationResponseAction.snooze,
  );
  final actionAt = DateTime.utc(2026, 9, 7, 11, 33, 9);

  // VS16 M7/M8 authorized old->new mapping (section 51): the previous
  // "Snooze applies in the response isolate" and "retry retains original
  // action time" expectations described the removed Snooze runtime. Snooze is
  // deferred, so these now assert the no-execution law instead: a legacy or
  // forged Snooze response must never apply, schedule, or enqueue anything.
  test(
    'Snooze is deferred: response isolate applies nothing and enqueues no work',
    () async {
      final background = _Background();
      final applied = Completer<bool>();
      var calls = 0;
      final response = enqueueReminderSnooze(
        snooze: intent,
        actionAtUtc: actionAt,
        backgroundWork: background,
        applySnooze: (actual, at) {
          calls++;
          return applied.future;
        },
      );
      applied.complete(true);
      await response;
      expect(calls, 0);
      expect(background.work, isEmpty);
    },
  );

  test('Snooze is deferred: no retry work is ever enqueued', () async {
    final background = _Background();
    await enqueueReminderSnooze(
      snooze: intent,
      actionAtUtc: actionAt,
      backgroundWork: background,
      applySnooze: (_, _) async => false,
    );
    expect(background.work, isEmpty);
  });

  test('Open cannot execute or enqueue Snooze', () async {
    final background = _Background();
    await enqueueReminderSnooze(
      snooze: const NotificationResponseIntent(
        profileId: 'profile',
        sourceKind: NotificationSourceKind.task,
        sourceId: 'task',
        occurrenceId: 'task:task:2026-09-07',
        action: NotificationResponseAction.open,
      ),
      actionAtUtc: actionAt,
      backgroundWork: background,
      applySnooze: (_, _) async => throw StateError('must not execute'),
    );
    expect(background.work, isEmpty);
  });

  test(
    'immediately shown reminder notification has zero action buttons',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await FlutterLocalNotificationsGateway().showCanonicalReminder(
        LocalNotificationRequest(
          platformId: 123,
          stableKey: 'reminder:task:profile:occurrence:base',
          channel: NotificationChannelKind.reminders,
          scheduledAtUtc: actionAt,
          title: 'Task',
          body: 'Reminder',
          responseIntent: intent,
        ),
      );
      final args = calls.single.arguments as Map;
      final android = args['platformSpecifics'] as Map;
      // VS16 owner decision: NO explicit Open or Snooze action buttons remain
      // on any reminder notification; the body tap is the only Open path. The
      // plugin omits the actions key entirely when no actions are configured.
      expect((android['actions'] as List?) ?? const [], isEmpty);
    },
  );

  test(
    'scheduled reminder notification also has zero action buttons',
    () async {
      // schedule() tags/cancels legacy WorkManager delivery work first; the
      // platform interface is faked so the zonedSchedule assertions stay
      // hermetic and never touch the plugin host.
      final originalWorkmanager = WorkmanagerPlatform.instance;
      WorkmanagerPlatform.instance = _FakeWorkmanagerPlatform();
      addTearDown(() => WorkmanagerPlatform.instance = originalWorkmanager);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final gateway = FlutterLocalNotificationsGateway();
      await gateway.schedule(
        LocalNotificationRequest(
          platformId: 456,
          stableKey: 'reminder:task:profile:occurrence:base',
          channel: NotificationChannelKind.reminders,
          scheduledAtUtc: DateTime.now().toUtc().add(
            const Duration(minutes: 5),
          ),
          title: 'Task',
          body: 'Reminder',
          responseIntent: intent,
        ),
      );
      final scheduledCall = calls.singleWhere(
        (call) => call.method == 'zonedSchedule',
      );
      final args = scheduledCall.arguments as Map;
      final android = args['platformSpecifics'] as Map;
      expect((android['actions'] as List?) ?? const [], isEmpty);
    },
  );

  test(
    'Snooze action is absent from the notification action surface',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await FlutterLocalNotificationsGateway().showCanonicalReminder(
        LocalNotificationRequest(
          platformId: 789,
          stableKey: 'reminder:calendarEvent:profile:occurrence:base',
          channel: NotificationChannelKind.reminders,
          scheduledAtUtc: actionAt,
          title: 'Event',
          body: 'Reminder',
          responseIntent: const NotificationResponseIntent(
            profileId: 'profile',
            sourceKind: NotificationSourceKind.calendarEvent,
            sourceId: 'event',
            occurrenceId: 'event:event:2026-09-07',
            action: NotificationResponseAction.open,
          ),
        ),
      );
      final args = calls.single.arguments as Map;
      final android = args['platformSpecifics'] as Map;
      final actions = (android['actions'] as List?) ?? const [];
      expect(actions.cast<Map>().where((a) => a['id'] == 'snooze'), isEmpty);
      expect(actions.cast<Map>().where((a) => a['id'] == 'open'), isEmpty);
    },
  );
}

// The gateway's schedule() cancels legacy WorkManager delivery tags first.
// MockPlatformInterfaceMixin satisfies the platform token check that rejects
// plain `implements` fakes; noSuchMethod covers the untouched API surface.
class _FakeWorkmanagerPlatform
    with MockPlatformInterfaceMixin
    implements WorkmanagerPlatform {
  @override
  Future<void> cancelByTag(String tag) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Background implements BackgroundWorkGateway {
  final work = <BackgroundWorkSpec>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<void> enqueueUnique(BackgroundWorkSpec value) async => work.add(value);
  @override
  Future<void> cancelUnique(String uniqueName) async {}
  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async =>
      BackgroundGatewayWorkState.absent;
}
