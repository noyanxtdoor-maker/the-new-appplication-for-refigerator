// Owner law (2026-09-19) — the Unreported hub surface.
//
// The drawer's planning area is exactly Tasks + Unreported, the Unreported row
// carries a RED NUMERIC indicator with no subtitle, the hub shows the three
// owner tabs (Life Goals, Events, Contacts) and never a Tasks tab, and an
// attached Contact keeps the canonical Contact hand-off.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';
import 'package:rmplanner/features/unreported/presentation/unreported_screen.dart';

import '../../support/test_dependencies.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    required List<UnreportedEntry> entries,
    Size size = const Size(431, 912),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
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
        extraOverrides: <Override>[
          unreportedEntriesProvider.overrideWith((ref) async => entries),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
  }

  Future<void> openHub(WidgetTester tester) async {
    await openDrawer(tester);
    await tester.tap(find.byKey(const Key('drawer-unreported')));
    await tester.pumpAndSettle();
  }

  testWidgets('the planning area is Tasks + Unreported with a red number', (
    tester,
  ) async {
    await pumpApp(
      tester,
      entries: <UnreportedEntry>[
        _entry(tab: UnreportedTab.lifeGoals, id: 'goal-occurrence'),
        _entry(tab: UnreportedTab.events, id: 'plain-occurrence'),
      ],
    );
    await openDrawer(tester);

    // Both planning destinations are present, in order, and the removed rows
    // are gone.
    expect(find.byKey(const Key('drawer-tasks')), findsOneWidget);
    expect(find.byKey(const Key('drawer-unreported')), findsOneWidget);
    for (final removed in <String>[
      'drawer-planner',
      'drawer-planning',
      'drawer-plan-history',
      'drawer-activity-history',
    ]) {
      expect(find.byKey(Key(removed)), findsNothing, reason: removed);
    }
    // The owner asked for a RED NUMBER and no subtitle copy.
    final badge = find.byKey(const Key('drawer-unreported-badge'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('2')),
      findsOneWidget,
    );
    expect(find.textContaining('requiring attention'), findsNothing);
  });

  testWidgets('the hub opens the three owner tabs and never a Tasks tab', (
    tester,
  ) async {
    await pumpApp(
      tester,
      entries: <UnreportedEntry>[
        _entry(tab: UnreportedTab.lifeGoals, id: 'goal-occurrence'),
        _entry(tab: UnreportedTab.events, id: 'plain-occurrence'),
      ],
    );
    await openHub(tester);

    expect(find.byType(UnreportedScreen), findsOneWidget);
    expect(find.byKey(const Key('unreported-tab-life-goals')), findsOneWidget);
    expect(find.byKey(const Key('unreported-tab-events')), findsOneWidget);
    expect(find.byKey(const Key('unreported-tab-contacts')), findsOneWidget);
    final tabs = find.descendant(
      of: find.byType(TabBar),
      matching: find.byType(Tab),
    );
    expect(tabs, findsNWidgets(3), reason: 'Tasks is not a fourth tab');

    // The Life Goals tab is selected first and shows only its own row.
    expect(
      find.byKey(const Key('unreported-row-goal-occurrence')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('unreported-row-plain-occurrence')),
      findsNothing,
    );
  });

  testWidgets('an attached Contact renders through the canonical Contact link', (
    tester,
  ) async {
    final contact = _contact('contact-1', 'Juan Dela Cruz');
    await pumpApp(
      tester,
      entries: <UnreportedEntry>[
        UnreportedEntry(
          tab: UnreportedTab.contacts,
          event: _awaiting('contact-occurrence'),
          goalId: null,
          contacts: <UnreportedContactRef>[
            UnreportedContactRef(
              contactId: contact.id,
              displayName: contact.displayName,
              contact: ContactSummary(contact: contact),
            ),
          ],
        ),
      ],
    );
    await openHub(tester);

    await tester.tap(find.byKey(const Key('unreported-tab-contacts')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('unreported-row-contact-occurrence')),
      findsOneWidget,
    );
    final link = find.byKey(const Key('unreported-contact-contact-1'));
    expect(link, findsOneWidget);
    expect(
      find.descendant(of: link, matching: find.text('Juan Dela Cruz')),
      findsOneWidget,
    );
  });

  testWidgets('an empty backlog shows no number and honest empty states', (
    tester,
  ) async {
    await pumpApp(tester, entries: const <UnreportedEntry>[]);
    await openDrawer(tester);

    expect(find.byKey(const Key('drawer-unreported-badge')), findsNothing);
    expect(find.byKey(const Key('drawer-tasks')), findsOneWidget);

    await tester.tap(find.byKey(const Key('drawer-unreported')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unreported-empty-lifeGoals')), findsOneWidget);
  });
}

UnreportedEntry _entry({required UnreportedTab tab, required String id}) {
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

Contact _contact(String id, String displayName) {
  final createdAt = DateTime.utc(2026, 9, 1, 9);
  return Contact(
    id: id,
    profileId: 'profile',
    firstName: displayName.split(' ').first,
    lastName: displayName.split(' ').last,
    displayName: displayName,
    preferredContactMethod: ContactPreferredMethod.message,
    isFavorite: false,
    lifecycleState: ContactLifecycleState.active,
    source: ContactSource.manual,
    createdAtUtc: createdAt,
    updatedAtUtc: createdAt,
  );
}
