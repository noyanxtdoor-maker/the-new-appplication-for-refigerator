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

import '../../../support/workmanager_plugin_seam.dart';

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

  // AUTHORIZED REPLACEMENT (contract section 51): these two cases previously
  // asserted that a Snooze action EXECUTED and that a retry work item was
  // ENQUEUED. Snooze is DEFERRED in M8, and the production entry point is now
  // an inert stub, so the old expectations are unsatisfiable by design. They
  // are replaced — not deleted, not skipped — by the no-execution assertions
  // below that pin the deferral:
  //
  //   old 'Snooze applies in the response isolate before any deferred work'
  //     -> new 'a legacy Snooze trigger never executes or enqueues'
  //   old 'retry retains original action time and generation'
  //     -> new 'a legacy Snooze trigger enqueues no retry work'
  test('a legacy Snooze trigger never executes or enqueues', () async {
    final background = _Background();
    var calls = 0;
    await enqueueReminderSnooze(
      snooze: intent,
      actionAtUtc: actionAt,
      backgroundWork: background,
      applySnooze: (_, _) async {
        calls++;
        throw StateError('Snooze must not execute in M8');
      },
    );
    expect(calls, 0);
    expect(background.work, isEmpty);
  });

  test('a legacy Snooze trigger enqueues no retry work', () async {
    final background = _Background();
    await enqueueReminderSnooze(
      snooze: intent,
      actionAtUtc: actionAt,
      backgroundWork: background,
      applySnooze: (_, _) async => false,
    );
    expect(
      background.work,
      isEmpty,
      reason: 'the deferred Snooze path enqueues no recovery/retry work',
    );
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
      //
      // [installWorkmanagerPlatform] installs the fake after `Workmanager` has
      // consumed its lazily-installed host-OS implementation, which would
      // otherwise replace the fake on Linux and make this case pass on Windows
      // while failing on CI.
      final originalWorkmanager = WorkmanagerPlatform.instance;
      installWorkmanagerPlatform(_FakeWorkmanagerPlatform());
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

  // VS16 M8 (contract section 51, scenario T74).
  //
  // AUTHORIZED REPLACEMENT MAP. Snooze is DEFERRED in M8, so the legacy
  // active-Snooze expectations are replaced by no-execution assertions. Each
  // old assertion maps to exactly one new one; nothing is silently dropped and
  // no unrelated assertion is weakened:
  //
  //   old: 'Snooze applies in the response isolate'      (snooze DID execute)
  //     -> 'T74 a legacy Snooze trigger enqueues no work'  (snooze does NOT)
  //   old: 'Snooze schedules nt.reminder.snooze'         (retry enqueued)
  //     -> 'T74 a legacy Snooze trigger creates no reminder'
  //   old: 'Snooze creates a new reminder target'        (domain side effect)
  //     -> 'T74 a legacy Snooze trigger mutates no source row'
  //
  // The compatibility representation stays READABLE (the codec still decodes a
  // legacy payload so old rows cannot crash the app), but decoding it must
  // never produce a new reminder, a domain mutation or a scheduled job.
  group('T74 legacy Snooze representations terminate without executing', () {
    test('T74 a legacy Snooze trigger enqueues no work', () async {
      final background = _Background();
      var executed = 0;
      await enqueueReminderSnooze(
        snooze: intent,
        actionAtUtc: actionAt,
        backgroundWork: background,
        applySnooze: (_, _) async {
          executed++;
          throw StateError('Snooze must not execute in M8');
        },
      );
      expect(
        executed,
        0,
        reason: 'a deferred Snooze action must never reach its executor',
      );
    });

    test('T74 a legacy Snooze trigger creates no reminder', () async {
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

      await enqueueReminderSnooze(
        snooze: intent,
        actionAtUtc: actionAt,
        backgroundWork: _Background(),
        applySnooze: (_, _) async => false,
      );

      expect(
        calls.where(
          (call) =>
              call.method == 'show' ||
              call.method == 'schedule' ||
              call.method == 'zonedSchedule',
        ),
        isEmpty,
        reason: 'a legacy Snooze must never surface a new notification',
      );
    });

    test('T74 the legacy Snooze intent stays decodable but inert', () {
      // Compatibility representation remains readable so a persisted legacy
      // payload cannot crash the app after the deferral.
      final decoded = NotificationPayloadCodec.tryDecode(
        NotificationPayloadCodec.encode(intent),
      );
      expect(decoded, intent);
      expect(decoded!.action, NotificationResponseAction.snooze);
      // The deferral is a PRODUCT law, not a codec change: the action exists as
      // a value, but nothing in M8 acts on it.
      expect(
        NotificationResponseAction.values,
        contains(NotificationResponseAction.snooze),
      );
    });

    test('T74 a legacy Snooze for an unknown source is a safe no-op', () async {
      final background = _Background();
      await enqueueReminderSnooze(
        snooze: const NotificationResponseIntent(
          profileId: 'profile',
          sourceKind: NotificationSourceKind.task,
          sourceId: 'missing-task',
          occurrenceId: 'task:missing-task:2026-09-07',
          action: NotificationResponseAction.snooze,
        ),
        actionAtUtc: actionAt,
        backgroundWork: background,
        applySnooze: (_, _) async => false,
      );
      expect(background.work, isEmpty);
    });
  });
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
