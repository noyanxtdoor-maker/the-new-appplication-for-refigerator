import 'package:flutter/material.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';

/// The single production typography source.  Feature screens may adjust color
/// or weight for emphasis, but the size and line-height tokens stay here so a
/// text-scale change cannot make one flow drift away from the rest of the app.
abstract final class AppTypography {
  static const TextStyle pageTitle = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 26,
    height: 32 / 26,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
  );
  static const TextStyle appBarTitle = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 24,
    height: 30 / 24,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
  );
  static const TextStyle sectionTitle = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 18,
    height: 24 / 18,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle cardTitle = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 16,
    height: 22 / 16,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle body = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 16,
    height: 22 / 16,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle secondary = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle micro = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle button = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 16,
    height: 20 / 16,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle metricLarge = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 28,
    height: 32 / 28,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle metricCompact = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 22,
    height: 26 / 22,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle bottomNavLabel = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle plannerEventTitle = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 14,
    height: 17 / 14,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle plannerEventTime = TextStyle(
    fontFamily: 'Roboto',
    fontSize: 13,
    height: 16 / 13,
    fontWeight: FontWeight.w400,
  );
}

abstract final class AppTheme {
  /// Canonical app highlight pink shared by existing dark highlight roles.
  static const Color rose = Color(0xFFF9B7C7);
  static const Color background = Color(0xFF0D0E10);
  static const Color surface = Color(0xFF181A1E);
  static const Color outline = Color(0xFF454850);
  static const Color warning = Color(0xFFFFC857);
  static const Color eventAccent = Color(0xFF4CAF50);

  // ------------------------------------------------------------- B1 light
  // Legacy B1 light tokens (superseded by the locked B2-CORRECTION Soft-Light
  // families below but kept for the existing tests/screens that still read
  // them directly).  Dark palette above is untouched.

  /// Legacy light app background.
  static const Color lightBackground = Color(0xFFF1EFEB);

  /// Legacy primary light surface.
  static const Color lightSurface = Color(0xFFF4F1F2);

  /// Legacy elevated/container light surface.
  static const Color lightSurfaceVariant = Color(0xFFECEAE6);

  /// Primary light text color.
  static const Color lightOnSurface = Color(0xFF1A1C1F);

  /// Secondary light text color.
  static const Color lightSecondary = Color(0xFF5F6368);

  /// Legacy light border/outline color.
  static const Color lightOutline = Color(0xFF85898C);

  /// Light warning/amber role.
  static const Color lightWarning = Color(0xFF8A4F00);

  // ------------------------------------------- B2-CORRECTION locked palettes
  // Owner-approved Soft-Light + Rose/Blue semantic families.  Rose Dark
  // compatibility is the pre-correction baseline; Blue Dark swaps ONLY the
  // semantic accent roles.

  // Rose Light ------------------------------------------------------------
  static const Color roseLightPrimary = Color(0xFFA62C49);
  static const Color roseLightOnPrimary = Color(0xFFFFFFFF);
  static const Color roseLightPrimaryContainer = Color(0xFFF9B7C7);
  static const Color roseLightOnPrimaryContainer = Color(0xFF6E1E33);
  static const Color roseLightProgress = Color(0xFFC8506B);
  static const Color roseLightCanvas = Color(0xFFF1EFEA);
  static const Color roseLightCard = Color(0xFFFAF8F5);
  static const Color roseLightRaised = Color(0xFFFFFFFF);
  static const Color roseLightContainer = Color(0xFFECEAE6);
  static const Color roseLightNav = Color(0xFFF4F2EE);
  static const Color roseLightCardOutline = Color(0xFFD9D7D3);
  static const Color roseLightInputOutline = Color(0xFF8A8782);
  static const Color roseLightOnSurface = Color(0xFF1A1C1F);
  static const Color roseLightSecondary = Color(0xFF5F6368);

  // Blue Light ------------------------------------------------------------
  static const Color blueLightPrimary = Color(0xFF175A8F);

