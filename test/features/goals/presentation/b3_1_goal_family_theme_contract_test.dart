// B3.1 fail-first: Goal-family theme semantic symmetry.
//
// Physical Blue Dark evidence proved three goal-family theme leaks:
//   1. Create Goal app bar #38292C / input surfaces warm — dark ColorScheme
//      seeds from Rose, so Material 3 surfaceTint + surfaceContainer* roles
//      composite warm even when `primary` is Blue.
//   2. Activity History / Goal Edit generic action icons pinned to
//      AppTheme.rose (pink #E8A5A5 in Blue Dark) instead of scheme.primary.
//   3. Link-to-Life-Goal bottom sheet #1C1618 — the same rose-seeded
//      surfaceContainerLow.
//
// Contract under test:
//   Blue mode  -> every theme-owned tint/surface/generic-action role resolves
//                 through the Blue semantic roles.
//   Rose mode  -> the same roles resolve through Rose (Rose Dark must stay
//                 byte-identical to the rose-seeded baseline).
//   Goal Icon artwork is NOT recolored by the theme fix (identity preserved).
//
// The theme-layer tests prove the systemic root cause (seed choice); the
// widget tests prove the rendered generic-action icons resolve to
// scheme.primary in both Blue and Rose modes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/presentation/goal_archive_screen.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

import '../../../support/test_dependencies.dart';

const PlannerDate _monday = PlannerDate(year: 2026, month: 8, day: 3);

/// A color is "warm" when its red channel dominates its blue channel (the
/// rose-seeded dark surfaces composite #38292C / #1C1618 — red-dominant).
/// Uses the 0-1 channel doubles (deprecated 0-255 int accessors avoided).
bool _isWarm(Color color) => color.r > color.b;

