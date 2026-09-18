import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// VS-11C1A: Event edit/report integration (owner lock).
///
/// One canonical Edit Event form:
///  - NORMAL Event            -> no Current Status section, no report section
///  - REPORT-REQUIRED Event   -> Current Status section inside the SAME form;
///    status intent tapped in the detail routes to the form (staged, never
///    persisted until Save); Save commits through the canonical
///    submitEventStatus -> submit path only.
///
/// VS-11C1A.2 (owner override): the per-Contact Meaningful Connections
/// confirmation is ARCHIVED. The active UI never passes confirmedContactIds
/// (null -> classic event-level contribution, Event-Type agnostic), and the
/// inline meaningful section no longer exists. Historical per-Contact rows
/// are preserved by the same-outcome null no-op and the save guard.
void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);
  const future = PlannerDate(year: 2026, month: 9, day: 10);
  const eventId = '88888888-8888-4888-8888-888888888888';
  const contactA = 'aaaa0000-0000-4000-8000-000000000001';
  const contactB = 'aaaa0000-0000-4000-8000-000000000002';
  const contributionRule = 'life-indicator:meaningful_connections:1:0:count';
  const exerciseRule = 'life-indicator:exercise:1:0:count';
  const profileId = '11111111-1111-4111-8111-111111111111';

  final uuid = const UuidIdentifierSource();

  // VS-11C1A: baseDraft carries the Meaningful Connections contribution rule
  // so a staged Completed save produces the canonical classic/per-Contact
  // contributions; Event Type identity stays generic (no activity type).
  const baseDraft = CalendarEventDraft(
    id: eventId,
    title: 'Current Status fixture',
    timing: CalendarEventTiming.timed,
    startDate: selected,
    startMinute: 9 * 60,
    endMinute: 11 * 60,
    timeZoneId: 'Asia/Manila',
    requiresReport: true,
    contributionRuleKey: contributionRule,
  );

  Future<({AppDatabase database, DriftOutcomeReportingRepository reports})>
  pumpApp(
    WidgetTester tester, {
    required CalendarEventDraft draft,
    List<(String, String)> contacts = const <(String, String)>[],
    List<String> peopleContactIds = const <String>[],
    PlannerDate plannerDate = selected,
    Future<void> Function({
      required String profileId,
      required DriftOutcomeReportingRepository reports,
    })? beforePump,
  }) async {
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
      identifiers: uuid,
    );
    for (final (id, name) in contacts) {
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
      draft: draft,
    );
    if (peopleContactIds.isNotEmpty) {
      await contactRepository.setEventPeople(
        profileId: profile.id,
        eventId: eventId,
        occurrenceId: DriftContactRepository.seriesOccurrenceId,
        originalDate: draft.startDate,
        contactIds: peopleContactIds,
      );
    }
    if (beforePump != null) {
      await beforePump(
        profileId: profile.id,
        reports: reportingRepository,
      );
    }

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
        plannerDateSource: FixedPlannerDateSource(plannerDate),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: draft.startDate,
    );
    await tester.tap(find.byKey(Key('planner-timed-event-$occurrenceId')));
    await tester.pumpAndSettle();

    return (database: database, reports: reportingRepository);
  }

  Future<void> openEditViaPencil(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('event-detail-sheet-edit-icon')));
    await tester.pumpAndSettle();
  }

  // The Current Status section sits at the bottom of the (lazy) Edit Event
  // ListView, so tests must scroll it into view before asserting on it.
  Future<void> scrollToStatusSection(WidgetTester tester) async {
    final formList = find.byKey(const Key('calendar-event-form-scroll'));
    final section = find.byKey(const Key('event-status-section'));
    for (var i = 0; i < 12 && section.evaluate().isEmpty; i++) {
      await tester.drag(formList, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    await tester.pumpAndSettle();
  }

  Future<void> saveForm(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('save-event-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-event-button')));
    await tester.pumpAndSettle();
  }

  OutcomeReportDraft reportDraft({
    required String id,
    required String ruleKey,
    required String indicatorKey,
    required OutcomeKind outcome,
    List<ContributionDraft> contributions = const <ContributionDraft>[],
  }) {
    return OutcomeReportDraft(
      id: id,
      source: OutcomeReportSource(
        type: OutcomeSourceType.event,
        sourceId: eventId,
        label: 'Current Status fixture',
        activityDate: selected,
        eventId: eventId,
        occurrenceId: CalendarEventOccurrenceIdentity.forDate(
          eventId: eventId,
          originalDate: selected,
        ),
        originalDate: selected,
        isContactEvent: true,
      ),
      activityDate: selected,
      outcome: outcome,
      contributions: contributions,
      // Mirrors submitEventStatus: Event Current Status writes intentionally
      // do not open a factual-value form.
      allowUnstructuredPartial: true,
    );
  }

  group('A. NORMAL EVENT', () {
    testWidgets('pencil opens Edit Event with NO Current Status and NO '
        'meaningful section, even with linked People', (tester) async {
      await pumpApp(
        tester,
        draft: const CalendarEventDraft(
          id: eventId,
          title: 'Plain event',
          timing: CalendarEventTiming.timed,
          startDate: selected,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
        ),
        contacts: <(String, String)>[(contactA, 'Ana Reyes')],
        peopleContactIds: const <String>[contactA],
      );
      await openEditViaPencil(tester);

      expect(find.byKey(const Key('event-status-section')), findsNothing);
      expect(find.byKey(const Key('meaningful-section')), findsNothing);
      expect(find.text('Current Status'), findsNothing);
    });
  });

  group('B/C. REPORT-REQUIRED VIA PENCIL + STATUS SHORTCUT', () {
    testWidgets(
      'status intent tap in detail routes to the SAME Edit Event form, stages '
      'the intended status, Back without Save persists NOTHING, and the detail '
      'has no direct report-commit check action',
      (tester) async {
        final harness = await pumpApp(tester, draft: baseDraft);

        // The detail sheet must no longer offer a direct commit action.
        expect(find.byKey(const Key('event-status-save')), findsNothing);
        expect(find.byKey(const Key('event-status-control')), findsOneWidget);

        // Tapping the Completed intent routes to the Edit Event form.
        await tester.tap(
          find.byKey(const Key('event-status-option-completedHappened')),
        );
        await tester.pumpAndSettle();

        // The SAME Edit Event form is now open.
        expect(find.byKey(const Key('event-title-field')), findsOneWidget);

        // Current Status section is present and the intended status staged.
        await scrollToStatusSection(tester);
        expect(find.byKey(const Key('event-status-section')), findsOneWidget);
        expect(find.text('Completed'), findsOneWidget);

        // Back without Save: no report, no ledger, no status write.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          await harness.database.select(harness.database.outcomeReports).get(),
          isEmpty,
        );
        expect(
          await harness.database
              .select(harness.database.activityLedgerEntries)
              .get(),
          isEmpty,
        );

        // Reopen the Event: status is still Unreported.
        expect(find.byKey(const Key('event-status-current-label')), findsOneWidget);
        expect(find.text('Unreported'), findsOneWidget);
      },
    );

    testWidgets('pencil on a report-required past Event opens Edit Event with '
        'Current Status visible and loads the existing effective report',
        (tester) async {
      await pumpApp(
        tester,
        draft: baseDraft,
        beforePump: ({required profileId, required reports}) => reports.submit(
          profileId: profileId,
          draft: reportDraft(
            id: uuid.nextUuid(),
            ruleKey: contributionRule,
            indicatorKey: 'meaningful_connections',
            outcome: OutcomeKind.partiallyCompleted,
          ),
          operationId: uuid.nextUuid(),
        ),
      );
      await openEditViaPencil(tester);

      await scrollToStatusSection(tester);
      expect(find.byKey(const Key('event-status-section')), findsOneWidget);
      expect(find.text('Missed'), findsOneWidget);
    });
  });

  group('D. SAVE', () {
    testWidgets('Save on a report-required Event commits exactly once through '
        'the canonical submit path', (tester) async {
      final harness = await pumpApp(tester, draft: baseDraft);

      await tester.tap(
        find.byKey(const Key('event-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();
      await saveForm(tester);

      final reports = await harness.database
          .select(harness.database.outcomeReports)
          .get();
      expect(reports, hasLength(1));
      expect(reports.single.outcome, OutcomeKind.completedHappened.name);
      // The outcome report is the source of truth: the event status column
      // must NOT be substituted with the report outcome (no duplicate write).
      final eventRow = await (harness.database
              .select(harness.database.calendarEvents)
            ..where((table) => table.id.equals(eventId)))
          .getSingle();
      expect(eventRow.status, CalendarEventStatus.scheduled.name);

      // Reopen and Save again: idempotent, no duplicate report.
      await tester.tap(find.byKey(const Key('event-detail-sheet-edit-icon')));
      await tester.pumpAndSettle();
      await saveForm(tester);
      final after = await harness.database
          .select(harness.database.outcomeReports)
          .get();
      expect(after, hasLength(1));
    });

    testWidgets('normal Event Save performs no outcome-report write',
        (tester) async {
      final harness = await pumpApp(
        tester,
        draft: const CalendarEventDraft(
          id: eventId,
          title: 'Plain event',
          timing: CalendarEventTiming.timed,
          startDate: selected,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
        ),
      );
      await openEditViaPencil(tester);
      await saveForm(tester);

      expect(
        await harness.database.select(harness.database.outcomeReports).get(),
        isEmpty,
      );
      expect(
        await harness.database
            .select(harness.database.activityLedgerEntries)
            .get(),
        isEmpty,
      );
    });
  });

  group('E/F. PEOPLE / ARCHIVED PER-CONTACT (VS-11C1A.2)', () {
    testWidgets(
      'non-Contact Event Type (Exercise) + requiresReport + People + Completed '
      '-> NO meaningful section; Save creates ONE classic event-level '
      'contribution and zero per-Contact rows',
      (tester) async {
        final harness = await pumpApp(
          tester,
          draft: const CalendarEventDraft(
            id: eventId,
            title: 'Morning run',
            timing: CalendarEventTiming.timed,
            startDate: selected,
            startMinute: 9 * 60,
            endMinute: 11 * 60,
            timeZoneId: 'Asia/Manila',
            requiresReport: true,
            contributionRuleKey: exerciseRule,
            activityTypeId: SystemEventTypeIds.exercise,
            activityTypeStableKeySnapshot: SystemEventTypeKeys.exercise,
            activityTypeLabelSnapshot: 'Exercise',
          ),
          contacts: <(String, String)>[
            (contactA, 'Ana Reyes'),
            (contactB, 'Ben Cruz'),
          ],
          peopleContactIds: const <String>[contactA, contactB],
        );
        await tester.tap(
          find.byKey(const Key('event-status-option-completedHappened')),
        );
        await tester.pumpAndSettle();

        // The archived UI is gone for ANY Event Type (Exercise included).
        await scrollToStatusSection(tester);
        expect(find.byKey(const Key('meaningful-section')), findsNothing);
        expect(
          find.text('Who did you meaningfully connect with?'),
          findsNothing,
        );

        // Save -> exactly one classic event-level contribution (no per-Person
        // rows, no Event-Type special-case zero).
        await saveForm(tester);
        final effective = await harness.reports.readLedgerHistory(
          profileId: profileId,
          indicatorKey: 'exercise',
          effectiveOnly: true,
        );
        expect(effective, hasLength(1));
        expect(effective.single.type, ActivityLedgerEntryType.contribution);
        expect(effective.single.contactId, isNull);
        expect(
          effective.where((row) => row.contactId != null),
          isEmpty,
          reason: 'linked People never create per-Contact Actual',
        );
      },
    );

    testWidgets('report-required Event with zero People -> NO meaningful '
        'section (type name alone never creates it)', (tester) async {
      await pumpApp(tester, draft: baseDraft);
      await tester.tap(
        find.byKey(const Key('event-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();

      await scrollToStatusSection(tester);
      expect(find.byKey(const Key('meaningful-section')), findsNothing);
    });

    testWidgets('ordinary Event edit with unchanged report outcome does NOT '
        'rewrite existing historical per-Contact rows', (tester) async {
      final harness = await pumpApp(
        tester,
        draft: baseDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
        beforePump: ({required profileId, required reports}) => reports.submit(
          profileId: profileId,
          draft: reportDraft(
            id: uuid.nextUuid(),
            ruleKey: contributionRule,
            indicatorKey: 'meaningful_connections',
            outcome: OutcomeKind.completedHappened,
            contributions: const <ContributionDraft>[
              ContributionDraft(
                ruleKey: contributionRule,
                indicatorKey: 'meaningful_connections',
                value: IndicatorValue(
                  scaledValue: 1,
                  scale: 0,
                  unit: 'count',
                ),
                contactId: contactA,
              ),
              ContributionDraft(
                ruleKey: contributionRule,
                indicatorKey: 'meaningful_connections',
                value: IndicatorValue(
                  scaledValue: 1,
                  scale: 0,
                  unit: 'count',
                ),
                contactId: contactB,
              ),
            ],
          ),
          operationId: uuid.nextUuid(),
        ),
      );
      // Pencil -> the effective report status (Completed) is loaded; saving
      // without touching the status must not submit any report at all.
      await openEditViaPencil(tester);
      expect(find.text('Completed'), findsOneWidget);
      await saveForm(tester);

      final ledger = await harness.database
          .select(harness.database.activityLedgerEntries)
          .get();
      expect(ledger.length, 2); // A+B contributions, zero reversals
      expect(
        ledger.where(
          (row) => row.entryType == ActivityLedgerEntryType.reversal.name,
        ),
        isEmpty,
      );
      final reports = await harness.database
          .select(harness.database.outcomeReports)
          .get();
      expect(reports, hasLength(1));
    });
  });

  group('FUTURE ELIGIBILITY', () {
    testWidgets('future report-required Event -> no Current Status section in '
        'Edit Event', (tester) async {
      await pumpApp(
        tester,
        draft: const CalendarEventDraft(
          id: eventId,
          title: 'Upcoming run',
          timing: CalendarEventTiming.timed,
          startDate: future,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: true,
        ),
        plannerDate: future,
      );
      // The detail sheet must not show a status row for a future Event.
      expect(find.byKey(const Key('event-status-control')), findsNothing);
      await openEditViaPencil(tester);
      expect(find.byKey(const Key('event-status-section')), findsNothing);
      expect(find.byKey(const Key('meaningful-section')), findsNothing);
    });
  });
}
