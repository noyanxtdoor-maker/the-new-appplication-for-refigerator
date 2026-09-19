// Owner law (2026-09-19) — the canonical UNREPORTED hub contract.
//
// ONE unreported-Event backlog, classified into exactly one of three tabs by
// canonical linkage, counted once, and mirrored to the hamburger indicator and
// the summary notification from a SINGLE provider.  Tasks are not in the
// backlog at all: they have one canonical home, the Tasks screen.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';

void main() {
  group('classification is the frozen exactly-once law', () {
    test('a manual Goal link wins over every other relationship', () {
      expect(
        UnreportedClassification.classify(
          goalId: 'goal-1',
          activityTypeStableKey: SystemEventTypeKeys.contact,
          hasEffectiveContacts: true,
        ),
        UnreportedTab.lifeGoals,
      );
    });

    test('an automatically Goal-linked type also lands in Life Goals', () {
      expect(
        UnreportedClassification.classify(
          goalId: null,
          activityTypeStableKey: SystemEventTypeKeys.lockedWliTypeKeys.first,
          hasEffectiveContacts: false,
        ),
        UnreportedTab.lifeGoals,
      );
    });

    test('the Goal-linked classification never consults title text', () {
      // A plain type with no Goal link stays out of Life Goals no matter how
      // Goal-like the title reads — only canonical linkage decides.
      expect(
        UnreportedClassification.classify(
          goalId: null,
          activityTypeStableKey: 'other',
          hasEffectiveContacts: false,
        ),
        UnreportedTab.events,
      );
    });

    test('a linked Contact type or an effective Contact link lands in Contacts', () {
      expect(
        UnreportedClassification.classify(
          goalId: null,
          activityTypeStableKey: SystemEventTypeKeys.contact,
          hasEffectiveContacts: false,
        ),
        UnreportedTab.contacts,
      );
      expect(
        UnreportedClassification.classify(
          goalId: null,
          activityTypeStableKey: 'other',
          hasEffectiveContacts: true,
        ),
        UnreportedTab.contacts,
      );
    });

    test('everything remaining is a plain unreported Event', () {
      expect(
        UnreportedClassification.classify(
          goalId: null,
          activityTypeStableKey: 'other',
          hasEffectiveContacts: false,
        ),
        UnreportedTab.events,
      );
    });

    test('the Contact Event Type outranks nothing and is outranked by Goals', () {
      // Precedence law: Life Goals -> Contacts -> Events.  Exactly one tab per
      // occurrence, so the combined row count can never double-count.
      final classifications = <UnreportedTab>{
        UnreportedClassification.classify(
          goalId: null,
          activityTypeStableKey: SystemEventTypeKeys.contact,
          hasEffectiveContacts: true,
        ),
        UnreportedClassification.classify(
          goalId: null,
          activityTypeStableKey: 'other',
          hasEffectiveContacts: false,
        ),
      };
      expect(classifications.length, 2);
    });
  });

  group('one number feeds the hub, the indicator and the notification', () {
    test('the count is the combined row count across all three tabs', () async {
      final entries = <UnreportedEntry>[
        _entry(tab: UnreportedTab.lifeGoals, id: 'occurrence-a'),
        _entry(tab: UnreportedTab.events, id: 'occurrence-b'),
        _entry(tab: UnreportedTab.contacts, id: 'occurrence-c'),
      ];
      final container = ProviderContainer(
        overrides: <Override>[
          unreportedEntriesProvider.overrideWith((ref) async => entries),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(unreportedCountProvider), 0);
      await container.read(unreportedEntriesProvider.future);

      expect(container.read(unreportedCountProvider), 3);
      final perTab = <int>[
        for (final tab in UnreportedTab.values)
          container.read(unreportedEntriesForTabProvider(tab)).length,
      ];
      expect(perTab, <int>[1, 1, 1]);
      expect(
        perTab.fold<int>(0, (sum, value) => sum + value),
        container.read(unreportedCountProvider),
        reason: 'the tabs and the indicator must be the same number',
      );
    });

    test('an empty backlog counts zero and hides the indicator', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          unreportedEntriesProvider.overrideWith(
            (ref) async => const <UnreportedEntry>[],
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(unreportedEntriesProvider.future);
      expect(container.read(unreportedCountProvider), 0);
    });
  });

  group('Tasks are absent from the backlog by construction', () {
    test('the backlog provider never reads a Task source', () {
      final source = File(
        'lib/features/unreported/application/unreported_providers.dart',
      ).readAsStringSync();

      // The hub's only Event input is the awaiting-report backlog.
      expect(source, contains('CalendarEventAwaitingReportSource'));
      expect(source, contains('readAwaitingReportEvents'));
      // No Task read may exist here: a Task can never become an unreported row.
      expect(source, isNot(contains('readTaskUniverse')));
      expect(source, isNot(contains('PlannerTask')));
    });

    test('the hub screen has exactly the three owner tabs and no Tasks tab', () {
      final source = File(
        'lib/features/unreported/presentation/unreported_screen.dart',
      ).readAsStringSync();

      expect(source, contains("Tab(key: Key('unreported-tab-life-goals')"));
      expect(source, contains("Tab(key: Key('unreported-tab-events')"));
      expect(source, contains("Tab(key: Key('unreported-tab-contacts')"));
      expect(source, contains('length: 3'));
      expect(source, isNot(contains("'Tasks'")));
      // The row opens the SAME canonical Event detail flow as the Planner.
      expect(source, contains('openPlannerCalendarEvent('));
    });
  });

  group('the summary notification', () {
    test('the appended source kind round-trips through the payload codec', () {
      final intent = NotificationResponseIntent(
        profileId: 'profile',
        sourceKind: NotificationSourceKind.unreportedSummary,
        sourceId: 'unreported-hub',
        action: NotificationResponseAction.open,
      );

      final decoded = NotificationPayloadCodec.tryDecode(
        NotificationPayloadCodec.encode(intent),
      );

      expect(decoded, intent);
      // Appended LAST: existing payload values persist across updates and must
      // never be reordered or reused.
      expect(
        NotificationSourceKind.values.last,
        NotificationSourceKind.unreportedSummary,
      );
    });

    test('the gateway posts the count with its tap intent', () {
      final source = File(
        'lib/core/notifications/'
        'flutter_local_notifications_launcher_badge_gateway.dart',
      ).readAsStringSync();

      expect(source, contains('NotificationSourceKind.unreportedSummary'));
      expect(source, contains('payload: payload'));
      // The count is always profile-scoped, so a tap can be routed.
      expect(source, contains('required String profileId'));
    });

    test('tapping the summary notification opens the Unreported hub', () {
      final source = File('lib/app/next_transfer_app.dart').readAsStringSync();

      expect(
        RegExp(
          r'case NotificationSourceKind\.unreportedSummary:[\s\S]*?'
          r'router\.go\(RoutePaths\.unreported\)',
        ).hasMatch(source),
        isTrue,
        reason: 'the summary tap must open the canonical hub',
      );
      // No fabricated destination: the hub is a real route.
      expect(RoutePaths.unreported, '/unreported');
    });
  });
}

UnreportedEntry _entry({required UnreportedTab tab, required String id}) {
  final endUtc = DateTime.utc(2026, 9, 6, 10);
  return UnreportedEntry(
    tab: tab,
    event: AwaitingReportEvent(
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
    ),
    goalId: null,
    contacts: const <UnreportedContactRef>[],
  );
}
