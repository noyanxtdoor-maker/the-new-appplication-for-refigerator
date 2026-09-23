import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_form_screen.dart';

import '../../../support/test_dependencies.dart';

void main() {
  testWidgets(
    'overlap shows one informational note without writing or disabling Save',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final clock = FixedClock(DateTime.utc(2026, 9, 22, 8));
      final zones = IanaCalendarEventTimeZones(displayTimeZoneId: 'Etc/UTC');
      final links = DriftTaskEventLinkRepository(
        database: database,
        clock: clock,
      );
      final reports = DriftOutcomeReportingRepository(
        database: database,
        clock: clock,
      );
      final calendar = DriftCalendarEventRepository(
        database: database,
        clock: clock,
        timeZones: zones,
        taskContextSource: links,
        linkContextTransfer: links,
        reportSource: reports,
      );
      final planner = DriftPlannerRepository(
        database: database,
        clock: clock,
        calendarSource: calendar,
        taskContextSource: links,
        historicalEffectReader: reports,
      );
      final startup = buildTestRepository(database: database);
      final profile = await startup.completeOnboarding();
      final eventTypes = DriftEventTypeRepository(
        database: database,
        clock: clock,
      );
      final type = (await eventTypes.readEventTypes(profileId: profile.id))
          .firstWhere(
            (value) =>
                !value.isLockedWliType &&
                value.stableKey != SystemEventTypeKeys.contact,
          );
      const date = PlannerDate(year: 2026, month: 9, day: 22);
      await calendar.saveEvent(
        profileId: profile.id,
        draft: CalendarEventDraft(
          id: 'bbbbbbbb-5555-4555-8555-555555555501',
          title: 'Existing overlap',
          timing: CalendarEventTiming.timed,
          startDate: date,
          startMinute: 9 * 60 + 30,
          endMinute: 10 * 60 + 30,
          timeZoneId: 'Etc/UTC',
          activityTypeId: type.id,
          requiresReport: false,
        ),
      );
      final before = await database.select(database.calendarEvents).get();

      final privacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerRepository: planner,
          calendarEventRepository: calendar,
          plannerDateSource: const FixedPlannerDateSource(date),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      final anchor = tester.element(
        find.byKey(const Key('planner-date-picker-trigger')),
      );
      unawaited(
        Navigator.of(anchor).push(
          MaterialPageRoute<void>(
            builder: (_) => CalendarEventFormScreen.create(
              initialDate: date,
              initialEventType: type,
              initialStartMinute: 9 * 60,
              initialDurationMinutes: 60,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('event-schedule-conflict-warning')),
        findsOneWidget,
      );
      expect(find.text('Conflicting event'), findsOneWidget);
      final save = tester.widget<FilledButton>(
        find.byKey(const Key('save-event-button')),
      );
      expect(save.onPressed, isNotNull);
      expect(
        (await database.select(database.calendarEvents).get()).length,
        before.length,
      );
    },
  );
}
