// POST-P2 OWNER DECISION (2026-09-22) — "Completed Events" in the Planner
// top-bar "Show in Planner" popup.
//
// Owner law:
//   * the menu reads, in order: Events, Completed Events, Backup Events, Tasks,
//     Completed Tasks;
//   * "Completed Events" is ON by default;
//   * it is NOT a second preference. It reads and writes the SAME persisted
//     value as Planner & Calendar -> Display -> "Show completed events"
//     (`PlannerSettings.showCompletedItems`), so the two surfaces can never
//     disagree, and no second column or parallel state exists.
//
// The tests below drive the REAL popup against the real persisted settings row:
//   * the menu order and the default are asserted on a default profile;
//   * unchecking Completed Events and pressing Apply must hide the completed
//     occurrence on the timeline AND leave the shared preference OFF in the
//     settings row the Settings screen reads;
//   * re-checking it must restore both;
//   * the Planner & Calendar screen, pumped afterwards from the same database,
//     must show the menu's own value — that is the synchronization proof, and
//     it is why this file uses two real screens rather than two mock objects.

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
import 'package:rmplanner/features/planner/presentation/planner_settings_screen.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/test_dependencies.dart';

const String _displayTimeZoneId = 'Asia/Manila';
const PlannerDate _selected = PlannerDate(year: 2026, month: 7, day: 27);

const String _scheduledId = '11111111-1111-4111-8111-111111111111';
const String _completedId = '22222222-2222-4222-8222-222222222222';

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

/// The five rows of the "Show in Planner" popup, in owner order.
const List<Key> _menuKeys = <Key>[
  Key('planner-filter-events'),
  Key('planner-filter-completed-events'),
  Key('planner-filter-backup-events'),
  Key('planner-filter-tasks'),
  Key('planner-filter-completed-tasks'),
];

void main() {
  late AppDatabase database;
  late String profileId;
  late DriftEventTypeRepository settingsRepository;
  late List<Override> overrides;

  setUp(() async {
    database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    profileId = (await startup.completeOnboarding()).id;

    settingsRepository = DriftEventTypeRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );

    final linkRepository = DriftTaskEventLinkRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final outcomeReportingRepository = DriftOutcomeReportingRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final plannerRepository = DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      calendarSource: _FixtureSource(<String, List<PlannerCalendarItem>>{
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
        ],
      }),
    );

    overrides = <Override>[
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
      calendarEventRepositoryProvider.overrideWithValue(
        DriftCalendarEventRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
          timeZones: IanaCalendarEventTimeZones(
            displayTimeZoneId: _displayTimeZoneId,
          ),
          taskContextSource: linkRepository,
          linkContextTransfer: linkRepository,
          reportSource: outcomeReportingRepository,
        ),
      ),
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
  });

  Future<void> pumpPlanner(WidgetTester tester) async {
    tester.view.physicalSize = const Size(862, 1824);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

  /// Opens the top-bar "Show in Planner" popup.
  Future<void> openFilterMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('planner-filter-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('planner-filter-menu')), findsOneWidget);
  }

  bool checkValue(WidgetTester tester, Key key) =>
      tester.widget<CheckboxListTile>(find.byKey(key)).value!;

  Future<void> toggle(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> apply(WidgetTester tester) async {
    // Scroll the footer into view first: the popup is scrollable and a small
    // viewport must not turn this into a tap on the dismiss barrier.
    await tester.ensureVisible(find.byKey(const Key('planner-filter-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-filter-apply')));
    await tester.pumpAndSettle();
  }

  Future<PlannerSettings> persistedSettings() =>
      settingsRepository.readPlannerSettings(profileId: profileId);

  testWidgets(
    'the popup lists all five options in the owner order, with Completed '
    'Events ON by default',
    (tester) async {
      await pumpPlanner(tester);
      await openFilterMenu(tester);

      for (final key in _menuKeys) {
        expect(
          find.byKey(key),
          findsOneWidget,
          reason: '$key must be rendered',
        );
      }

      double topOf(Key key) => tester.getTopLeft(find.byKey(key)).dy;
      for (var i = 1; i < _menuKeys.length; i++) {
        expect(
          topOf(_menuKeys[i - 1]),
          lessThan(topOf(_menuKeys[i])),
          reason:
              '${_menuKeys[i - 1]} must sit above ${_menuKeys[i]}: the owner '
              'fixed the order as Events, Completed Events, Backup Events, '
              'Tasks, Completed Tasks',
        );
      }

      expect(
        checkValue(tester, const Key('planner-filter-completed-events')),
        isTrue,
        reason: 'a default profile shows completed Events',
      );
      expect(
        (await persistedSettings()).showCompletedItems,
        isTrue,
        reason: 'and the shared persisted preference agrees',
      );

      await tester.tapAt(const Offset(12, 12));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'unchecking Completed Events hides the completed occurrence and leaves the '
    'SHARED preference OFF',
    (tester) async {
      await pumpPlanner(tester);
      expect(_timelineBlock(_completedId), findsOneWidget);

      await openFilterMenu(tester);
      await toggle(tester, const Key('planner-filter-completed-events'));
      expect(
        checkValue(tester, const Key('planner-filter-completed-events')),
        isFalse,
      );
      await apply(tester);

      expect(
        _timelineBlock(_completedId),
        findsNothing,
        reason: 'the menu option must be as real as the Settings toggle',
      );
      expect(
        _timelineBlock(_scheduledId),
        findsOneWidget,
        reason: 'a scheduled occurrence is never a completed one',
      );
      expect(
        (await persistedSettings()).showCompletedItems,
        isFalse,
        reason:
            'the menu wrote the SHARED preference, not a private filter flag',
      );
    },
  );

  testWidgets(
    're-checking Completed Events restores them, and Planner & Calendar reads '
    'the SAME value',
    (tester) async {
      await pumpPlanner(tester);

      // OFF through the menu...
      await openFilterMenu(tester);
      await toggle(tester, const Key('planner-filter-completed-events'));
      await apply(tester);
      expect(_timelineBlock(_completedId), findsNothing);

      // ...and ON again through the menu.
      await openFilterMenu(tester);
      await toggle(tester, const Key('planner-filter-completed-events'));
      await apply(tester);
      expect(_timelineBlock(_completedId), findsOneWidget);

      // The Settings screen, pumped from the same database, must show exactly
      // what the menu last wrote. This is the synchronization proof: one
      // screen wrote, the other read, and they cannot disagree because there is
      // only one persisted value.
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: const MaterialApp(home: PlannerSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final row = tester.widget<SwitchListTile>(
        find.byKey(const Key('show-completed-setting')),
      );
      expect(
        row.value,
        isTrue,
        reason: 'Settings must reflect the menu without a restart',
      );
      expect(find.text('Show completed events'), findsOneWidget);
    },
  );

  testWidgets(
    'the Settings toggle is the same preference the menu reads on open',
    (tester) async {
      // Write through the SETTINGS side first (the canonical controller), then
      // open the menu: the option must already read OFF.
      await settingsRepository.savePlannerSettings(
        profileId: profileId,
        settings: const PlannerSettings.defaults().copyWith(
          showCompletedItems: false,
        ),
      );

      await pumpPlanner(tester);
      expect(
        _timelineBlock(_completedId),
        findsNothing,
        reason: 'a value written by Settings governs the timeline',
      );

      await openFilterMenu(tester);
      expect(
        checkValue(tester, const Key('planner-filter-completed-events')),
        isFalse,
        reason: 'the menu must open on the value Settings persisted',
      );
      await tester.tapAt(const Offset(12, 12));
      await tester.pumpAndSettle();
    },
  );
}
