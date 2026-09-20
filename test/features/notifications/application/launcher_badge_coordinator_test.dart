import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/notifications/launcher_badge_gateway.dart';
import 'package:rmplanner/features/notifications/application/launcher_badge_coordinator.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';

/// Owner law (2026-09-19): the summary notification count IS the canonical
/// Unreported hub row count.  The coordinator is fed ONLY the awaiting-report
/// backlog, so a Task or an upcoming Event can never contribute — they are
/// not in that projection at all.
void main() {
  final now = DateTime.utc(2026, 9, 6, 10);
  const today = PlannerDate(year: 2026, month: 9, day: 6);

  test('the summary count tracks the unreported backlog exactly', () async {
    final backlog = _Backlog();
    final gateway = _Badge();
    final coordinator = LauncherBadgeCoordinator(
      awaitingReports: backlog,
      gateway: gateway,
    );

    expect(
      await coordinator.refresh(
        profileId: 'profile',
        today: today,
        nowUtc: now,
      ),
      0,
    );
    expect(gateway.counts, <int>[0]);

    backlog.items = <AwaitingReportEvent>[
      _entry(now.subtract(const Duration(hours: 2))),
    ];
    expect(
      await coordinator.refresh(
        profileId: 'profile',
        today: today,
        nowUtc: now,
      ),
      1,
    );

    backlog.items = <AwaitingReportEvent>[
      _entry(now.subtract(const Duration(hours: 2))),
      _entry(now.subtract(const Duration(hours: 3))),
    ];
    expect(
      await coordinator.refresh(
        profileId: 'profile',
        today: today,
        nowUtc: now,
      ),
      2,
    );

    // The backlog draining removes the indicator entirely.
    backlog.items = const <AwaitingReportEvent>[];
    expect(
      await coordinator.refresh(
        profileId: 'profile',
        today: today,
        nowUtc: now,
      ),
      0,
    );
    expect(gateway.counts, <int>[0, 1, 2, 0]);
  });

  test('every published count carries the profile-scoped tap intent', () async {
    final gateway = _Badge();
    final coordinator = LauncherBadgeCoordinator(
      awaitingReports: _Backlog()
        ..items = <AwaitingReportEvent>[
          _entry(now.subtract(const Duration(hours: 2))),
        ],
      gateway: gateway,
    );

    await coordinator.refresh(
      profileId: 'profile-a',
      today: today,
      nowUtc: now,
    );
    await coordinator.refresh(
      profileId: 'profile-b',
      today: today,
      nowUtc: now,
    );

    // A count without its profile could never be routed on tap.
    expect(gateway.profiles, <String>['profile-a', 'profile-b']);
    expect(gateway.counts, <int>[1, 1]);
  });

  test('repeated refresh is an idempotent projection of the backlog', () async {
    final gateway = _Badge();
    final coordinator = LauncherBadgeCoordinator(
      awaitingReports: _Backlog()
        ..items = <AwaitingReportEvent>[
          _entry(now.subtract(const Duration(hours: 2))),
        ],
      gateway: gateway,
    );

    await coordinator.refresh(profileId: 'profile', today: today, nowUtc: now);
    await coordinator.refresh(profileId: 'profile', today: today, nowUtc: now);

    expect(gateway.counts, <int>[1, 1]);
  });
}

AwaitingReportEvent _entry(DateTime endUtc) => AwaitingReportEvent(
  item: PlannerCalendarItem(
    id: 'occurrence-${endUtc.hour}',
    eventId: 'event-${endUtc.hour}',
    originalDate: PlannerDate.fromDateTime(endUtc),
    title: 'Unreported event',
    date: PlannerDate.fromDateTime(endUtc),
    timing: PlannerEventTiming.timed,
    state: PlannerEventState.scheduled,
    requiresReport: true,
    hasOutcomeReport: false,
    startUtc: endUtc.subtract(const Duration(hours: 1)),
    endUtc: endUtc,
  ),
  goalId: null,
  activityTypeStableKey: null,
);

final class _Backlog implements CalendarEventAwaitingReportSource {
  List<AwaitingReportEvent> items = const <AwaitingReportEvent>[];

  @override
  Future<List<AwaitingReportEvent>> readAwaitingReportEvents({
    required String profileId,
    required PlannerDate today,
    required DateTime nowUtc,
  }) async => items;
}

final class _Badge implements LauncherBadgeGateway {
  final List<int> counts = <int>[];
  final List<String> profiles = <String>[];

  @override
  Future<void> setCount({required String profileId, required int count}) async {
    counts.add(count);
    profiles.add(profileId);
  }
}
