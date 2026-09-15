import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/calendar_event_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/application/planner_tap_marker_provider.dart';
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

  test('Delta 4.2D Lock 2: the generic placeholder clips its configured '
      'default duration at midnight', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(plannerTapMarkerProvider.notifier)
        .show(
          date: selected,
          startMinute: 23 * 60 + 45,
          defaultDurationMinutes: 60,
        );

    final placeholder = container.read(plannerTapMarkerProvider)!;
    expect(placeholder.startMinute, 23 * 60 + 45);
    expect(placeholder.endMinute, 24 * 60);
    expect(placeholder.endMinute - placeholder.startMinute, 15);
  });

  testWidgets(
    // Delta 4.2R R8 owner override: the configured default is 30 minutes,
    // so the generic placeholder spans exactly 30 minutes.
    'Delta 4.2D: tapping the timeline shows a generic 30-minute Event '
    'placeholder at the snapped canonical coordinates BEFORE Event Type '
    'selection, and cancel removes it without persistence',
    (tester) async {
      final database = await pumpPlanner(tester);
      expect(find.byKey(const Key('planner-tap-placeholder')), findsNothing);
      expect(
        find.byKey(const Key('planner-create-button')),
        findsOneWidget,
        reason: 'the + FAB is visible during normal Planner use',
      );

      final surface = find.byKey(const Key('planner-timeline-create-surface'));
      await tester.tapAt(tester.getTopLeft(surface) + const Offset(20, 210));
      // The placeholder must appear immediately, before the picker settles.
      await tester.pump();
      final placeholder = find.byKey(const Key('planner-tap-placeholder'));
      expect(
        placeholder,
        findsOneWidget,
        reason: 'the generic Event placeholder must appear immediately',
      );
      final gridRect = tester.getRect(
        find.byKey(const Key('planner-time-grid')),
      );
      final placeholderRect = tester.getRect(placeholder);
      expect(placeholderRect.top - gridRect.top, closeTo(210, .01));
      expect(placeholderRect.height, closeTo(30, .01));
      // R4-07: the ordinary hour gutter is compact again; the long
      // current-time label now owns an independent overlay layout.
      expect(placeholderRect.left - gridRect.left, closeTo(56, .01));
      expect(
        find.descendant(
          of: placeholder,
          matching: find.byKey(const Key('planner-tap-placeholder-title')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: placeholder, matching: find.text('Event')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('planner-tap-marker-dot')), findsNothing);
      expect(find.byKey(const Key('planner-tap-marker-label')), findsNothing);

      final placeholderContainer = ProviderScope.containerOf(
        tester.element(placeholder),
      );
      final placeholderState = placeholderContainer.read(
        plannerTapMarkerProvider,
      )!;
      expect(placeholderState.startMinute, 210);
      expect(placeholderState.endMinute, 240);
      await tester.pumpAndSettle();
      expect(find.text('Select Event Type'), findsOneWidget);
      expect(
        find.byKey(const Key('planner-tap-placeholder')),
        findsOneWidget,
        reason:
            'the placeholder remains associated with the Planner timeline '
            'behind the Event Type selector',
      );
      expect(
        find.byKey(const Key('event-type-picker-tap-marker')),
        findsNothing,
        reason:
            'the tapped-time feedback is rendered in the Planner timeline '
            'layer, never as a dot+time badge inside the selector UI',
      );
      expect(
        find.byKey(const Key('planner-create-button')),
        findsNothing,
        reason: 'the + FAB is hidden once a creation session is engaged',
      );

      await tester.tap(find.byKey(const Key('event-type-picker-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('planner-tap-placeholder')), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      expect(
        container.read(plannerEventCreationDraftProvider),
        isNull,
        reason: 'canceling the selector must not create a draft',
      );
      expect(
        container.read(plannerTapMarkerProvider),
        isNull,
        reason: 'canceling the selector must clear the placeholder',
      );
      expect(
        find.byKey(const Key('planner-create-button')),
        findsOneWidget,
        reason: 'the + FAB returns after the creation session ends',
      );
      expect(await database.select(database.calendarEvents).get(), isEmpty);
    },
  );

  testWidgets(
    'Delta 4.2D/4.2C: selecting an Event Type replaces the generic Event '
    'placeholder with '
    'the pink provisional draft with top-right start and bottom-left end '
    'handles, and the + FAB stays hidden; canceling the editor restores it',
    (tester) async {
      await pumpPlanner(tester);
      final surface = find.byKey(const Key('planner-timeline-create-surface'));
      await tester.tapAt(tester.getTopLeft(surface) + const Offset(20, 210));
      await tester.pump();
      expect(find.byKey(const Key('planner-tap-placeholder')), findsOneWidget);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('event-type-option-temple_visit')));
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byKey(const Key('planner-tap-placeholder')), findsNothing);
      expect(
        find.byKey(const Key('planner-provisional-event-block')),
        findsOneWidget,
        reason: 'the placeholder transitions into the provisional draft block',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('planner-provisional-event-block')),
          matching: find.text('Temple Visit'),
        ),
        findsNothing,
        reason: 'the type-specific provisional draft remains TIME ONLY',
      );
      expect(
        find.byKey(const Key('planner-provisional-start-handle')),
        findsOneWidget,
        reason: 'the top-right START handle is visible',
      );
      expect(
        find.byKey(const Key('planner-provisional-resize-hit')),
        findsOneWidget,
        reason: 'the bottom-left END handle is visible',
      );
      expect(
        find.byKey(const Key('planner-create-button')),
        findsNothing,
        reason: 'the + FAB stays hidden while the draft editor is open',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('calendar-event-detail-sheet'))),
      );
      expect(container.read(plannerEventCreationDraftProvider), isNotNull);

      await tester.tap(find.byKey(const Key('calendar-event-sheet-close')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(container.read(plannerEventCreationDraftProvider), isNull);
      expect(
        find.byKey(const Key('planner-provisional-event-block')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('planner-create-button')),
        findsOneWidget,
        reason: 'the + FAB returns after Cancel',
      );
    },
  );

  testWidgets('Delta 4.2C: the END handle resizes directly, the draft body '
      'moves without persistence, both handles sit fully inside, and no '
      'outline is painted', (tester) async {
    final database = await pumpPlanner(tester);
    final surface = find.byKey(const Key('planner-timeline-create-surface'));
    // 3:30 AM -> minute 210 at the default 60 px/hour density.  Early in
    // the day keeps the draft block above the initial 40% editor sheet so
    // its endpoint handles stay reachable.
    await tester.tapAt(tester.getTopLeft(surface) + const Offset(20, 210));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const Key('event-type-option-temple_visit')));
    await tester.pump(const Duration(milliseconds: 600));

    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('calendar-event-detail-sheet'))),
    );
    var draft = container.read(plannerEventCreationDraftProvider)!;
    expect(draft.startMinute, 3 * 60 + 30);
    // Delta 4.2R R9: the provisional draft uses the configured Planner
    // default (30 minutes) for timeline creation, so 3:30 AM spans to 4:00
    // AM instead of the Event Type's own default.
    expect(draft.endMinute, 4 * 60);

    // Bottom-left END handle: ordinary touch slop, then +30 minutes.
    final endHandle = find.byKey(const Key('planner-provisional-resize-hit'));
    final endGesture = await tester.startGesture(tester.getCenter(endHandle));
    await tester.pump(const Duration(milliseconds: 20));
    await endGesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 80));
    await endGesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    draft = container.read(plannerEventCreationDraftProvider)!;
    expect(
      draft.startMinute,
      3 * 60 + 30,
      reason: 'the END handle must not move the start',
    );
    expect(draft.endMinute, 4 * 60 + 30);

    // MP-06B theme-family draft surface: the provisional block fill is the
    // active appearance's primaryContainer token (Blue -> blue family,
    // Rose -> rose family) and its time text is onPrimaryContainer (unlike
    // the locked white text of saved Events).
    final visibleBlock = find.byKey(
      const Key('planner-provisional-event-visible'),
    );
    final bodyGesture = await tester.startGesture(
      tester.getCenter(visibleBlock),
    );
    await tester.pump(const Duration(milliseconds: 20));
    await bodyGesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 80));
    await bodyGesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    draft = container.read(plannerEventCreationDraftProvider)!;
    // The body drag moves both times together: start 3:30 -> 4:00 and
    // end 4:30 -> 5:00 under the 30-minute default (Delta 4.2R R9).
    expect(draft.startMinute, 4 * 60);
    expect(draft.endMinute, 5 * 60);
    expect(await database.select(database.calendarEvents).get(), isEmpty);

    expect(visibleBlock, findsOneWidget);
    final material = tester.widget<Material>(
      find.descendant(of: visibleBlock, matching: find.byType(Material)).first,
    );
    expect(
      material.color,
      Theme.of(tester.element(visibleBlock)).colorScheme.primaryContainer,
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.side, BorderSide.none);
    final visibleRect = tester.getRect(visibleBlock);
    final startDot = find.byKey(
      const Key('planner-provisional-start-handle-dot'),
    );
    final endDot = find.byKey(const Key('planner-provisional-end-handle-dot'));
    // MP-06B: the integrated corner grip is a 14 dp cap fully INSIDE the
    // filled draft block (upper-right START, bottom-left END) - START top is
    // flush with the block top, END bottom is flush with the block bottom.
    final startRect = tester.getRect(startDot);
    final endRect = tester.getRect(endDot);
    expect(startRect.right, closeTo(visibleRect.right, .01));
    expect(startRect.top, closeTo(visibleRect.top, .01));
    expect(startRect.bottom, lessThanOrEqualTo(visibleRect.bottom + 0.01));
    expect(endRect.left, closeTo(visibleRect.left, .01));
    expect(endRect.bottom, closeTo(visibleRect.bottom, .01));
    expect(endRect.top, greaterThanOrEqualTo(visibleRect.top - 0.01));
    final timeText = tester.widget<Text>(
      find
          .descendant(of: visibleBlock, matching: find.textContaining('4:00'))
          .first,
    );
    final style = timeText.style;
    expect(style?.color, isNot(Colors.white));

    await tester.tap(find.byKey(const Key('calendar-event-sheet-close')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(container.read(plannerEventCreationDraftProvider), isNull);
  });
}
