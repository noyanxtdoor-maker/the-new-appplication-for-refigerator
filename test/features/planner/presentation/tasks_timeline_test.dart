// Owner law (2026-09-20) — the Tasks timeline.
//
// Pins the PMG-inspired presentation the owner approved: flat date-grouped
// timeline with a pinned date header and a rail, NEVER one large rounded card
// per Task; undated Tasks land in a final NO DUE DATE group; Completed groups
// by the canonical completion date (no schema change); the whole row stays
// tappable into the canonical Task Preview; and the screen carries an explicit
// standard back arrow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/tasks_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planning_timeline.dart';

import '../../../support/test_dependencies.dart';

PlannerTask _task({
  required String id,
  String title = 'Task',
  PlannerDate? dueDate,
  int? dueMinute,
  PlannerTaskStatus status = PlannerTaskStatus.incomplete,
  DateTime? updatedAtUtc,
}) {
  return PlannerTask(
    id: id,
    profileId: 'profile',
    title: title,
    dueDate: dueDate,
    dueMinute: dueMinute,
    status: status,
    requiresReport: false,
    createdAtUtc: DateTime.utc(2026, 9, 1),
    updatedAtUtc: updatedAtUtc ?? DateTime.utc(2026, 9, 1),
  );
}

String _labelForUtc(DateTime utc) {
  final local = utc.toLocal();
  return planningDateSectionLabel(
    PlannerDate(year: local.year, month: local.month, day: local.day),
  );
}