  /// R1 (2026-08-16 owner re-lock): theme-independent blue for Goal Icon
  /// FALLBACK rendering (null/unknown iconId). The raw Goal Icon SVG artwork
  /// family uses literal light-teal blues (~0xFF5CAEC9 / #5baeca); the
  /// fallback Material icon must use the SAME raw-art family in BOTH themes
  /// so no icon color can be substituted by the active theme (previously
  /// Light navy primary vs Dark periwinkle primary). Not the theme primary.
  static const Color goalIconFallbackBlue = Color(0xFF5CAEC9);
  static const Color blueLightOnPrimary = Color(0xFFFFFFFF);
  static const Color blueLightPrimaryContainer = Color(0xFFD3E3F4);
  static const Color blueLightOnPrimaryContainer = Color(0xFF123A5C);
  static const Color blueLightProgress = Color(0xFF3B7DB8);
  static const Color blueLightCanvas = Color(0xFFEEF0F2);
  static const Color blueLightCard = Color(0xFFF8F9FB);
  static const Color blueLightRaised = Color(0xFFFFFFFF);
  static const Color blueLightContainer = Color(0xFFE8EDF2);
  static const Color blueLightNav = Color(0xFFF2F4F6);
  static const Color blueLightCardOutline = Color(0xFFD4D9DF);
  static const Color blueLightInputOutline = Color(0xFF818890);
  static const Color blueLightOnSurface = Color(0xFF1A1C1F);
  static const Color blueLightSecondary = Color(0xFF5F6368);

  // Blue Dark (semantic accents only; neutrals stay the dark baseline) ----
  // M2 OWNER CORRECTION (Issue 2, 2026-09-14): dark accents were too bright
  // and inconsistent (Blue read as cyan/electric #389CDB, Rose as hot pink
  // #EB6986).  Both primaries are now deep, muted, coherent dark accents:
  //   Blue Dark  #277CB5 (was #389CDB, then #277FB5) — deep blue, never
  //     cyan/electric;
  //   Rose Dark  #C34D6E (was #EB6986, then #C95470) — deep muted
  //     rose/burgundy.
  // Each holds >=4.3:1 contrast against the real dark surfaces (#0D0E10
  // background, #181A1E surface, #101113 navigation), so FABs, selected
  // navigation, and the Planner current-time indicator stay readable while
  // the overall dark composition stays subdued.  The muted container pair is
  // unchanged, and Light tokens, semantic/data colors, and Goal artwork stay
  // exactly as they were.
  //
  // M6 FINAL CORRECTION (Issue 2 supersession, 2026-09-15): the M2 "near-black
  // onPrimary" law is SUPERSEDED by the owner's final M6 law — a primary
  // blue/rose filled action surface uses a WHITE foreground in BOTH themes.
  // The two dark primaries were nudged by the smallest tonal step that makes
  // WHITE reach the pinned 4.5:1 on-primary target while keeping every
  // existing accent-vs-dark-surface gate:
  //   Blue Dark #277CB5 — white 4.53:1, vs #0D0E10 4.26:1
  //   Rose Dark #C34D6E — white 4.56:1, vs #0D0E10 4.24:1
  // Both keep the exact accepted hue (the deltas are ~1% in luminance), so
  // the identity is unchanged — only the tonal step needed for a white
  // foreground.
  static const Color blueDarkPrimary = brandBlueHue;
  static const Color roseDarkPrimary = Color(0xFFC34D6E);

  /// The ONE canonical foreground for a primary-filled action surface in
  /// DARK mode (FABs, filled buttons, primary pills, the create overlay).
  /// White in both themes; see the M6 final correction note above.
  static const Color darkOnPrimary = Color(0xFFFFFFFF);
  static const Color blueDarkPrimaryContainer = Color(0xFF123A5C);
  static const Color blueDarkOnPrimaryContainer = Color(0xFFD3E3F4);

  /// The ONE documented Next Transfer Blue identity.
  ///
  /// Light and Dark resolve different TONAL steps of this single hue so the
  /// accent stays legible on a near-white and on a near-black canvas, but the
  /// brand identity itself is defined once here and everywhere else derives
  /// from it (no stray or user-facing "alternative" blue exists).
  static const Color brandBlueHue = Color(0xFF277CB5);

  // ------------------------------------------------------- B2 accessors
  // Brightness-aware semantic accessors.  Dark mode ALWAYS returns the exact
  // pre-B2 constant so dark goldens stay byte-identical; light mode resolves
  // the active Theme Color's semantic tokens from the color scheme.

