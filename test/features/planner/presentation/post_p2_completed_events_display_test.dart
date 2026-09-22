// POST-P2 OWNER DECISION (2026-09-22) — "Show completed events".
//
// The audit proved the persisted `showCompletedItems` flag had NO renderer or
// filter consumer anywhere in lib/: completed Event occurrences always painted
// and the control was inert.  The owner made it real, for EVENTS ONLY, and
// renamed it (completed TASKS already have their own working filter in the
// Planner "Show in Planner" popup, so "items" claimed both).
//
// These tests fail against the pre-change tree:
//   * the completed occurrence was in the timeline projection with the setting
//     OFF (there was no filter at all);
//   * the neighbouring-day preview likewise ignored the setting.
//
// SCOPE, DELIBERATELY NARROW: this is a PRESENTATION filter. It never queries,
// never deletes, never changes a report outcome and never touches recurrence
// identity — so `didNotHappen` (a distinct accepted outcome, not a completion)
// and scheduled occurrences must be untouched, and a cancelled/deleted
// occurrence must stay invisible under EVERY setting combination.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/next_transfer_app.dart'
    show appEnvironmentProvider;
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/core/security/auth_token_store.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/application/task_event_link_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_interactive_day_pager.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/test_dependencies.dart';

const String _displayTimeZoneId = 'Asia/Manila';
const PlannerDate _selected = PlannerDate(year: 2026, month: 7, day: 27);

const String _scheduledId = '11111111-1111-4111-8111-111111111111';
const String _completedId = '22222222-2222-4222-8222-222222222222';
const String _didNotHappenId = '33333333-3333-4333-8333-333333333333';
const String _cancelledId = '44444444-4444-4444-8444-444444444444';
const String _prevDayCompletedId = '55555555-5555-4555-8555-555555555555';

/// A synthetic calendar source, so the PRESENTATION filter can be measured with
/// no report pipeline, no recurrence expansion and no query in the way.
final class _FixtureSource implements PlannerCalendarSource {
  _FixtureSource(this.itemsByDate);

  final Map<String, List<PlannerCalendarItem>> itemsByDate;

  @override
  Future<List<PlannerCalendarItem>> readDay({
    required String profileId,
    required PlannerDate date,
  }) async => itemsByDate[date.iso8601] ?? const <PlannerCalendarItem>[];
}

PlannerCalendarItem _item({
  required String id,
  required PlannerEventState state,
  required PlannerDate date,
  required int startHour,
}) {
  return PlannerCalendarItem(
    id: CalendarEventOccurrenceIdentity.forDate(
      eventId: id,
      originalDate: date,
    ),
    title: 'Fixture ${state.name}',
    eventId: id,
    originalDate: date,
    date: date,
    timing: PlannerEventTiming.timed,
    state: state,
    requiresReport: false,
    hasOutcomeReport: state != PlannerEventState.scheduled,
    startLocal: DateTime(date.year, date.month, date.day, startHour),
    endLocal: DateTime(date.year, date.month, date.day, startHour + 1),
  );
}

class _StartupPrewarm extends ConsumerWidget {
  const _StartupPrewarm();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(startupControllerProvider);
    return const SizedBox.shrink();
  }
}

String _occurrenceIdFor(String eventId, PlannerDate date) =>
    CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: date,
    );

Finder _timelineBlock(String eventId) => find.byKey(
  Key('planner-timed-event-${_occurrenceIdFor(eventId, _selected)}'),
);

Finder _previewBlock(String eventId, PlannerDate date) => find.byKey(
  Key('planner-pager-preview-event-${_occurrenceIdFor(eventId, date)}'),
);

