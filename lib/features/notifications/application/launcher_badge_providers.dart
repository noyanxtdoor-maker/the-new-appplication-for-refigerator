import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/notifications/launcher_badge_gateway.dart';
import 'package:rmplanner/features/notifications/application/launcher_badge_coordinator.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

final launcherBadgeGatewayProvider = Provider<LauncherBadgeGateway>((ref) {
  throw StateError('LauncherBadgeGateway must be overridden at the app root');
});

typedef LauncherBadgeRefresh = Future<void> Function();

/// M3 badge refresh — ONE provider-owned active full-universe refresh plus at
/// most ONE dirty-generation trailing refresh.
///
/// Law (ticket section 3):
/// - every caller invokes the SAME [launcherBadgeRefreshProvider] function;
/// - while one full-universe refresh is running, additional requests are
///   coalesced: they mark the generation dirty and share the active future;
/// - when the active refresh completes, a dirty generation triggers exactly
///   one trailing full-universe refresh (never a pile-up of queued reads);
/// - a completion from a stale generation can never publish: each generation
///   checks it is still current before contacting the gateway;
/// - the universe is ALWAYS the full 42-day Event range plus Tasks — a
///   source-scoped Event projection is never treated as the badge universe;
/// - permission/platform failures keep the exact best-effort semantics:
///   canonical persistence has already committed and is never rolled back.
final launcherBadgeRefreshProvider = Provider<LauncherBadgeRefresh>((ref) {
  var running = false;
  var dirtyGeneration = 0;
  Future<void>? active;

  Future<void> runGeneration() async {
    try {
      final startup = ref.read(startupControllerProvider);
      final calendar = ref.read(calendarEventRepositoryProvider);
      final planner = ref.read(plannerRepositoryProvider);
      if (startup is! StartupReady ||
          calendar is! CalendarEventRangeSource ||
          planner is! PlannerBadgeTaskSource) {
        return;
      }
      await LauncherBadgeCoordinator(
        calendarSource: calendar as CalendarEventRangeSource,
        taskSource: planner as PlannerBadgeTaskSource,
        gateway: ref.read(launcherBadgeGatewayProvider),
      ).refresh(
        profileId: startup.profile.id,
        today: ref.read(plannerDateSourceProvider).today(),
        nowUtc: DateTime.now().toUtc(),
      );
    } on Object {
      // Badge rendering is a best-effort platform projection. Canonical Event
      // and Task persistence has already committed and must never roll back.
    }
  }

  Future<void> refresh() async {
    if (running) {
      // Coalesce: the active pass already covers this caller; mark the
      // generation dirty so one trailing pass re-reads latest truth.
      dirtyGeneration += 1;
      return active;
    }
    running = true;
    try {
      active = runGeneration();
      final current = dirtyGeneration;
      await active;
      if (dirtyGeneration != current) {
        // Exactly ONE trailing refresh with the latest durable truth.
        dirtyGeneration = 0;
        await runGeneration();
      }
    } finally {
      running = false;
      active = null;
    }
  }

  return refresh;
});