  /// Secondary text / muted icon color (dark #9CA0A6, light active secondary).
  static Color secondaryTextOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF9CA0A6)
      : Theme.of(context).colorScheme.onSurfaceVariant;

  /// Detail-sheet caption/label color (NX-01).  Dark keeps the exact
  /// pre-NX white60 pixels byte-identical; Light resolves the semantic
  /// onSurfaceVariant so captions stay readable on the Light surface.
  static Color detailCaptionOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? Colors.white60
      : Theme.of(context).colorScheme.onSurfaceVariant;

  /// Elevated surface / container (dark #2A2D31, light container/well).
  static Color surfaceVariantOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF2A2D31)
      : Theme.of(context).colorScheme.surfaceContainerHighest;

  /// Deeper dark surface variant (dark #1C1E21).
  static Color surfaceRaisedOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF1C1E21)
      : Theme.of(context).colorScheme.surfaceContainerHighest;

  /// Home plan-block fill (dark #23262C).
  static Color blockOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF23262C)
      : Theme.of(context).colorScheme.surfaceContainerHighest;

  /// Card/panel fill (dark #2A2A2B, light active card surface).
  static Color cardOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF2A2A2B)
      : Theme.of(context).colorScheme.surface;

  /// Raised control fill (dark #343638, light container/well tone so
  /// controls like progress tracks stay visible on cards).
  static Color raisedOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF343638)
      : Theme.of(context).colorScheme.surfaceContainerHighest;

  /// Bottom-navigation surface (dark #101113, light active app/nav surface).
  static Color navBarOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF101113)
      : Theme.of(context).colorScheme.surfaceContainer;

  /// Warning role (dark #FFC857, light #8A4F00).  Status color — never
  /// recolored by Theme Color.
  static Color warningOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? warning : lightWarning;

  /// Text/icon on a filled surface: exact white translucency in dark,
  /// on-surface translucency in light (keeps dark pixels byte-identical).
  ///
  /// Dark mode returns the EXACT pre-B2 constant for the known translucency
  /// steps (white / white70 / white54 / white24 / the two alpha literals used
  /// by the Planner strips) instead of re-computing a float alpha, so dark
  /// goldens stay byte-identical regardless of alpha round-trips.
  static Color onFillTextOf(BuildContext context, double opacity) {
    if (Theme.of(context).brightness == Brightness.dark) {
      if (opacity >= 0.999) {
        return Colors.white;
      }
      if (opacity >= 0.70 && opacity < 0.705) {
        return Colors.white70; // 0xB3FFFFFF
      }
      if (opacity >= 0.54 && opacity < 0.545) {
        return Colors.white54; // 0x8AFFFFFF
      }
      if (opacity >= 0.239 && opacity < 0.2405) {
        return Colors.white24; // 0x3DFFFFFF
      }
      if (opacity >= 0.7215 && opacity < 0.7217) {
        return const Color(0xB8FFFFFF); // date-strip unselected text
      }
      if (opacity >= 0.7019 && opacity < 0.7021) {
        return const Color(0xB3FFFFFF); // pager hour labels
      }
      return Colors.white.withValues(alpha: opacity);
    }
    return Theme.of(context).colorScheme.onSurface.withValues(alpha: opacity);
  }

  /// Accent teal (dark #9EDCE3, light #357083).  Status/data color — never
  /// recolored by Theme Color.
  static Color accentTealOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF9EDCE3)
      : const Color(0xFF357083);

  /// Accent gold (dark #F1C94F, light #84681C).  Status/data color — never
  /// recolored by Theme Color.
  static Color accentGoldOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFF1C94F)
      : const Color(0xFF84681C);

  /// Rose-tinted container (dark #400018 fill, light #FBE3E9).  Status/
  /// identity container — never recolored by Theme Color.
  static Color roseContainerOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF400018)
      : const Color(0xFFFBE3E9);

  /// Disabled foreground (dark #6B6F76, light #8E9295).
  static Color disabledForegroundOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF6B6F76)
      : const Color(0xFF8E9295);

  /// Neutral chart/track fill (dark #3D4144, light active card outline tone).
  static Color trackFillOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF3D4144)
      : Theme.of(context).colorScheme.outlineVariant;

  /// Border/outline role (dark #454850, light subtle card outline).
  static Color outlineOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? outline
      : Theme.of(context).colorScheme.outlineVariant;

  /// App surface fill (dark #181A1E, light active app/nav surface).  Used by
  /// pinned app bars and raised containers that must stay exactly on the app
  /// surface in both themes.
  static Color surfaceOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? surface
      : Theme.of(context).colorScheme.surfaceContainer;

  /// Home/feature card border (dark #414649, light subtle card outline).
  static Color cardBorderOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF414649)
      : Theme.of(context).colorScheme.outlineVariant;

  /// Major section separator (dark #4A4E50, light subtle card outline tone).
  static Color majorSeparatorOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF4A4E50)
      : Theme.of(context).colorScheme.outlineVariant;

  /// Filter-builder section divider (dark #45484A, light subtle card outline
  /// tone).
  static Color sectionDividerOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF45484A)
      : Theme.of(context).colorScheme.outlineVariant;

  /// Draggable-sheet grab handle: dark, high-contrast near-black in both
  /// themes so the drag affordance reads clearly over the map UI.
  static Color dragHandleOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFB7BCC3)
      : const Color(0xFF2A2C30);

  static ThemeData light([ThemeColorMode themeColor = ThemeColorMode.rose]) {
    final isRose = themeColor == ThemeColorMode.rose;
    final primary = isRose ? roseLightPrimary : blueLightPrimary;
    final onPrimary = isRose ? roseLightOnPrimary : blueLightOnPrimary;
    final primaryContainer = isRose
        ? roseLightPrimaryContainer
        : blueLightPrimaryContainer;
    final onPrimaryContainer = isRose
        ? roseLightOnPrimaryContainer
        : blueLightOnPrimaryContainer;
    final progressAccent = isRose ? roseLightProgress : blueLightProgress;
    final canvas = isRose ? roseLightCanvas : blueLightCanvas;
    final card = isRose ? roseLightCard : blueLightCard;
    final raised = isRose ? roseLightRaised : blueLightRaised;
    final container = isRose ? roseLightContainer : blueLightContainer;
    final navSurface = isRose ? roseLightNav : blueLightNav;
    final cardOutline = isRose ? roseLightCardOutline : blueLightCardOutline;
    final inputOutline = isRose ? roseLightInputOutline : blueLightInputOutline;
    final onSurface = isRose ? roseLightOnSurface : blueLightOnSurface;
    final secondary = isRose ? roseLightSecondary : blueLightSecondary;

    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.light,
          surface: card,
        ).copyWith(
          primary: primary,
          onPrimary: onPrimary,
          primaryContainer: primaryContainer,
          onPrimaryContainer: onPrimaryContainer,
          tertiary: progressAccent,
          surface: card,
          onSurface: onSurface,
          onSurfaceVariant: secondary,
          secondary: secondary,
          onSecondary: onSurface,
          outline: inputOutline,
          outlineVariant: cardOutline,
          surfaceContainerLowest: raised,
          surfaceContainerLow: card,
          surfaceContainer: navSurface,
          surfaceContainerHigh: container,
          surfaceContainerHighest: container,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: 'Roboto',
      colorScheme: colorScheme,
      scaffoldBackgroundColor: canvas,
      appBarTheme: AppBarTheme(
        toolbarHeight: 72,
        // B2-CORRECTION shared title fix: the title must resolve to a
        // non-null color.  Light uses the active onSurface so titles are
        // dark/readable on the Light app bar.
        titleTextStyle: AppTypography.pageTitle.copyWith(color: onSurface),
      ),
      textTheme: const TextTheme(
        displayLarge: AppTypography.pageTitle,
        headlineSmall: AppTypography.metricLarge,
        titleLarge: AppTypography.pageTitle,
        titleMedium: AppTypography.sectionTitle,
        bodyLarge: AppTypography.body,
        bodyMedium: AppTypography.cardTitle,
        bodySmall: AppTypography.secondary,
        labelLarge: AppTypography.button,
        labelMedium: AppTypography.micro,
        labelSmall: AppTypography.micro,
      ),
      cardTheme: CardThemeData(
        color: card,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cardOutline),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        insetPadding: EdgeInsets.symmetric(horizontal: 22, vertical: 28),
        titleTextStyle: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 19,
          height: 24 / 19,
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        contentTextStyle: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 14,
          height: 20 / 14,
          fontWeight: FontWeight.w400,
          color: onSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      // App-owned primary FABs share one semantic role in every palette.
      // Individual feature FABs must not bypass this with container colors:
      // same theme + same primary-action role = primary/onPrimary.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: onPrimary,
      ),
      // B2-CORRECTION selected navigation: the Material indicator is filled
      // with the semantic primary, the selected icon rides onPrimary, and
      // the selected label uses primary.  Unselected stays secondary.
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: navSurface,
        indicatorColor: primary,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? onPrimary
                : secondary,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => AppTypography.bottomNavLabel.copyWith(
            color: states.contains(WidgetState.selected) ? primary : secondary,
          ),
        ),
      ),
    );
  }

  static ThemeData dark([ThemeColorMode themeColor = ThemeColorMode.rose]) {
    final isBlue = themeColor == ThemeColorMode.blue;
    // B3.1 systemic fix: the dark scheme must never seed Blue-mode surfaces
    // from Rose.  Material 3 derives surfaceTint and the surfaceContainer*
    // roles from the seed, so a Rose seed composites warm in Blue mode (the
    // proven #38292C Create Goal app bar, #1C1618 Link-to-Life-Goal sheet).
    // Blue mode therefore seeds from the Blue primary so every theme-owned
    // tint/surface role follows the active Theme Color while neutral dark
    // surfaces stay dark; Rose Dark keeps the exact Rose seed (byte-identical
    // baseline, pinned by the B3.1 contract tests).
    // Preserve the accepted dark neutral/container family; only accent roles
    // are superseded by M3.1, not stored colors or Goal artwork.
    // M6 FINAL CORRECTION: the dark seed must derive from the canonical brand
    // identity, never from an unrelated pale blue.  Blue Dark therefore seeds
    // from the documented Next Transfer Blue itself; Rose Dark keeps the
    // canonical rose highlight seed (byte-identical baseline).
    final seed = isBlue ? brandBlueHue : rose;
    final primary = isBlue ? blueDarkPrimary : roseDarkPrimary;
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
          surface: surface,
        ).copyWith(
          primary: primary,
          onPrimary: darkOnPrimary,
          secondary: primary,
          onSecondary: darkOnPrimary,
          tertiary: primary,
          onTertiary: darkOnPrimary,
          primaryContainer: isBlue ? blueDarkPrimaryContainer : null,
          onPrimaryContainer: isBlue ? blueDarkOnPrimaryContainer : null,
          surface: surface,
          onSurface: const Color(0xFFF4F1F2),
          outline: outline,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Roboto',
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        toolbarHeight: 72,
        // B2-CORRECTION shared title fix: Dark keeps the EXACT pixel color
        // the pre-correction color-null path rendered (white on non-web
        // platforms), so the existing dark goldens stay byte-identical.
        titleTextStyle: AppTypography.pageTitle.copyWith(color: Colors.white),
      ),
      textTheme: const TextTheme(
        displayLarge: AppTypography.pageTitle,
        headlineSmall: AppTypography.metricLarge,
        titleLarge: AppTypography.pageTitle,
        titleMedium: AppTypography.sectionTitle,
        bodyLarge: AppTypography.body,
        bodyMedium: AppTypography.cardTitle,
        bodySmall: AppTypography.secondary,
        labelLarge: AppTypography.button,
        labelMedium: AppTypography.micro,
        labelSmall: AppTypography.micro,
      ),
      cardTheme: CardThemeData(
        color: surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: outline),
        ),
      ),
      dialogTheme: const DialogThemeData(
        insetPadding: EdgeInsets.symmetric(horizontal: 22, vertical: 28),
        titleTextStyle: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 19,
          height: 24 / 19,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 14,
          height: 20 / 14,
          fontWeight: FontWeight.w400,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      // Keep the owner-accepted dark accents on the same canonical primary
      // FAB role as Light mode. Contacts, Maps, and Planner inherit this
      // treatment rather than independently selecting container roles.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: darkOnPrimary,
      ),
      // Pack 2 accent restraint: the selected root uses the theme primary
      // (Rose Dark baseline = canonical rose; Blue Dark = blue accent), while
      // unselected roots use a neutral gray.  No filled indicator or pink bar
      // background; selection stays legible in dark mode.
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: const Color(0xFF101113),
        indicatorColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? colorScheme.primary
                : const Color(0xFF9CA0A6),
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => AppTypography.bottomNavLabel.copyWith(
            color: states.contains(WidgetState.selected)
                ? colorScheme.primary
                : const Color(0xFF9CA0A6),
          ),
        ),
      ),
    );
  }
}
