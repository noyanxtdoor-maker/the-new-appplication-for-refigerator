import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/planner_tap_marker_provider.dart';
import 'package:rmplanner/features/planner/application/planner_task_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 8, day: 27);

  testWidgets(
    'owner reproduction: a normal timed Task reaches PlannerDay and default Day',
    (tester) async {
      tester.view.physicalSize = const Size(862, 1824);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 27, 6)),
        calendarSource: MemoryPlannerCalendarSource(<PlannerCalendarItem>[]),
      );
      const taskId = 'owner-timed-task';
      await plannerRepository.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: taskId,
          title: 'Owner timed Task',
          dueDate: selected,
          dueMinute: 1080,
          recurrence: PlannerTaskRecurrence.none,
          requiresReport: false,
        ),
      );

      final day = await plannerRepository.readDay(
        profileId: profile.id,
        selectedDate: selected,
        today: selected,
      );
      expect(day.tasks.map((task) => task.id), contains(taskId));

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('planner-day-scroll')), findsOneWidget);
      expect(find.text('TASKS'), findsNothing);
      expect(
        find.byKey(const Key('task-footprint:owner-timed-task')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('planner-task-block-status-owner-timed-task')),
        findsOneWidget,
        reason: 'A timed Task has its factual status symbol in the block.',
      );
      expect(
        find.byKey(const Key('planner-task-block-accent-owner-timed-task')),
        findsOneWidget,
        reason:
            'A saved Task uses the Event-family accent primitive, not the legacy Task-only row.',
      );
      expect(
        find.byKey(const Key('planner-task-block-content-owner-timed-task')),
        findsOneWidget,
        reason:
            'Task title, time, density, and status use the shared Event-family content primitive.',
      );
      expect(
        find.byKey(const Key('planner-timed-event-owner-timed-task')),
        findsNothing,
      );

      final taskBlock = find.byKey(
        const Key('planner-task-block-owner-timed-task'),
      );
      await tester.ensureVisible(taskBlock);
      await tester.pumpAndSettle();
      final hold = await tester.startGesture(tester.getCenter(taskBlock));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester
            .widget<Material>(
              find.byKey(
                const Key('planner-task-block-hold-feedback-owner-timed-task'),
              ),
            )
            .elevation,
        6,
        reason:
            'A draggable saved Task enters the shared Event-family long-press activation feedback before it moves.',
      );
      expect(
        find.byKey(const Key('planner-provisional-resize-hit')),
        findsNothing,
        reason:
            'Task long-press activation must never introduce a resize target.',
      );
      await hold.up();
      await tester.pump();
      expect(
        tester
            .widget<Material>(
              find.byKey(
                const Key('planner-task-block-hold-feedback-owner-timed-task'),
              ),
            )
            .elevation,
        0,
        reason: 'Task press-hold feedback clears on release.',
      );
      await tester.tap(taskBlock);
      await tester.pumpAndSettle();
      expect(find.text('Owner timed Task'), findsWidgets);
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Date'), findsOneWidget);
      expect(find.text('Time'), findsOneWidget);
      expect(find.text('Owner timed Task'), findsWidgets);
      expect(
        find.byKey(const Key('task-activity-history-button')),
        findsOneWidget,
        reason:
            'The accepted Task Preview exposes the shared navigation row, '
            'which scopes Activity History by the Task source slot.',
      );
      await tester.tap(find.byKey(const Key('task-preview-sheet-close')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('planner-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-filter-tasks')));
      await tester.tap(find.byKey(const Key('planner-filter-apply')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('task-footprint:owner-timed-task')),
        findsNothing,
      );
      expect(find.byKey(const Key('timed-events-section')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'five overlapping timed Tasks fit the 400dp Day canvas without a RenderFlex overflow',
    (tester) async {
      tester.view.physicalSize = const Size(400, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 27, 6)),
        calendarSource: MemoryPlannerCalendarSource(<PlannerCalendarItem>[]),
      );

      for (var index = 0; index < 5; index++) {
        await plannerRepository.saveTask(
          profileId: profile.id,
          draft: PlannerTaskDraft(
            id: 'narrow-task-$index',
            title: 'Narrow Task ${index + 1}',
            dueDate: selected,
            dueMinute: 18 * 60,
            requiresReport: false,
          ),
        );
      }

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      for (var index = 0; index < 5; index++) {
        expect(
          find.byKey(Key('planner-task-block-narrow-task-$index')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('planner-task-block-status-narrow-task-$index')),
          findsOneWidget,
          reason: 'A narrow Task lane keeps its factual status symbol.',
        );
      }
      expect(
        tester.takeException(),
        isNull,
        reason: 'dense Task collision columns must never RenderFlex overflow',
      );
    },
  );

  testWidgets(
    'mixed Event and Task collision lanes keep each Task status symbol without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(400, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final event = PlannerCalendarItem(
        id: 'mixed-event',
        title: 'Mixed collision Event',
        date: selected,
        timing: PlannerEventTiming.timed,
        state: PlannerEventState.scheduled,
        requiresReport: false,
        hasOutcomeReport: false,
        startLocal: DateTime(2026, 8, 27, 18),
        endLocal: DateTime(2026, 8, 27, 19),
      );
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 27, 6)),
        calendarSource: MemoryPlannerCalendarSource(<PlannerCalendarItem>[
          event,
        ]),
      );
      for (var index = 0; index < 4; index++) {
        await plannerRepository.saveTask(
          profileId: profile.id,
          draft: PlannerTaskDraft(
            id: 'mixed-task-$index',
            title: 'Mixed Task ${index + 1}',
            dueDate: selected,
            dueMinute: 18 * 60,
            requiresReport: false,
          ),
        );
      }

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Mixed collision Event'), findsOneWidget);
      for (var index = 0; index < 4; index++) {
        expect(
          find.byKey(Key('planner-task-block-status-mixed-task-$index')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Task provisional draft synchronizes form/canvas and Cancel or Save '
    'clears only the draft at the correct boundary',
    (tester) async {
      tester.view.physicalSize = const Size(862, 1824);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 27, 6)),
        calendarSource: MemoryPlannerCalendarSource(<PlannerCalendarItem>[]),
      );

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      // Owner recording path: Planner timeline tap -> Select Event Type ->
      // Task. This is the only path that owns the transient generic Event
      // feedback block, so it proves Task selection clears that artifact while
      // retaining its canonical Planner-local draft.
      // The accepted Planner auto-scrolls the timeline to the current time, so
      // the create surface's own top-left can sit above the scroll viewport and
      // a fixed offset from it would miss the tappable timeline entirely. Reset
      // the day scroll first so the tap geometry is deterministic (the same
      // canonical setup the Delta 4.2D creation-session contract uses).
      final plannerScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('planner-day-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      plannerScroll.position.jumpTo(0);
      await tester.pumpAndSettle();

      final surface = find.byKey(const Key('planner-timeline-create-surface'));
      await tester.tapAt(tester.getTopLeft(surface) + const Offset(20, 210));
      await tester.pump();
      expect(find.byKey(const Key('planner-tap-placeholder')), findsOneWidget);
      await tester.pumpAndSettle();
      final pickerTask = find.byKey(const Key('event-type-option-task'));
      await tester.ensureVisible(pickerTask);
      await tester.tap(pickerTask);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('task-provisional-draggable-sheet')),
        findsOneWidget,
        reason:
            'the real Planner Event-Type picker Task path opens the partial '
            'production Task sheet, not a full-page Task route.',
      );
      expect(find.byKey(const Key('planner-task-draft-block')), findsOneWidget);
      expect(
        find.byKey(const Key('planner-provisional-event-visible')),
        findsOneWidget,
        reason:
            'the Task draft is rendered by the same production provisional '
            'Event block, rather than the saved Task-card primitive.',
      );
      expect(
        find.byKey(const Key('planner-tap-placeholder')),
        findsNothing,
        reason:
            'Choosing Task ends the generic Event-type selection feedback; '
            'only the Task-owned provisional block may remain.',
      );
      final taskSheetContainer = ProviderScope.containerOf(
        tester.element(
          find.byKey(const Key('task-provisional-draggable-sheet')),
        ),
      );
      expect(
        taskSheetContainer.read(plannerTapMarkerProvider),
        isNull,
        reason:
            'the transient Event marker is cleared immediately, rather than '
            'surviving until the Task editor closes.',
      );
      expect(find.text('New Task'), findsNothing);
      expect(
        find.byKey(const Key('planner-provisional-resize-hit')),
        findsNothing,
        reason:
            'the shared provisional renderer must not grant Task a resize target.',
      );
      expect(
        find.byKey(const Key('planner-create-button')),
        findsNothing,
        reason:
            'an active editor session must prevent nested Planner creation.',
      );
      expect(find.byKey(const Key('task-due-date-field')), findsNothing);
      await tester.tap(find.byKey(const Key('task-form-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('planner-task-draft-block')), findsNothing);
      expect(find.byKey(const Key('planner-create-button')), findsOneWidget);

      Future<ProviderContainer> openTaskDraft() async {
        await tester.tap(find.byKey(const Key('planner-create-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('create-task-action')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('task-provisional-draggable-sheet')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('planner-task-draft-block')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('task-due-date-field')),
          findsNothing,
          reason:
              'Planner Task creation begins as an undated form while its '
              'real provisional block is already visible.',
        );
        return ProviderScope.containerOf(
          tester.element(
            find.byKey(const Key('task-provisional-draggable-sheet')),
          ),
        );
      }

      final firstContainer = await openTaskDraft();
      final firstDraft = firstContainer.read(plannerTaskCreationDraftProvider);
      expect(firstDraft, isNotNull);
      final initialSheetBounds = tester.getRect(
        find.byKey(const Key('task-provisional-draggable-sheet')),
      );
      await tester.drag(
        find.byKey(const Key('task-form-sheet-header')),
        const Offset(0, -500),
      );
      await tester.drag(
        find.byKey(const Key('task-form-sheet-header')),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getRect(find.byKey(const Key('task-provisional-draggable-sheet')))
            .height,
        greaterThan(initialSheetBounds.height + 300),
        reason:
            'the Task form must expand from partial to the full safe-area '
            'editor extent using the production draggable sheet.',
      );
      await tester.drag(
        find.byKey(const Key('task-form-sheet-header')),
        const Offset(0, 325),
      );
      await tester.drag(
        find.byKey(const Key('task-form-sheet-header')),
        const Offset(0, 325),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getRect(find.byKey(const Key('task-provisional-draggable-sheet')))
            .height,
        lessThan(initialSheetBounds.height + 80),
        reason:
            'the same production handle collapses back to the low partial '
            'Planner sheet instead of leaving a full-screen Task form.',
      );
      expect(
        find.text('Notes: What do you need to remember about this?'),
        findsOneWidget,
        reason: 'the normal Task Notes prompt stays inside an empty field.',
      );
      expect(find.byKey(Key('task-draft:${firstDraft!.id}')), findsOneWidget);
      expect(
        find.byKey(const Key('planner-provisional-event-visible')),
        findsOneWidget,
        reason:
            'The unsaved Task draft delegates to the actual Event provisional '
            'renderer rather than a saved Task card shell.',
      );

      await tester.enterText(
        find.byKey(const Key('task-title-field')),
        'Draft stays a Task',
      );
      await tester.pumpAndSettle();
      expect(
        firstContainer.read(plannerTaskCreationDraftProvider)?.title,
        'Draft stays a Task',
      );

      // This is the same owner the Day-canvas drag updates. A late-day valid
      // draft must be revealed by the production Planner viewport while the
      // real Task form overlay remains open; a detached widget existence check
      // would miss the owner-observed physical failure.
      firstContainer
          .read(plannerTaskCreationDraftProvider.notifier)
          .updateMinute(18 * 60);
      await tester.pumpAndSettle();
      final lateDraftBlock = find.byKey(Key('task-draft:${firstDraft.id}'));
      expect(
        tester.getCenter(lateDraftBlock).dy,
        lessThan(
          tester
              .getRect(
                find.byKey(const Key('task-provisional-draggable-sheet')),
              )
              .top,
        ),
        reason:
            'the real Planner overlay must expose a late-day Task draft above '
            'the open Task form',
      );
      firstContainer
          .read(plannerTaskCreationDraftProvider.notifier)
          .updateMinute(9 * 60 + 30);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Positioned>(
              find.byKey(const Key('planner-provisional-event-visible')),
            )
            .height,
        15,
      );

      // B7 shares the saved Task/Event-family content primitive across the
      // supported phone and tablet widths. The draft keeps its truthful
      // logical 15-minute placement and never emits a layout overflow.
      for (final width in <double>[360, 400, 480, 600, 800, 1024]) {
        tester.view.physicalSize = Size(width, 912);
        tester.view.devicePixelRatio = 1;
        await tester.pump();
        expect(
          find.byKey(const Key('planner-task-draft-block')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Positioned>(
                find.byKey(const Key('planner-provisional-event-visible')),
              )
              .height,
          15,
        );
        expect(tester.takeException(), isNull);
      }

      // B7: the real provisional Task card, unlike a saved recurring Task,
      // owns an in-canvas vertical drag. The draft is still exactly fifteen
      // minutes and the open form mirrors the canonical draft owner.
      final draftBlock = find.byKey(Key('task-draft:${firstDraft.id}'));
      await tester.ensureVisible(draftBlock);
      expect(
        tester.getCenter(draftBlock).dy,
        lessThan(
          tester
              .getRect(
                find.byKey(const Key('task-provisional-draggable-sheet')),
              )
              .top,
        ),
        reason: 'the draft must remain physically reachable above the form',
      );
      final drag = await tester.startGesture(tester.getCenter(draftBlock));
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveBy(const Offset(0, -60));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(
        firstContainer.read(plannerTaskCreationDraftProvider)?.minute,
        8 * 60 + 30,
        reason: 'the fixed 15-minute Task draft moves one canonical hour up',
      );
      expect(
        find.byKey(const Key('task-due-date-field')),
        findsNothing,
        reason:
            'a provisional drag with Due Date OFF must not silently make the '
            'Task dated.',
      );
      expect(
        tester
            .widget<Positioned>(
              find.byKey(const Key('planner-provisional-event-visible')),
            )
            .height,
        15,
        reason: 'dragging changes only the due minute, never Task duration',
      );
      expect(
        find.byKey(Key('planner-top-resize-hit:task-draft:${firstDraft.id}')),
        findsNothing,
      );
      expect(
        find.byKey(Key('planner-resize-hit:task-draft:${firstDraft.id}')),
        findsNothing,
      );

      await tester.drag(
        find.byKey(const Key('task-form-sheet-header')),
        const Offset(0, -280),
      );
      await tester.pumpAndSettle();
      final dueDateSwitch = find.byKey(const Key('task-set-due-date-switch'));
      await tester.ensureVisible(dueDateSwitch);
      await tester.tap(dueDateSwitch);
      await tester.pumpAndSettle();
      expect(
        firstContainer.read(plannerTaskCreationDraftProvider)?.minute,
        8 * 60 + 30,
        reason:
            'enabling Due Date adopts the existing provisional position '
            'instead of recreating a second draft.',
      );
      expect(find.byKey(const Key('task-due-date-field')), findsOneWidget);
      expect(
        find.text('8:30 AM'),
        findsWidgets,
        reason:
            'once explicitly enabled, the Due Time field is seeded from the '
            'current provisional draft position.',
      );
      await tester.tap(dueDateSwitch);
      await tester.pumpAndSettle();
      expect(
        firstContainer.read(plannerTaskCreationDraftProvider)?.id,
        firstDraft.id,
      );
      expect(find.byKey(Key('task-draft:${firstDraft.id}')), findsOneWidget);
      expect(find.byKey(const Key('task-due-date-field')), findsNothing);

      await tester.tap(find.byKey(const Key('task-form-close')));
      await tester.pumpAndSettle();
      expect(firstContainer.read(plannerTaskCreationDraftProvider), isNull);
      expect(await database.select(database.plannerTasks).get(), isEmpty);

      final secondContainer = await openTaskDraft();
      final secondDraft = secondContainer.read(
        plannerTaskCreationDraftProvider,
      )!;
      final secondDraftDate = secondDraft.date;
      final secondDraftMinute = secondDraft.minute;
      await tester.enterText(
        find.byKey(const Key('task-title-field')),
        'Saved draft Task',
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const Key('save-task-button'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      final saved = await plannerRepository.readTask(
        profileId: profile.id,
        taskId: secondDraft.id,
      );
      expect(saved, isNotNull);
      expect(saved!.id, secondDraft.id);
      expect(saved.title, 'Saved draft Task');
      expect(
        saved.dueDate,
        secondDraftDate,
        reason:
            'a Planner-created Task must preserve its visible provisional '
            'civil date even while Set Due Date remains OFF.',
      );
      expect(
        saved.dueMinute,
        secondDraftMinute,
        reason:
            'a Planner-created Task must preserve its visible provisional '
            'minute even while Set Due Date remains OFF.',
      );
      expect(secondContainer.read(plannerTaskCreationDraftProvider), isNull);
      final savedFootprint = find.byKey(
        Key('task-footprint:${secondDraft.id}'),
      );
      expect(
        savedFootprint,
        findsOneWidget,
        reason:
            'Save clears the draft and immediately replaces it with exactly '
            'one canonical Day footprint using the same Task id.',
      );
      expect(
        tester.widget<Positioned>(savedFootprint).height,
        15,
        reason: 'a saved Planner Task remains a fixed 15-minute footprint.',
      );
      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-tasks')));
      await tester.pumpAndSettle();
      // Owner law (2026-09-20): the overflow `Tasks` row opens the ONE
      // canonical Tasks screen — there is no second Tasks list in the Planner.
      expect(find.byKey(const Key('tasks-tab-incomplete')), findsOneWidget);
      final canonicalRow = find.byKey(Key('tasks-row-${secondDraft.id}'));
      await tester.scrollUntilVisible(
        canonicalRow,
        250,
        scrollable: find.descendant(
          of: find.byKey(const Key('tasks-incomplete-list')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        canonicalRow,
        findsOneWidget,
        reason:
            'the same canonical Task remains in the canonical Tasks screen.',
      );
      expect(find.text('Saved draft Task'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'default Day renders a recurring Task once on a later matching date',
    (tester) async {
      const anchor = PlannerDate(year: 2026, month: 8, day: 27);
      const matching = PlannerDate(year: 2027, month: 8, day: 27);
      const nonMatching = PlannerDate(year: 2027, month: 8, day: 28);
      tester.view.physicalSize = const Size(862, 1824);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2027, 8, 27, 6)),
        calendarSource: MemoryPlannerCalendarSource(<PlannerCalendarItem>[]),
      );
      const taskId = 'later-yearly-task';
      await plannerRepository.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: taskId,
          title: 'Later yearly Task',
          dueDate: anchor,
          dueMinute: 1080,
          recurrence: PlannerTaskRecurrence.yearly,
          requiresReport: false,
        ),
      );

      final matchingDay = await plannerRepository.readDay(
        profileId: profile.id,
        selectedDate: matching,
        today: matching,
      );
      final nonMatchingDay = await plannerRepository.readDay(
        profileId: profile.id,
        selectedDate: nonMatching,
        today: matching,
      );
      expect(matchingDay.tasks.map((task) => task.id), contains(taskId));
      expect(
        nonMatchingDay.tasks.map((task) => task.id),
        isNot(contains(taskId)),
      );

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          plannerDateSource: const FixedPlannerDateSource(matching),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('task-footprint:later-yearly-task')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'timed Task blocks obey completion filters and never enter Event resize',
    (tester) async {
      tester.view.physicalSize = const Size(862, 1824);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 27, 6)),
        calendarSource: MemoryPlannerCalendarSource(<PlannerCalendarItem>[]),
      );
      const incompleteId = 'day-incomplete-task';
      const completedId = 'day-completed-task';
      const skippedId = 'day-skipped-task';
      const cancelledId = 'day-cancelled-task';
      const undatedId = 'day-undated-task';
      for (final draft in <PlannerTaskDraft>[
        const PlannerTaskDraft(
          id: incompleteId,
          title: 'Incomplete timed Task',
          dueDate: selected,
          dueMinute: 540,
          requiresReport: false,
        ),
        const PlannerTaskDraft(
          id: completedId,
          title: 'Completed timed Task',
          dueDate: selected,
          dueMinute: 600,
          requiresReport: false,
        ),
        const PlannerTaskDraft(
          id: skippedId,
          title: 'Skipped timed Task',
          dueDate: selected,
          dueMinute: 660,
          requiresReport: false,
        ),
        const PlannerTaskDraft(
          id: cancelledId,
          title: 'Cancelled timed Task',
          dueDate: selected,
          dueMinute: 720,
          requiresReport: false,
        ),
        const PlannerTaskDraft(
          id: undatedId,
          title: 'Undated Task',
          dueDate: null,
          requiresReport: false,
        ),
      ]) {
        await plannerRepository.saveTask(profileId: profile.id, draft: draft);
      }
      await plannerRepository.changeTaskStatus(
        profileId: profile.id,
        taskId: completedId,
        target: PlannerTaskStatus.completed,
        operationId: 'complete-day-task',
      );
      await plannerRepository.changeTaskStatus(
        profileId: profile.id,
        taskId: skippedId,
        target: PlannerTaskStatus.skipped,
        operationId: 'skip-day-task',
      );
      await plannerRepository.changeTaskStatus(
        profileId: profile.id,
        taskId: cancelledId,
        target: PlannerTaskStatus.cancelled,
        operationId: 'cancel-day-task',
      );

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      final incompleteFootprint = find.byKey(
        const Key('task-footprint:day-incomplete-task'),
      );
      expect(incompleteFootprint, findsOneWidget);
      // P1 (2026-09-21): the canvas origin is the configured start hour, so a
      // Task whose persisted dueMinute is 09:00 sits (540 - 360) minutes below
      // the canvas top at the default 06:00-22:00 window and 60dp/hour scale.
      // The persisted dueMinute itself is untouched — only the presentation
      // origin moved.
      expect(
        tester.widget<Positioned>(incompleteFootprint).top,
        180,
        reason:
            'a timed Task is anchored to its persisted dueMinute measured '
            'from the configured 06:00 canvas origin',
      );
      expect(
        tester.widget<Positioned>(incompleteFootprint).height,
        15,
        reason:
            'At the active 60dp/hour canvas scale, the 15-minute logical '
            'Task footprint occupies exactly 15dp without a Task-only floor.',
      );
      expect(
        find.byKey(const Key('task-footprint:day-completed-task')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('task-footprint:day-skipped-task')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('task-footprint:day-cancelled-task')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('task-footprint:day-undated-task')),
        findsNothing,
      );

      await tester.ensureVisible(incompleteFootprint);
      await tester.longPress(incompleteFootprint);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const Key('planner-resize-hit:task-footprint:day-incomplete-task'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key(
            'planner-top-resize-hit:task-footprint:day-incomplete-task',
          ),
        ),
        findsNothing,
      );

      // Exercise the real Day-canvas move path. The 60dp vertical movement
      // advances the default 60dp/hour grid by one hour; the production snap
      // law owns the final persisted minute.
      final taskCenter = tester.getCenter(incompleteFootprint);
      final move = await tester.startGesture(taskCenter);
      await tester.pump(const Duration(milliseconds: 600));
      await move.moveBy(const Offset(0, 60));
      await tester.pump();
      await move.up();
      await tester.pumpAndSettle();
      final moved = await plannerRepository.readTask(
        profileId: profile.id,
        taskId: incompleteId,
      );
      expect(moved, isNotNull);
      expect(moved!.id, incompleteId);
      expect(moved.title, 'Incomplete timed Task');
      expect(moved.dueDate, selected);
      expect(moved.dueMinute, 600);
      expect(moved.recurrence, PlannerTaskRecurrence.none);

      await tester.tap(find.byKey(const Key('planner-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-filter-completed-tasks')));
      await tester.tap(find.byKey(const Key('planner-filter-apply')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('task-footprint:day-incomplete-task')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('task-footprint:day-completed-task')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('planner-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-filter-tasks')));
      await tester.tap(find.byKey(const Key('planner-filter-apply')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('task-footprint:day-incomplete-task')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('task-footprint:day-completed-task')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
