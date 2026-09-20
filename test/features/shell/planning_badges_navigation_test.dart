// Owner law (2026-09-20) — the planning badges, the Home attention dot and the
// planning back navigation.
//
// Pins: the hamburger Tasks badge counts ONLY Incomplete Tasks (the same
// canonical set the Incomplete tab renders), the Home hamburger gets a small
// red DOT — never a number — when either Tasks or Unreported has content, the
// Messages unread dot stays independent, the hamburger and Planner entries
// reach the SAME canonical Tasks screen, that screen's back arrow returns to
// wherever the user came from, and no provider refresh lands inside a build
// phase.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';
import 'package:rmplanner/features/planner/presentation/tasks_screen.dart';
import 'package:rmplanner/features/shell/messages/application/message_providers.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';

import '../../support/test_dependencies.dart';

typedef _Seeded = ({AppDatabase database, DriftPlannerRepository repository});

Future<_Seeded> _seedTasks({
  required int incomplete,
  required int completed,
}) async {
  final database = openMemoryDatabase();
  final profile = await buildTestRepository(
    database: database,
  ).completeOnboarding();
  final repository = DriftPlannerRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 9, 6, 10)),
  );
  for (var index = 0; index < incomplete; index++) {
    await repository.saveTask(
      profileId: profile.id,
      draft: PlannerTaskDraft(
        id: 'incomplete-$index',
        title: 'Incomplete $index',
        dueDate: const PlannerDate(year: 2026, month: 9, day: 7),
        requiresReport: false,
      ),
    );
  }
  for (var index = 0; index < completed; index++) {
    await repository.saveTask(
      profileId: profile.id,
      draft: PlannerTaskDraft(
        id: 'completed-$index',
        title: 'Completed $index',
        dueDate: const PlannerDate(year: 2026, month: 9, day: 7),
        requiresReport: false,
      ),
    );
    await repository.changeTaskStatus(
      profileId: profile.id,
      taskId: 'completed-$index',
      target: PlannerTaskStatus.completed,
      operationId: 'complete-$index',
    );
  }
  return (database: database, repository: repository);
}

