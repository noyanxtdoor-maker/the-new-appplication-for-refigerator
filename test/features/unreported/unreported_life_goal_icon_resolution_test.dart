// Owner law (2026-09-20) — every Unreported → Life Goals row shows its OWN
// Life Goal's chosen icon.
//
// OWNER-REPORTED DEFECT: all Life Goals rows rendered the SAME generic Life
// Goal glyph.  An Event created under one of the six fixed Goal-linked Event
// Types carries NO manual `goalId`, yet its Event Type IS the canonical alias
// for a Goal slot — so the slot's live occupant is the linked Goal and the row
// must draw THAT Goal's own icon.
//
// This is the owner's physical path end to end: the REAL backlog provider
// against a REAL database, with nothing stubbed except the calendar's "today".
// On the pre-fix baseline the provider attached no Goal to the row, so both
// rows drew the same fallback glyph and the icon assertions below failed.  It
// deliberately touches no post-fix API, so it compiles and fails *behaviourally*
// on that baseline rather than merely failing to build.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../support/test_dependencies.dart';

void main() {
  const fixedToday = PlannerDate(year: 2026, month: 9, day: 21);

  testWidgets(
    'GOAL-ICON-3 (real backlog): two auto-linked Life Goals rows render two '
    'different Goal icons',
    (tester) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final clock = FixedClock(DateTime.utc(2026, 9, 21, 8));
      final events = DriftCalendarEventRepository(
        database: database,
        clock: clock,
        timeZones: IanaCalendarEventTimeZones(
          displayTimeZoneId: 'Asia/Manila',
        ),
      );
      final startup = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profileId = (await startup.completeOnboarding()).id;

      // The canonical system Event Types exist first, then the slot Goals are
      // created through the canonical Goal repository — the production order.
      final eventTypes = DriftEventTypeRepository(
        database: database,
        clock: clock,
      );
      await eventTypes.readEventTypes(profileId: profileId);

      final goalRepository = DriftGoalRepository(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );
      const amount = IndicatorAmount(scaledValue: 1, scale: 0, unit: 'count');

      // Two Goals, each with its OWN chosen icon — the same write the Goal
      // editor makes.  The repository owns slot allocation, so the slot is read
      // back rather than assumed.
      Future<CanonicalGoalSlot> occupy({
        required GoalRole role,
        required String title,
        required String iconId,
      }) async {
        final goal = await goalRepository.createGoal(
          profileId: profileId,
          role: role,
          title: title,
          targets: const GoalTargets(weekly: amount),
          operationId: 'goal-icon-resolution-$title',
        );
        final affected =
            await (database.update(database.goals)
                  ..where((table) => table.id.equals(goal.id)))
                .write(GoalsCompanion(iconId: Value<String?>(iconId)));
        expect(affected, 1, reason: 'the created Goal must be re-iconed');
        return CanonicalGoalSlot.bySlot(goal.activeSlotIndex!);
      }

      final slotA = await occupy(
        role: GoalRole.dailyWeekly,
        title: 'Goal A',
        iconId: 'work_briefcase',
      );
      final slotB = await occupy(
        role: GoalRole.weekly,
        title: 'Goal B',
        iconId: 'jogging',
      );
      expect(
        slotA.slotIndex,
        isNot(slotB.slotIndex),
        reason: 'the two Goals must occupy two different slots',
      );

      // Two Events under the fixed Goal-linked Event Types, with NO manual Goal
      // link and awaiting report — exactly what the owner creates in the app.
      Future<void> saveEvent({
        required CanonicalGoalSlot slot,
        required String id,
        required String title,
      }) {
        return events.saveEvent(
          profileId: profileId,
          draft: CalendarEventDraft(
            id: id,
            title: title,
            timing: CalendarEventTiming.allDay,
            startDate: PlannerDate.parse('2026-09-19'),
            activityTypeId: slot.eventTypeId,
            activityTypeStableKeySnapshot: slot.eventTypeStableKey,
            activityTypeLabelSnapshot: slot.eventTypeStableKey,
            activityTypeColorValueSnapshot: 0xFF000000,
            recurrence: const CalendarRecurrenceRule(),
            requiresReport: true,
            isBackupAppointment: false,
          ),
        );
      }

      const eventA = 'a1000000-0000-4000-8000-000000000001';
      const eventB = 'a2000000-0000-4000-8000-000000000002';
      await saveEvent(slot: slotA, id: eventA, title: 'Apply somewhere');
      await saveEvent(slot: slotB, id: eventB, title: 'Run');

      // The canonical backlog names the rows, so the assertions address the real
      // occurrence ids rather than a guess.
      final backlog = await events.readAwaitingReportEvents(
        profileId: profileId,
        today: fixedToday,
        nowUtc: DateTime.now().toUtc(),
      );
      expect(backlog, hasLength(2));
      String occurrenceOf(String eventId) => backlog
          .firstWhere((entry) => entry.item.eventId == eventId)
          .item
          .id;

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          calendarEventRepository: events,
          extraOverrides: <Override>[
            plannerDateSourceProvider.overrideWithValue(
              const FixedPlannerDateSource(fixedToday),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-unreported')));
      await tester.pumpAndSettle();

      final markerA = find.byKey(
        Key('unreported-goal-marker-${occurrenceOf(eventA)}'),
      );
      final markerB = find.byKey(
        Key('unreported-goal-marker-${occurrenceOf(eventB)}'),
      );
      expect(markerA, findsOneWidget);
      expect(markerB, findsOneWidget);

      final iconA = tester.widget<GoalIcon>(markerA).iconId;
      final iconB = tester.widget<GoalIcon>(markerB).iconId;
      expect(
        iconA,
        'work_briefcase',
        reason: "the Job Application row must render ITS Goal's own icon",
      );
      expect(
        iconB,
        'jogging',
        reason: "the Exercise row must render ITS Goal's own icon",
      );
      expect(
        iconA,
        isNot(iconB),
        reason: 'two auto-linked Life Goals must not share one generic icon.',
      );
      // The generic fallback glyph is what every row used to draw; it must not
      // appear on a row whose Goal resolves.
      expect(find.byIcon(Icons.track_changes_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
