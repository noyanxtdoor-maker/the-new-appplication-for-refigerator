import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/presentation/goal_edit_screen.dart';
import 'package:rmplanner/features/goals/presentation/goal_icon_picker_screen.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/event_type_form_screen.dart';

import '../../../support/gated_event_type_repository.dart';
import '../../../support/test_dependencies.dart';

Future<void> _push<T>(WidgetTester tester, Widget child) async {
  final context = tester.element(find.byType(Scaffold).first);
  unawaited(
    Navigator.of(context).push<T>(MaterialPageRoute<T>(builder: (_) => child)),
  );
  await tester.pumpAndSettle();
}

void main() {
  const monday = PlannerDate(year: 2026, month: 7, day: 27);

  testWidgets(
    'A4: loaded Goal Edit opens assigned Event Type immediately and keeps its draft',
    (tester) async {
      tester.view.physicalSize = const Size(393, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final startup = buildTestRepository(database: database);
      final profile = await startup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
      // seeded explicitly instead of being created implicitly at onboarding.
      await seedLegacyCanonicalGoals(database, profile.id);
      final goalRepository = DriftGoalRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        identifiers: const UuidIdentifierSource(),
      );
      final goal = (await goalRepository.readActiveGoals(
        profile.id,
      )).firstWhere((candidate) => candidate.title == 'Job Applications');
      final before = await goalRepository.readProgress(
        profileId: profile.id,
        goalId: goal.id,
        today: monday,
      );
      expect(before, isNotNull);

      final delegate = DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      final assignedType =
          (await delegate.readEventTypes(profileId: profile.id)).firstWhere(
            (candidate) =>
                candidate.stableKey == goal.assignedEventTypeStableKey,
          );
      final gated = GatedEventTypeRepository(delegate)
        ..blockReadEventType = true;
      addTearDown(() async {
        gated.releaseAll();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });

      final privacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(monday),
          eventTypeRepository: gated,
        ),
      );
      await tester.pumpAndSettle();
      await _push<void>(
        tester,
        GoalEditScreen(goalId: goal.id, initialGoal: goal),
      );
      expect(find.text('Edit Goal'), findsOneWidget);
      // Contract G: the preview shows the stored Goal title as the alias
      // (the raw canonical label is never renamed in activity_types).
      expect(
        find.descendant(
          of: find.byKey(const Key('goal-assigned-event-type')),
          matching: find.text(goal.title),
        ),
        findsOneWidget,
      );
      expect(assignedType.label, isNot(goal.title));

      const draftTitle = 'Unsaved Job Search Draft';
      final titleField = find.byKey(const Key('goal-title'));
      await tester.enterText(titleField, draftTitle);
      final weeklyTarget = find.byKey(const Key('goal-period-weekly'));
      // The Edit Goal body scrollable. Resolve it from the screen's ListView so
      // it cannot drift onto the title field's inner horizontal Scrollable
      // (which is an axis-mismatched target and cannot be dragged vertically).
      final goalEditScrollable = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        weeklyTarget,
        180,
        scrollable: goalEditScrollable,
      );
      await tester.tap(
        find.descendant(
          of: weeklyTarget,
          matching: find.byTooltip('Increase Weekly Target'),
        ),
      );
      await tester.pump();
      final draftWeekly = (before!.weeklyTarget.value?.scaledValue ?? 0) + 1;
      expect(
        find.descendant(of: weeklyTarget, matching: find.text('$draftWeekly')),
        findsOneWidget,
      );

      final iconRow = find.byKey(const Key('goal-icon-choice-row'));
      await tester.scrollUntilVisible(
        iconRow,
        -180,
        scrollable: goalEditScrollable,
      );
      await tester.tap(iconRow);
      await tester.pumpAndSettle();
      final walletTile = find.byKey(const Key('goal-icon-tile-finance_wallet'));
      await tester.scrollUntilVisible(
        walletTile,
        200,
        scrollable: find
            .descendant(
              of: find.byType(GoalIconPickerScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(walletTile);
      await tester.pump();
      await tester.tap(find.byKey(const Key('goal-icon-picker-save')));
      await tester.pump();
      expect(find.text('Choose Icon'), findsNothing);
      expect(
        find.descendant(of: iconRow, matching: find.text('Pie Chart')),
        findsOneWidget,
      );

      // Contract G/T15 (reconciled to the shipped surface): the nested INLINE
      // Event Type editor was removed. The Assigned Event Type card keeps a
      // keyed draft-only control ('Edit Event Type') that opens the Goal-local
      // draft editor; it never writes the shared Event Type. The card shows the
      // Goal-title ALIAS (the draft title wins over the canonical raw label);
      // no shared Event Type write may occur and Cancel leaves the stored Goal
      // untouched.
      expect(
        find.byKey(const Key('goal-edit-event-type')),
        findsOneWidget,
        reason: 'The draft-only Event Type control is the shipped surface.',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('goal-assigned-event-type')),
          matching: find.text(draftTitle),
        ),
        findsOneWidget,
        reason: 'the preview shows the unsaved Goal title as the alias',
      );
      expect(gated.readEventTypeCalls, 0);
      expect(find.byType(EventTypeFormScreen), findsNothing);

      expect(find.text('Edit Goal'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(titleField).controller!.text,
        draftTitle,
      );
      // Edit Goal's body is a lazily-built ListView, so the weekly target row
      // is unmounted once the icon round trip scrolls it out of the viewport
      // cache. Bring it back into view before re-asserting the draft value so
      // the assertion tests the DRAFT, not the scroll position.
      // Edit Goal's body is a lazily-built ListView, so rows scrolled out of the
      // viewport are unmounted. The icon round trip leaves the list parked at
      // the icon row, so bring the Weekly Target row back into view before
      // re-asserting the draft value: the assertion must test the DRAFT, not
      // the scroll position. Dragging the ListView itself avoids drifting onto
      // the title field's inner (horizontal) Scrollable.
      for (var attempt = 0; attempt < 12; attempt++) {
        if (weeklyTarget.evaluate().isNotEmpty) break;
        await tester.drag(find.byType(ListView), const Offset(0, -200));
        await tester.pump();
      }
      expect(
        find.descendant(of: weeklyTarget, matching: find.text('$draftWeekly')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: iconRow, matching: find.text('Pie Chart')),
        findsOneWidget,
      );
      final stored = await goalRepository.readGoal(
        profileId: profile.id,
        goalId: goal.id,
      );
      expect(stored?.title, goal.title);
      expect(stored?.iconId, goal.iconId);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('A4: ID-only Event Type fallback still loads and handles missing', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
    // seeded explicitly instead of being created implicitly at onboarding.
    await seedLegacyCanonicalGoals(database, profile.id);
    final repository = DriftEventTypeRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    const custom = EventTypeDraft(
      id: 'a4-id-only-custom',
      label: 'A4 ID-only Custom',
      icon: EventTypeIcon.calendar,
      colorValue: 0xFF010204,
      reportRequiredDefault: false,
      defaultDurationMinutes: 60,
      indicatorKeys: <String>{},
    );
    await repository.saveCustomType(profileId: profile.id, draft: custom);

    final privacy = TestPrivacyDependencies(database: database);
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
      ),
    );
    await tester.pumpAndSettle();

    await _push<bool>(
      tester,
      const EventTypeFormScreen.edit(eventTypeId: 'a4-id-only-custom'),
    );
    expect(find.text('Edit Event Type'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const Key('custom-event-type-label')),
          )
          .controller!
          .text,
      custom.label,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await _push<bool>(
      tester,
      const EventTypeFormScreen.edit(eventTypeId: 'missing-a4-type'),
    );
    expect(find.text('Edit Event Type'), findsNothing);
    expect(find.byKey(const Key('home-app-bar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
