// VS16 M8 — background operational details inside the EXISTING diagnostic
// export preview (contract section 38, scenarios T71-T72).
//
// The law under test:
//  * M8 adds NO diagnostics page, NO new route and NO new colours. The
//    background facts reuse the preview screen that already exists;
//  * background cards are NOT collected or rendered on entry. They appear ONLY
//    after an explicit Prepare AND only while the existing operational-details
//    opt-in is ON, because reading platform work state is itself an explicit
//    owner decision;
//  * turning the opt-in OFF withdraws the cards again and does not leave a
//    stale snapshot behind;
//  * the heading keeps the established `titleMedium` / `w700` convention and
//    every card keeps the established `Card` + `ListTile` pattern.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';

import '../../../support/test_dependencies.dart';

void main() {
  /// Opens the Privacy Center → Diagnostic export preview screen through the
  /// real navigation surface so the test proves the EXISTING journey, not a
  /// directly-mounted widget.
  Future<void> openPreview(WidgetTester tester, TestPrivacyDependencies p) async {
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('drawer-account-settings')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const Key('global-app-drawer-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-account-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-privacy-data')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('diagnostic-preview-tile')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostic-preview-tile')));
    await tester.pumpAndSettle();
  }

  Future<TestPrivacyDependencies> pumpApp(WidgetTester tester) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startupRepository = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startupRepository.completeOnboarding();
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
      ),
    );
    await tester.pumpAndSettle();
    return privacy;
  }

  testWidgets(
    'T71 background cards appear only after prepare with optional details on',
    (tester) async {
      final privacy = await pumpApp(tester);
      await openPreview(tester, privacy);

      // On entry nothing has been collected: no heading, no rows.
      expect(
        find.text('Background work'),
        findsNothing,
        reason: 'entry must not collect or render background details',
      );
      expect(find.text('Background details unavailable.'), findsNothing);
      expect(find.text('Notification scheduler'), findsNothing);

      // Prepare with the operational-details opt-in still OFF: the sanitized
      // event preview appears, but background cards stay absent.
      await tester.tap(
        find.byKey(const Key('prepare-diagnostic-preview-button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('sanitized events ready for review'),
        findsOneWidget,
      );
      expect(
        find.text('Background work'),
        findsNothing,
        reason: 'prepare without the opt-in must not read platform state',
      );

      // Turn the opt-in ON: cards must now appear.
      await tester.tap(find.byKey(const Key('diagnostic-context-checkbox')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('prepare-diagnostic-preview-button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Background work'), findsOneWidget);
      // Typed technical facts only, using the established row projection. The
      // screen is a lazy ListView, so the lower rows are revealed by scrolling
      // as they would be for a real owner.
      expect(find.text('Notification scheduler'), findsOneWidget);
      for (final label in <String>[
        'Background scheduler',
        'Pending reminders',
        'Recovery state',
        'Recovery registration',
        'Captured',
      ]) {
        await tester.scrollUntilVisible(
          find.text(label),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(label), findsOneWidget);
      }
      // Every row is rendered with the established Card + ListTile pattern.
      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.byType(ListTile),
        ),
        findsWidgets,
      );
    },
  );

  testWidgets('T71 turning the opt-in off withdraws the background cards', (
    tester,
  ) async {
    final privacy = await pumpApp(tester);
    await openPreview(tester, privacy);

    await tester.tap(find.byKey(const Key('diagnostic-context-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('prepare-diagnostic-preview-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Background work'), findsOneWidget);

    // Opt-in OFF: the stale snapshot must not survive the toggle.
    await tester.tap(find.byKey(const Key('diagnostic-context-checkbox')));
    await tester.pumpAndSettle();
    expect(find.text('Background work'), findsNothing);
    expect(find.text('Notification scheduler'), findsNothing);
  });

  testWidgets('T72 the heading keeps the established style and adds no route', (
    tester,
  ) async {
    final privacy = await pumpApp(tester);
    await openPreview(tester, privacy);

    await tester.tap(find.byKey(const Key('diagnostic-context-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('prepare-diagnostic-preview-button')),
    );
    await tester.pumpAndSettle();

    final heading = tester.widget<Text>(find.text('Background work'));
    final theme = Theme.of(
      tester.element(find.byKey(const Key('prepare-diagnostic-preview-button'))),
    );
    expect(heading.style?.fontWeight, FontWeight.w700);
    expect(
      heading.style?.fontSize,
      theme.textTheme.titleMedium?.fontSize,
      reason: 'the heading reuses titleMedium rather than a bespoke style',
    );
    // The status row uses the same convention as the pre-existing event count.
    final count = tester.widget<Text>(
      find.textContaining('sanitized events ready for review'),
    );
    expect(count.style?.fontWeight, FontWeight.w700);

    // The screen stays inside the existing InternalAppBar journey.
    expect(find.text('Diagnostic export preview'), findsWidgets);
    // No new diagnostics route was introduced for M8.
    expect(RoutePaths.diagnosticPreview, '/privacy/diagnostics');
    expect(tester.takeException(), isNull);
  });
}