void main() {
  group('B3.1 dark theme systemic tint (root cause)', () {
    test('Blue Dark must not seed theme-owned surfaces from Rose: tint and '
        'container roles follow the Blue seed and are NOT warm', () {
      final blue = AppTheme.dark(ThemeColorMode.blue).colorScheme;
      final rose = AppTheme.dark(ThemeColorMode.rose).colorScheme;

      // The Blue semantic primary is already wired.
      expect(blue.primary, AppTheme.blueDarkPrimary);

      // surfaceTint drives the M3 scrolled-under app bar composite
      // (the proven warm #38292C Create Goal bar).
      expect(
        blue.surfaceTint,
        isNot(equals(rose.surfaceTint)),
        reason: 'Blue Dark tint must not be the rose-seeded tint',
      );
      expect(
        _isWarm(blue.surfaceTint),
        isFalse,
        reason: 'Blue Dark surfaceTint must not be warm/rose-derived',
      );

      // surfaceContainerLow drives bottom sheets (the proven warm #1C1618
      // Link-to-Life-Goal sheet).
      expect(
        blue.surfaceContainerLow,
        isNot(equals(rose.surfaceContainerLow)),
        reason: 'Blue Dark sheet surface must not be rose-derived',
      );
      expect(
        _isWarm(blue.surfaceContainerLow),
        isFalse,
        reason: 'Blue Dark sheet surface must not be warm',
      );

      // The remaining container roles that Material composites (dialogs,
      // wells, inputs) must also follow the Blue seed.
      expect(
        blue.surfaceContainerHigh,
        isNot(equals(rose.surfaceContainerHigh)),
      );
      expect(
        blue.surfaceContainerHighest,
        isNot(equals(rose.surfaceContainerHighest)),
      );
      expect(_isWarm(blue.surfaceContainerHigh), isFalse);
      expect(_isWarm(blue.surfaceContainerHighest), isFalse);
    });

    test('Rose Dark stays byte-identical to the rose-seeded baseline '
        '(tint and container roles unchanged)', () {
      final rose = AppTheme.dark(ThemeColorMode.rose).colorScheme;
      final baseline = ColorScheme.fromSeed(
        seedColor: AppTheme.rose,
        brightness: Brightness.dark,
        surface: AppTheme.surface,
      );
      expect(rose.primary, AppTheme.roseDarkPrimary);
      expect(rose.surfaceTint, baseline.surfaceTint);
      expect(rose.surfaceContainerLow, baseline.surfaceContainerLow);
      expect(rose.surfaceContainerHigh, baseline.surfaceContainerHigh);
      expect(rose.surfaceContainerHighest, baseline.surfaceContainerHighest);
      expect(rose.surface, AppTheme.surface);
    });
  });

  group('B3.1 goal-family rendered roles', () {
    Future<void> pumpArchive(
      WidgetTester tester, {
      required ThemeData theme,
      int initialTab = 1,
    }) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final startup = buildTestRepository(database: database);
      final profile = await startup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
      // seeded explicitly instead of being created implicitly at onboarding.
      await seedLegacyCanonicalGoals(database, profile.id);
      final repository = DriftGoalRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 3, 12)),
        identifiers: const UuidIdentifierSource(),
      );
      final goal = (await repository.readActiveGoals(profile.id)).first;
      await repository.archiveGoal(profileId: profile.id, goalId: goal.id);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            startupRepositoryProvider.overrideWithValue(startup),
            diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
            plannerDateSourceProvider.overrideWithValue(
              const FixedPlannerDateSource(_monday),
            ),
            goalRepositoryProvider.overrideWithValue(repository),
          ],
          child: Consumer(
            builder: (context, ref, child) {
              final state = ref.watch(startupControllerProvider);
              if (state is! StartupReady) {
                return const SizedBox();
              }
              return MaterialApp(
                theme: theme,
                home: GoalArchiveScreen(initialTab: initialTab),
              );
            },
          ),
        ),
      );
      // Let the archive screen's _load complete.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(profile.id, isNotEmpty);
    }

    testWidgets('Blue Dark: generic Activity History action icons resolve to '
        'scheme.primary (not Rose)', (tester) async {
      await pumpArchive(tester, theme: AppTheme.dark(ThemeColorMode.blue));
      final icon = tester.widget<Icon>(
        find.byIcon(Icons.archive_outlined).first,
      );
      expect(
        icon.color,
        AppTheme.blueDarkPrimary,
        reason: 'generic archive action must be Blue primary in Blue mode',
      );
    });

    testWidgets('GI-02: archived Goal row art is exactly 56dp (2x of 28)', (
      tester,
    ) async {
      await pumpArchive(
        tester,
        theme: AppTheme.dark(ThemeColorMode.blue),
        initialTab: 0,
      );
      final goalIconFinder = find.byType(GoalIcon).first;
      final goalIcon = tester.widget<GoalIcon>(goalIconFinder);
      expect(
        goalIcon.size,
        56,
        reason: 'GI-02 archived goal row art must be 56dp (2x of 28)',
      );
      // The art itself paints at exactly 56dp inside the 64dp wrapper
      // (the wrapper grew just enough for the 2x art).  The seeded goal
      // has no iconId, so the render is the fallback Icon at `size`.
      final icon = find.descendant(
        of: goalIconFinder,
        matching: find.byType(Icon),
      );
      expect(icon, findsOneWidget);
      expect(
        tester.widget<Icon>(icon).size,
        56,
        reason: 'archived row art must RENDER at exactly 56dp',
      );
    });

    testWidgets(
      'Rose Dark: the same generic action icons resolve to Rose primary '
      '(canonical rose)',
      (tester) async {
        await pumpArchive(tester, theme: AppTheme.dark(ThemeColorMode.rose));
        final icon = tester.widget<Icon>(
          find.byIcon(Icons.archive_outlined).first,
        );
        expect(
          icon.color,
          AppTheme.roseDarkPrimary,
          reason: 'generic archive action must be Rose primary in Rose mode',
        );
      },
    );
  });
}
