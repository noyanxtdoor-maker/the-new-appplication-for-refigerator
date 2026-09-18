import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/event_color_math.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_content.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_color_resolver.dart';

import '../../../support/test_dependencies.dart';

/// Closed-beta V2 (owner decisions 2026-09-17) — Task vs Meal color identity.
///
/// The owner observed that Meal and Task are visibly different in the Event
/// Type selector and in Settings > Colors, yet their Planner timeline blocks
/// look effectively identical. The canonical Meal defaults are unchanged; the
/// Task default is retuned to a body that belongs to the Task's OWN warm
/// family. The interim cool-slate body #3D4F59 was physically rejected in owner
/// review #3 because on the device it reads BLUE, so the body is now the accent
/// hue carried into the accepted dark band (`#5D5956`).
///
/// These are REGRESSION FLOORS, not a palette-generation algorithm: a small
/// test-local RGB distance helper proves the two identities stay visually
/// distinguishable in the rendered dark and light block bodies, in the raw
/// configured pair, and in every surface that presents the Task identity.
void main() {
  // ---------------------------------------------------------------------
  // Regression floors (owner law, 2026-09-17).
  // ---------------------------------------------------------------------
  const double rawAccentFloor = 40;
  const double darkBlockFloor = 24;
  const double lightBlockFloor = 12;

  /// Euclidean distance in 8-bit RGB space. Deliberately not a perceptual
  /// metric: these are coarse regression floors, and a plain RGB distance
  /// keeps the contract readable and dependency-free.
  double rgbDistance(int leftArgb, int rightArgb) {
    final leftRed = (leftArgb >> 16) & 0xFF;
    final leftGreen = (leftArgb >> 8) & 0xFF;
    final leftBlue = leftArgb & 0xFF;
    final rightRed = (rightArgb >> 16) & 0xFF;
    final rightGreen = (rightArgb >> 8) & 0xFF;
    final rightBlue = rightArgb & 0xFF;
    return math.sqrt(
      math.pow(leftRed - rightRed, 2) +
          math.pow(leftGreen - rightGreen, 2) +
          math.pow(leftBlue - rightBlue, 2),
    );
  }

  double colorDistance(Color left, Color right) =>
      rgbDistance(left.toARGB32(), right.toARGB32());

  PlannerCalendarItem itemFor({
    required String activityTypeId,
    required int activityTypeColorValue,
  }) {
    final start = DateTime(2026, 9, 17, 9);
    return PlannerCalendarItem(
      id: 'identity-probe:$activityTypeId',
      title: 'Probe',
      date: const PlannerDate(year: 2026, month: 9, day: 17),
      timing: PlannerEventTiming.timed,
      state: PlannerEventState.scheduled,
      requiresReport: false,
      hasOutcomeReport: false,
      startLocal: start,
      endLocal: start.add(const Duration(minutes: 30)),
      activityTypeId: activityTypeId,
      activityTypeColorValue: activityTypeColorValue,
    );
  }

  test('the data-layer Task identity mirrors the presentation constant', () {
    expect(
      PlannerEventColorDefaults.taskStableKey,
      PlannerEventColorResolver.taskStableKey,
      reason:
          'The synthetic Task stable key must be identical in both layers, '
          'or a Task color save would be judged against the wrong identity.',
    );
  });

  test('Meal keeps its accepted warm beige identity', () {
    expect(PlannerEventColorDefaults.meal.accentArgb, 0xFFE1CFB9);
    expect(PlannerEventColorDefaults.meal.surfaceArgb, 0xFF4B4744);
  });

  test('Task carries the restored original warm accent on a warm dark body', () {
    // Owner law (2026-09-18, corrected after owner physical review #3): the
    // ORIGINAL Task accent returns AND the dark body belongs to the same warm
    // family. The retired pair was #F2E9E0 / #494844 — that body collapsed onto
    // Meal's own #4B4744 in Dark (ΔRGB 2,1,0) and in the Light render — and the
    // interim #3D4F59 detour was rejected as visibly BLUE on the device.
    expect(PlannerEventColorDefaults.task.accentArgb, 0xFFF2E9E0);
    expect(PlannerEventColorDefaults.task.surfaceArgb, 0xFF5D5956);
  });

  test('the Task dark body is the accent hue carried into the accepted band', () {
    // Owner law (2026-09-18): the dark body must NOT be a Task-only magic hex.
    // `PlannerEventColorDefaults.task` documents this exact derivation, so
    // recompute it here and fail the moment the two drift apart.
    final derived = EventColorMath.fromHsl(h: 30, s: 0.04, l: 0.35);
    expect(
      PlannerEventColorDefaults.task.surfaceArgb,
      derived,
      reason:
          'The Task dark body must stay the documented Task-hue derivation '
          '(${EventColorMath.formatHex(derived)}).',
    );
    expect(EventColorMath.formatHex(derived), '#5D5956');
  });

  test('the Task dark body is warm and subdued — never blue, never bright', () {
    final argb = PlannerEventColorDefaults.task.surfaceArgb;
    final hsl = EventColorMath.toHsl(argb);
    final red = (argb >> 16) & 0xFF;
    final green = (argb >> 8) & 0xFF;
    final blue = argb & 0xFF;
    // Warm family: a warm hue with a warm channel ordering.
    expect(hsl.h, lessThanOrEqualTo(60));
    expect(red, greaterThanOrEqualTo(green));
    expect(green, greaterThanOrEqualTo(blue));
    // Subdued: a low-chroma neutral, so it can never read as slate blue.
    expect(hsl.s, lessThan(0.10));
    // Not bright: it belongs to the dark block band, so white text keeps its
    // contrast (the generic light-muted derivation would only reach 3.83:1).
    expect(EventColorMath.relativeLuminance(argb), lessThan(0.20));
    expect(
      EventColorMath.contrastRatio(argb, 0xFFFFFFFF),
      greaterThanOrEqualTo(4.5),
    );
    // The physically rejected blue is gone for good.
    expect(argb, isNot(0xFF3D4F59));
  });

  test('the Task dark body stays perceptually clear of Meal and Shopping', () {
    for (final entry in <String, int>{
      'Meal': PlannerEventColorDefaults.meal.surfaceArgb,
      'Shopping': PlannerEventColorDefaults.work.surfaceArgb,
    }.entries) {
      final distance = EventColorMath.okLabDistance(
        PlannerEventColorDefaults.task.surfaceArgb,
        entry.value,
      );
      expect(
        EventColorMath.isNearDuplicate(
          PlannerEventColorDefaults.task.surfaceArgb,
          entry.value,
        ),
        isFalse,
        reason:
            'The Task dark body must not collapse onto ${entry.key} '
            '(OKLab distance $distance). The retired #494844 scored 0.004 '
            'against Meal, which is exactly the collision this body avoids.',
      );
    }
  });

  test('the raw configured Task accent stays clearly apart from Meal and '
      'Shopping', () {
    final neighbours = <String, EventColorPreference>{
      'Meal': PlannerEventColorDefaults.meal,
      // "Shopping" is the presented label of the stable Work identity.
      'Shopping': PlannerEventColorDefaults.work,
    };
    for (final entry in neighbours.entries) {
      expect(
        rgbDistance(
          entry.value.accentArgb,
          PlannerEventColorDefaults.task.accentArgb,
        ),
        greaterThanOrEqualTo(rawAccentFloor),
        reason:
            'The configured ${entry.key} and Task accents must differ by at '
            'least $rawAccentFloor RGB units. Before the 2026-09-18 restore the '
            'Task accent was #8FAFC2, only '
            '${rgbDistance(0xFF8FAFC2, PlannerEventColorDefaults.work.accentArgb).toStringAsFixed(1)} '
            'RGB units from Shopping — the owner-observed collision.',
      );
    }
    // Meal and Shopping both keep their accepted pairs; only Task moved.
    expect(PlannerEventColorDefaults.meal.accentArgb, 0xFFE1CFB9);
    expect(PlannerEventColorDefaults.meal.surfaceArgb, 0xFF4B4744);
    expect(PlannerEventColorDefaults.work.accentArgb, 0xFFA9BEC9);
    expect(PlannerEventColorDefaults.work.surfaceArgb, 0xFF43494D);
  });

  testWidgets(
    'the rendered Task block stays distinguishable from Shopping in dark AND light',
    (tester) async {
      final preferences = <String, EventColorPreference>{
        SystemEventTypeKeys.work: PlannerEventColorDefaults.work,
        PlannerEventColorResolver.taskStableKey: PlannerEventColorDefaults.task,
      };
      final shoppingItem = itemFor(
        activityTypeId: SystemEventTypeKeys.work,
        activityTypeColorValue: PlannerEventColorDefaults.work.accentArgb,
      );
      final taskItem = itemFor(
        activityTypeId: PlannerEventColorResolver.taskStableKey,
        activityTypeColorValue: PlannerEventColorDefaults.task.accentArgb,
      );

      Future<({Color shopping, Color task, Color accentShopping, Color accentTask})>
      capture({required bool dark}) async {
        late Color shopping;
        late Color task;
        late Color accentShopping;
        late Color accentTask;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: Builder(
              builder: (context) {
                shopping = PlannerEventColorResolver.surfaceColor(
                  context,
                  shoppingItem,
                  preferences,
                );
                task = PlannerEventColorResolver.surfaceColor(
                  context,
                  taskItem,
                  preferences,
                );
                accentShopping = PlannerEventColorResolver.accentColor(
                  context,
                  shoppingItem,
                  preferences,
                );
                accentTask = PlannerEventColorResolver.accentColor(
                  context,
                  taskItem,
                  preferences,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        return (
          shopping: shopping,
          task: task,
          accentShopping: accentShopping,
          accentTask: accentTask,
        );
      }

      // Every system body is a dark veil from the same accepted band, and the
      // Task body now sits in that band too (warm neutral #5D5956 instead of the
      // rejected slate blue). The identity separation a user actually reads
      // lives in the ACCENT, so the body floors here only have to prove that the
      // two bodies have not collapsed onto one another.
      const double shoppingDarkBodyFloor = 10;
      const double shoppingLightBodyFloor = 8;

      final dark = await capture(dark: true);
      expect(
        colorDistance(dark.accentShopping, dark.accentTask),
        greaterThanOrEqualTo(darkBlockFloor),
        reason:
            'Dark rendered Shopping(${dark.accentShopping.toARGB32().toRadixString(16)}) '
            'and Task(${dark.accentTask.toARGB32().toRadixString(16)}) accents must '
            'stay apart by at least $darkBlockFloor RGB units.',
      );
      expect(
        colorDistance(dark.shopping, dark.task),
        greaterThanOrEqualTo(shoppingDarkBodyFloor),
        reason:
            'Dark rendered Shopping(${dark.shopping.toARGB32().toRadixString(16)}) '
            'and Task(${dark.task.toARGB32().toRadixString(16)}) bodies must not '
            'collapse onto one another.',
      );

      final light = await capture(dark: false);
      expect(
        colorDistance(light.accentShopping, light.accentTask),
        greaterThanOrEqualTo(lightBlockFloor),
        reason:
            'Light rendered Shopping(${light.accentShopping.toARGB32().toRadixString(16)}) '
            'and Task(${light.accentTask.toARGB32().toRadixString(16)}) accents must '
            'stay apart by at least $lightBlockFloor RGB units.',
      );
      expect(
        colorDistance(light.shopping, light.task),
        greaterThanOrEqualTo(shoppingLightBodyFloor),
        reason:
            'Light rendered Shopping(${light.shopping.toARGB32().toRadixString(16)}) '
            'and Task(${light.task.toARGB32().toRadixString(16)}) bodies must not '
            'collapse onto one another.',
      );
    },
  );

  testWidgets(
    'the rendered Planner block bodies stay distinguishable in dark AND light',
    (tester) async {
      final preferences = <String, EventColorPreference>{
        SystemEventTypeKeys.meal: PlannerEventColorDefaults.meal,
        PlannerEventColorResolver.taskStableKey: PlannerEventColorDefaults.task,
      };
      final mealItem = itemFor(
        activityTypeId: SystemEventTypeKeys.meal,
        activityTypeColorValue: PlannerEventColorDefaults.meal.accentArgb,
      );
      final taskItem = itemFor(
        activityTypeId: PlannerEventColorResolver.taskStableKey,
        activityTypeColorValue: PlannerEventColorDefaults.task.accentArgb,
      );

      Future<({Color meal, Color task, Color accentMeal, Color accentTask})>
      capture({required bool dark}) async {
        late Color meal;
        late Color task;
        late Color accentMeal;
        late Color accentTask;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: Builder(
              builder: (context) {
                meal = PlannerEventColorResolver.surfaceColor(
                  context,
                  mealItem,
                  preferences,
                );
                task = PlannerEventColorResolver.surfaceColor(
                  context,
                  taskItem,
                  preferences,
                );
                accentMeal = PlannerEventColorResolver.accentColor(
                  context,
                  mealItem,
                  preferences,
                );
                accentTask = PlannerEventColorResolver.accentColor(
                  context,
                  taskItem,
                  preferences,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        return (
          meal: meal,
          task: task,
          accentMeal: accentMeal,
          accentTask: accentTask,
        );
      }

      final dark = await capture(dark: true);
      expect(
        colorDistance(dark.meal, dark.task),
        greaterThanOrEqualTo(darkBlockFloor),
        reason:
            'Dark rendered block bodies must differ by at least '
            '$darkBlockFloor RGB units (Meal ${dark.meal.toARGB32().toRadixString(16)}, '
            'Task ${dark.task.toARGB32().toRadixString(16)}).',
      );

      final light = await capture(dark: false);
      expect(
        colorDistance(light.meal, light.task),
        greaterThanOrEqualTo(lightBlockFloor),
        reason:
            'Light rendered block bodies must differ by at least '
            '$lightBlockFloor RGB units.',
      );
      // A distinguishable body is not enough on its own: the identity must
      // also survive the Light accent transform.
      expect(
        colorDistance(light.accentMeal, light.accentTask),
        greaterThanOrEqualTo(lightBlockFloor),
        reason: 'Light rendered accents must stay distinguishable too.',
      );
    },
  );

  testWidgets(
    'the RENDERED Planner timeline shows distinct Meal and Task block bodies',
    (tester) async {
      // End-to-end proof of the owner's exact observation: a real timed Task
      // footprint and a real Meal Event are rendered by the production Planner
      // day surface, and the block bodies they are painted with must differ.
      const selected = PlannerDate(year: 2026, month: 9, day: 17);
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
      final profile = await startup.completeOnboarding();

      final midnight = DateTime(selected.year, selected.month, selected.day);
      final mealStart = midnight.add(const Duration(hours: 12));
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 17, 6)),
        calendarSource: MemoryPlannerCalendarSource(<PlannerCalendarItem>[
          PlannerCalendarItem(
            id: 'meal-event',
            title: 'Lunch',
            date: selected,
            timing: PlannerEventTiming.timed,
            state: PlannerEventState.scheduled,
            requiresReport: false,
            hasOutcomeReport: false,
            startLocal: mealStart,
            endLocal: mealStart.add(const Duration(minutes: 60)),
            // A real Event carries the canonical Event Type ID (the Task
            // footprint is the special case that carries the synthetic stable
            // key instead), so this must be the ID for the colour map lookup.
            activityTypeId: SystemEventTypeIds.meal,
            activityTypeLabel: 'Meal',
            activityTypeColorValue: PlannerEventColorDefaults.meal.accentArgb,
          ),
        ]),
      );
      const taskId = 'v2-timed-task';
      await plannerRepository.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: taskId,
          title: 'Owner timed Task',
          dueDate: selected,
          dueMinute: 540,
          recurrence: PlannerTaskRecurrence.none,
          requiresReport: false,
        ),
      );

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerRepository: plannerRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('planner-day-scroll')), findsOneWidget);

      // The Meal Event and the Task footprint are rendered by two different
      // block widgets, so read the paint each one actually applies: the Event
      // content view's resolved pair, and the Task block's Material fill.
      final mealBlockView = tester
          .widgetList<PlannerEventBlockContentView>(
            find.byType(PlannerEventBlockContentView),
          )
          .firstWhere((view) => view.event.id == 'meal-event');
      final taskFootprint = find.byKey(Key('task-footprint:$taskId'));
      expect(taskFootprint, findsOneWidget);
      final taskFill = tester
          .widgetList<Material>(
            find.descendant(of: taskFootprint, matching: find.byType(Material)),
          )
          .first
          .color!;

      // Dark is the harness default, so each rendered pair is the canonical
      // stored/resolved pair the production block supplies itself.
      expect(taskFill.toARGB32(), PlannerEventColorDefaults.task.surfaceArgb);
      expect(
        mealBlockView.surfaceColor!.toARGB32(),
        PlannerEventColorDefaults.meal.surfaceArgb,
      );
      expect(
        mealBlockView.accentColor!.toARGB32(),
        PlannerEventColorDefaults.meal.accentArgb,
      );
      expect(
        colorDistance(taskFill, mealBlockView.surfaceColor!),
        greaterThanOrEqualTo(darkBlockFloor),
        reason:
            'The TWO RENDERED PLANNER BLOCK BODIES must be visually distinct — '
            'this is the exact owner-observed regression.',
      );
      // The resolved ACCENT pair is covered by the resolver-level test above;
      // this test owns the two RENDERED bodies, which is the owner's sighting.
    },
  );

  testWidgets(
    'a customized Task preference drives the Planner Task block and leaves Meal alone',
    (tester) async {
      const customTask = EventColorPreference(
        accentArgb: 0xFF6E8FA3,
        surfaceArgb: 0xFF2F3E46,
      );
      final preferences = <String, EventColorPreference>{
        SystemEventTypeKeys.meal: PlannerEventColorDefaults.meal,
        PlannerEventColorResolver.taskStableKey: customTask,
      };
      late Color taskSurface;
      late Color taskAccent;
      late Color mealSurface;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) {
              taskSurface = PlannerEventColorResolver.surfaceColor(
                context,
                itemFor(
                  activityTypeId: PlannerEventColorResolver.taskStableKey,
                  activityTypeColorValue: customTask.accentArgb,
                ),
                preferences,
              );
              taskAccent = PlannerEventColorResolver.accentColor(
                context,
                itemFor(
                  activityTypeId: PlannerEventColorResolver.taskStableKey,
                  activityTypeColorValue: customTask.accentArgb,
                ),
                preferences,
              );
              mealSurface = PlannerEventColorResolver.surfaceColor(
                context,
                itemFor(
                  activityTypeId: SystemEventTypeKeys.meal,
                  activityTypeColorValue:
                      PlannerEventColorDefaults.meal.accentArgb,
                ),
                preferences,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(taskSurface.toARGB32(), customTask.surfaceArgb);
      expect(taskAccent.toARGB32(), customTask.accentArgb);
      expect(
        mealSurface.toARGB32(),
        PlannerEventColorDefaults.meal.surfaceArgb,
      );
    },
  );

  group(
    'accent uniqueness treats the synthetic Task identity symmetrically',
    () {
      late AppDatabase database;
      late DriftEventTypeRepository repository;
      late String profileId;

      setUp(() async {
        database = openMemoryDatabase();
        profileId = (await buildTestRepository(
          database: database,
        ).completeOnboarding()).id;
        repository = DriftEventTypeRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 9, 17, 12)),
        );
      });

      tearDown(() => database.close());

      test('the Task may always keep its own current accent', () async {
        final saved = await repository.saveEventColorPreference(
          profileId: profileId,
          eventTypeStableKey: PlannerEventColorResolver.taskStableKey,
          preference: PlannerEventColorDefaults.task,
        );
        expect(
          saved[PlannerEventColorResolver.taskStableKey],
          PlannerEventColorDefaults.task,
        );
        final document = await repository.readEventColorPreferences(
          profileId: profileId,
        );
        expect(
          document[PlannerEventColorResolver.taskStableKey],
          PlannerEventColorDefaults.task,
        );
      });

      test('a real Event Type cannot take the Task accent', () async {
        // Symmetry: the synthetic Task identity is an active peer, so its color
        // cannot be claimed by a real Event Type.
        await expectLater(
          repository.saveEventColorPreference(
            profileId: profileId,
            eventTypeStableKey: SystemEventTypeKeys.service,
            preference: EventColorPreference(
              accentArgb: PlannerEventColorDefaults.task.accentArgb,
              surfaceArgb: PlannerEventColorDefaults.task.surfaceArgb,
            ),
          ),
          throwsA(isA<StateError>()),
        );
      });

      test('the Task cannot take an active Event Type accent', () async {
        final types = await repository.readEventTypes(profileId: profileId);
        final meal = types.singleWhere(
          (type) => type.stableKey == SystemEventTypeKeys.meal,
        );
        await expectLater(
          repository.saveEventColorPreference(
            profileId: profileId,
            eventTypeStableKey: PlannerEventColorResolver.taskStableKey,
            preference: EventColorPreference(
              accentArgb: PlannerEventColorDefaults.meal.accentArgb,
              surfaceArgb: PlannerEventColorDefaults.task.surfaceArgb,
            ),
          ),
          throwsA(isA<StateError>()),
          reason:
              'Meal(${meal.stableKey}) remains a protected active identity.',
        );
      });
    },
  );

  testWidgets(
    'the Event Type picker Task dot uses the live configured Task accent',
    (tester) async {
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
      final profile = await startup.completeOnboarding();

      const customTask = EventColorPreference(
        accentArgb: 0xFF6E8FA3,
        surfaceArgb: 0xFF2F3E46,
      );
      await DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 17, 12)),
      ).saveEventColorPreference(
        profileId: profile.id,
        eventTypeStableKey: PlannerEventColorResolver.taskStableKey,
        preference: customTask,
      );

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

      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('planner-day-scroll')),
        findsOneWidget,
        reason: 'the Planner Day surface must be mounted before probing.',
      );
      final plannerScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('planner-day-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      plannerScroll.position.jumpTo(0);
      await tester.pumpAndSettle();

      final surface = find.byKey(const Key('planner-timeline-create-surface'));
      await tester.tapAt(tester.getTopLeft(surface) + const Offset(20, 210));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-type-picker')), findsOneWidget);

      final taskDot = find.byKey(const Key('event-type-icon-planner_task'));
      expect(
        taskDot,
        findsOneWidget,
        reason: 'the Task row must expose its own identity dot.',
      );
      final decoration =
          tester.widget<DecoratedBox>(taskDot).decoration as BoxDecoration;
      expect(
        decoration.color!.toARGB32(),
        customTask.accentArgb,
        reason:
            'The picker Task dot must follow the live configured Task accent '
            'rather than a hard-coded literal.',
      );
    },
  );
}