void main() {
  group('canonical section label', () {
    test('reads as an uppercase month, day and year', () {
      expect(
        planningDateSectionLabel(
          const PlannerDate(year: 2026, month: 9, day: 9),
        ),
        'SEP 9, 2026',
      );
      expect(
        planningDateSectionLabel(
          const PlannerDate(year: 2026, month: 1, day: 31),
        ),
        'JAN 31, 2026',
      );
    });
  });

  group('Incomplete grouping', () {
    test('same due date is ONE section holding every Task', () {
      final groups = groupIncompleteTasks(<PlannerTask>[
        _task(
          id: 'a',
          dueDate: const PlannerDate(year: 2026, month: 9, day: 7),
          dueMinute: 9 * 60,
        ),
        _task(
          id: 'b',
          dueDate: const PlannerDate(year: 2026, month: 9, day: 7),
          dueMinute: 14 * 60,
        ),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.label, 'SEP 7, 2026');
      expect(groups.single.tasks.map((task) => task.id).toList(), <String>[
        'a',
        'b',
      ]);
    });

    test('two due dates are two ordered sections', () {
      final groups = groupIncompleteTasks(<PlannerTask>[
        _task(
          id: 'later',
          dueDate: const PlannerDate(year: 2026, month: 9, day: 20),
        ),
        _task(
          id: 'earlier',
          dueDate: const PlannerDate(year: 2026, month: 9, day: 19),
        ),
      ]);
      expect(groups.map((group) => group.label).toList(), <String>[
        'SEP 19, 2026',
        'SEP 20, 2026',
      ]);
    });

    test('an undated Task stays visible in a final NO DUE DATE group', () {
      final groups = groupIncompleteTasks(<PlannerTask>[
        _task(id: 'undated'),
        _task(
          id: 'dated',
          dueDate: const PlannerDate(year: 2026, month: 9, day: 19),
        ),
      ]);
      expect(groups, hasLength(2));
      expect(groups.last.label, taskNoDueDateGroupLabel);
      expect(groups.last.tasks.single.id, 'undated');
    });

    test('a completed Task is never an incomplete Task', () {
      final groups = groupIncompleteTasks(<PlannerTask>[
        _task(
          id: 'done',
          status: PlannerTaskStatus.completed,
          dueDate: const PlannerDate(year: 2026, month: 9, day: 19),
        ),
      ]);
      expect(groups, isEmpty);
    });
  });

  group('Completed grouping', () {
    test('groups by the canonical completion date, newest first', () {
      final older = DateTime.utc(2026, 9, 5, 12);
      final newer = DateTime.utc(2026, 9, 9, 12);
      final groups = groupCompletedTasks(<PlannerTask>[
        _task(
          id: 'old',
          status: PlannerTaskStatus.completed,
          updatedAtUtc: older,
        ),
        _task(
          id: 'new',
          status: PlannerTaskStatus.completed,
          updatedAtUtc: newer,
        ),
      ]);
      expect(groups.map((group) => group.label).toList(), <String>[
        _labelForUtc(newer),
        _labelForUtc(older),
      ]);
      expect(groups.first.tasks.single.id, 'new');
    });

    test('an old completed Task is never dropped', () {
      final january = DateTime.utc(2026, 1, 5, 12);
      final groups = groupCompletedTasks(<PlannerTask>[
        _task(
          id: 'january',
          status: PlannerTaskStatus.completed,
          updatedAtUtc: january,
        ),
      ]);
      expect(groups.single.label, _labelForUtc(january));
    });
  });

  group('Tasks timeline surface', () {
    Future<DriftPlannerRepository> seed(AppDatabase database) async {
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final repository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 6, 10)),
      );
      Future<void> save({
        required String id,
        required String title,
        required PlannerDate? dueDate,
        int? dueMinute,
      }) => repository.saveTask(
        profileId: profile.id,
        draft: PlannerTaskDraft(
          id: id,
          title: title,
          dueDate: dueDate,
          dueMinute: dueMinute,
          requiresReport: false,
        ),
      );

      await save(
        id: 'timed-task',
        title: 'Call ward clerk',
        dueDate: const PlannerDate(year: 2026, month: 9, day: 7),
        dueMinute: 9 * 60,
      );
      await save(
        id: 'date-only-task',
        title: 'Date only task',
        dueDate: const PlannerDate(year: 2026, month: 9, day: 7),
      );
      await save(id: 'undated-task', title: 'Undated follow-up', dueDate: null);
      await save(
        id: 'completed-task',
        title: 'Completed long ago',
        dueDate: const PlannerDate(year: 2026, month: 1, day: 5),
        dueMinute: 8 * 60,
      );
      await repository.changeTaskStatus(
        profileId: profile.id,
        taskId: 'completed-task',
        target: PlannerTaskStatus.completed,
        operationId: 'complete-old-task',
      );
      return repository;
    }

    Future<void> openTasks(WidgetTester tester, AppDatabase database) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final privacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: buildTestRepository(
            database: database,
            privacyGate: privacy.gate,
          ),
          plannerRepository: await seed(database),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-tasks')));
      await tester.pumpAndSettle();
    }

    testWidgets('renders the pinned date timeline, never a card per Task', (
      tester,
    ) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await openTasks(tester, database);

      // Both same-day Tasks share ONE date section; the undated Task has its own.
      expect(find.text('SEP 7, 2026'), findsOneWidget);
      expect(find.text(taskNoDueDateGroupLabel), findsOneWidget);

      // Pinned headers, not plain section rows.
      final headers = tester
          .widgetList<SliverPersistentHeader>(
            find.byType(SliverPersistentHeader),
          )
          .toList();
      expect(headers, isNotEmpty);
      expect(headers.every((header) => header.pinned), isTrue);

      // The accepted large rounded card presentation is gone.
      expect(
        find.descendant(
          of: find.byKey(const Key('tasks-incomplete-list')),
          matching: find.byType(Card),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a timed Task shows its time and a date-only Task does not', (
      tester,
    ) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await openTasks(tester, database);

      final timedRow = find.byKey(const Key('tasks-row-timed-task'));
      final dateOnlyRow = find.byKey(const Key('tasks-row-date-only-task'));
      expect(timedRow, findsOneWidget);
      expect(dateOnlyRow, findsOneWidget);

      // A timed Task carries its due time; a date-only Task carries the title
      // ONLY — no fabricated time is ever rendered for it.
      expect(
        find.descendant(of: timedRow, matching: find.byType(Text)),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: timedRow, matching: find.text('9:00 AM')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dateOnlyRow, matching: find.byType(Text)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the whole row opens the canonical Task Preview', (
      tester,
    ) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await openTasks(tester, database);

      await tester.tap(find.byKey(const Key('tasks-row-timed-task')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('task-preview-sheet')), findsOneWidget);
      expect(find.byKey(const Key('task-detail-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the screen carries a standard back arrow', (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await openTasks(tester, database);

      expect(find.byKey(const Key('tasks-back')), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets(
      'Completed keeps an old Task and groups it by completion date',
      (tester) async {
        final database = openMemoryDatabase();
        addTearDown(database.close);
        await openTasks(tester, database);

        await tester.tap(find.byKey(const Key('tasks-tab-completed')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('tasks-row-completed-task')),
          findsOneWidget,
          reason:
              'a January completion is still findable — no retention window.',
        );
        expect(find.text('Call ward clerk'), findsNothing);
      },
    );
  });
}
