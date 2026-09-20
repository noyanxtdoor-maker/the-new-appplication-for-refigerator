// B2-FINAL-POLISH fail-first: MP-19 (Event Save -> circular check) and
// Theme Color symmetry for generic Event/drawer actions.
//
// BLUE mode: Event check + drawer selection use Blue semantic primary.
// ROSE mode: the same controls use Rose semantic primary.
// MP-19: `save-event-button` key preserved, check icon replaces the Save
// text pill, tooltip 'Save event', >=48x48 target.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/shell/global_drawer_controller.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';

import '../../../support/test_dependencies.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    required AppearanceMode appearance,
    required ThemeColorMode themeColor,
    Size size = const Size(431, 912),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startup.completeOnboarding();
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        initialAppearance: appearance,
        initialThemeColor: themeColor,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('main-bottom-navigation')),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the Calendar Event create form: Planner -> + -> New Event ->
  /// select "Other" type.
  Future<void> openEventForm(WidgetTester tester) async {
    await tapTab(tester, 'Planner');
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-calendar-event-action')));
    await tester.pumpAndSettle();
    final other = find.byKey(const Key('event-type-option-other'));
    await tester.ensureVisible(other);
    await tester.pumpAndSettle();
    await tester.tap(other);
    await tester.pumpAndSettle();
  }

  Color primaryOf(WidgetTester tester) {
    return Theme.of(
      tester.element(find.byType(Scaffold).first),
    ).colorScheme.primary;
  }

  group('MP-19 Event Save -> circular check', () {
    for (final (label, themeColor) in <(String, ThemeColorMode)>[
      ('BLUE', ThemeColorMode.blue),
      ('ROSE', ThemeColorMode.rose),
    ]) {
      testWidgets('$label: save-event-button becomes a check with '
          "'Save event' and >=48x48 target", (tester) async {
        const appearance = AppearanceMode.dark;
        await pumpApp(tester, appearance: appearance, themeColor: themeColor);
        await openEventForm(tester);

        // The key survives.
        final button = find.byKey(const Key('save-event-button'));
        expect(button, findsOneWidget);
        // The Save text pill is gone; a check glyph replaced it.
        expect(
          find.descendant(
            of: find.byKey(const Key('calendar-event-sheet-header')),
            matching: find.text('Save'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('save-event-button')),
            matching: find.byIcon(Icons.check),
          ),
          findsOneWidget,
        );
        // Accessibility: tooltip + semantic label 'Save event'.
        expect(find.byTooltip('Save event'), findsOneWidget);
        // Hit target >= 48x48.
        final size = tester.getSize(button);
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        // Semantic primary fill (Blue primary in Blue, Rose primary in Rose).
        final color = primaryOf(tester);
        final expected = switch ((appearance, themeColor)) {
          (AppearanceMode.dark, ThemeColorMode.blue) =>
            AppTheme.blueDarkPrimary,
          (AppearanceMode.dark, ThemeColorMode.rose) =>
            AppTheme.roseDarkPrimary,
          (AppearanceMode.light, ThemeColorMode.blue) =>
            AppTheme.blueLightPrimary,
          _ => AppTheme.roseLightPrimary,
        };
        expect(color, expected);
      });
    }
  });

  group('Theme Color symmetry', () {
    /// Reopens the drawer from the shell itself.
    ///
    /// Owner law (2026-09-19): the Tasks and Unreported destinations carry no
    /// hamburger, so this uses the shell's own drawer controller — the exact
    /// controller every hamburger already calls.
    Future<void> openDrawerFromShell(WidgetTester tester) async {
      final BuildContext context = tester.element(
        find.byKey(const Key('main-bottom-navigation')),
      );
      GlobalDrawerScope.of(context).open();
      await tester.pumpAndSettle();
    }

    Future<void> openDrawer(WidgetTester tester, String hamburgerKey) async {
      await tester.tap(find.byKey(Key(hamburgerKey)));
      await tester.pumpAndSettle();
    }

    testWidgets('BLUE: Event + Address action use Blue semantic primary', (
      tester,
    ) async {
      await pumpApp(
        tester,
        appearance: AppearanceMode.dark,
        themeColor: ThemeColorMode.blue,
      );
      await openEventForm(tester);
      final primary = primaryOf(tester);
      expect(primary, AppTheme.blueDarkPrimary);

      // + Address action follows the Theme Color (inherited icon color).
      // The form viewport builds rows lazily, so scroll until it exists.
      final formScrollable = find.byElementPredicate((element) {
        if (element.widget is! Scrollable || element is! StatefulElement) {
          return false;
        }
        final state = element.state;
        return state is ScrollableState &&
            state.position.viewportDimension > 100 &&
            element.findAncestorWidgetOfExactType<ListView>()?.key ==
                const Key('calendar-event-form-scroll');
      });
      final formState = tester.state<ScrollableState>(formScrollable.at(0));
      final addAddress = find.byKey(const Key('add-address-button'));
      for (var attempt = 0; attempt < 12; attempt++) {
        if (addAddress.evaluate().isNotEmpty) {
          break;
        }
        formState.position.jumpTo(
          (formState.position.pixels + 260)
              .clamp(0, formState.position.maxScrollExtent)
              .toDouble(),
        );
        await tester.pumpAndSettle();
      }
      expect(addAddress, findsOneWidget);
      await tester.ensureVisible(addAddress);
      await tester.pumpAndSettle();
      final addIcon = find.descendant(
        of: addAddress,
        matching: find.byType(Icon),
      );
      final inheritedColor = IconTheme.of(tester.element(addIcon)).color;
      expect(inheritedColor, primary);
    });

    testWidgets('BLUE: drawer selected row uses Blue primary', (tester) async {
      await pumpApp(
        tester,
        appearance: AppearanceMode.dark,
        themeColor: ThemeColorMode.blue,
      );
      final primary = primaryOf(tester);
      expect(primary, AppTheme.blueDarkPrimary);
      await openDrawer(tester, 'home-hamburger');
      await tester.tap(find.byKey(const Key('drawer-tasks')));
      await tester.pumpAndSettle();
      await openDrawerFromShell(tester);
      final selectedIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('drawer-tasks')),
          matching: find.byType(Icon),
        ),
      );
      expect(selectedIcon.color, primary);
    });

    testWidgets('ROSE: drawer selected row uses Rose primary, unselected '
        'stays neutral', (tester) async {
      await pumpApp(
        tester,
        appearance: AppearanceMode.dark,
        themeColor: ThemeColorMode.rose,
      );
      final primary = primaryOf(tester);
      expect(primary, AppTheme.roseDarkPrimary);
      await openDrawer(tester, 'home-hamburger');
      await tester.tap(find.byKey(const Key('drawer-tasks')));
      await tester.pumpAndSettle();
      await openDrawerFromShell(tester);
      final selectedIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('drawer-tasks')),
          matching: find.byType(Icon),
        ),
      );
      expect(selectedIcon.color, primary);
      // An unselected row stays neutral (not rose/blue).
      final unselectedIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('drawer-about')),
          matching: find.byType(Icon),
        ),
      );
      expect(unselectedIcon.color, isNot(primary));
    });
  });
}
