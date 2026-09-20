import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:rmplanner/app/router/route_names.dart';

/// Canonical navigation for the planning shell-child destinations (Tasks,
/// Unreported) — owner law, 2026-09-20.
///
/// Both destinations are SHELL CHILDREN reached with `go`, never `push`: the
/// accepted bottom navigation stays visible and there is exactly one shell.
/// Because `go` replaces the shell page instead of stacking one, the framework
/// cannot imply a back arrow, and a plain `Navigator.pop` has nothing to pop.
/// So the screen renders an explicit arrow and this file decides where it
/// goes:
///
///   * a genuinely stacked page (a push that really happened) is popped, which
///     returns to its logical parent;
///   * otherwise the arrow returns to the location the destination was opened
///     FROM, which is carried on the existing router state ([PlanningRouteOrigin]);
///   * with no recorded origin (cold start, deep link, notification) it falls
///     back to Home, which is a valid MainShell destination.
///
/// The origin is recorded at the moment of navigation only. It is never
/// persisted and never global, so a stale value cannot send the user
/// somewhere unrelated.
final class PlanningRouteOrigin {
  const PlanningRouteOrigin(this.location);

  /// The matched location the destination was opened from.
  final String location;
}

/// Opens [path] inside the existing shell, recording the current location as
/// the back origin.
void openPlanningDestination(BuildContext context, String path) {
  final origin = GoRouterState.of(context).matchedLocation;
  context.go(path, extra: PlanningRouteOrigin(origin));
}

/// Opens [path] with an origin captured BEFORE the caller changed the tree
/// (the drawer closes itself first, so its own context is already defunct).
void openPlanningDestinationFrom(
  BuildContext context,
  String path,
  String origin,
) {
  context.go(path, extra: PlanningRouteOrigin(origin));
}

/// The origin [path] was opened with, or null when the destination was
/// entered directly.
PlanningRouteOrigin? planningRouteOriginOf(BuildContext context) {
  final extra = GoRouterState.of(context).extra;
  return extra is PlanningRouteOrigin ? extra : null;
}

/// The canonical back action for a planning destination.
void handlePlanningBack(BuildContext context, PlanningRouteOrigin? origin) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
    return;
  }
  context.go(origin?.location ?? RoutePaths.home);
}

/// The visible standard back arrow for a planning destination.
final class PlanningBackButton extends StatelessWidget {
  const PlanningBackButton({required this.origin, super.key});

  final PlanningRouteOrigin? origin;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Back',
      onPressed: () => handlePlanningBack(context, origin),
      icon: const Icon(Icons.arrow_back),
    );
  }
}
