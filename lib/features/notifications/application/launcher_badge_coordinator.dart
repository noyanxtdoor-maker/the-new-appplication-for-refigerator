import 'package:rmplanner/core/notifications/launcher_badge_gateway.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

/// Projects the ONE canonical UNREPORTED backlog to the platform.
///
/// Owner law (2026-09-19): the summary-notification count IS the Unreported
/// hub's row count, read from the same awaiting-report source the hub uses.
/// Tasks are absent by construction — they are not Events and now have their
/// own canonical home — and upcoming Events are absent because the backlog
/// only contains ELAPSED report-required occurrences.  The launcher badge and
/// the app-status notification share this number, so the icon, the shade and
/// the in-app indicator can never disagree.
final class LauncherBadgeCoordinator {
  const LauncherBadgeCoordinator({
    required this.awaitingReports,
    required this.gateway,
  });

  final CalendarEventAwaitingReportSource awaitingReports;
  final LauncherBadgeGateway gateway;

  Future<int> refresh({
    required String profileId,
    required PlannerDate today,
    required DateTime nowUtc,
  }) async {
    final entries = await awaitingReports.readAwaitingReportEvents(
      profileId: profileId,
      today: today,
      nowUtc: nowUtc,
    );
    final count = entries.length;
    await gateway.setCount(profileId: profileId, count: count);
    return count;
  }
}
