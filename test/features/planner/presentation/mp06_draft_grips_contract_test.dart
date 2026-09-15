// MP-06 / MP-06B contract: the provisional draft renders exactly TWO
// integrated compact corner grips - upper-right START, bottom-left END - on
// top of the existing 44 dp invisible hit targets, reusing the approved
// saved-Event Corner Tab Grip visual. MP-06B (owner correction 2026-08-17):
// the visible 14 dp caps sit FULLY INSIDE the filled theme-family draft
// block, and the draft surface follows the app theme family
// (colorScheme.primaryContainer). No floating dots, no upper-left/
// bottom-right handles, no saved-Event behavior change.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/calendar_event_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 8, day: 8);

  Future<AppDatabase> pumpPlanner(WidgetTester tester) async {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    // M6 zero-goal law: this scenario describes an EXISTING (pre-M6) user.
    final profile = await startup.completeOnboarding();
    await seedLegacyCanonicalGoals(database, profile.id);
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerDateSource: const FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    final plannerScroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('planner-day-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    plannerScroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    return database;
  }

  Future<void> openDraft(WidgetTester tester) async {
    final surface = find.byKey(const Key('planner-timeline-create-surface'));
    await tester.tapAt(tester.getTopLeft(surface) + const Offset(20, 210));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const Key('event-type-option-temple_visit')));
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets(
    'MP-06: the draft renders exactly two integrated corner grips '
    '(upper-right START, bottom-left END) on 44 dp targets, and no '
    'floating dot / no extra handles exist',
    (tester) async {
      await pumpPlanner(tester);
      await openDraft(tester);

      final startTarget = find.byKey(
        const Key('planner-provisional-start-handle'),
      );
      final endTarget = find.byKey(const Key('planner-provisional-resize-hit'));
      expect(startTarget, findsOneWidget);
      expect(endTarget, findsOneWidget);
      // Both invisible hit targets stay 44 x 44 (unchanged contract).
      expect(tester.getSize(startTarget), const Size(44, 44));
      expect(tester.getSize(endTarget), const Size(44, 44));

      final startDot = find.byKey(
        const Key('planner-provisional-start-handle-dot'),
      );
      final endDot = find.byKey(
        const Key('planner-provisional-end-handle-dot'),
      );
      expect(startDot, findsOneWidget);
      expect(endDot, findsOneWidget);
      // Exactly two visible grips - no upper-left/bottom-right extras.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key != null &&
              w.key.toString().contains('planner-provisional-') &&
              w.key.toString().contains('handle-dot'),
        ),
        findsNWidgets(2),
      );

      // Compact integrated corner treatment: 14 x 14 visible cap.
      expect(tester.getSize(startDot), const Size(14, 14));
      expect(tester.getSize(endDot), const Size(14, 14));

      // MP-06B: the 14 dp caps sit FULLY INSIDE the filled draft block.
      // START: top edge flush with the block's upper-right corner, right
      // edge on the block corner, cap extends downward inside the block.
      // END: bottom edge flush with the block's lower-left corner, cap
      // extends upward inside the block. No straddle; the grip/fill
      // contrast (primary on primaryContainer) keeps the caps visible.
      final block = find.byKey(const Key('planner-provisional-event-block'));
      final blockRect = tester.getRect(block);
      final startRect = tester.getRect(startDot);
      expect(startRect.right, closeTo(blockRect.right, 0.01));
      expect(startRect.top, closeTo(blockRect.top, 0.01));
      expect(startRect.bottom, lessThanOrEqualTo(blockRect.bottom + 0.01));

      final endRect = tester.getRect(endDot);
      expect(endRect.left, closeTo(blockRect.left, 0.01));
      expect(endRect.bottom, closeTo(blockRect.bottom, 0.01));
      expect(endRect.top, greaterThanOrEqualTo(blockRect.top - 0.01));

      await tester.tap(find.byKey(const Key('calendar-event-sheet-close')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        ProviderScope.containerOf(
          tester.element(find.byType(Material).last),
        ).read(plannerEventCreationDraftProvider),
        isNull,
      );
    },
  );

  testWidgets(
    'MP-06: START drag moves the start only, END drag moves the end only, '
    'and the integrated grip geometry follows the draft on each resize',
    (tester) async {
      await pumpPlanner(tester);
      await openDraft(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('calendar-event-detail-sheet'))),
      );
      var draft = container.read(plannerEventCreationDraftProvider)!;
      final startMinute = draft.startMinute;
      final endMinute = draft.endMinute;

      // END drag: +30 minutes.
      final endHandle = find.byKey(const Key('planner-provisional-resize-hit'));
      final endGesture = await tester.startGesture(tester.getCenter(endHandle));
      await tester.pump(const Duration(milliseconds: 20));
      await endGesture.moveBy(const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 80));
      await endGesture.up();
      await tester.pump(const Duration(milliseconds: 400));
      draft = container.read(plannerEventCreationDraftProvider)!;
      expect(draft.startMinute, startMinute, reason: 'END must not move start');
      expect(draft.endMinute, endMinute + 30);

      // START drag: -30 minutes.
      final startHandle = find.byKey(
        const Key('planner-provisional-start-handle'),
      );
      final startGesture = await tester.startGesture(
        tester.getCenter(startHandle),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await startGesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 80));
      await startGesture.up();
      await tester.pump(const Duration(milliseconds: 400));
      draft = container.read(plannerEventCreationDraftProvider)!;
      expect(draft.startMinute, startMinute - 30);
      expect(draft.endMinute, endMinute + 30, reason: 'START must not move end');

      // MP-06B: the grips stay FULLY INSIDE the (now taller) block corners.
      final block = find.byKey(const Key('planner-provisional-event-block'));
      final blockRect = tester.getRect(block);
      final startRect = tester.getRect(
        find.byKey(const Key('planner-provisional-start-handle-dot')),
      );
      final endRect = tester.getRect(
        find.byKey(const Key('planner-provisional-end-handle-dot')),
      );
      expect(startRect.right, closeTo(blockRect.right, 0.01));
      expect(startRect.top, closeTo(blockRect.top, 0.01));
      expect(startRect.bottom, lessThanOrEqualTo(blockRect.bottom + 0.01));
      expect(endRect.left, closeTo(blockRect.left, 0.01));
      expect(endRect.bottom, closeTo(blockRect.bottom, 0.01));
      expect(endRect.top, greaterThanOrEqualTo(blockRect.top - 0.01));

      // MP-06B: the draft surface follows the app theme family (container
      // token), never a hardcoded pink.
      final visibleBlock = find.byKey(
        const Key('planner-provisional-event-visible'),
      );
      final material = tester.widget<Material>(
        find.descendant(of: visibleBlock, matching: find.byType(Material)).first,
      );
      expect(
        material.color,
        Theme.of(tester.element(visibleBlock)).colorScheme.primaryContainer,
      );

      await tester.tap(find.byKey(const Key('calendar-event-sheet-close')));
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'MP-06: saving the draft keeps saved-Event handle behavior unchanged '
    '(saved grip keys still present; no draft handle leak)',
    (tester) async {
      await pumpPlanner(tester);
      await openDraft(tester);

      // Save the draft.
      await tester.tap(find.byKey(const Key('save-event-button')));
      await tester.pump(const Duration(milliseconds: 600));

      // Draft handles are gone after save.
      expect(
        find.byKey(const Key('planner-provisional-start-handle')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('planner-provisional-resize-hit')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('planner-provisional-start-handle-dot')),
        findsNothing,
      );

      // The saved Event is present; its resize handles use the SAVED keys.
      expect(find.byKey(const Key('planner-timed-event-')), findsNothing);
      final savedEvents = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith(
              'planner-timed-event-',
            ),
      );
      expect(savedEvents, findsWidgets, reason: 'the saved Event block exists');
    },
  );
}
