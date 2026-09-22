// P1 (2026-09-21) — Planner settings refinement contract.
//
// Owner-approved P1 removed exactly three redundant presentation surfaces from
// the Planner settings screen (the Timeline zoom dropdown, the Show
// current-time toggle, and the static Notification behavior card) while KEEPING
// the capabilities they sat next to. It also normalized the persisted
// current-time preference, because removing its only control would otherwise
// strand the indicator hidden behind a legacy stored `false`.
//
// P1 owner-review correction (2026-09-21) then removed TWO more management
// surfaces: the Event Types management row and the "Quick edit on timeline"
// toggle. Both capabilities survive — the Event Type picker, Default Event Type
// and every stored Event Type are untouched, and direct manipulation is now
// STANDARD behavior (see planner_refinement_quick_edit_test.dart for the
// legacy-stored-false proof).
//
// Group 1 proves the removed controls are gone and the live capabilities
// remain. Group 2 proves the effective-preference normalization law and that a
// legitimate saved zoom is never reset.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';
import 'package:rmplanner/features/planner/presentation/planner_settings_screen.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

import '../../../support/test_dependencies.dart';

void main() {
  group('removed controls are absent and live capabilities remain', () {
    Future<void> pumpPlannerSettings(WidgetTester tester) async {
      // A tall surface so every settings card lays out without scrolling; the
      // absence assertions are meaningful either way, but presence assertions
      // must not depend on scroll position.
      tester.view.physicalSize = const Size(431, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(
        database: database,
        permissionGateway: FakePermissionGateway(
          states: const <OptionalPermission, OperatingSystemPermissionState>{
            OptionalPermission.notifications:
                OperatingSystemPermissionState.denied,
          },
        ),
      );
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
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('drawer-account-settings')),
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('global-app-drawer-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-account-settings')));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-planner-calendar')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('settings-planner-calendar')));
      await tester.pumpAndSettle();

      expect(find.byType(PlannerSettingsScreen), findsOneWidget);
    }

    testWidgets('the three approved redundant surfaces are gone', (
      tester,
    ) async {
      await pumpPlannerSettings(tester);

      // 1. Timeline / Timeframe zoom dropdown.
      expect(
        find.byKey(const Key('planner-zoom-preset-setting')),
        findsNothing,
      );
      expect(find.text('Timeline zoom'), findsNothing);

      // 2. Show current-time toggle (the feature itself remains; only the
      //    control is removed).
      expect(find.byKey(const Key('current-time-line-setting')), findsNothing);
      expect(find.text('Show current-time line'), findsNothing);

      // 3. Static duplicate Notification behavior card.
      expect(find.text('Notification behavior'), findsNothing);

      // 4. Owner-review correction: the Event Types MANAGEMENT row is gone
      //    from Planner settings (the taxonomy itself and its picker remain).
      expect(find.byKey(const Key('event-types-settings-link')), findsNothing);

      // 5. Owner-review correction: the Quick edit toggle is gone; direct
      //    manipulation is standard behavior now.
      expect(find.byKey(const Key('quick-edit-setting')), findsNothing);
      expect(find.text('Quick edit on timeline'), findsNothing);
    });

    testWidgets('Default Event Type remains live', (tester) async {
      await pumpPlannerSettings(tester);

      // The Event Types taxonomy stays alive internally: the Default Event
      // Type control and its eligibility-driven choices are untouched, and the
      // Event Type picker in Event creation is covered by the creation suites.
      expect(
        find.byKey(const Key('default-event-type-setting')),
        findsOneWidget,
      );
    });

    testWidgets('untouched settings controls all survive', (tester) async {
      await pumpPlannerSettings(tester);

      for (final key in <String>[
        'visible-planner-hours-heading',
        'planner-full-day-preset',
        'default-duration-setting',
        'time-snap-setting',
        'use-24-hour-setting',
        'initial-scroll-setting',
        'show-completed-setting',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('P2-D: 24-hour time moved into Display, in owner order', (
      tester,
    ) async {
      await pumpPlannerSettings(tester);

      // Exactly ONE time-format control exists. The owner deleted the idea of a
      // second "12-hour time" toggle: OFF of this single control IS 12-hour.
      expect(find.byKey(const Key('use-24-hour-setting')), findsOneWidget);
      expect(find.text('24-hour time'), findsOneWidget);

      double top(Finder finder) => tester.getTopLeft(finder).dy;

      final timelineHeader = find.text('Timeline');
      final displayHeader = find.text('Display');
      final tile = find.byKey(const Key('use-24-hour-setting'));
      final snap = find.byKey(const Key('time-snap-setting'));
      final initialScroll = find.byKey(const Key('initial-scroll-setting'));
      final completed = find.byKey(const Key('show-completed-setting'));

      // Section membership proved by layout order, not by string presence: the
      // tile now sits BELOW the Timeline section's own controls...
      expect(top(snap), lessThan(top(tile)));
      expect(top(initialScroll), lessThan(top(tile)));
      // ...and below the Display heading.
      expect(top(timelineHeader), lessThan(top(displayHeader)));
      expect(top(displayHeader), lessThan(top(tile)));

      // Owner-mandated Display order after the post-P2 decision (2026-09-22):
      // 1. 24-hour time  2. Show completed events.  The "Show cancelled items"
      // control was removed, so there is no third row to order.
      expect(top(tile), lessThan(top(completed)));
      expect(find.text('Show completed events'), findsOneWidget);
      expect(
        find.byKey(const Key('show-cancelled-setting')),
        findsNothing,
        reason: 'removed by owner decision; the column itself is untouched',
      );
    });
  });

  group('effective preference normalization', () {
    late AppDatabase database;
    late DriftEventTypeRepository repository;
    late String profileId;

    setUp(() async {
      database = openMemoryDatabase();
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
      await seedLegacyCanonicalGoals(database, profileId);
      repository = DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 21, 12)),
      );
    });

    tearDown(() => database.close());

    Future<void> writeLegacyRow({
      bool? showCurrentTime,
      int? timelineHourHeight,
    }) {
      return (database.update(
        database.plannerPreferences,
      )..where((table) => table.profileId.equals(profileId))).write(
        PlannerPreferencesCompanion(
          showCurrentTime: showCurrentTime == null
              ? const Value<bool>.absent()
              : Value<bool>(showCurrentTime),
          timelineHourHeight: timelineHourHeight == null
              ? const Value<int>.absent()
              : Value<int>(timelineHourHeight),
        ),
      );
    }

    test(
      'a legacy stored false no longer hides the current-time feature',
      () async {
        await repository.savePlannerSettings(
          profileId: profileId,
          settings: const PlannerSettings.defaults(),
        );
        await writeLegacyRow(showCurrentTime: false);

        // The raw column is preserved exactly as stored...
        final raw = await (database.select(
          database.plannerPreferences,
        )..where((table) => table.profileId.equals(profileId))).getSingle();
        expect(raw.showCurrentTime, isFalse);

        // ...but the effective value the app uses is always true.
        final restored = await repository.readPlannerSettings(
          profileId: profileId,
        );
        expect(restored.showCurrentTime, isTrue);
        expect(restored.effectiveShowCurrentTime, isTrue);
      },
    );

    test(
      'an ordinary settings save converges the legacy column to true',
      () async {
        await repository.savePlannerSettings(
          profileId: profileId,
          settings: const PlannerSettings.defaults(),
        );
        await writeLegacyRow(showCurrentTime: false);

        // A save carrying the stale false still persists the EFFECTIVE value,
        // so the legacy value converges without a migration.
        await repository.savePlannerSettings(
          profileId: profileId,
          settings: (await repository.readPlannerSettings(
            profileId: profileId,
          )).copyWith(showCurrentTime: false),
        );

        final raw = await (database.select(
          database.plannerPreferences,
        )..where((table) => table.profileId.equals(profileId))).getSingle();
        expect(raw.showCurrentTime, isTrue);
      },
    );

    test(
      'a legitimate saved zoom is retained, never reset to Normal',
      () async {
        for (final hourHeight in <double>[44, 60, 88, 121]) {
          await repository.savePlannerSettings(
            profileId: profileId,
            settings: PlannerSettings.defaults().copyWith(
              timelineHourHeight: hourHeight,
            ),
          );
          final restored = await repository.readPlannerSettings(
            profileId: profileId,
          );
          expect(
            restored.timelineHourHeight,
            hourHeight,
            reason: 'saved zoom $hourHeight must round-trip unchanged',
          );
        }
      },
    );

    test('a corrupt persisted zoom falls back into the safety range', () async {
      await repository.savePlannerSettings(
        profileId: profileId,
        settings: const PlannerSettings.defaults(),
      );

      await writeLegacyRow(timelineHourHeight: 9999);
      final high = await repository.readPlannerSettings(profileId: profileId);
      expect(
        high.timelineHourHeight,
        PlannerZoomPolicy.absoluteMaximumHourHeight,
      );

      await writeLegacyRow(timelineHourHeight: 0);
      final low = await repository.readPlannerSettings(profileId: profileId);
      expect(
        low.timelineHourHeight,
        PlannerZoomPolicy.absoluteMinimumHourHeight,
      );
    });

    test(
      'the effective visible range derives from the stored boundaries',
      () async {
        await repository.savePlannerSettings(
          profileId: profileId,
          settings: const PlannerSettings.defaults().copyWith(
            visibleStartHour: 6,
            visibleEndHour: 18,
          ),
        );

        final restored = await repository.readPlannerSettings(
          profileId: profileId,
        );
        // 6 AM first boundary, 6 PM final boundary, inclusive labels.
        expect(restored.visibleStartHour, 6);
        expect(restored.visibleEndHour, 18);
        expect(restored.visibleStartMinute, 6 * 60);
        expect(restored.visibleEndMinute, 18 * 60);
        expect(restored.visibleSpanHours, 12);
        expect(restored.visibleSpanMinutes, 12 * 60);
      },
    );

    test('the full-day window maps 24 to next-day midnight', () async {
      await repository.savePlannerSettings(
        profileId: profileId,
        settings: const PlannerSettings.defaults().copyWith(
          visibleStartHour: 0,
          visibleEndHour: 24,
        ),
      );

      final restored = await repository.readPlannerSettings(
        profileId: profileId,
      );
      expect(restored.visibleStartMinute, 0);
      expect(restored.visibleEndMinute, 24 * 60);
      expect(restored.visibleSpanHours, 24);
    });

    test('a reversed range is rejected rather than stored', () async {
      await expectLater(
        repository.savePlannerSettings(
          profileId: profileId,
          settings: const PlannerSettings.defaults().copyWith(
            visibleStartHour: 18,
            visibleEndHour: 6,
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
