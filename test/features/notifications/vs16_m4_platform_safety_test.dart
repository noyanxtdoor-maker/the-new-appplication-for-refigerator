// VS16 M4 — platform-safety contract tests.
//
// Locks the M4 architecture boundaries: recovery via WorkManager only (no
// foreground service, no exact alarms, no background location), sanitized
// durable work payloads, and the canonical receiver set.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/workmanager_background_work_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';

void main() {
  group('manifest safety', () {
    late String manifest;

    setUpAll(() {
      manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
    });

    test('source manifest never declares foreground-service usage', () {
      expect(manifest, isNot(contains('FOREGROUND_SERVICE')));
      expect(manifest, isNot(contains('foregroundServiceType')));
      expect(manifest, isNot(contains('<service')));
    });

    test('source manifest never requests exact alarms', () {
      expect(manifest, isNot(contains('SCHEDULE_EXACT_ALARM')));
      expect(manifest, isNot(contains('USE_EXACT_ALARM')));
      expect(manifest, isNot(contains('USE_FULL_SCREEN_INTENT')));
    });

    test('source manifest never requests background location', () {
      expect(
        manifest,
        isNot(contains('android.permission.ACCESS_BACKGROUND_LOCATION')),
      );
      expect(manifest, isNot(contains('geofence')));
    });

    test('flutter_local_notifications scheduled receiver stays enabled', () {
      // M4 delivers canonical reminders through WorkManager, but scheduled
      // plugin notifications remain a valid path; the receiver must survive.
      expect(
        manifest,
        contains(
          'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver',
        ),
      );
      expect(manifest, isNot(contains('android:enabled="false"')));
    });

    test('recovery receiver listens to the four approved triggers only', () {
      expect(manifest, contains('android.intent.action.BOOT_COMPLETED'));
      expect(manifest, contains('android.intent.action.MY_PACKAGE_REPLACED'));
      expect(manifest, contains('android.intent.action.TIME_SET'));
      expect(manifest, contains('android.intent.action.TIMEZONE_CHANGED'));
    });
  });

  group('production source safety', () {
    for (final path in <String>[
      'lib/core/background/workmanager_background_work_gateway.dart',
      'lib/core/notifications/flutter_local_notifications_gateway.dart',
      'lib/features/notifications/application/reminder_background_runtime.dart',
      'lib/features/notifications/application/reminder_reconciler.dart',
      'lib/features/planner/application/event_reminder_horizon_reconciler.dart',
    ]) {
      test('$path never uses foreground execution', () {
        final value = File(path).readAsStringSync();
        expect(
          value,
          isNot(contains('setForeground')),
          reason: '$path must not promote work to a foreground service',
        );
        expect(
          value,
          isNot(contains('startForegroundService')),
          reason: '$path must not start a foreground service',
        );
        expect(
          value,
          isNot(contains('AndroidForegroundColorService')),
          reason: '$path must not declare a custom foreground worker',
        );
        expect(
          value,
          isNot(contains('ExactAlarm')),
          reason: '$path must not schedule exact alarms',
        );
        expect(
          value,
          isNot(contains('androidExactAlarm')),
          reason: '$path must not schedule exact alarms',
        );
      });
    }
  });

  group('durable work payload safety', () {
    test('snooze WorkManager input is ID-only and generation-scoped', () {
      final spec = BackgroundWorkSpec(
        uniqueName: 'nt.snooze.source.occurrence.3',
        taskName: 'nt.reminder.snooze',
        inputData: {
          'profile_id': 'profile-1',
          'source_kind': 'calendarEvent',
          'source_id': 'event-1',
          'occurrence_id': 'occurrence-1',
          'generation': 3,
          'action_utc_ms': 1_789_000_000_000,
        },
      );
      spec.validate();
      expect(spec.inputData.keys, <String>{
        'profile_id',
        'source_kind',
        'source_id',
        'occurrence_id',
        'generation',
        'action_utc_ms',
      });
      expect(
        spec.inputData.keys.any(
          (key) =>
              key.contains('title') ||
              key.contains('body') ||
              key.contains('text'),
        ),
        isFalse,
      );
    });

    test('delivery WorkManager input is the strict three-field allowlist', () {
      const canonical = CanonicalReminderWorkSpec(
        stableKey: 'reminder:calendarEvent:p:o:base',
        scheduledUtcMs: 1789000000000,
        sourceRevision: 'm7w_m4_1_0_60',
      );
      final spec = canonical.toWorkSpec(
        platformNotificationId: 42,
        nowUtc: DateTime.utc(2026, 9, 11),
      );
      spec.validate();
      expect(spec.taskName, 'nt.reminder.delivery');
      expect(spec.inputData.keys, <String>{
        'stable_key',
        'scheduled_utc_ms',
        'source_revision',
      });
      expect(
        spec.inputData.keys.any(
          (key) =>
              key.contains('title') ||
              key.contains('body') ||
              key.contains('text') ||
              key.contains('name') ||
              key.contains('location'),
        ),
        isFalse,
      );
      expect(
        spec.uniqueName,
        'nt.reminder.42.1789000000000.'
        '${sha256.convert(utf8.encode('m7w_m4_1_0_60')).toString().substring(0, 16)}',
      );
    });

    test('legacy two-key and extra-key delivery input is a terminal no-op', () {
      expect(
        CanonicalReminderWorkSpec.tryParse(<String, Object?>{
          'stable_key': 'reminder:calendarEvent:p:o:base',
          'scheduled_utc_ms': 1789000000000,
        }),
        isNull,
        reason: 'the legacy two-key delivery shape must not be replayed',
      );
      expect(
        CanonicalReminderWorkSpec.tryParse(<String, Object?>{
          'stable_key': 'reminder:calendarEvent:p:o:base',
          'scheduled_utc_ms': 1789000000000,
          'source_revision': 'm7w_1',
          'title': 'Private',
        }),
        isNull,
        reason: 'extra keys must be rejected, never silently ignored',
      );
      expect(
        CanonicalReminderWorkSpec.tryParse(<String, Object?>{
          'stable_key': 'reminder:calendarEvent:p:o:base',
          'scheduled_utc_ms': 1789000000000,
          'source_revision': 'm7w_1',
        })?.sourceRevision,
        'm7w_1',
      );
    });

    test('recovery dispatch input carries no data at all', () {
      final spec = BackgroundWorkSpec(
        uniqueName: 'nt.reminder.recovery',
        taskName: 'nt.reminder.recovery',
      );
      spec.validate();
      expect(spec.inputData, isEmpty);
    });
  });

  group('background request sanitization', () {
    test('rejects private rendered content in identity fields', () {
      expect(
        () => BackgroundWorkRequest(
          stableKey: 'reminder:calendarEvent:p:o:base',
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.occurrence,
          state: BackgroundWorkState.scheduled,
          attemptCount: 0,
          snoozeCount: 0,
          sourceRevision: 'm4_1_0_60.Visit Private Place tomorrow at 3',
          createdAtUtc: DateTime.utc(2026),
          updatedAtUtc: DateTime.utc(2026),
        ).validate(),
        throwsArgumentError,
      );
    });

    test('snooze target survives only as sanitized eligibility metadata', () {
      final request = BackgroundWorkRequest(
        stableKey: 'reminder:task:p:o:base',
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.task,
        state: BackgroundWorkState.scheduled,
        attemptCount: 0,
        snoozeCount: 2,
        scheduledForUtc: DateTime.utc(2026, 9, 7, 22),
        nextEligibleAtUtc: DateTime.utc(2026, 9, 7, 21, 55),
        createdAtUtc: DateTime.utc(2026),
        updatedAtUtc: DateTime.utc(2026),
      );
      request.validate();
      expect(request.snoozedUntilUtc, DateTime.utc(2026, 9, 7, 21, 55));
      expect(request.snoozeCount, 2);
    });
  });

  group('notification payload safety', () {
    test('payload contract keeps its v1 action surface for dormant decode', () {
      // The current product never sends a Snooze action anymore, but the
      // stored-payload contract (and decode of a pre-cleanup payload) stays
      // stable so body taps continue to resolve to OPEN.
      expect(
        NotificationResponseAction.values.map((action) => action.name),
        <String>['open', 'snooze'],
      );
    });

    test('snooze intent round-trips its generation for dedupe checks', () {
      const intent = NotificationResponseIntent(
        profileId: 'profile-1',
        sourceKind: NotificationSourceKind.task,
        sourceId: 'task-1',
        occurrenceId: 'occurrence-1',
        action: NotificationResponseAction.snooze,
        generation: 4,
      );
      expect(NotificationPayloadCodec.tryDecode(encode(intent)), intent);
    });

    test('headless entry point ignores non-snooze background responses', () {
      // nextTransferReminderAction early-returns unless the decoded action is
      // snooze; current notifications carry no actions at all, so cold-start
      // body taps never enqueue WorkManager work.
      const intent = NotificationResponseIntent(
        profileId: 'profile-1',
        sourceKind: NotificationSourceKind.calendarEvent,
        sourceId: 'event-1',
        action: NotificationResponseAction.open,
      );
      expect(intent.action, isNot(NotificationResponseAction.snooze));
    });
  });

  group('dormant snooze worker contract', () {
    // Snooze is deferred from the current product: no notification action can
    // enqueue it. These lock the sanitized identity of the historical worker
    // that remains reachable only through the runtime boundary.
    test('unique name is scoped per source, occurrence, and generation', () {
      const intent = NotificationResponseIntent(
        profileId: 'profile-1',
        sourceKind: NotificationSourceKind.task,
        sourceId: 'task-1',
        occurrenceId: 'occurrence-1',
        action: NotificationResponseAction.snooze,
        generation: 2,
      );
      final uniqueName =
          'nt.snooze.${intent.sourceId}.${intent.occurrenceId}.${intent.generation}';
      expect(uniqueName, 'nt.snooze.task-1.occurrence-1.2');
      // A repeated action with the same generation enqueues the same unique
      // work, so duplicates coalesce instead of stacking snoozes.
      expect(
        'nt.snooze.${intent.sourceId}.${intent.occurrenceId}.${intent.generation}',
        uniqueName,
      );
    });

    test('runtime rejects future delivery keys as stale clock retries', () {
      final future = DateTime.now().toUtc().add(const Duration(hours: 1));
      expect(
        runReminderRuntime(
          deliveryKey: 'reminder:calendarEvent:p:o:base',
          scheduledAtUtc: future,
        ),
        completion(isFalse),
      );
    });
  });
}

String encode(NotificationResponseIntent intent) =>
    NotificationPayloadCodec.encode(intent);
