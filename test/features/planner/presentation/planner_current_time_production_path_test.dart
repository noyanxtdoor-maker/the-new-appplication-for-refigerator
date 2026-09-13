// VS16 M7 — Planner current-time PRODUCTION-PATH coverage.
//
// The focused `planner_current_time_indicator_test.dart` suite injects an
// external `ValueListenable<DateTime>` through
// `PlannerScreen(currentTimeListenable:)`. That is deliberate and correct for
// deterministic geometry tests, but it means the suite never exercises the
// PRODUCTION wiring: the screen-owned `ValueNotifier<DateTime>` created in
// `initState` and the minute-boundary `Timer` that refreshes it.
//
// This file closes that gap. It pumps the REAL `PlannerScreen` with NO
// `currentTimeListenable`, so the production path runs, and asserts:
//
//   1. the overlay is bound to a screen-owned `ValueNotifier<DateTime>`,
//      observed from the widget tree (no private state is touched);
//   2. that notifier drives the rendered readout — the label text equals
//      `formatPlannerCurrentTimeLabel(notifier.value)` exactly;
//   3. the minute-boundary ticker is LIVE: advancing the test clock past a
//      minute boundary causes the ticker to assign a NEW `DateTime` to the
//      notifier (proved with `identical`, which cannot be satisfied by the
//      pre-existing instance);
//   4. the ticker re-arms across boundaries and is torn down in `dispose`
//      (flutter_test fails the test if a timer is still pending after the
//      tree is disposed, so a missing `cancel()` is caught here).
//
// It does not restate the geometry contracts already covered by the focused
// suite; it proves the source of the current-time value.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/next_transfer_app.dart'
    show appEnvironmentProvider;
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/core/security/auth_token_store.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/task_event_link_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';

import '../../../support/test_dependencies.dart';

const String _tz = 'Asia/Manila';

List<Override> _overrides({
  required AppDatabase database,
  required TestPrivacyDependencies privacy,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required DriftStartupRepository startup,
}) {
  final link = DriftTaskEventLinkRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final outcome = DriftOutcomeReportingRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final calendar = DriftCalendarEventRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: _tz),
    taskContextSource: link,
    linkContextTransfer: link,
    reportSource: outcome,
  );
  return <Override>[
    appEnvironmentProvider.overrideWithValue(
      const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
    ),
    diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
    startupRepositoryProvider.overrideWithValue(startup),
    privacyRepositoryProvider.overrideWithValue(privacy.repository),
    privacyGateProvider.overrideWithValue(privacy.gate),
    deviceAuthenticatorProvider.overrideWithValue(privacy.authenticator),
    permissionGatewayProvider.overrideWithValue(privacy.permissionGateway),
    authTokenStoreProvider.overrideWithValue(
      SecureAuthTokenStore(privacy.secureStorage),
    ),
    calendarEventRepositoryProvider.overrideWithValue(calendar),
    eventTypeRepositoryProvider.overrideWithValue(
      DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      ),
    ),
    outcomeReportingRepositoryProvider.overrideWithValue(outcome),
    plannerRepositoryProvider.overrideWithValue(plannerRepository),
    contactRepositoryProvider.overrideWithValue(
      DriftContactRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        identifiers: const UuidIdentifierSource(),
      ),
    ),
    taskEventLinkRepositoryProvider.overrideWithValue(link),
    plannerDateSourceProvider.overrideWithValue(
      FixedPlannerDateSource(selected),
    ),
  ];
}

DriftPlannerRepository _plannerRepo(AppDatabase database) {
  final link = DriftTaskEventLinkRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final outcome = DriftOutcomeReportingRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final calendar = DriftCalendarEventRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: _tz),
    taskContextSource: link,
    linkContextTransfer: link,
    reportSource: outcome,
  );
  return DriftPlannerRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    calendarSource: calendar,
    taskContextSource: link,
    historicalEffectReader: outcome,
  );
}

class _Prewarm extends ConsumerWidget {
  const _Prewarm();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(startupControllerProvider);
    return const SizedBox.shrink();
  }
}

/// The production current-time source, read from the widget tree.
///
/// `PlannerScreen`'s `State` type is library-private, so this file deliberately
/// does NOT reach into private state. Instead it reads the
/// `ValueListenableBuilder<DateTime>` that the PRODUCTION overlay actually
/// subscribed to, scoped to the overlay's own key. Because no
/// `currentTimeListenable` was injected, that listenable can only be the
/// screen-owned `ValueNotifier<DateTime>` created in `initState` — so this
/// observes the real production source, and it observes the one the render
/// pipeline is bound to rather than merely the one the field holds.
ValueNotifier<DateTime> _screenOwnedNotifier(WidgetTester tester) {
  final builderFinder = find.descendant(
    of: find.byKey(const Key('planner-current-time-overlay')),
    matching: find.byType(ValueListenableBuilder<DateTime>),
  );
  expect(
    builderFinder,
    findsOneWidget,
    reason:
        'the production overlay must subscribe to exactly one '
        'ValueListenable<DateTime> source',
  );
  final listenable = tester
      .widget<ValueListenableBuilder<DateTime>>(builderFinder)
      .valueListenable;
  expect(
    listenable,
    isA<ValueNotifier<DateTime>>(),
    reason:
        'with no injected currentTimeListenable the production screen MUST '
        'create and own its ValueNotifier<DateTime> in initState, and the '
        'overlay must be bound to that very instance',
  );
  return listenable as ValueNotifier<DateTime>;
}

