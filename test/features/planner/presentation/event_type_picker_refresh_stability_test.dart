import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/planner/application/event_type_creation_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/presentation/event_type_picker_dialog.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/gated_event_type_repository.dart';
import '../../../support/test_dependencies.dart';

/// Closed-beta forensic regression (owner beta recording #2, 2026-09-18).
///
/// The recording shows the 'Select Event Type' selector on a real beta device
/// collapsing its list region to the empty-state line
/// 'No active Event Types are available.' thirteen times in thirteen seconds,
/// for 1-5 frames each (33-167 ms), while the title, the Cancel action and the
/// surrounding chrome stayed byte-identical. The measured blink rectangle is
/// exactly the empty-state `Text`'s own rect, so the selector was really
/// rendering "this profile has no Event Types" rather than losing a subtree.
///
/// Cause: [eventTypeCreationChoicesProvider] is a FutureProvider, so EVERY
/// re-resolution publishes AsyncLoading while Riverpod retains the previous
/// list in `value`. The selector resolved its rows through
/// `maybeWhen(orElse: const [])`, which discards that retained list, and the
/// sheet chose between the rows and the empty-state message on
/// `choices.isEmpty` alone. Any raw-controller reload, Goal change stream
/// emission or presentation-document write therefore blanked a perfectly valid
/// selector to a false statement about the profile's data.
///
/// This test is fail-first: on the pre-fix selector the pending-refresh
/// assertions below see the empty-state message and no rows.
void main() {
  late AppDatabase database;
  late GatedEventTypeRepository gatedTypes;

  setUp(() async {
    database = openMemoryDatabase();
    gatedTypes = GatedEventTypeRepository(
      DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 9, 12)),
      ),
    );
    // A real upgraded install: onboarding is complete and the canonical Goal
    // slots occupy their Event Types, which is what makes the picker resolve a
    // non-empty choosable list.
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    await seedLegacyCanonicalGoals(database, profile.id);
  });

  tearDown(() async {
    gatedTypes.releaseAll();
    await database.close();
  });

  Future<void> pumpPickerHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = FixedClock(DateTime.utc(2026, 9, 9, 12));
    final startup = buildTestRepository(database: database);
    final goals = DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          eventTypeRepositoryProvider.overrideWithValue(gatedTypes),
          goalRepositoryProvider.overrideWithValue(goals),
          startupRepositoryProvider.overrideWithValue(startup),
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(ThemeColorMode.blue),
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(startupControllerProvider);
              return Scaffold(
                body: TextButton(
                  key: const Key('open-picker'),
                  onPressed: () {
                    unawaited(
                      showEventTypePicker(context: context, ref: ref),
                    );
                  },
                  child: const Text('Open'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'an open selector keeps its resolved rows while the creation projection '
    're-resolves, and holds them non-actionable until it settles',
    (tester) async {
      await pumpPickerHost(tester);
      await tester.tap(find.byKey(const Key('open-picker')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('event-type-picker')),
        findsOneWidget,
        reason: 'the selector must open for this regression to be meaningful',
      );
      expect(
        find.byKey(const Key('event-type-picker-list')),
        findsOneWidget,
        reason: 'the seeded profile must resolve at least one Event Type',
      );
      expect(find.text('No active Event Types are available.'), findsNothing);

      final settledSize = tester.getSize(
        find.byKey(const Key('event-type-picker')),
      );
      final settledTaps = tester
          .widgetList<InkWell>(
            find.descendant(
              of: find.byKey(const Key('event-type-picker-list')),
              matching: find.byType(InkWell),
            ),
          )
          .map((well) => well.onTap)
          .toList();
      expect(settledTaps, isNotEmpty);
      expect(settledTaps.every((onTap) => onTap != null), isTrue);

      // Re-resolve the projection exactly the way the device does: a raw
      // controller reload keeps the previous creation list in `value` while the
      // fresh projection is pending.
      gatedTypes.blockGlobalReads = true;
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('event-type-picker'))),
      );
      unawaited(container.read(eventTypeControllerProvider.notifier).load());
      await tester.pump();
      await tester.pump();

      expect(
        find.text('No active Event Types are available.'),
        findsNothing,
        reason:
            'a pending refresh must never claim the profile has no Event Types',
      );
      expect(
        find.byKey(const Key('event-type-picker-list')),
        findsOneWidget,
        reason: 'the resolved rows must survive the pending refresh',
      );
      expect(
        tester.getSize(find.byKey(const Key('event-type-picker'))),
        settledSize,
        reason:
            'the selector geometry recorded on the beta device must not change',
      );
      expect(
        find.text('Select Event Type'),
        findsOneWidget,
        reason: 'the title stays stable while the projection re-resolves',
      );

      // The retained rows are visible but must not be selectable while the
      // fresh projection is pending: that is the archive/reoccupation tap
      // guard the original `orElse: const []` was protecting.
      final pendingTaps = tester
          .widgetList<InkWell>(
            find.descendant(
              of: find.byKey(const Key('event-type-picker-list')),
              matching: find.byType(InkWell),
            ),
          )
          .map((well) => well.onTap)
          .toList();
      expect(pendingTaps, isNotEmpty);
      expect(
        pendingTaps.every((onTap) => onTap == null),
        isTrue,
        reason: 'rows retained across a pending refresh must stay inert',
      );

      // Releasing the read must restore the settled selector exactly. The
      // reload is real database work, so give the event loop real turns before
      // asserting on the settled frame.
      gatedTypes.blockGlobalReads = false;
      gatedTypes.releaseGlobalReads();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-type-picker-list')), findsOneWidget);
      expect(find.text('No active Event Types are available.'), findsNothing);
      final controller = container.read(eventTypeControllerProvider);
      final projection = container.read(eventTypeCreationChoicesProvider);
      expect(controller.isLoading, isFalse, reason: 'the reload must complete');
      expect(
        projection.hasError,
        isFalse,
        reason: 'the fresh projection must resolve (${projection.error})',
      );
      expect(
        tester
            .widgetList<InkWell>(
              find.descendant(
                of: find.byKey(const Key('event-type-picker-list')),
                matching: find.byType(InkWell),
              ),
            )
            .every((well) => well.onTap != null),
        isTrue,
        reason:
            'the rows become selectable again once the projection settles '
            '(controllerLoading=${controller.isLoading}, '
            'controllerMessage=${controller.message}, '
            'projectionIsLoading=${projection.isLoading}, '
            'projectionHasError=${projection.hasError}, '
            'projectionHasValue=${projection.hasValue}, '
            'projectionError=${projection.error})',
      );
    },
  );
}
