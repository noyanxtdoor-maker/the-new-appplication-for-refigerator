// Owner law (2026-09-20) — Task terminal status, the Incomplete/Completed
// partition and the numbers that read it.
//
// OWNER-REPORTED DEFECT: a Task sitting in Tasks → Incomplete did not move to
// Completed after its Current Status was saved as Completed, Missed or Did Not
// Attempt, and the Tasks red number could survive with nothing incomplete left.
//
// The data-path tests below drive the REAL report transaction and then read the
// canonical universe the screen renders, so the partition, the terminal
// timestamp and the "neither tab" hole are all pinned without a widget pump.
// One live test then proves the owner's physical path end to end: the number on
// the drawer, and the Home attention dot.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/tasks_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planning_timeline.dart';
import 'package:rmplanner/features/shell/global_app_drawer.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 9, day: 21);

  String reportId(int index) =>
      '70000000-0000-4000-8000-0000000000${index.toString().padLeft(2, '0')}';

  String operationIdFor(int index) =>
      '71000000-0000-4000-8000-0000000000${index.toString().padLeft(2, '0')}';

  group('the canonical Task partition', () {
    late AppDatabase database;
    late String profileId;
    late DriftPlannerRepository planner;
    late DriftOutcomeReportingRepository reporting;
    var reportSeq = 0;

    setUp(() async {
      database = openMemoryDatabase();
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
      final clock = FixedClock(DateTime.utc(2026, 9, 21, 8));
      planner = DriftPlannerRepository(database: database, clock: clock);
      reporting = DriftOutcomeReportingRepository(
        database: database,
        clock: clock,
      );
      reportSeq = 0;
    });

    tearDown(() async {
      await database.close();
    });

    Future<void> seedTasks(int count) async {
      for (var index = 0; index < count; index += 1) {
        await planner.saveTask(
          profileId: profileId,
          draft: PlannerTaskDraft(
            id: 'task-$index',
            title: 'Fixture $index',
            dueDate: selected,
            dueMinute: (9 + index) * 60,
            requiresReport: false,
          ),
        );
      }
    }

    /// The exact transaction the Task Preview's Current Status control runs.
    Future<void> reportOutcome(String taskId, OutcomeKind outcome) async {
      final source = await reporting.readTaskSource(
        profileId: profileId,
        taskId: taskId,
      );
      reportSeq += 1;
      await reporting.submit(
        profileId: profileId,
        draft: OutcomeReportDraft(
          id: reportId(reportSeq),
          source: source!,
          activityDate: source.activityDate,
          outcome: outcome,
          contributions: const <ContributionDraft>[],
          allowUnstructuredPartial: true,
        ),
        operationId: operationIdFor(reportSeq),
      );
    }

    Future<List<PlannerTask>> universe() =>
        planner.readTaskUniverse(profileId: profileId);

    Set<String> incompleteIds(List<PlannerTask> all) => <String>{
      for (final group in groupIncompleteTasks(all))
        for (final task in group.tasks) task.id,
    };

    Set<String> completedIds(List<PlannerTask> all) => <String>{
      for (final group in groupCompletedTasks(all))
        for (final task in group.tasks) task.id,
    };

    test('TASK-TERM-1/2/3: every terminal Current Status leaves Incomplete '
        'and is findable in Completed', () async {
      for (final outcome in <OutcomeKind>[
        OutcomeKind.completedHappened,
        OutcomeKind.partiallyCompleted,
        OutcomeKind.didNotHappen,
      ]) {
        // A fresh store per outcome: each case must stand on its own rather
        // than inherit a previous case's reports.
        final fresh = openMemoryDatabase();
        final freshProfile = (await buildTestRepository(
          database: fresh,
        ).completeOnboarding()).id;
        final clock = FixedClock(DateTime.utc(2026, 9, 21, 8));
        final freshPlanner = DriftPlannerRepository(
          database: fresh,
          clock: clock,
        );
        final freshReporting = DriftOutcomeReportingRepository(
          database: fresh,
          clock: clock,
        );
        for (final id in <String>['task-0', 'task-1']) {
          await freshPlanner.saveTask(
            profileId: freshProfile,
            draft: PlannerTaskDraft(
              id: id,
              title: id,
              dueDate: selected,
              dueMinute: 9 * 60,
              requiresReport: false,
            ),
          );
        }
        final source = await freshReporting.readTaskSource(
          profileId: freshProfile,
          taskId: 'task-0',
        );
        await freshReporting.submit(
          profileId: freshProfile,
          draft: OutcomeReportDraft(
            id: reportId(1),
            source: source!,
            activityDate: source.activityDate,
            outcome: outcome,
            contributions: const <ContributionDraft>[],
            allowUnstructuredPartial: true,
          ),
          operationId: operationIdFor(1),
        );

        final all = await freshPlanner.readTaskUniverse(
          profileId: freshProfile,
        );
        expect(
          incompleteIds(all),
          <String>{'task-1'},
          reason: '${outcome.name} must leave Tasks → Incomplete.',
        );
        expect(
          completedIds(all),
          <String>{'task-0'},
          reason: '${outcome.name} must be findable in Tasks → Completed.',
        );
        await fresh.close();
      }
    });

    test('TASK-TERM-4: no Task is ever in both tabs', () async {
      await seedTasks(3);
      await reportOutcome('task-0', OutcomeKind.didNotHappen);
      await reportOutcome('task-1', OutcomeKind.completedHappened);

      final all = await universe();
      expect(incompleteIds(all).intersection(completedIds(all)), isEmpty);
      expect(incompleteIds(all), <String>{'task-2'});
      expect(completedIds(all), <String>{'task-0', 'task-1'});
    });

    test('TASK-TERM-5: no Task disappears from both tabs', () async {
      await seedTasks(3);
      await reportOutcome('task-0', OutcomeKind.partiallyCompleted);
      // A Task retired through the canonical lifecycle change (the Planner's
      // own cancel path) is terminal too, and must never vanish entirely.
      await planner.changeTaskStatus(
        profileId: profileId,
        taskId: 'task-2',
        target: PlannerTaskStatus.cancelled,
        operationId: '80000000-0000-4000-8000-000000000001',
      );

      final all = await universe();
      expect(
        incompleteIds(all).union(completedIds(all)),
        <String>{'task-0', 'task-1', 'task-2'},
        reason: 'every persisted Task is in exactly one tab.',
      );
      expect(incompleteIds(all), <String>{'task-1'});
      expect(completedIds(all), containsAll(<String>['task-0', 'task-2']));
    });

    test('a terminal report dates the Completed group by the report', () async {
      await seedTasks(1);
      await reportOutcome('task-0', OutcomeKind.didNotHappen);

      final groups = groupCompletedTasks(await universe());
      expect(groups, hasLength(1));
      expect(
        groups.single.label,
        planningDateSectionLabel(
          PlannerDate.fromDateTime(
            DateTime.utc(2026, 9, 21, 8).toLocal(),
          ),
        ),
        reason: 'the group is dated when the Task stopped awaiting action.',
      );
    });

    test('returning a Task to Unreported puts it back in Incomplete', () async {
      await seedTasks(1);
      await reportOutcome('task-0', OutcomeKind.partiallyCompleted);
      expect(completedIds(await universe()), <String>{'task-0'});

      final source = await reporting.readTaskSource(
        profileId: profileId,
        taskId: 'task-0',
      );
      await reporting.clearSubmittedStatus(
        profileId: profileId,
        source: source!,
        operationId: '80000000-0000-4000-8000-000000000002',
        correctionReason: 'Returned to Unreported.',
      );

      final all = await universe();
      expect(incompleteIds(all), <String>{'task-0'});
      expect(completedIds(all), isEmpty);
    });
  });

  // ---------------------------------------------------------------------
  // The owner's physical path: the number on the drawer and the Home dot.
  // ---------------------------------------------------------------------
  testWidgets('TASK-BADGE/TASK-REACTIVE: the Tasks number counts down live to '
      'nothing and the Home dot follows', (tester) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startupRepository = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    final profile = await startupRepository.completeOnboarding();
    final planner = DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 21, 8)),
    );
    for (var index = 0; index < 3; index += 1) {
      await planner.saveTask(
        profileId: profile.id,
        draft: PlannerTaskDraft(
          id: 'task-$index',
          title: 'Fixture $index',
          dueDate: selected,
          dueMinute: (9 + index) * 60,
          requiresReport: false,
        ),
      );
    }

    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        plannerDateSource: const FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();

    int? taskNumber() {
      final badges = tester
          .widgetList<DrawerCountBadge>(find.byType(DrawerCountBadge))
          .toList();
      return badges.isEmpty ? 0 : badges.first.count;
    }

    // TB-1 and HD-2: three open Tasks read as 3 and the Home dot is shown.
    expect(
      find.byKey(const Key('home-hamburger-attention-dot')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    expect(taskNumber(), 3);
    await tester.tapAt(const Offset(400, 500));
    await tester.pumpAndSettle();

    Future<void> openTasks() async {
      await tester.tap(find.byKey(const Key('nav-planner')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
    }

    Future<void> backHome() async {
      await tester.tap(find.byKey(const Key('tasks-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-home')));
      await tester.pumpAndSettle();
    }

    Future<void> report(String taskId, String outcome) async {
      await tester.tap(find.byKey(Key('tasks-row-$taskId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('task-status-option-$outcome')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-preview-sheet-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('tasks-row-$taskId')),
        findsNothing,
        reason: 'the row leaves Incomplete with no restart and no re-entry.',
      );
    }

    await openTasks();
    await report('task-0', 'partiallyCompleted');
    await backHome();
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    expect(taskNumber(), 2);
    await tester.tapAt(const Offset(400, 500));
    await tester.pumpAndSettle();

    await openTasks();
    await report('task-1', 'didNotHappen');
    await backHome();
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    expect(taskNumber(), 1);
    await tester.tapAt(const Offset(400, 500));
    await tester.pumpAndSettle();

    await openTasks();
    await report('task-2', 'completedHappened');
    await backHome();

    // TB-4 and HD-1: nothing is open any more, so the number is GONE — never a
    // red 0 — and the Home planning dot clears with it.
    expect(
      find.byKey(const Key('home-hamburger-attention-dot')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    expect(taskNumber(), 0);
    expect(
      find.descendant(
        of: find.byKey(const Key('drawer-tasks')),
        matching: find.text('0'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
