// P4 (2026-09-22) — SMART UNREPORTED SUMMARY ROUTING on the real app.
//
// Tapping the generic/unreported SUMMARY notification must open the Unreported
// hub on the tab that owns the most actionable occurrences AT TAP TIME — never
// the counts the notification was rendered with, and never a permanent
// "winning tab".
//
// The laws under test:
//  * the tab comes from ONE fresh canonical projection per accepted tap;
//  * the tie priority is Life Goals -> Events -> Contacts;
//  * a zero backlog opens Life Goals and its honest empty state;
//  * the tab request is a typed ONE-SHOT: the user's own later tab selection is
//    never seized by a later backlog change;
//  * a wrong-profile intent is ignored before any read happens;
//  * a stale slow completion cannot override a later tap;
//  * a failed or timed-out read is NOT a zero backlog: the hub still opens on
//    its canonical first tab with honest state, and a late result cannot
//    redirect afterwards;
//  * a specific Event/Task intent never writes a summary tab request.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/router/app_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';
import 'package:rmplanner/features/unreported/presentation/unreported_screen.dart';

import '../support/test_dependencies.dart';

/// The canonical backlog seam, driven like the real provider: every
/// re-evaluation is counted so "one fresh projection per tap" is provable.
final class _Backlog {
  _Backlog(this._entries);

  List<UnreportedEntry> _entries;
  int evaluations = 0;
  bool gated = false;
  Completer<List<UnreportedEntry>>? _gate;

  set entries(List<UnreportedEntry> next) => _entries = next;

  Future<List<UnreportedEntry>> read() {
    evaluations++;
    if (!gated) return Future<List<UnreportedEntry>>.value(_entries);
    final gate = Completer<List<UnreportedEntry>>();
    _gate = gate;
    return gate.future;
  }

  /// Completes a gated read with the CURRENT entries (a late completion).
  void release() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete(_entries);
  }
}

