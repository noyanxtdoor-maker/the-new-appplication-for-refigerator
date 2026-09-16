import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';

/// M2 OWNER CORRECTION (Issue 2, 2026-09-14) — Dark Blue/Rose accent law.
///
/// - exact canonical Dark Blue/Dark Rose primary tokens;
/// - consistent accent roles across theme consumers (FABs, selected
///   navigation, Planner current-time indicator resolve to the same tokens);
/// - Light mode unchanged;
/// - semantic/data colors unchanged;
/// - contrast/readability against the real dark surfaces.
void main() {
  // Real dark surfaces from AppTheme.
  const background = AppTheme.background; // #0D0E10
  const surface = AppTheme.surface; // #181A1E
  const navSurface = Color(0xFF101113);

  double luminance(Color c) => c.computeLuminance();
  double contrastRatio(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  group('exact canonical dark tokens', () {
    test('Dark Blue primary is the corrected muted deep blue', () {
      // M6 final correction nudged the tonal step so WHITE reaches 4.5:1.
      expect(AppTheme.blueDarkPrimary, const Color(0xFF277CB5));
      // NOT the old bright cyan/electric blue.
      expect(AppTheme.blueDarkPrimary, isNot(const Color(0xFF389CDB)));
    });

    test('Dark Rose primary is the corrected muted deep rose', () {
      expect(AppTheme.roseDarkPrimary, const Color(0xFFC34D6E));
      // NOT the old hot/bright pink.
      expect(AppTheme.roseDarkPrimary, isNot(const Color(0xFFEB6986)));
    });
  });

  group('AppTheme.dark() resolves the canonical tokens into roles', () {
    test('Blue dark scheme', () {
      final scheme = AppTheme.dark(ThemeColorMode.blue).colorScheme;
      expect(scheme.primary, AppTheme.blueDarkPrimary);
      expect(scheme.secondary, AppTheme.blueDarkPrimary);
      expect(scheme.tertiary, AppTheme.blueDarkPrimary);
      expect(scheme.onPrimary, AppTheme.darkOnPrimary);
    });

    test('Rose dark scheme', () {
      final scheme = AppTheme.dark(ThemeColorMode.rose).colorScheme;
      expect(scheme.primary, AppTheme.roseDarkPrimary);
      expect(scheme.secondary, AppTheme.roseDarkPrimary);
      expect(scheme.tertiary, AppTheme.roseDarkPrimary);
      expect(scheme.onPrimary, AppTheme.darkOnPrimary);
    });

    test('dark FABs resolve the single floating-control surface role', () {
      final blueTheme = AppTheme.dark(ThemeColorMode.blue);
      final roseTheme = AppTheme.dark(ThemeColorMode.rose);
      final blue = blueTheme.colorScheme;
      final rose = roseTheme.colorScheme;
      // The dark ColorScheme accents are UNCHANGED by the floating-control law,
      // so the patch cannot flatten the accepted dark theme.
      expect(blue.primary, AppTheme.blueDarkPrimary);
      expect(blue.onPrimary, AppTheme.darkOnPrimary);
      expect(rose.primary, AppTheme.roseDarkPrimary);
      expect(rose.onPrimary, AppTheme.darkOnPrimary);
      // POST-M7 CLOSURE (owner law, 2026-09-16): an app-owned floating control
      // is ONE identity in both themes, so the dark FAB resolves the LIGHT
      // tonal step of its family while the WHITE glyph is unchanged.
      expect(
        blueTheme.floatingActionButtonTheme.backgroundColor,
        AppTheme.blueLightPrimary,
      );
      expect(
        roseTheme.floatingActionButtonTheme.backgroundColor,
        AppTheme.roseLightPrimary,
      );
      expect(
        blueTheme.floatingActionButtonTheme.foregroundColor,
        AppTheme.darkOnPrimary,
      );
      expect(
        roseTheme.floatingActionButtonTheme.foregroundColor,
        AppTheme.darkOnPrimary,
      );
    });

    test('Contacts and all three Maps FABs inherit the shared primary FAB role', () {
      final contacts = File(
        'lib/features/contacts/presentation/contacts_screen.dart',
      ).readAsStringSync();
      final maps = File(
        'lib/features/maps/presentation/google_maps_surface.dart',
      ).readAsStringSync();
      expect(contacts, contains("key: const Key('add-contact-fab')"));
      expect(
        contacts,
        isNot(
          contains(
            'backgroundColor: Theme.of(context).colorScheme.primaryContainer',
          ),
        ),
      );
      expect(
        contacts,
        isNot(
          contains(
            'foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer',
          ),
        ),
      );
      for (final key in <String>[
        'maps-drop-pin-button',
        'maps-type-button',
        'maps-locate-button',
      ]) {
        final control = maps.substring(maps.indexOf(key));
        expect(
          control,
          isNot(
            contains(
              'backgroundColor: Theme.of(context).colorScheme.primaryContainer',
            ),
          ),
        );
        expect(
          control,
          isNot(
            contains(
              'foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer',
            ),
          ),
        );
      }
      expect(maps, isNot(contains('_controlSurfaceOf')));
    });

    test('dark selected navigation resolves to the canonical primary', () {
      final blue = AppTheme.dark(ThemeColorMode.blue);
      final rose = AppTheme.dark(ThemeColorMode.rose);
      final blueIcon = blue.navigationBarTheme.iconTheme!.resolve({
        WidgetState.selected,
      });
      final roseLabel = rose.navigationBarTheme.labelTextStyle!.resolve({
        WidgetState.selected,
      });
      expect(blueIcon?.color, AppTheme.blueDarkPrimary);
      expect(roseLabel?.color, AppTheme.roseDarkPrimary);
    });
  });

  group('contrast/readability on real dark surfaces', () {
    test('primary is readable against background, surface and nav surface', () {
      for (final primary in [
        AppTheme.blueDarkPrimary,
        AppTheme.roseDarkPrimary,
      ]) {
        expect(
          contrastRatio(primary, background),
          greaterThanOrEqualTo(4.0),
          reason: 'primary vs background',
        );
        expect(
          contrastRatio(primary, surface),
          greaterThanOrEqualTo(3.5),
          reason: 'primary vs surface',
        );
        expect(
          contrastRatio(primary, navSurface),
          greaterThanOrEqualTo(4.0),
          reason: 'primary vs nav surface',
        );
      }
    });

    test('onPrimary is readable on primary', () {
      for (final primary in [
        AppTheme.blueDarkPrimary,
        AppTheme.roseDarkPrimary,
      ]) {
        expect(
          contrastRatio(AppTheme.darkOnPrimary, primary),
          greaterThanOrEqualTo(4.0),
        );
      }
    });

    test('dark Blue container pair stays muted and readable', () {
      expect(AppTheme.blueDarkPrimaryContainer, const Color(0xFF123A5C));
      expect(AppTheme.blueDarkOnPrimaryContainer, const Color(0xFFD3E3F4));
      expect(
        contrastRatio(
          AppTheme.blueDarkOnPrimaryContainer,
          AppTheme.blueDarkPrimaryContainer,
        ),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('corrected accents are meaningfully darker than the old ones', () {
      // The correction must be visibly meaningful, not a tiny step.
      expect(
        luminance(AppTheme.blueDarkPrimary),
        lessThan(luminance(const Color(0xFF389CDB)) * 0.8),
      );
      expect(
        luminance(AppTheme.roseDarkPrimary),
        lessThan(luminance(const Color(0xFFEB6986)) * 0.8),
      );
    });
  });

  group('no-change boundaries', () {
    test(
      'Light Blue and Light Rose primary FAB roles match Planner defaults',
      () {
        for (final theme in <ThemeData>[
          AppTheme.light(ThemeColorMode.blue),
          AppTheme.light(ThemeColorMode.rose),
        ]) {
          expect(
            theme.floatingActionButtonTheme.backgroundColor,
            theme.colorScheme.primary,
          );
          expect(
            theme.floatingActionButtonTheme.foregroundColor,
            theme.colorScheme.onPrimary,
          );
        }
      },
    );

    test('Light primaries are byte-identical', () {
      expect(AppTheme.blueLightPrimary, const Color(0xFF175A8F));
      expect(AppTheme.roseLightPrimary, const Color(0xFFA62C49));
      final blueLight = AppTheme.light(ThemeColorMode.blue).colorScheme;
      final roseLight = AppTheme.light(ThemeColorMode.rose).colorScheme;
      expect(blueLight.primary, AppTheme.blueLightPrimary);
      expect(roseLight.primary, AppTheme.roseLightPrimary);
    });

    test('semantic/status/data colors are untouched', () {
      expect(AppTheme.warning, const Color(0xFFFFC857));
      expect(AppTheme.eventAccent, const Color(0xFF4CAF50));
      expect(AppTheme.rose, const Color(0xFFF9B7C7));
      // Goal icon fallback artwork color — never theme-recolored.
      expect(AppTheme.goalIconFallbackBlue, const Color(0xFF5CAEC9));
    });

    test(
      'Maps controls resolve both dark primaries through the active role',
      () {
        final darkBlue = AppTheme.dark(ThemeColorMode.blue).colorScheme.primary;
        final darkRose = AppTheme.dark(ThemeColorMode.rose).colorScheme.primary;
        expect(darkBlue, AppTheme.blueDarkPrimary);
        expect(darkRose, AppTheme.roseDarkPrimary);
      },
    );
  });
}