Future<void> _pumpApp(
  WidgetTester tester,
  _Seeded seeded, {
  bool messagesUnread = false,
  List<UnreportedEntry> unreported = const <UnreportedEntry>[],
}) async {
  tester.view.physicalSize = const Size(431, 912);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final privacy = TestPrivacyDependencies(database: seeded.database);
  await tester.pumpWidget(
    privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: buildTestRepository(
        database: seeded.database,
        privacyGate: privacy.gate,
      ),
      plannerRepository: seeded.repository,
      extraOverrides: <Override>[
        unreportedEntriesProvider.overrideWith((ref) async => unreported),
        if (messagesUnread)
          hasUnreadMessagesProvider.overrideWith((ref) => true),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openDrawer(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('home-hamburger')));
  await tester.pumpAndSettle();
}

void main() {
  test('a retired Planner presentation name can never strand the Planner', () {
    expect(
      PlannerPresentation.fromStoredName('tasks'),
      PlannerPresentation.day,
    );
    expect(
      PlannerPresentation.fromStoredName('nonsense'),
      PlannerPresentation.day,
    );
    expect(PlannerPresentation.fromStoredName(null), PlannerPresentation.day);
    expect(
      PlannerPresentation.fromStoredName('week'),
      PlannerPresentation.week,
    );
  });

  group('hamburger Tasks badge', () {
    testWidgets('counts Incomplete Tasks only', (tester) async {
      final seeded = await _seedTasks(incomplete: 3, completed: 5);
      addTearDown(seeded.database.close);
      await _pumpApp(tester, seeded);
      await openDrawer(tester);

      final badge = find.byKey(const Key('drawer-tasks-badge'));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('3')),
        findsOneWidget,
        reason: 'completed Tasks never contribute to the Tasks badge',
      );
      expect(find.textContaining('incomplete tasks'), findsNothing);
    });

    testWidgets('shows no number at all when nothing is incomplete', (
      tester,
    ) async {
      final seeded = await _seedTasks(incomplete: 0, completed: 4);
      addTearDown(seeded.database.close);
      await _pumpApp(tester, seeded);
      await openDrawer(tester);

      expect(find.byKey(const Key('drawer-tasks-badge')), findsNothing);
      expect(find.byKey(const Key('drawer-tasks')), findsOneWidget);
    });

    testWidgets('reacts to a canonical Task change without a restart', (
      tester,
    ) async {
      final seeded = await _seedTasks(incomplete: 3, completed: 0);
      addTearDown(seeded.database.close);
      await _pumpApp(tester, seeded);
      await openDrawer(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('drawer-tasks-badge')),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-hamburger'))),
      );
      await container
          .read(plannerControllerProvider.notifier)
          .changeStatus(
            taskId: 'incomplete-0',
            target: PlannerTaskStatus.completed,
            operationId: 'complete-one',
          );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('drawer-tasks-badge')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Home hamburger attention dot', () {
    testWidgets('absent when both planning destinations are empty', (
      tester,
    ) async {
      final seeded = await _seedTasks(incomplete: 0, completed: 0);
      addTearDown(seeded.database.close);
      await _pumpApp(tester, seeded);

      expect(
        find.byKey(const Key('home-hamburger-attention-dot')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('present, as a dot and never a number, with Tasks only', (
      tester,
    ) async {
      final seeded = await _seedTasks(incomplete: 2, completed: 0);
      addTearDown(seeded.database.close);
      await _pumpApp(tester, seeded);

      expect(
        find.byKey(const Key('home-hamburger-attention-dot')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('home-hamburger')),
          matching: find.text('2'),
        ),
        findsNothing,
        reason: 'the hamburger carries an attention DOT, never a count',
      );
    });

    testWidgets('present once with Unreported only', (tester) async {
      final seeded = await _seedTasks(incomplete: 0, completed: 0);
      addTearDown(seeded.database.close);
      await _pumpApp(
        tester,
        seeded,
        unreported: <UnreportedEntry>[
          UnreportedEntry(
            tab: UnreportedTab.events,
            event: _awaiting('occurrence'),
            goalId: null,
            contacts: const <UnreportedContactRef>[],
          ),
        ],
      );

      expect(
        find.byKey(const Key('home-hamburger-attention-dot')),
        findsOneWidget,
      );
    });

    testWidgets('Messages unread alone never raises the planning dot', (
      tester,
    ) async {
      final seeded = await _seedTasks(incomplete: 0, completed: 0);
      addTearDown(seeded.database.close);
      await _pumpApp(tester, seeded, messagesUnread: true);

      expect(find.byKey(const Key('home-messages-unread-dot')), findsOneWidget);
      expect(
        find.byKey(const Key('home-hamburger-attention-dot')),
        findsNothing,
      );
    });
  });

  group('planning navigation', () {
    testWidgets('drawer and Planner overflow open the SAME canonical screen', (
      tester,
    ) async {
      final seeded = await _seedTasks(incomplete: 1, completed: 0);
      addTearDown(seeded.database.close);
      await _pumpApp(tester, seeded);

      // Drawer entry.
      await openDrawer(tester);
      await tester.tap(find.byKey(const Key('drawer-tasks')));
      await tester.pumpAndSettle();
      expect(find.byType(TasksScreen), findsOneWidget);
      expect(find.byKey(const Key('tasks-tab-incomplete')), findsOneWidget);
      expect(find.byKey(const Key('planner-tasks-view')), findsNothing);

      // Its back arrow returns to the entry origin (Home) with no second shell.
      await tester.tap(find.byKey(const Key('tasks-back')));
      await tester.pumpAndSettle();
      expect(find.byType(TasksScreen), findsNothing);
      expect(find.byKey(const Key('home-title')), findsOneWidget);

      // Planner entry reaches the same screen and returns to the Planner.
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-tasks')));
      await tester.pumpAndSettle();
      expect(find.byType(TasksScreen), findsOneWidget);
      expect(find.byKey(const Key('tasks-tab-incomplete')), findsOneWidget);
      expect(find.byKey(const Key('planner-tasks-view')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('tasks-back')));
      await tester.pumpAndSettle();
      expect(find.byType(TasksScreen), findsNothing);
      expect(find.byKey(const Key('planner-selected-date')), findsOneWidget);
    });

    testWidgets('Unreported back arrow returns to the entry origin', (
      tester,
    ) async {
      final seeded = await _seedTasks(incomplete: 0, completed: 0);
      addTearDown(seeded.database.close);
      await _pumpApp(tester, seeded);

      await openDrawer(tester);
      await tester.tap(find.byKey(const Key('drawer-unreported')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unreported-tab-events')), findsOneWidget);

      await tester.tap(find.byKey(const Key('unreported-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

AwaitingReportEvent _awaiting(String id) {
  return AwaitingReportEvent(
    item: PlannerCalendarItem(
      id: id,
      eventId: 'event-$id',
      originalDate: const PlannerDate(year: 2026, month: 9, day: 19),
      title: 'Awaiting $id',
      date: const PlannerDate(year: 2026, month: 9, day: 19),
      timing: PlannerEventTiming.timed,
      state: PlannerEventState.scheduled,
      requiresReport: true,
      hasOutcomeReport: false,
    ),
    goalId: null,
    activityTypeStableKey: null,
  );
}
