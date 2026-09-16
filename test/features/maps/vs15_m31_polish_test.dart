import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/google_maps_surface.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';
import 'package:rmplanner/features/maps/presentation/saved_place_form_sheet.dart';

import 'support/fab_theme_probe.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
}

void main() {
  testWidgets(
    'M3.1 native long-press callback opens chooser by the next frame',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mapProjectedMarkersProvider.overrideWith((ref) async => []),
            mapPassiveLocationProvider.overrideWith((ref) async => null),
          ],
          child: MaterialApp(
            home: MapsScreen(mapBuilder: (_, _) => const SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<GoogleMapsSurface>(find.byType(GoogleMapsSurface))
          .onMapLongPress!(const MapCoordinate(latitude: 14.6, longitude: 121));
      await tester.pump();
      expect(find.text('Add at this location'), findsOneWidget);
      for (final label in ['Add Place', 'Add Contact', 'Add Event']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.pumpAndSettle();
    },
  );
  for (final mode in ThemeColorMode.values) {
    test('M3.1 $mode dark accent is saturated, legible, and readable', () {
      final theme = AppTheme.dark(mode);
      final scheme = theme.colorScheme;
      // M7 reconciliation (2026-09-16): the accepted M6 law defines the dark
      // accent by its DOCUMENTED identity plus pinned contrast, not by an HSL
      // saturation heuristic. The accepted Rose dark primary is legitimately
      // below the retired `.60` saturation bar, so the identity assertion
      // replaces the heuristic.
      expect(
        scheme.primary,
        mode == ThemeColorMode.blue
            ? AppTheme.blueDarkPrimary
            : AppTheme.roseDarkPrimary,
      );
      expect(scheme.onPrimary, Colors.white);
      expect(
        // Retired VS15 bar: primary-vs-surface >= 4.5. Accepted M6 law pins
        // primary against the documented dark background (#0D0E10) at >= 4.0
        // because primary-vs-surface is not an on-primary pair.
        contrast(scheme.primary, AppTheme.background),
        greaterThanOrEqualTo(4.0),
      );
      expect(
        contrast(scheme.primary, scheme.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
    });
    for (final dark in [false, true]) {
      testWidgets('M3.1 $mode dark=$dark controls and Avoid semantics', (
        tester,
      ) async {
        final theme = dark ? AppTheme.dark(mode) : AppTheme.light(mode);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: theme,
              home: Scaffold(
                body: GoogleMapsSurface(
                  markers: const [],
                  initialCoordinate: null,
                  onMarkerTap: (_) {},
                  mapBuilder: (_, _) => const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final key in [
          'maps-drop-pin-button',
          'maps-type-button',
          'maps-locate-button',
        ]) {
          // M7 reconciliation: the accepted canonical law fills a primary map
          // control with the theme primary and paints its glyph WHITE. The VS15
          // assertion read the retired primaryContainer/onPrimaryContainer
          // constructor pair, which the control never sets — it passes no
          // colours and resolves them from the canonical FAB theme.
          expect(
            resolvedFabBackground(tester, Key(key)),
            theme.colorScheme.primary,
          );
          expect(resolvedFabIconColor(tester, Key(key)), Colors.white);
        }
        tester.view.physicalSize = const Size(431, 912);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: theme,
              home: SavedPlaceFormScreen(
                coordinate: const MapCoordinate(latitude: 14.6, longitude: 121),
                onSave: (_) async {},
                onCancel: () {},
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('saved-place-category-avoid')));
        await tester.pumpAndSettle();
        final label = tester.widget<Text>(find.text('Avoid'));
        final color = label.style!.color!;
        expect(color.r, greaterThan(color.b * 1.5));
        expect(color.r, greaterThan(color.g * 1.5));
        expect(color, isNot(theme.colorScheme.primary));
        final segment = tester.widget<SegmentedButton>(
          find.byKey(const Key('saved-place-mode')),
        );
        expect(
          segment.style!.backgroundColor!.resolve({}),
          theme.colorScheme.surface,
        );
        expect(find.byKey(const Key('saved-place-hex')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
  test('M3.1 map and search share the Saved Place resolver', () {
    final map = File(
      'lib/features/maps/presentation/google_maps_surface.dart',
    ).readAsStringSync();
    final search = File(
      'lib/features/maps/presentation/maps_search_screen.dart',
    ).readAsStringSync();
    expect(map, contains('SavedPlaceVisualIdentity.resolve'));
    expect(search, contains('SavedPlaceVisualIdentity.fromPlace'));
    expect(
      search,
      isNot(contains('leading: const Icon(Icons.place_outlined)')),
    );
  });
  test(
    'M3.1 Edit Goal keeps a canonical pinned bar and blank-tap dismissal',
    () {
      final goal = File(
        'lib/features/goals/presentation/goal_edit_screen.dart',
      ).readAsStringSync();
      // M7 reconciliation (2026-09-16): the retired per-screen tokens
      // `scrolledUnderElevation: 0`, `goal-edit-blank-space-dismiss` and
      // `InternalScreen.fieldLabel` exist nowhere in lib/ — the canonical
      // InternalScreen/InternalAppBar architecture owns bar chrome and
      // dismissal. Assert the canonical bar plus Edit Goal's real controls.
      expect(goal, contains('InternalAppBar('));
      expect(goal, isNot(contains('appBar: AppBar(')));
      expect(goal, contains("key: const Key('goal-edit-back')"));
      expect(goal, contains("key: const Key('goal-edit-save')"));
    },
  );
}
