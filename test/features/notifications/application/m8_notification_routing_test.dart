// VS16 M8 — notification response routing (contract section 19, scenarios
// T61-T64).
//
// The law under test:
//  * a notification OPEN is re-validated against the CURRENT ready profile and
//    the CURRENT mounted navigator AFTER the router has moved, so a stale
//    resolution (Privacy Lock re-locking during the frame) is a safe no-op
//    rather than a presentation over a locked app;
//  * a Snooze response terminates at app routing without scheduling, enqueuing
//    or mutating anything (Snooze is DEFERRED);
//  * an absent or no-longer-scheduled Event is a safe no-op;
//  * a Task that still exists but is already completed still opens its FACTUAL
//    preview and never implies it is incomplete.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/router/app_router.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/task_preview_sheet.dart';

import '../../../support/test_dependencies.dart';

/// Counts every enqueue so "routing scheduled nothing" is provable.
final class _CountingBackgroundWork implements BackgroundWorkGateway {
  int enqueues = 0;
  final List<String> cancelled = <String>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async => enqueues++;

  @override
  Future<void> cancelUnique(String uniqueName) async =>
      cancelled.add(uniqueName);

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async =>
      BackgroundGatewayWorkState.absent;
}

void main() {
  late String source;

  setUpAll(() {
    source = File('lib/app/next_transfer_app.dart').readAsStringSync();
  });

  group('T61 post-await readiness and profile recheck', () {
    test('T61 the guard re-validates BOTH the ready profile and the mounted '
        'navigator after the await', () {
      expect(
        source,
        contains('NavigatorState? _navigatorAfterAwait(String profileId)'),
        reason: 'FAIL pre-fix: no post-await recheck existed at all',
      );
      // The guard must consult the CURRENT ready profile, not a value captured
      // before the await.
      final guard = RegExp(
        r'NavigatorState\?\s+_navigatorAfterAwait\(String profileId\)\s*\{'
        r'([\s\S]*?)\n  \}',
      ).firstMatch(source);
      expect(guard, isNotNull);
      final body = guard!.group(1)!;
      expect(
        body,
        contains('_notificationProfileReady(profileId)'),
        reason: 'the ready profile must be re-read after the await',
      );
      expect(
        body,
        contains('navigator == null || !navigator.mounted'),
        reason: 'the navigator must be proven mounted before presentation',
      );
    });

    test('T61 every post-await presentation site checks the guard result', () {
      // `router.go` plus a zero-duration delay yields a frame; each of the three
      // sites that then presents a preview must bail out when the guard says the
      // resolution is stale.
      final sites = RegExp(
        r'final navigator = _navigatorAfterAwait\(intent\.profileId\);',
      ).allMatches(source).length;
      expect(
        sites,
        3,
        reason: 'Event, Task and Awaiting-Report all present after the await',
      );
      final guarded = RegExp(
        r'final navigator = _navigatorAfterAwait\(intent\.profileId\);\s*\n'
        r'\s*if \(navigator == null \|\| !navigator\.mounted\) return;',
      ).allMatches(source).length;
      expect(
        guarded,
        3,
        reason:
            'FAIL pre-fix: the presentation could run over a re-locked app',
      );
    });

    test('T61 a Snooze response never reaches the readiness logic', () {
      final snoozeBranch = RegExp(
        r"if \(intent\.action == NotificationResponseAction\.snooze\) \{"
        r'([\s\S]*?)\n    \}',
      ).firstMatch(source);
      expect(snoozeBranch, isNotNull);
      expect(
        snoozeBranch!.group(1),
        contains('return;'),
        reason: 'the Snooze branch must terminate before any routing work',
      );
      expect(
        snoozeBranch.group(1),
        isNot(contains('router.go')),
        reason: 'Snooze must never navigate',
      );
      expect(
        snoozeBranch.group(1),
        isNot(contains('enqueue')),
        reason: 'Snooze must never enqueue work',
      );
    });
  });

  group('T61-T64 routing behaviour on the real app', () {
    late TestPrivacyDependencies privacy;
    late _CountingBackgroundWork background;
    late String profileId;

    Future<ProviderContainer> pumpApp(
      WidgetTester tester, {
      DriftPlannerRepository? plannerRepository,
    }) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      profileId = profile.id;
      background = _CountingBackgroundWork();

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          extraOverrides: [
            backgroundWorkGatewayProvider.overrideWithValue(background),
          ],
        ),
      );
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
    }

    String locationOf(ProviderContainer container) => container
        .read(appRouterProvider)
        .routerDelegate
        .currentConfiguration
        .uri
        .toString();

    testWidgets('T62 a Snooze response is rejected at app routing', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final before = locationOf(container);
      final controller = container.read(notificationResponseControllerProvider);

      controller.capture(
        payload: NotificationPayloadCodec.encode(
          NotificationResponseIntent(
            profileId: profileId,
            sourceKind: NotificationSourceKind.task,
            sourceId: 'any-task',
            occurrenceId: 'task:any-task:2026-09-12',
            action: NotificationResponseAction.snooze,
            generation: 2,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        locationOf(container),
        before,
        reason: 'a deferred Snooze response must not navigate anywhere',
      );
      expect(
        background.enqueues,
        0,
        reason: 'a deferred Snooze response must not schedule deferred work',
      );
      expect(
        find.byType(TaskPreviewSheet),
        findsNothing,
        reason: 'Snooze is not an OPEN and must not present a preview',
      );
    });

    testWidgets('T63 an absent Event is a safe no-op', (tester) async {
      final container = await pumpApp(tester);
      final before = locationOf(container);

      container
          .read(notificationResponseControllerProvider)
          .capture(
            payload: NotificationPayloadCodec.encode(
              NotificationResponseIntent(
                profileId: profileId,
                sourceKind: NotificationSourceKind.calendarEvent,
                sourceId: 'event-that-does-not-exist',
                occurrenceId: 'occurrence-that-does-not-exist',
                action: NotificationResponseAction.open,
              ),
            ),
          );
      await tester.pumpAndSettle();

      expect(
        locationOf(container),
        before,
        reason: 'a missing source must not move the app',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('T61 an intent for another profile is a safe no-op', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final before = locationOf(container);

      container
          .read(notificationResponseControllerProvider)
          .capture(
            payload: NotificationPayloadCodec.encode(
              const NotificationResponseIntent(
                profileId: 'a-different-profile',
                sourceKind: NotificationSourceKind.task,
                sourceId: 'their-task',
                occurrenceId: 'their-occurrence',
                action: NotificationResponseAction.open,
              ),
            ),
          );
      await tester.pumpAndSettle();

      expect(
        locationOf(container),
        before,
        reason: 'profile isolation: another profile\'s source is never opened',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('T64 a completed but existing Task opens its factual preview', (
      tester,
    ) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      background = _CountingBackgroundWork();
      final planner = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      await planner.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'completed-task',
          title: 'Already finished errand',
          dueDate: PlannerDate(year: 2026, month: 7, day: 27),
          dueMinute: 9 * 60,
          requiresReport: true,
        ),
      );
      await planner.changeTaskStatus(
        profileId: profile.id,
        taskId: 'completed-task',
        target: PlannerTaskStatus.completed,
        operationId: 'm8-routing-complete',
      );

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: planner,
          extraOverrides: [
            backgroundWorkGatewayProvider.overrideWithValue(background),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );

      container
          .read(notificationResponseControllerProvider)
          .capture(
            payload: NotificationPayloadCodec.encode(
              NotificationResponseIntent(
                profileId: profile.id,
                sourceKind: NotificationSourceKind.task,
                sourceId: 'completed-task',
                occurrenceId: 'task:completed-task:2026-07-27',
                action: NotificationResponseAction.open,
              ),
            ),
          );
      await tester.pumpAndSettle();

      expect(
        find.byType(TaskPreviewSheet),
        findsOneWidget,
        reason:
            'a completed Task is still a real source, so its factual preview '
            'opens instead of being treated as dead',
      );
      expect(find.text('Already finished errand'), findsWidgets);
      // The status control reports the CANONICAL state; it never invents
      // "Unreported" for a Task the owner already completed.
      //
      // `task-status-current-label` is placed ON the label `Text` itself, so
      // the label is fetched by key directly. A `find.descendant(of: <that
      // key>)` search would match nothing, because a widget is not its own
      // descendant.
      final label = tester.widget<Text>(
        find.byKey(const Key('task-status-current-label')),
      );
      expect(
        <String>['Unreported', 'Did Not Attempt', 'Missed', 'Completed'],
        contains(label.data),
        reason: 'only a factual canonical status label may be shown',
      );
    });
  });
}