void main() {
  group('the completed-occurrence predicate', () {
    // The predicate decides what the Day timeline AND its neighbouring-day
    // previews paint. Every state is pinned so a future edit cannot quietly
    // widen or narrow the law.
    PlannerCalendarItem item() => _item(
      id: _scheduledId,
      state: PlannerEventState.scheduled,
      date: _selected,
      startHour: 9,
    );

    test('completed and partially-completed count as completed', () {
      expect(
        plannerItemIsCompletedOccurrence(
          const PlannerCalendarItem(
            id: 'a',
            title: 'a',
            date: _selected,
            timing: PlannerEventTiming.timed,
            state: PlannerEventState.completedHappened,
            requiresReport: true,
            hasOutcomeReport: true,
          ),
        ),
        isTrue,
      );
      expect(
        plannerItemIsCompletedOccurrence(
          const PlannerCalendarItem(
            id: 'b',
            title: 'b',
            date: _selected,
            timing: PlannerEventTiming.timed,
            state: PlannerEventState.partiallyCompleted,
            requiresReport: true,
            hasOutcomeReport: true,
          ),
        ),
        isTrue,
      );
    });

    test('scheduled, did-not-happen, cancelled and rescheduled do NOT', () {
      for (final state in <PlannerEventState>[
        PlannerEventState.scheduled,
        PlannerEventState.didNotHappen,
        PlannerEventState.cancelled,
        PlannerEventState.rescheduled,
      ]) {
        expect(
          plannerItemIsCompletedOccurrence(
            PlannerCalendarItem(
              id: state.name,
              title: state.name,
              date: _selected,
              timing: PlannerEventTiming.timed,
              state: state,
              requiresReport: true,
              hasOutcomeReport: false,
            ),
          ),
          isFalse,
          reason: '$state is not a completion',
        );
      }
      // Sanity: the fixture helper itself is a live item.
      expect(item().state, PlannerEventState.scheduled);
    });
  });

  group('the Day timeline obeys "Show completed events"', () {
    late AppDatabase database;
    late String profileId;

    Future<void> pumpPlanner(
      WidgetTester tester, {
      required bool showCompleted,
    }) async {
      tester.view.physicalSize = const Size(862, 1824);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final privacy = TestPrivacyDependencies(database: database);
      final startup = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      profileId = (await startup.completeOnboarding()).id;

      // Persist the owner's setting through the canonical settings row, so the
      // test measures the real read path rather than a hand-built object.
      final settingsRepository = DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      await settingsRepository.savePlannerSettings(
        profileId: profileId,
        settings: const PlannerSettings.defaults().copyWith(
          showCompletedItems: showCompleted,
        ),
      );

      final previous = _selected.addDays(-1);
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        calendarSource: _FixtureSource(<String, List<PlannerCalendarItem>>{
          previous.iso8601: <PlannerCalendarItem>[
            _item(
              id: _prevDayCompletedId,
              state: PlannerEventState.completedHappened,
              date: previous,
              startHour: 9,
            ),
          ],
          _selected.iso8601: <PlannerCalendarItem>[
            _item(
              id: _scheduledId,
              state: PlannerEventState.scheduled,
              date: _selected,
              startHour: 9,
            ),
            _item(
              id: _completedId,
              state: PlannerEventState.completedHappened,
              date: _selected,
              startHour: 11,
            ),
            _item(
              id: _didNotHappenId,
              state: PlannerEventState.didNotHappen,
              date: _selected,
              startHour: 13,
            ),
            _item(
              id: _cancelledId,
              state: PlannerEventState.cancelled,
              date: _selected,
              startHour: 15,
            ),
          ],
        }),
      );

      final linkRepository = DriftTaskEventLinkRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      final outcomeReportingRepository = DriftOutcomeReportingRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      final calendarRepository = DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        timeZones: IanaCalendarEventTimeZones(
          displayTimeZoneId: _displayTimeZoneId,
        ),
        taskContextSource: linkRepository,
        linkContextTransfer: linkRepository,
        reportSource: outcomeReportingRepository,
      );
      final overrides = <Override>[
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
        calendarEventRepositoryProvider.overrideWithValue(calendarRepository),
        eventTypeRepositoryProvider.overrideWithValue(settingsRepository),
        outcomeReportingRepositoryProvider.overrideWithValue(
          outcomeReportingRepository,
        ),
        plannerRepositoryProvider.overrideWithValue(plannerRepository),
        taskEventLinkRepositoryProvider.overrideWithValue(linkRepository),
        plannerDateSourceProvider.overrideWithValue(
          FixedPlannerDateSource(_selected),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: const MaterialApp(home: _StartupPrewarm()),
        ),
      );
      final prewarmElement = tester.element(find.byType(_StartupPrewarm));
      await ProviderScope.containerOf(
        prewarmElement,
      ).read(startupControllerProvider.notifier).initialize();
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp(
            home: PlannerScreen(
              currentTimeListenable: ValueNotifier<DateTime>(
                DateTime(2026, 7, 27, 12, 0),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final plannerElement = tester.element(find.byType(PlannerScreen));
      await ProviderScope.containerOf(
        plannerElement,
      ).read(plannerControllerProvider.notifier).selectDate(_selected);
      await tester.pumpAndSettle();
    }

    setUp(() async {
      database = openMemoryDatabase();
      addTearDown(database.close);
    });

    testWidgets(
      'OFF hides a completed occurrence but keeps every other state',
      (tester) async {
        await pumpPlanner(tester, showCompleted: false);

        expect(
          _timelineBlock(_completedId),
          findsNothing,
          reason:
              'a completed occurrence must not paint while the setting is off',
        );
        // Not completions: these must survive untouched.
        expect(_timelineBlock(_scheduledId), findsOneWidget);
        expect(
          _timelineBlock(_didNotHappenId),
          findsOneWidget,
          reason: '"Did not happen" is a distinct outcome, never a completion',
        );
        // And a cancelled (== deleted) occurrence is invisible either way.
        expect(_timelineBlock(_cancelledId), findsNothing);
      },
    );

    testWidgets('ON paints the completed occurrence again', (tester) async {
      await pumpPlanner(tester, showCompleted: true);

      expect(_timelineBlock(_completedId), findsOneWidget);
      expect(_timelineBlock(_scheduledId), findsOneWidget);
      expect(_timelineBlock(_didNotHappenId), findsOneWidget);
      expect(
        _timelineBlock(_cancelledId),
        findsNothing,
        reason: 'the cancelled/deleted law is independent of this setting',
      );
    });

    testWidgets('ON also shows the completed occurrence in the neighbouring '
        'day preview', (tester) async {
      final previous = _selected.addDays(-1);
      await pumpPlanner(tester, showCompleted: true);

      // The preview column is a real rendered page (the same key the pinch
      // preview-continuity suite reads), so this is the control case for the
      // OFF assertion below: it proves the fixture actually reaches the pager.
      expect(_previewBlock(_prevDayCompletedId, previous), findsOneWidget);
    });

    testWidgets('OFF hides the completed occurrence in the neighbouring day '
        'preview too', (tester) async {
      final previous = _selected.addDays(-1);
      await pumpPlanner(tester, showCompleted: false);

      expect(
        _previewBlock(_prevDayCompletedId, previous),
        findsNothing,
        reason:
            'a preview column must not show what the visible day would hide',
      );
      // The preview page itself still exists — only the completed occurrence
      // is gone, so this cannot pass by the whole page being absent.
      expect(
        find.byKey(Key('planner-day-page-${previous.iso8601}')),
        findsOneWidget,
      );
    });
  });
}
