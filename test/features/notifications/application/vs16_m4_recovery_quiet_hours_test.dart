import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/notifications/application/reconcile_reminders.dart';
import 'package:rmplanner/features/notifications/application/reminder_quiet_hours.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(data.initializeTimeZones);
  test('off preserves target', () {
    final target = DateTime.utc(2026, 9, 7, 22);
    expect(
      ReminderQuietHours.delayUntilEnd(
        targetUtc: target,
        settings: const QuietHoursSettings.disabled(),
        location: tz.UTC,
      ),
      target,
    );
  });
  for (final hour in [22, 23, 0, 6]) {
    test('overnight hour $hour delays to next local 07:00', () {
      final target = DateTime.utc(2026, 9, 7, hour);
      expect(
        ReminderQuietHours.delayUntilEnd(
          targetUtc: target,
          settings: const QuietHoursSettings(
            enabled: true,
            startMinute: 1320,
            endMinute: 420,
          ),
          location: tz.UTC,
        ),
        DateTime.utc(2026, 9, hour >= 22 ? 8 : 7, 7),
      );
    });
  }
  test('end boundary is exclusive', () {
    final target = DateTime.utc(2026, 9, 7, 7);
    expect(
      ReminderQuietHours.delayUntilEnd(
        targetUtc: target,
        settings: const QuietHoursSettings(
          enabled: true,
          startMinute: 1320,
          endMinute: 420,
        ),
        location: tz.UTC,
      ),
      target,
    );
  });
  test('normal interval delays within same day', () {
    expect(
      ReminderQuietHours.delayUntilEnd(
        targetUtc: DateTime.utc(2026, 9, 7, 12),
        settings: const QuietHoursSettings(
          enabled: true,
          startMinute: 720,
          endMinute: 780,
        ),
        location: tz.UTC,
      ),
      DateTime.utc(2026, 9, 7, 13),
    );
  });
  test('zone change recomputes end from canonical wall time', () {
    final target = DateTime.utc(2026, 9, 7, 16);
    const settings = QuietHoursSettings(
      enabled: true,
      startMinute: 1320,
      endMinute: 420,
    );
    expect(
      ReminderQuietHours.delayUntilEnd(
        targetUtc: target,
        settings: settings,
        location: tz.getLocation('Asia/Singapore'),
      ),
      DateTime.utc(2026, 9, 7, 23),
    );
    expect(
      ReminderQuietHours.delayUntilEnd(
        targetUtc: target,
        settings: settings,
        location: tz.UTC,
      ),
      target,
    );
  });
  test('DST transition uses local end instead of fixed duration', () {
    expect(
      ReminderQuietHours.delayUntilEnd(
        targetUtc: DateTime.utc(2026, 3, 8, 4),
        settings: const QuietHoursSettings(
          enabled: true,
          startMinute: 1320,
          endMinute: 420,
        ),
        location: tz.getLocation('America/New_York'),
      ),
      DateTime.utc(2026, 3, 8, 11),
    );
  });
  test('overlapping triggers coalesce with one trailing pass', () async {
    final release = Completer<void>();
    var events = 0;
    var tasks = 0;
    final recovery = ReconcileReminders(
      reconcileEvents: () async {
        events++;
        if (events == 1) await release.future;
      },
      reconcileTasks: () async {
        tasks++;
      },
    );
    final first = recovery();
    await Future<void>.delayed(Duration.zero);
    final second = recovery();
    final third = recovery();
    release.complete();
    await Future.wait([first, second, third]);
    expect(events, 2);
    expect(tasks, 2);
  });
  test('failed recovery permits a later retry', () async {
    var calls = 0;
    final recovery = ReconcileReminders(
      reconcileEvents: () async {
        if (++calls == 1) throw StateError('temporary failure');
      },
      reconcileTasks: () async {},
    );
    await expectLater(recovery(), throwsStateError);
    await recovery();
    expect(calls, 2);
  });

  group('T58 the durable marker is claimed, completed and failed as ONE '
      'generation', () {
    test('T58 a mutation landing mid-pass produces exactly ONE trailing pass '
        'instead of a stale completion', () async {
      var passes = 0;
      var claims = 0;
      final completedTokens = <String>[];
      // The marker reports a NEWER dirty generation on the first completion,
      // modelling a canonical write that landed while the pass was running.
      var completeCalls = 0;
      final recovery = ReconcileReminders(
        reconcileEvents: () async {
          passes++;
        },
        reconcileTasks: () async {},
        claimRepair: () async {
          claims++;
          return 'generation-$claims';
        },
        completeRepair: (token) async {
          completedTokens.add(token);
          completeCalls++;
          // First completion says "truth changed underneath you".
          return completeCalls != 1;
        },
      );

      await recovery();

      expect(passes, 2, reason: 'exactly one trailing pass');
      expect(claims, 2, reason: 'each pass claims its OWN generation');
      expect(
        completedTokens,
        <String>['generation-1', 'generation-2'],
        reason: 'an older result never completes a newer generation',
      );
    });

    test('T58 a failed pass records its attempt against the captured '
        'generation and still rethrows', () async {
      final failures = <(String, String)>[];
      final recovery = ReconcileReminders(
        reconcileEvents: () async => throw StateError('runtime down'),
        reconcileTasks: () async {},
        claimRepair: () async => 'generation-7',
        completeRepair: (token) async {
          // A failed pass must never reach completion from the failure path.
          fail('completeRepair must not run for a failed pass');
        },
        failRepair: (token, category) async => failures.add((token, category)),
      );

      await expectLater(recovery(), throwsStateError);
      expect(failures, <(String, String)>[
        ('generation-7', ReconcileReminders.unavailableFailureCategory),
      ]);
      expect(
        ReconcileReminders.unavailableFailureCategory,
        'runtime_unavailable',
        reason: 'a persisted category is a stable technical token',
      );
    });

    test('T58 a pass with nothing dirty claims nothing and completes nothing',
        () async {
      var passes = 0;
      var completionCalls = 0;
      final recovery = ReconcileReminders(
        reconcileEvents: () async => passes++,
        reconcileTasks: () async {},
        claimRepair: () async => null,
        completeRepair: (token) async {
          completionCalls++;
          return true;
        },
      );
      await recovery();
      expect(passes, 1);
      expect(
        completionCalls,
        0,
        reason: 'no captured generation means nothing to complete',
      );
    });
  });

  group('T59 a timezone change re-derives the delayed target', () {
    const settings = QuietHoursSettings(
      enabled: true,
      startMinute: 1320,
      endMinute: 420,
    );

    test('T59 the same instant lands on different target times per zone', () {
      final target = DateTime.utc(2026, 9, 7, 16);
      // Singapore is UTC+8: 16:00 UTC is 00:00 local, inside quiet hours, so it
      // delays to 07:00 local == 23:00 UTC the same day.
      expect(
        ReminderQuietHours.delayUntilEnd(
          targetUtc: target,
          settings: settings,
          location: tz.getLocation('Asia/Singapore'),
        ),
        DateTime.utc(2026, 9, 7, 23),
      );
      // The SAME instant in UTC is 16:00 local, outside quiet hours.
      expect(
        ReminderQuietHours.delayUntilEnd(
          targetUtc: target,
          settings: settings,
          location: tz.UTC,
        ),
        target,
      );
      // Asia/Manila is also UTC+8, so it must agree with Singapore exactly.
      expect(
        ReminderQuietHours.delayUntilEnd(
          targetUtc: target,
          settings: settings,
          location: tz.getLocation('Asia/Manila'),
        ),
        DateTime.utc(2026, 9, 7, 23),
        reason: 'two zones sharing an offset must derive the same target',
      );
    });

    test('T59 re-deriving after a zone change is stable and idempotent', () {
      final target = DateTime.utc(2026, 9, 7, 16);
      final first = ReminderQuietHours.delayUntilEnd(
        targetUtc: target,
        settings: settings,
        location: tz.getLocation('Asia/Singapore'),
      );
      // Recomputing the already-delayed target must not push it further.
      final second = ReminderQuietHours.delayUntilEnd(
        targetUtc: first,
        settings: settings,
        location: tz.getLocation('Asia/Singapore'),
      );
      expect(
        second,
        first,
        reason: 'a derived target is already outside quiet hours',
      );
    });

    test('T59 a DST transition in the same zone moves the local target', () {
      // America/New_York springs forward on 2026-03-08: 04:00 UTC is 23:00 the
      // previous local day, so the delayed 07:00 local target is 11:00 UTC.
      expect(
        ReminderQuietHours.delayUntilEnd(
          targetUtc: DateTime.utc(2026, 3, 8, 4),
          settings: settings,
          location: tz.getLocation('America/New_York'),
        ),
        DateTime.utc(2026, 3, 8, 11),
      );
      // One week later the offset has shifted by an hour, so the identical
      // local target resolves to a different UTC instant.
      expect(
        ReminderQuietHours.delayUntilEnd(
          targetUtc: DateTime.utc(2026, 3, 15, 4),
          settings: settings,
          location: tz.getLocation('America/New_York'),
        ),
        DateTime.utc(2026, 3, 15, 11),
      );
    });
  });

  group('T60 coalescing never double-runs recovery', () {
    test('T60 many simultaneous triggers collapse into one pass plus one '
        'trailing pass', () async {
      final release = Completer<void>();
      var events = 0;
      var tasks = 0;
      var planning = 0;
      var orphans = 0;
      final recovery = ReconcileReminders(
        reconcileEvents: () async {
          events++;
          if (events == 1) await release.future;
        },
        reconcileTasks: () async => tasks++,
        reconcilePlanning: () async => planning++,
        reconcileOrphans: () async => orphans++,
      );

      final triggers = <Future<void>>[recovery()];
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 8; i++) {
        triggers.add(recovery());
      }
      release.complete();
      await Future.wait(triggers);

      // One in-flight pass plus exactly one trailing pass for every trigger
      // that arrived while it ran — never one pass per trigger.
      expect(events, 2);
      expect(tasks, 2);
      expect(planning, 2);
      expect(orphans, 2);
    });

    test('T60 a held trigger waits for the durable write and then runs once',
        () async {
      var events = 0;
      final recovery = ReconcileReminders(
        reconcileEvents: () async => events++,
        reconcileTasks: () async {},
      );
      final release = recovery.hold();
      final pending = recovery();
      await Future<void>.delayed(Duration.zero);
      expect(events, 0, reason: 'a held trigger must not start a pass');
      release();
      await pending;
      expect(events, 1);
    });

    test('T60 releasing a hold twice is harmless', () async {
      var events = 0;
      final recovery = ReconcileReminders(
        reconcileEvents: () async => events++,
        reconcileTasks: () async {},
      );
      final release = recovery.hold();
      release();
      release();
      await recovery();
      expect(events, 1);
    });
  });
}