void main() {
  late String profileId;

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    required _Backlog backlog,
    bool fail = false,
  }) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startupRepository = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    final profile = await startupRepository.completeOnboarding();
    profileId = profile.id;

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        extraOverrides: <Override>[
          unreportedEntriesProvider.overrideWith((ref) {
            if (fail) {
              return Future<List<UnreportedEntry>>.error(
                StateError('the canonical read failed'),
              );
            }
            return backlog.read();
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  String locationOf(ProviderContainer container) => container
      .read(appRouterProvider)
      .routerDelegate
      .currentConfiguration
      .uri
      .toString();

  int activeTabIndex(WidgetTester tester) =>
      tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

  UnreportedSummaryTabRequest? pendingRequest(ProviderContainer container) =>
      container.read(unreportedSummaryTabRequestProvider);

  // Every real summary tap carries the NEXT posted generation, and the
  // controller de-dupes an identical intent inside two seconds (the Android
  // double-tap guard), so each simulated tap takes a fresh generation.
  var summaryGeneration = 0;

  void tapSummary(ProviderContainer container, {String? forProfile}) {
    container
        .read(notificationResponseControllerProvider)
        .capture(
          payload: NotificationPayloadCodec.encode(
            NotificationResponseIntent(
              profileId: forProfile ?? profileId,
              sourceKind: NotificationSourceKind.unreportedSummary,
              sourceId: 'unreported-hub',
              action: NotificationResponseAction.open,
              generation: ++summaryGeneration,
            ),
          ),
        );
  }

  Future<void> openHubFromDrawer(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-unreported')));
    await tester.pumpAndSettle();
  }

  group('cold start / hub not yet mounted', () {
    testWidgets('an Events-majority backlog opens Events', (tester) async {
      final backlog = _Backlog(_mix(lifeGoals: 1, events: 4, contacts: 2));
      final container = await pumpApp(tester, backlog: backlog);
      expect(locationOf(container), isNot(RoutePaths.unreported));

      tapSummary(container);
      await tester.pumpAndSettle();

      expect(locationOf(container), RoutePaths.unreported);
      expect(activeTabIndex(tester), 1, reason: 'Events');
      // The visible tab renders exactly the seeded Events rows, so the routing
      // count source and the rendered rows are the same projection.
      for (var index = 0; index < 4; index++) {
        expect(
          find.byKey(Key('unreported-row-ev-$index')),
          findsOneWidget,
          reason: 'the routed tab renders the Events rows it counted',
        );
      }
      expect(
        find.byKey(const Key('unreported-row-lg-0')),
        findsNothing,
        reason: 'only the routed tab is visible',
      );
    });

    testWidgets('a Life Goals tie opens Life Goals', (tester) async {
      final backlog = _Backlog(_mix(lifeGoals: 2, events: 2, contacts: 2));
      final container = await pumpApp(tester, backlog: backlog);

      tapSummary(container);
      await tester.pumpAndSettle();

      expect(activeTabIndex(tester), 0, reason: 'Life Goals owns a tie');
    });

    testWidgets('an Events/Contacts tie below Life Goals opens Events', (
      tester,
    ) async {
      final backlog = _Backlog(_mix(lifeGoals: 1, events: 3, contacts: 3));
      final container = await pumpApp(tester, backlog: backlog);

      tapSummary(container);
      await tester.pumpAndSettle();

      expect(activeTabIndex(tester), 1, reason: 'Events outranks Contacts');
    });

    testWidgets('a Contacts-majority backlog opens Contacts', (tester) async {
      final backlog = _Backlog(_mix(lifeGoals: 0, events: 0, contacts: 1));
      final container = await pumpApp(tester, backlog: backlog);

      tapSummary(container);
      await tester.pumpAndSettle();

      expect(activeTabIndex(tester), 2, reason: 'Contacts');
      expect(find.byKey(const Key('unreported-row-co-0')), findsOneWidget);
    });

    testWidgets('a zero backlog opens Life Goals with its honest empty state', (
      tester,
    ) async {
      final backlog = _Backlog(const <UnreportedEntry>[]);
      final container = await pumpApp(tester, backlog: backlog);

      tapSummary(container);
      await tester.pumpAndSettle();

      expect(locationOf(container), RoutePaths.unreported);
      expect(activeTabIndex(tester), 0);
      expect(
        find.byKey(const Key('unreported-empty-lifeGoals')),
        findsOneWidget,
      );
    });

    testWidgets('tap-time truth beats the notification-time counts', (
      tester,
    ) async {
      // The notification was rendered while Life Goals dominated...
      final backlog = _Backlog(_mix(lifeGoals: 6));
      final container = await pumpApp(tester, backlog: backlog);
      final before = backlog.evaluations;

      // ...and the backlog moved to Contacts before the tap.
      backlog.entries = _mix(contacts: 1);
      tapSummary(container);
      await tester.pumpAndSettle();

      expect(
        activeTabIndex(tester),
        2,
        reason: 'the CURRENT backlog decides the tab, not the delivered count',
      );
      expect(
        backlog.evaluations,
        before + 1,
        reason: 'exactly ONE fresh canonical projection per accepted tap',
      );
    });

    testWidgets('a stale cached empty backlog cannot beat fresh truth', (
      tester,
    ) async {
      final backlog = _Backlog(const <UnreportedEntry>[]);
      final container = await pumpApp(tester, backlog: backlog);

      backlog.entries = _mix(events: 2);
      tapSummary(container);
      await tester.pumpAndSettle();

      expect(
        activeTabIndex(tester),
        1,
        reason: 'the cached empty list is stale',
      );
      expect(find.byKey(const Key('unreported-row-ev-1')), findsOneWidget);
    });
  });

  group('warm app / hub already mounted', () {
    testWidgets('a summary tap moves an already-mounted hub to the right tab', (
      tester,
    ) async {
      final backlog = _Backlog(_mix(lifeGoals: 1));
      final container = await pumpApp(tester, backlog: backlog);
      await openHubFromDrawer(tester);
      expect(find.byType(UnreportedScreen), findsOneWidget);
      // The user parked on Contacts.
      await tester.tap(find.byKey(const Key('unreported-tab-contacts')));
      await tester.pumpAndSettle();
      expect(activeTabIndex(tester), 2);

      backlog.entries = _mix(events: 3);
      tapSummary(container);
      await tester.pumpAndSettle();

      expect(activeTabIndex(tester), 1, reason: 'the request applies in place');
      expect(find.byType(UnreportedScreen), findsOneWidget);
    });

    testWidgets('the request is one-shot: a later manual tab change sticks', (
      tester,
    ) async {
      final backlog = _Backlog(_mix(events: 2));
      final container = await pumpApp(tester, backlog: backlog);
      await openHubFromDrawer(tester);

      tapSummary(container);
      await tester.pumpAndSettle();
      expect(activeTabIndex(tester), 1);
      expect(
        pendingRequest(container),
        isNull,
        reason: 'the hub consumes the request exactly once',
      );

      // The user takes control...
      await tester.tap(find.byKey(const Key('unreported-tab-contacts')));
      await tester.pumpAndSettle();
      expect(activeTabIndex(tester), 2);

      // ...and a later backlog change must not seize the tab back.
      backlog.entries = _mix(events: 9);
      container.invalidate(unreportedEntriesProvider);
      await tester.pumpAndSettle();
      expect(
        activeTabIndex(tester),
        2,
        reason: 'later backlog changes update rows, never the current tab',
      );
    });
  });

  group('profile / lifecycle', () {
    testWidgets('a wrong-profile summary intent reads nothing and routes '
        'nowhere', (tester) async {
      final backlog = _Backlog(_mix(events: 4));
      final container = await pumpApp(tester, backlog: backlog);
      final before = locationOf(container);
      final evaluations = backlog.evaluations;

      tapSummary(container, forProfile: 'a-different-profile');
      await tester.pumpAndSettle();

      expect(locationOf(container), before);
      expect(pendingRequest(container), isNull);
      expect(
        backlog.evaluations,
        evaluations,
        reason: 'another profile must not trigger a backlog read at all',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('unmounting during the await cancels the routing result', (
      tester,
    ) async {
      final backlog = _Backlog(_mix(events: 4))..gated = true;
      final container = await pumpApp(tester, backlog: backlog);

      tapSummary(container);
      await tester.pump();
      // The app goes away before the fresh read resolves.
      await tester.pumpWidget(const SizedBox());
      backlog.entries = _mix(contacts: 5);
      backlog.release();
      // Let the 5-second routing timeout drain so no timer outlives the test.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('duplicate taps and stale completions', () {
    testWidgets('concurrent taps are coalesced into ONE projection, and the '
        'latest tap wins', (tester) async {
      final backlog = _Backlog(_mix(lifeGoals: 6))..gated = true;
      final container = await pumpApp(tester, backlog: backlog);
      final before = backlog.evaluations;

      // The first tap's read is still in flight.
      tapSummary(container);
      await tester.pump();
      expect(backlog.evaluations, before + 1);

      // A second tap lands while the first read is still pending.
      tapSummary(container);
      await tester.pump();
      expect(
        backlog.evaluations,
        before + 1,
        reason: 'identical concurrent work is coalesced',
      );

      backlog.entries = _mix(contacts: 5);
      backlog.release();
      await tester.pumpAndSettle();

      expect(
        activeTabIndex(tester),
        2,
        reason: 'the newest accepted tap owns the routing result',
      );
    });
  });

  group('error and timeout', () {
    testWidgets('a hung read falls back after five seconds without '
        'hijacking later', (tester) async {
      final backlog = _Backlog(_mix(contacts: 9))..gated = true;
      final container = await pumpApp(tester, backlog: backlog);

      tapSummary(container);
      await tester.pump();
      expect(locationOf(container), isNot(RoutePaths.unreported));

      await tester.pump(const Duration(seconds: 5));
      // The hub is honest about the still-pending read (a spinner), so pump a
      // bounded amount instead of waiting for every frame to stop.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        locationOf(container),
        RoutePaths.unreported,
        reason: 'a timeout still routes to the canonical hub',
      );
      expect(
        activeTabIndex(tester),
        0,
        reason: 'the honest Life Goals default',
      );

      // The abandoned read finally completing must not redirect the user.
      backlog.release();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        activeTabIndex(tester),
        0,
        reason: 'a stale slow completion never seizes the tab afterwards',
      );
      expect(tester.takeException(), isNull);

      // A later tap still routes from fresh truth: the abandoned read left no
      // poisoned state behind (its slot was cleared on the timeout).
      backlog.entries = _mix(events: 3);
      backlog.gated = false;
      tapSummary(container);
      await tester.pumpAndSettle();
      expect(
        activeTabIndex(tester),
        1,
        reason: 'a new summary tap routes from the CURRENT backlog',
      );
    });

    testWidgets('a failing read is not a zero backlog', (tester) async {
      final backlog = _Backlog(const <UnreportedEntry>[]);
      final container = await pumpApp(tester, backlog: backlog, fail: true);

      tapSummary(container);
      await tester.pumpAndSettle();

      expect(locationOf(container), RoutePaths.unreported);
      expect(activeTabIndex(tester), 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('regression: other notification sources', () {
    testWidgets('a specific Event intent writes no summary tab request', (
      tester,
    ) async {
      final backlog = _Backlog(_mix(events: 3));
      final container = await pumpApp(tester, backlog: backlog);

      container
          .read(notificationResponseControllerProvider)
          .capture(
            payload: NotificationPayloadCodec.encode(
              NotificationResponseIntent(
                profileId: profileId,
                sourceKind: NotificationSourceKind.calendarEvent,
                sourceId: 'event-that-does-not-exist',
                occurrenceId: 'occurrence-that-does-not-exist',
                action: NotificationResponseAction.open,
              ),
            ),
          );
      await tester.pumpAndSettle();

      expect(
        pendingRequest(container),
        isNull,
        reason: 'the summary tab seam is summary-tap only',
      );
      expect(find.byType(UnreportedScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// A mixed backlog.  Each tab numbers its own occurrences, so `ev-0` is always
/// the first Events entry no matter how many Life Goals came before it.
List<UnreportedEntry> _mix({
  int lifeGoals = 0,
  int events = 0,
  int contacts = 0,
}) {
  return <UnreportedEntry>[
    for (var index = 0; index < lifeGoals; index++)
      _entry(UnreportedTab.lifeGoals, 'lg-$index'),
    for (var index = 0; index < events; index++)
      _entry(UnreportedTab.events, 'ev-$index'),
    for (var index = 0; index < contacts; index++)
      _entry(UnreportedTab.contacts, 'co-$index'),
  ];
}

UnreportedEntry _entry(UnreportedTab tab, String id) {
  return UnreportedEntry(
    tab: tab,
    event: _awaiting(id),
    goalId: null,
    contacts: const <UnreportedContactRef>[],
  );
}

AwaitingReportEvent _awaiting(String id) {
  final endUtc = DateTime.utc(2026, 9, 6, 10);
  return AwaitingReportEvent(
    item: PlannerCalendarItem(
      id: id,
      eventId: 'event-$id',
      originalDate: PlannerDate.fromDateTime(endUtc),
      title: 'Unreported $id',
      date: PlannerDate.fromDateTime(endUtc),
      timing: PlannerEventTiming.timed,
      state: PlannerEventState.scheduled,
      requiresReport: true,
      hasOutcomeReport: false,
      startUtc: endUtc.subtract(const Duration(hours: 1)),
      endUtc: endUtc,
    ),
    goalId: null,
    activityTypeStableKey: null,
  );
}
