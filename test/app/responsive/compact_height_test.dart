import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/presentation/settings_screen.dart';

import '../../support/test_dependencies.dart';
import '../../support/view_size.dart';

/// PRE-BETA RESPONSIVE (2026-09-16) — compact-height reachability.
///
/// A ~393 dp tall window (landscape phone, short split-screen pane, or large
/// text) is the case where "content fits and actions stay reachable" is most
/// likely to fail. Android's Tier-3 `Config_Changes` requirement is that the
/// app fills the available area with NO overflow, so an overflow here is a real
/// defect rather than a cosmetic one.
void main() {
  const PlannerDate monday = PlannerDate(year: 2026, month: 7, day: 27);

  Future<void> pumpShell(
    WidgetTester tester,
    Size size, {
    double textScale = 1.0,
  }) async {
    if (textScale != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    setLogicalViewSize(tester, size);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    await startup.completeOnboarding();
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
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> goTo(WidgetTester tester, String label) async {
    await tester.tap(navigationLabelFinder(label));
    await tester.pumpAndSettle();
  }

  /// Every primary destination must render without an overflow, at every
  /// compact-height size, in both navigation presentations.
  Future<void> sweepPrimaryDestinations(
    WidgetTester tester,
    Size size, {
    double textScale = 1.0,
  }) async {
    await pumpShell(tester, size, textScale: textScale);
    expect(
      tester.takeException(),
      isNull,
      reason: 'Home overflowed at $size (textScale $textScale)',
    );

    for (final String destination in <String>['Planner', 'Contacts', 'Maps']) {
      await goTo(tester, destination);
      expect(
        tester.takeException(),
        isNull,
        reason: '$destination overflowed at $size (textScale $textScale)',
      );
      expect(
        navigationFinder(),
        findsOneWidget,
        reason: 'navigation must stay usable at $size',
      );
    }

    await goTo(tester, 'Home');
    expect(tester.takeException(), isNull);
  }

  group('compact height: landscape phone', () {
    testWidgets('primary destinations render without overflow at 874x393', (
      tester,
    ) async {
      await sweepPrimaryDestinations(tester, TestWindowSizes.phoneLandscape);
    });
  });

  group('compact height: short windows', () {
    testWidgets('primary destinations render without overflow at 800x479', (
      tester,
    ) async {
      await sweepPrimaryDestinations(
        tester,
        TestWindowSizes.compactHeightBoundary,
      );
    });

    testWidgets('primary destinations render without overflow at 540x800', (
      tester,
    ) async {
      await sweepPrimaryDestinations(tester, TestWindowSizes.compactSplit);
    });
  });

  group('text scale matrix', () {
    for (final double scale in <double>[1.0, 1.3, 1.5]) {
      testWidgets('phone portrait at text scale $scale', (tester) async {
        await sweepPrimaryDestinations(
          tester,
          TestWindowSizes.phonePortrait,
          textScale: scale,
        );
      });

      testWidgets('landscape phone at text scale $scale', (tester) async {
        await sweepPrimaryDestinations(
          tester,
          TestWindowSizes.phoneLandscape,
          textScale: scale,
        );
      });

      testWidgets('tablet portrait at text scale $scale', (tester) async {
        await sweepPrimaryDestinations(
          tester,
          TestWindowSizes.tabletPortrait,
          textScale: scale,
        );
      });
    }
  });

  group('high-risk compact-height surfaces', () {
    // NOTE ON PUMPING: the Planner runs the accepted M6 recurring
    // minute-boundary current-time ticker (planner_screen.dart
    // `_scheduleCurrentTimeTicker`). Because `pumpAndSettle` advances the fake
    // clock, that ticker keeps scheduling frames and the settle loop cannot
    // finish. Planner interactions are therefore driven with BOUNDED pumps;
    // the ticker is frozen product law and is not changed.
    Future<void> boundedSettle(WidgetTester tester) async {
      await tester.pump();
      for (int i = 0; i < 24; i += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('the Contacts filter builder stays usable', (tester) async {
      await pumpShell(tester, TestWindowSizes.phoneLandscape);
      await goTo(tester, 'Contacts');
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('contacts-filter-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('filter-builder-scroll')),
        findsOneWidget,
        reason: 'the filter builder must open on a short window',
      );
      expect(tester.takeException(), isNull);

      // The builder's category sections are INLINE accordions -- the bottom
      // sheet is reached from the quick-filter chips elsewhere, and is covered
      // directly in `compact_height_surfaces_test.dart`. The compact-height
      // risk here is an EXPANDED section growing past a 393 dp viewport, so
      // that is what is driven: expand a section that actually has options and
      // prove the last one stays reachable.
      final Finder scrollable = find.descendant(
        of: find.byKey(const Key('filter-builder-scroll')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('displayed-fields-row')),
        140,
        scrollable: scrollable,
      );
      await tester.tap(find.byKey(const Key('displayed-fields-row')));
      await tester.pumpAndSettle();

      final Finder options = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'filter-inline-option-',
            ),
      );
      expect(
        options,
        findsWidgets,
        reason: 'the inline section must expand on a short window',
      );
      expect(tester.takeException(), isNull);

      // The builder body builds all of its children, so an expanded section
      // puts the tail of its list OUTSIDE the 393 dp viewport. Reachability is
      // therefore proven by bringing it into view and hit-testing it, which
      // fails if the window cannot actually scroll to it.
      await tester.ensureVisible(options.last);
      await tester.pumpAndSettle();
      expect(
        options.last.hitTestable().evaluate(),
        isNotEmpty,
        reason: 'the last inline option must stay reachable on a short window',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Planner create overlay stays reachable and dismissable', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.phoneLandscape);
      await goTo(tester, 'Planner');
      await boundedSettle(tester);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('planner-create-button')));
      await boundedSettle(tester);
      expect(
        find.byKey(const Key('create-task-action')),
        findsOneWidget,
        reason: 'the create actions must stay reachable on a short window',
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('contextual-create-close')));
      await boundedSettle(tester);
      expect(find.byKey(const Key('contextual-create-overlay')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Task creation screen opens at compact height', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.phoneLandscape);
      await goTo(tester, 'Planner');
      await boundedSettle(tester);
      await tester.tap(find.byKey(const Key('planner-create-button')));
      await boundedSettle(tester);
      await tester.tap(find.byKey(const Key('create-task-action')));
      await boundedSettle(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the Task creation screen must not overflow at 874x393',
      );
    });
  });

  group('settings stays reachable on a short window', () {
    testWidgets('settings opens and scrolls at 874x393', (tester) async {
      await pumpShell(tester, TestWindowSizes.phoneLandscape);
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      // On a short window the drawer scrolls; the entry must still be
      // reachable and actually tappable, so it is scrolled fully into view
      // rather than merely "found".
      await tester.scrollUntilVisible(
        find.byKey(const Key('drawer-account-settings')),
        160,
        scrollable: find.descendant(
          of: find.byKey(const Key('global-app-drawer-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(
        find.byKey(const Key('drawer-account-settings')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('drawer-account-settings')));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The LAST settings row must be reachable by scrolling on a short window,
      // never clipped away behind the bottom edge.
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-start-of-week')),
        200,
        scrollable: find.descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.byKey(const Key('settings-start-of-week')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('settings-start-of-week')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
