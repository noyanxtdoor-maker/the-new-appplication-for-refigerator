import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';

import '../../../support/test_dependencies.dart';

/// OPD-3-004 PRESENTATION AFTER OWNER ARCHIVE (VS-11C1A.2, 2026-08-17).
///
/// Owner override: explicit per-Contact "Meaningful Connections" confirmation
/// is DEFERRED/ARCHIVED and is no longer an active VS-11 release gate. The
/// active Event reporting UX is event-level:
///  - a report-required Event (including a `meaningful_connection` Contact
///    Event) with linked People shows NO per-person confirmation section;
///  - Save submits the classic event-level ScheduledPotentialRule
///    contribution (exactly one) and never fabricates contact_id rows;
///  - the v29 per-Contact backend stays dormant: an explicit
///    confirmedContactIds list still writes deterministic per-Contact rows.
void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);
  const eventId = '88888888-8888-4888-8888-888888888888';
  const contactA = 'aaaa0000-0000-4000-8000-000000000001';
  const contactB = 'aaaa0000-0000-4000-8000-000000000002';
  const contributionRule = 'life-indicator:meaningful_connections:1:0:count';
  const profileId = '11111111-1111-4111-8111-111111111111';

  Future<({AppDatabase database, DriftOutcomeReportingRepository reports})>
  pumpContactEvent(WidgetTester tester) async {
    tester.view.physicalSize = const Size(862, 1824);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startupRepository = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    final profile = await startupRepository.completeOnboarding();
    final linkRepository = DriftTaskEventLinkRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final reportingRepository = DriftOutcomeReportingRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final calendarRepository = DriftCalendarEventRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
      taskContextSource: linkRepository,
      linkContextTransfer: linkRepository,
      reportSource: reportingRepository,
    );
    final plannerRepository = DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      calendarSource: calendarRepository,
      taskContextSource: linkRepository,
      historicalEffectReader: reportingRepository,
    );
    final contactRepository = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      identifiers: const UuidIdentifierSource(),
    );
    for (final (id, name) in <(String, String)>[
      (contactA, 'Ana Reyes'),
      (contactB, 'Ben Cruz'),
    ]) {
      await contactRepository.createContact(
        profileId: profile.id,
        draft: ContactDraft(
          id: id,
          firstName: name.split(' ').first,
          lastName: name.split(' ').last,
          displayName: name,
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );
    }
    await calendarRepository.saveEvent(
      profileId: profile.id,
      draft: const CalendarEventDraft(
        id: eventId,
        title: 'Weekly connection visit',
        timing: CalendarEventTiming.timed,
        startDate: selected,
        startMinute: 9 * 60,
        endMinute: 10 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: true,
        contributionRuleKey: contributionRule,
        activityTypeId: SystemEventTypeIds.meaningfulConnection,
        activityTypeStableKeySnapshot: SystemEventTypeKeys.meaningfulConnection,
        activityTypeLabelSnapshot: 'Meaningful Connections',
      ),
    );
    await contactRepository.setEventPeople(
      profileId: profile.id,
      eventId: eventId,
      occurrenceId: DriftContactRepository.seriesOccurrenceId,
      originalDate: selected,
      contactIds: const <String>[contactA, contactB],
    );

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        plannerRepository: plannerRepository,
        calendarEventRepository: calendarRepository,
        contactRepository: contactRepository,
        plannerDateSource: const FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: selected,
    );
    await tester.tap(find.byKey(Key('planner-timed-event-$occurrenceId')));
    await tester.pumpAndSettle();

    return (database: database, reports: reportingRepository);
  }

  Future<void> scrollToStatusSection(WidgetTester tester) async {
    final formList = find.byKey(const Key('calendar-event-form-scroll'));
    final section = find.byKey(const Key('event-status-section'));
    for (var i = 0; i < 12 && section.evaluate().isEmpty; i++) {
      await tester.drag(formList, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    await tester.pumpAndSettle();
  }

  Future<void> stageCompletedFromDetail(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const Key('event-status-option-completedHappened')),
    );
    await tester.pumpAndSettle();
  }

  Future<void> saveForm(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('save-event-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-event-button')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'ARCHIVED: report-required Contact Event (meaningful_connection type) '
    'with People + Completed shows NO meaningful section; Save writes the '
    'classic event-level contribution with zero contact_id rows',
    (tester) async {
      final harness = await pumpContactEvent(tester);
      final database = harness.database;
      final reports = harness.reports;

      await stageCompletedFromDetail(tester);
      expect(find.byKey(const Key('event-title-field')), findsOneWidget);
      await scrollToStatusSection(tester);

      // The per-Contact confirmation UI is archived: nothing anywhere.
      expect(find.byKey(const Key('meaningful-section')), findsNothing);
      expect(
        find.text('Who did you meaningfully connect with?'),
        findsNothing,
      );
      for (final id in <String>[contactA, contactB]) {
        expect(find.byKey(Key('meaningful-contact-$id')), findsNothing);
      }

      // Save -> one event-level contribution, zero per-Contact rows, even
      // though this is a Contact Event with linked People.
      await saveForm(tester);
      final reportRows = await database.select(database.outcomeReports).get();
      expect(reportRows, hasLength(1));
      expect(reportRows.single.outcome, OutcomeKind.completedHappened.name);
      final effective = await reports.readLedgerHistory(
        profileId: profileId,
        indicatorKey: 'meaningful_connections',
        effectiveOnly: true,
      );
      expect(effective, hasLength(1));
      expect(effective.single.type, ActivityLedgerEntryType.contribution);
      expect(effective.single.contactId, isNull);
      expect(
        effective.where((row) => row.contactId != null),
        isEmpty,
        reason: 'linked People alone never create per-Contact Actual',
      );
    },
  );

  testWidgets(
    'ARCHIVED: the meaningful_connection Event Type does NOT re-enable the '
    'archived UI; the explicit dormant per-Contact API still works',
    (tester) async {
      final harness = await pumpContactEvent(tester);
      final database = harness.database;
      // Capture the app container BEFORE navigating into the form (the
      // Planner route may not stay in the element tree once covered).
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlannerScreen)),
      );

      // Pencil into the Edit Event form: no confirmation section, and the
      // ordinary Event field edits remain available.
      await tester.tap(find.byKey(const Key('event-detail-sheet-edit-icon')));
      await tester.pumpAndSettle();
      await scrollToStatusSection(tester);
      expect(find.byKey(const Key('meaningful-section')), findsNothing);

      // Dormant capability: an explicit confirmedContactIds list passed at a
      // low level still writes deterministic per-Contact attribution.
      final result = await container
          .read(outcomeReportingControllerProvider.notifier)
          .submitEventStatus(
            eventId: eventId,
            originalDate: selected,
            outcome: OutcomeKind.completedHappened,
            operationId: const UuidIdentifierSource().nextUuid(),
            contributionRuleKey: contributionRule,
            confirmedContactIds: const <String>[contactA, contactB],
          );
      expect(result, isNotNull);
      final ledger = await database
          .select(database.activityLedgerEntries)
          .get();
      final contactRows = ledger
          .where((row) => row.contactId != null)
          .toList(growable: false);
      expect(contactRows, hasLength(2));
      expect(contactRows.map((row) => row.contactId).toSet(), {
        contactA,
        contactB,
      });
    },
  );
}
