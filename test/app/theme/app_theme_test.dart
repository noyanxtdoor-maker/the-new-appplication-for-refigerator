import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';

void main() {
  group('Rose Dark compatibility baseline (unchanged)', () {
    test('canonical highlight pink is shared by the dark color scheme', () {
      const expectedRose = Color(0xFFF9B7C7);
      final scheme = AppTheme.dark(ThemeColorMode.rose).colorScheme;

      expect(AppTheme.rose, expectedRose);
      expect(scheme.primary, AppTheme.roseDarkPrimary);
      expect(scheme.onPrimary, const Color(0xFF0D0E10));
    });

    test('Q4: primary and surface text meet WCAG AA contrast', () {
      final scheme = AppTheme.dark(ThemeColorMode.rose).colorScheme;

      expect(
        _contrast(scheme.primary, scheme.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.surface, scheme.onSurface),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('AppTheme.dark() critical token values are identical to baseline', () {
      final scheme = AppTheme.dark(ThemeColorMode.rose).colorScheme;

      expect(scheme.primary, AppTheme.roseDarkPrimary);
      expect(scheme.onPrimary, const Color(0xFF0D0E10));
      expect(scheme.surface, const Color(0xFF181A1E));
      expect(scheme.onSurface, const Color(0xFFF4F1F2));
      expect(scheme.outline, const Color(0xFF454850));
      expect(AppTheme.background, const Color(0xFF0D0E10));
      expect(
        AppTheme.dark(ThemeColorMode.rose).scaffoldBackgroundColor,
        const Color(0xFF0D0E10),
      );
    });
  });

  group('B2-CORRECTION locked Rose Light palette', () {
    test('exact neutral surface values', () {
      final scheme = AppTheme.light(ThemeColorMode.rose).colorScheme;

      expect(scheme.brightness, Brightness.light);
      expect(scheme.surface, const Color(0xFFFAF8F5));
      expect(scheme.onSurface, const Color(0xFF1A1C1F));
      expect(scheme.secondary, const Color(0xFF5F6368));
      expect(scheme.outlineVariant, const Color(0xFFD9D7D3));
      expect(
        AppTheme.light(ThemeColorMode.rose).scaffoldBackgroundColor,
        const Color(0xFFF1EFEA),
      );
    });

    test('exact semantic values', () {
      final scheme = AppTheme.light(ThemeColorMode.rose).colorScheme;

      expect(scheme.primary, const Color(0xFFA62C49));
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.primaryContainer, const Color(0xFFF9B7C7));
      expect(scheme.onPrimaryContainer, const Color(0xFF6E1E33));
    });

    test('Rose Light contrast contract', () {
      final scheme = AppTheme.light(ThemeColorMode.rose).colorScheme;
      final card = scheme.surface;
      final canvas = AppTheme.light(
        ThemeColorMode.rose,
      ).scaffoldBackgroundColor;

      // primary/on card >= 4.5
      expect(_contrast(scheme.primary, card), greaterThanOrEqualTo(4.5));
      // primary/on canvas >= 4.5
      expect(_contrast(scheme.primary, canvas), greaterThanOrEqualTo(4.5));
      // onSurface >= 7
      expect(_contrast(scheme.onSurface, card), greaterThanOrEqualTo(7.0));
      // secondary >= 4.5
      expect(_contrast(scheme.secondary, card), greaterThanOrEqualTo(4.5));
      // onPrimary >= 4.5
      expect(
        _contrast(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(4.5),
      );
      // selected-nav indicator/icon: onPrimary against primary fill >= 4.5
      expect(
        _contrast(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(4.5),
      );
      // card outline stays subtle (below text-level 3:1)
      expect(_contrast(scheme.outlineVariant, card), lessThan(3.0));
    });
  });

  group('B2-CORRECTION locked Blue Light palette', () {
    test('exact neutral surface values (subtly cool)', () {
      final scheme = AppTheme.light(ThemeColorMode.blue).colorScheme;

      expect(scheme.brightness, Brightness.light);
      expect(scheme.surface, const Color(0xFFF8F9FB));
      expect(scheme.onSurface, const Color(0xFF1A1C1F));
      expect(scheme.secondary, const Color(0xFF5F6368));
      expect(scheme.outlineVariant, const Color(0xFFD4D9DF));
      expect(
        AppTheme.light(ThemeColorMode.blue).scaffoldBackgroundColor,
        const Color(0xFFEEF0F2),
      );
    });

    test('exact semantic values', () {
      final scheme = AppTheme.light(ThemeColorMode.blue).colorScheme;

      expect(scheme.primary, const Color(0xFF175A8F));
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.primaryContainer, const Color(0xFFD3E3F4));
      expect(scheme.onPrimaryContainer, const Color(0xFF123A5C));
    });

    test('Blue Light contrast contract', () {
      final scheme = AppTheme.light(ThemeColorMode.blue).colorScheme;
      final card = scheme.surface;
      final canvas = AppTheme.light(
        ThemeColorMode.blue,
      ).scaffoldBackgroundColor;

      expect(_contrast(scheme.primary, card), greaterThanOrEqualTo(4.5));
      expect(_contrast(scheme.primary, canvas), greaterThanOrEqualTo(4.5));
      expect(_contrast(scheme.onSurface, card), greaterThanOrEqualTo(7.0));
      expect(_contrast(scheme.secondary, card), greaterThanOrEqualTo(4.5));
      expect(
        _contrast(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(4.5),
      );
      expect(_contrast(scheme.outlineVariant, card), lessThan(3.0));
    });
  });

  group('B2-CORRECTION Blue Dark palette', () {
    test('Blue Dark swaps semantic accents only; dark neutrals unchanged', () {
      final blue = AppTheme.dark(ThemeColorMode.blue).colorScheme;
      final rose = AppTheme.dark(ThemeColorMode.rose).colorScheme;

      expect(blue.primary, AppTheme.blueDarkPrimary);
      expect(blue.onPrimary, const Color(0xFF0D0E10));
      expect(blue.primaryContainer, const Color(0xFF123A5C));
      expect(blue.onPrimaryContainer, const Color(0xFFD3E3F4));

      // Dark neutrals identical to Rose Dark baseline.
      expect(blue.surface, rose.surface);
      expect(blue.onSurface, rose.onSurface);
      expect(blue.outline, rose.outline);
      expect(blue.brightness, Brightness.dark);
      expect(
        AppTheme.dark(ThemeColorMode.blue).scaffoldBackgroundColor,
        AppTheme.dark(ThemeColorMode.rose).scaffoldBackgroundColor,
      );
    });

    test('Blue Dark critical contrast pairs', () {
      // M2 OWNER CORRECTION (Issue 2): the primary is deliberately DEEPER and
      // muted, so its contrast against the raised dark surface is tuned to
      // >=3.5:1 (accent visibility, not body-text readability), while text
      // pairs keep their strict 4.5:1 law.
      final scheme = AppTheme.dark(ThemeColorMode.blue).colorScheme;

      expect(
        _contrast(scheme.primary, scheme.surface),
        greaterThanOrEqualTo(3.5),
      );
      // onPrimary is the near-black baseline used for icons on filled
      // accent surfaces; against the deeper muted primary it holds >=4.0:1
      // (well above the 3:1 graphics/UI-component bar).
      expect(
        _contrast(scheme.primary, scheme.onPrimary),
        greaterThanOrEqualTo(4.0),
      );
      expect(
        _contrast(scheme.surface, scheme.onSurface),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('Light dialog readability', () {
    for (final mode in ThemeColorMode.values) {
      test('${mode.name} Light dialog text resolves to active onSurface', () {
        final theme = AppTheme.light(mode);
        final scheme = theme.colorScheme;
        final dialog = theme.dialogTheme;

        expect(dialog.backgroundColor, scheme.surfaceContainerHigh);
        expect(dialog.titleTextStyle?.color, scheme.onSurface);
        expect(dialog.contentTextStyle?.color, scheme.onSurface);
        expect(
          _contrast(scheme.onSurface, scheme.surfaceContainerHigh),
          greaterThanOrEqualTo(7.0),
        );
      });

      testWidgets(
        '${mode.name} Light AlertDialog inherits readable title and body text',
        (tester) async {
          final theme = AppTheme.light(mode);
          final scheme = theme.colorScheme;

          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: const Scaffold(
                body: AlertDialog(
                  title: Text('Delete this item?'),
                  content: Text('This action cannot be undone.'),
                ),
              ),
            ),
          );

          final titleStyle = tester.widget<DefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('Delete this item?'),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          );
          final contentStyle = tester.widget<DefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('This action cannot be undone.'),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          );

          expect(titleStyle.style.color, scheme.onSurface);
          expect(contentStyle.style.color, scheme.onSurface);
        },
      );
    }
  });

  group('B2-CORRECTION default + accessor contract', () {
    test('default theme color is Rose for backward compatibility', () {
      expect(
        AppTheme.light().colorScheme.primary,
        AppTheme.light(ThemeColorMode.rose).colorScheme.primary,
      );
      expect(
        AppTheme.dark().colorScheme.primary,
        AppTheme.dark(ThemeColorMode.rose).colorScheme.primary,
      );
    });

    testWidgets('Rose Dark accessors remain the pre-correction dark values', (
      tester,
    ) async {
      late BuildContext probeContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(ThemeColorMode.rose),
          home: Builder(
            builder: (context) {
              probeContext = context;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(AppTheme.cardOf(probeContext), const Color(0xFF2A2A2B));
      expect(AppTheme.raisedOf(probeContext), const Color(0xFF343638));
      expect(AppTheme.navBarOf(probeContext), const Color(0xFF101113));
      expect(AppTheme.surfaceOf(probeContext), const Color(0xFF181A1E));
      expect(AppTheme.secondaryTextOf(probeContext), const Color(0xFF9CA0A6));
    });
  });
}

double _contrast(Color first, Color second) {
  final light = first.computeLuminance() >= second.computeLuminance()
      ? first
      : second;
  final dark = identical(light, first) ? second : first;
  return (light.computeLuminance() + 0.05) / (dark.computeLuminance() + 0.05);
}