void main() {
  testWidgets(
    'CT-04 production path — the screen-owned notifier + minute-boundary '
    'ticker drive the rendered readout (no injected listenable)',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final plannerRepository = _plannerRepo(database);

      // The indicator only shows when the selected Planner date equals the
      // calendar date of the CLOCK — and the production clock is
      // `DateTime.now()`, which the test cannot pin. So the selected date is
      // derived from the real "now" and the planning window is widened to the
      // full civil day, which is the only way to exercise the production path
      // deterministically at any wall-clock time.
      final today = PlannerDate.fromDateTime(DateTime.now());

      final privacy = TestPrivacyDependencies(database: database);
      final startup = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      await startup.completeOnboarding();

      Widget app(Widget child) => ProviderScope(
        overrides: _overrides(
          database: database,
          privacy: privacy,
          plannerRepository: plannerRepository,
          selected: today,
          startup: startup,
        ),
        child: MaterialApp(home: child),
      );

      await tester.pumpWidget(app(const _Prewarm()));
      final prewarmElement = tester.element(find.byType(_Prewarm));
      await ProviderScope.containerOf(
        prewarmElement,
      ).read(startupControllerProvider.notifier).initialize();
      await tester.pumpAndSettle();

      // NOTE: no `currentTimeListenable:` argument — this is the production
      // construction path.
      await tester.pumpWidget(app(const PlannerScreen()));
      await tester.pumpAndSettle();

      final plannerElement = tester.element(find.byType(PlannerScreen));
      final container = ProviderScope.containerOf(plannerElement);
      await container
          .read(plannerControllerProvider.notifier)
          .selectDate(today);
      await tester.pumpAndSettle();

      // Widen the planning window so the indicator is reachable whatever the
      // real wall-clock hour is (the shipped default window is 6..22).
      final settingsController = container.read(
        eventTypeControllerProvider.notifier,
      );
      await settingsController.saveSettings(
        container
            .read(eventTypeControllerProvider)
            .settings
            .copyWith(visibleStartHour: 0, visibleEndHour: 24),
      );
      await tester.pumpAndSettle();

      // ---- 1. the screen owns the notifier -------------------------------
      final notifier = _screenOwnedNotifier(tester);

      // ---- 2. that notifier drives the rendered readout ------------------
      final indicator = find.byKey(const Key('planner-current-time-indicator'));
      expect(
        indicator,
        findsOneWidget,
        reason: 'the production-owned clock must produce a visible indicator',
      );
      final label = find.byKey(const Key('planner-current-time-label'));
      expect(label, findsOneWidget);
      expect(
        tester.widget<Text>(label).data,
        formatPlannerCurrentTimeLabel(notifier.value),
        reason:
            'the readout must be built from the SCREEN-OWNED notifier value, '
            'proving the production source is live (not the injected seam)',
      );

      // ---- 3. the minute-boundary ticker is live -------------------------
      // `onTick` assigns a freshly constructed `DateTime.now()` to the
      // notifier. `ValueNotifier` skips the assignment only when the new value
      // is `==` to the old one; because real wall-clock microseconds elapse
      // between `initState` and the tick, the assigned instance is always a
      // NEW object. So `identical` is an exact, non-flaky proof that the
      // timer callback actually ran: if the timer had not fired, the notifier
      // would still hold the very same instance.
      final before = notifier.value;
      await tester.pump(const Duration(seconds: 61));
      expect(
        identical(notifier.value, before),
        isFalse,
        reason:
            'the minute-boundary ticker must fire and refresh the '
            'screen-owned notifier with a new DateTime',
      );

      // The readout still tracks the notifier after the tick.
      expect(
        tester.widget<Text>(label).data,
        formatPlannerCurrentTimeLabel(notifier.value),
        reason: 'after a tick the readout must still mirror the notifier',
      );

      // ---- 4. the ticker re-arms across a second boundary ----------------
      final afterFirstTick = notifier.value;
      await tester.pump(const Duration(seconds: 61));
      expect(
        identical(notifier.value, afterFirstTick),
        isFalse,
        reason: 'the ticker must re-arm itself after each tick',
      );
      expect(
        tester.widget<Text>(label).data,
        formatPlannerCurrentTimeLabel(notifier.value),
      );
      expect(tester.takeException(), isNull);

      // ---- 5. dispose cancels the ticker ---------------------------------
      // Unmounting runs `PlannerScreenState.dispose`, which cancels
      // `_currentTimeTicker`. flutter_test fails the test if a timer is still
      // pending after the tree is torn down, so this unmount is the assertion.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
