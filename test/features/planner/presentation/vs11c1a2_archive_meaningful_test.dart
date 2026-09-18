import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
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

/// VS-11C1A.2: archive the per-Contact Meaningful Connections confirmation UX
/// and restore classic event-level report semantics (owner override).
///
///  - NO per-Contact confirmation UI anywhere in active Event edit/detail UX.
///  - Active UI submits WITHOUT confirmedContactIds (null) -> classic
///    event-level ScheduledPotentialRule contribution, even for Contact
///    Events; linked People alone never create contact_id rows.
///  - Historical per-Contact rows are preserved: an ordinary Event edit with
///    an unchanged report outcome never rewrites them.
///  - Dormant explicit mode survives: confirmedContactIds [A,B] -> per-Contact
///    attribution; [] -> explicit zero; null -> classic.
///  - Current Status is the FIRST section (above Event Type) in Edit Event.
///  - Notes hint follows the staged status; typed content is preserved.
///  - Removing a Person with X removes from draft immediately, persists after
///    Save; Back without Save preserves persisted People.
///  - Event detail/preview shows People above Activity History.
void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);
  const eventId = '88888888-8888-4888-8888-888888888888';
  const contactA = 'aaaa0000-0000-4000-8000-000000000001';
  const contactB = 'aaaa0000-0000-4000-8000-000000000002';
  const contributionRule = 'life-indicator:meaningful_connections:1:0:count';

  final uuid = const UuidIdentifierSource();

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

  // A Contact Event (isContactEvent = true via meaningful_connection type).
  const contactDraft = CalendarEventDraft(
    id: eventId,
    title: 'Weekly connection visit',
    timing: CalendarEventTiming.timed,
    startDate: selected,
    startMinute: 9 * 60,
    endMinute: 11 * 60,
    timeZoneId: 'Asia/Manila',
    requiresReport: true,
    contributionRuleKey: contributionRule,
    activityTypeId: SystemEventTypeIds.meaningfulConnection,
    activityTypeStableKeySnapshot: SystemEventTypeKeys.meaningfulConnection,
    activityTypeLabelSnapshot: 'Meaningful Connections',
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

  Future<void> scrollToStatusSection(WidgetTester tester) async {
    final formList = find.byKey(const Key('calendar-event-form-scroll'));
    final section = find.byKey(const Key('event-status-section'));
    for (var i = 0; i < 12 && section.evaluate().isEmpty; i++) {
      await tester.drag(formList, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    await tester.pumpAndSettle();
  }

  Future<void> scrollToPeopleSection(WidgetTester tester) async {
    final formList = find.byKey(const Key('calendar-event-form-scroll'));
    final section = find.byKey(const Key('event-people-section'));
    for (var i = 0; i < 14 && section.evaluate().isEmpty; i++) {
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

  Future<ProviderContainer> appContainer(WidgetTester tester) async {
    final element = tester.element(find.byType(PlannerScreen));
    return ProviderScope.containerOf(element);
  }

  OutcomeReportDraft reportDraft({
    required String id,
    required String ruleKey,
    required String indicatorKey,
    required OutcomeKind outcome,
    List<ContributionDraft> contributions = const <ContributionDraft>[],
    bool isContactEvent = false,
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
        isContactEvent: isContactEvent,
      ),
      activityDate: selected,
      outcome: outcome,
      contributions: contributions,
      allowUnstructuredPartial: true,
    );
  }

  ContributionDraft contactContribution(String contactId) {
    final rule = ScheduledPotentialRule.tryParse(contributionRule);
    return ContributionDraft(
      ruleKey: contributionRule,
      indicatorKey: rule!.indicatorKey,
      value: IndicatorValue(
        scaledValue: rule.value.scaledValue,
        scale: rule.value.scale,
        unit: rule.value.unit,
      ),
      contactId: contactId,
    );
  }

  group('A. ARCHIVED UX', () {
    testWidgets('report-required Event + People + Completed -> NO Meaningful '
        'Connections section in Edit Event', (tester) async {
      await pumpApp(
        tester,
        draft: contactDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
      );
      // The status shortcut routes straight into the Edit Event form with
      // Completed staged; that is the entry point under test.
      await tester.tap(
        find.byKey(const Key('event-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-title-field')), findsOneWidget);
      await scrollToStatusSection(tester);

      expect(find.byKey(const Key('meaningful-section')), findsNothing);
      expect(find.text('Meaningful Connections'), findsNothing);
      expect(find.text('Who did you meaningfully connect with?'), findsNothing);
      expect(
        find.byKey(Key('meaningful-contact-$contactA')),
        findsNothing,
      );
      expect(
        find.byKey(Key('meaningful-contact-$contactB')),
        findsNothing,
      );
    });

    testWidgets('Event Type meaningful_connection/contact does NOT re-enable '
        'the archived UI', (tester) async {
      await pumpApp(
        tester,
        draft: contactDraft,
        contacts: <(String, String)>[(contactA, 'Ana Reyes')],
        peopleContactIds: const <String>[contactA],
      );
      await tester.tap(
        find.byKey(const Key('event-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-title-field')), findsOneWidget);
      await scrollToStatusSection(tester);

      expect(find.byKey(const Key('meaningful-section')), findsNothing);
      expect(find.text('Meaningful Connections'), findsNothing);
      expect(find.text('Who did you meaningfully connect with?'), findsNothing);
    });

    testWidgets('Event detail keeps the Meaningful Connections Event Type '
        'label (concept preserved) with NO per-person confirmation UI',
        (tester) async {
      await pumpApp(
        tester,
        draft: contactDraft,
        contacts: <(String, String)>[(contactA, 'Ana Reyes')],
        peopleContactIds: const <String>[contactA],
      );
      // The Life Indicator / Event Type concept named "Meaningful Connections"
      // remains a normal Event Type label.
      expect(find.text('Meaningful Connections'), findsWidgets);
      // No per-person confirmation section/checkbox anywhere on the detail.
      expect(find.byKey(const Key('meaningful-section')), findsNothing);
      expect(
        find.text('Who did you meaningfully connect with?'),
        findsNothing,
      );
      expect(find.byKey(Key('meaningful-contact-$contactA')), findsNothing);
    });
  });

  group('B. NEW REPORT SEMANTICS (event-level)', () {
    testWidgets(
      'new Completed report with People linked -> classic event-level '
      'contribution, NOT one row per Person, even for a Contact Event',
      (tester) async {
        final harness = await pumpApp(
          tester,
          draft: contactDraft,
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
        await saveForm(tester);

        final ledger = await harness.database
            .select(harness.database.activityLedgerEntries)
            .get();
        final contributions = ledger
            .where(
              (row) =>
                  row.entryType ==
                  ActivityLedgerEntryType.contribution.name,
            )
            .toList(growable: false);
        // One event-level contribution, no per-Person rows.
        expect(contributions, hasLength(1));
        expect(contributions.single.contactId, isNull);
      },
    );

    testWidgets('linked People alone never create contact_id rows',
        (tester) async {
      final harness = await pumpApp(
        tester,
        draft: baseDraft,
        contacts: <(String, String)>[(contactA, 'Ana Reyes')],
        peopleContactIds: const <String>[contactA],
      );
      await tester.tap(
        find.byKey(const Key('event-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();
      await saveForm(tester);

      final ledger = await harness.database
          .select(harness.database.activityLedgerEntries)
          .get();
      expect(ledger.where((row) => row.contactId != null), isEmpty);
    });
  });

  group('C. HISTORICAL PER-CONTACT PRESERVATION', () {
    testWidgets(
      'ordinary Event edit (title only) with unchanged report outcome leaves '
      'existing per-Contact A+B ledger rows byte-preserved',
      (tester) async {
        final harness = await pumpApp(
          tester,
          draft: baseDraft,
          contacts: <(String, String)>[
            (contactA, 'Ana Reyes'),
            (contactB, 'Ben Cruz'),
          ],
          peopleContactIds: const <String>[contactA, contactB],
          beforePump: ({required profileId, required reports}) =>
              reports.submit(
                profileId: profileId,
                draft: reportDraft(
                  id: uuid.nextUuid(),
                  ruleKey: contributionRule,
                  indicatorKey: 'meaningful_connections',
                  outcome: OutcomeKind.completedHappened,
                  contributions: <ContributionDraft>[
                    contactContribution(contactA),
                    contactContribution(contactB),
                  ],
                ),
                operationId: uuid.nextUuid(),
              ),
        );

        final before = await harness.database
            .select(harness.database.activityLedgerEntries)
            .get();
        expect(
          before.where((row) => row.contactId != null),
          hasLength(2),
        );

        // Ordinary edit: change only the title, keep the staged status as the
        // loaded effective report (Completed) -> Save.
        await openEditViaPencil(tester);
        await tester.enterText(
          find.byKey(const Key('event-title-field')),
          'Renamed fixture',
        );
        await tester.pumpAndSettle();
        await saveForm(tester);

        final after = await harness.database
            .select(harness.database.activityLedgerEntries)
            .get();
        expect(after.length, before.length);
        final contactRows = after
            .where((row) => row.contactId != null)
            .toList(growable: false);
        expect(contactRows, hasLength(2));
        expect(contactRows.map((row) => row.contactId).toSet(), {
          contactA,
          contactB,
        });
        // No new reports were created by the ordinary edit.
        final reports = await harness.database
            .select(harness.database.outcomeReports)
            .get();
        expect(reports, hasLength(1));
      },
    );

    testWidgets('reopen after ordinary edit -> no hidden per-Contact rewrite',
        (tester) async {
      final harness = await pumpApp(
        tester,
        draft: baseDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
        beforePump: ({required profileId, required reports}) =>
            reports.submit(
              profileId: profileId,
              draft: reportDraft(
                id: uuid.nextUuid(),
                ruleKey: contributionRule,
                indicatorKey: 'meaningful_connections',
                outcome: OutcomeKind.completedHappened,
                contributions: <ContributionDraft>[
                  contactContribution(contactA),
                  contactContribution(contactB),
                ],
              ),
              operationId: uuid.nextUuid(),
            ),
      );
      await openEditViaPencil(tester);
      await tester.enterText(
        find.byKey(const Key('event-title-field')),
        'Renamed again',
      );
      await tester.pumpAndSettle();
      await saveForm(tester);

      // Reopen the event and save WITHOUT touching the status.
      await tester.tap(find.byKey(const Key('event-detail-sheet-edit-icon')));
      await tester.pumpAndSettle();
      await saveForm(tester);

      final ledger = await harness.database
          .select(harness.database.activityLedgerEntries)
          .get();
      // 2 seeded contributions + 0 reversals (no rewrite on either save).
      expect(ledger.length, 2);
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

  group('D. DORMANT CAPABILITY (explicit per-Contact mode)', () {
    testWidgets('explicit confirmedContactIds [A,B] still creates exactly two '
        'per-Contact contributions', (tester) async {
      final harness = await pumpApp(
        tester,
        draft: baseDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
      );
      final container = await appContainer(tester);
      final result = await container
          .read(outcomeReportingControllerProvider.notifier)
          .submitEventStatus(
            eventId: eventId,
            originalDate: selected,
            outcome: OutcomeKind.completedHappened,
            operationId: uuid.nextUuid(),
            contributionRuleKey: contributionRule,
            confirmedContactIds: const <String>[contactA, contactB],
          );
      expect(result, isNotNull);
      final ledger = await harness.database
          .select(harness.database.activityLedgerEntries)
          .get();
      final contactRows = ledger
          .where((row) => row.contactId != null)
          .toList(growable: false);
      expect(contactRows, hasLength(2));
      expect(contactRows.map((row) => row.contactId).toSet(), {
        contactA,
        contactB,
      });
    });

    testWidgets('explicit [] means explicit zero per-Contact', (tester) async {
      final harness = await pumpApp(
        tester,
        draft: contactDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
      );
      final container = await appContainer(tester);
      final result = await container
          .read(outcomeReportingControllerProvider.notifier)
          .submitEventStatus(
            eventId: eventId,
            originalDate: selected,
            outcome: OutcomeKind.completedHappened,
            operationId: uuid.nextUuid(),
            contributionRuleKey: contributionRule,
            confirmedContactIds: const <String>[],
          );
      expect(result, isNotNull);
      final ledger = await harness.database
          .select(harness.database.activityLedgerEntries)
          .get();
      expect(ledger.where((row) => row.contactId != null), isEmpty);
    });

    testWidgets('null/omitted -> classic event-level contribution even for a '
        'Contact Event (no Event-Type special-case zero)', (tester) async {
      final harness = await pumpApp(
        tester,
        draft: contactDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
      );
      final container = await appContainer(tester);
      final result = await container
          .read(outcomeReportingControllerProvider.notifier)
          .submitEventStatus(
            eventId: eventId,
            originalDate: selected,
            outcome: OutcomeKind.completedHappened,
            operationId: uuid.nextUuid(),
            contributionRuleKey: contributionRule,
          );
      expect(result, isNotNull);
      final ledger = await harness.database
          .select(harness.database.activityLedgerEntries)
          .get();
      final contributions = ledger
          .where(
            (row) =>
                row.entryType == ActivityLedgerEntryType.contribution.name,
          )
          .toList(growable: false);
      expect(contributions, hasLength(1));
      expect(contributions.single.contactId, isNull);
    });

    testWidgets('same outcome with null (archived UI) is a no-op that '
        'preserves existing per-Contact rows', (tester) async {
      final harness = await pumpApp(
        tester,
        draft: baseDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
        beforePump: ({required profileId, required reports}) =>
            reports.submit(
              profileId: profileId,
              draft: reportDraft(
                id: uuid.nextUuid(),
                ruleKey: contributionRule,
                indicatorKey: 'meaningful_connections',
                outcome: OutcomeKind.completedHappened,
                contributions: <ContributionDraft>[
                  contactContribution(contactA),
                  contactContribution(contactB),
                ],
              ),
              operationId: uuid.nextUuid(),
            ),
      );
      final container = await appContainer(tester);
      final result = await container
          .read(outcomeReportingControllerProvider.notifier)
          .submitEventStatus(
            eventId: eventId,
            originalDate: selected,
            outcome: OutcomeKind.completedHappened,
            operationId: uuid.nextUuid(),
            contributionRuleKey: contributionRule,
          );
      expect(result, isNotNull);
      expect(result!.unchanged, isTrue);
      final ledger = await harness.database
          .select(harness.database.activityLedgerEntries)
          .get();
      expect(
        ledger.where((row) => row.contactId != null),
        hasLength(2),
      );
      expect(
        ledger.where(
          (row) => row.entryType == ActivityLedgerEntryType.reversal.name,
        ),
        isEmpty,
      );
    });
  });

  group('E. STATUS / NOTES LAYOUT', () {
    testWidgets('report-required Edit Event: Current Status is BEFORE Event '
        'Type (first form section)', (tester) async {
      await pumpApp(tester, draft: baseDraft);
      await openEditViaPencil(tester);

      final statusSection = find.byKey(const Key('event-status-section'));
      final eventTypeField = find.byKey(const Key('event-type-field'));
      expect(statusSection, findsOneWidget);
      expect(eventTypeField, findsOneWidget);
      final statusDy = tester.getTopLeft(statusSection).dy;
      final typeDy = tester.getTopLeft(eventTypeField).dy;
      expect(statusDy, lessThan(typeDy));
    });

    testWidgets('normal Event: no Current Status section', (tester) async {
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
      );
      await openEditViaPencil(tester);
      expect(find.byKey(const Key('event-status-section')), findsNothing);
      expect(find.text('Current Status'), findsNothing);
    });

    testWidgets('Completed staged -> Notes hint "What happened?"',
        (tester) async {
      await pumpApp(tester, draft: baseDraft);
      await tester.tap(
        find.byKey(const Key('event-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('event-notes-field')));
      await tester.pumpAndSettle();
      expect(find.text('What happened?'), findsOneWidget);
    });

    testWidgets('Missed staged -> Notes hint "What happened? Why was it '
        'missed?"', (tester) async {
      await pumpApp(tester, draft: baseDraft);
      await tester.tap(
        find.byKey(const Key('event-status-option-partiallyCompleted')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('event-notes-field')));
      await tester.pumpAndSettle();
      expect(find.text('What happened? Why was it missed?'), findsOneWidget);
    });

    testWidgets('Unreported (default) -> generic Notes hint', (tester) async {
      await pumpApp(tester, draft: baseDraft);
      await openEditViaPencil(tester);
      await tester.tap(find.byKey(const Key('event-notes-field')));
      await tester.pumpAndSettle();
      expect(
        find.text('What do you need to remember about this?'),
        findsOneWidget,
      );
    });

    testWidgets('changing status does NOT erase typed Notes', (tester) async {
      await pumpApp(tester, draft: baseDraft);
      await openEditViaPencil(tester);
      await tester.enterText(
        find.byKey(const Key('event-notes-field')),
        'Remember the follow-up call',
      );
      await tester.pumpAndSettle();
      await scrollToStatusSection(tester);
      await tester.tap(
        find.byKey(const Key('event-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();
      final field = tester.widget<TextFormField>(
        find.byKey(const Key('event-notes-field')),
      );
      expect(field.controller?.text, 'Remember the follow-up call');
    });
  });

  group('F. PEOPLE REMOVE', () {
    testWidgets('A+B -> tap X on B -> B disappears from the draft immediately',
        (tester) async {
      await pumpApp(
        tester,
        draft: baseDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
      );
      await openEditViaPencil(tester);
      await scrollToPeopleSection(tester);
      await tester.ensureVisible(
        find.byKey(Key('remove-event-person-$contactB')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('remove-event-person-$contactB')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('event-person-$contactB')), findsNothing);
      expect(find.byKey(Key('event-person-$contactA')), findsOneWidget);
    });

    testWidgets('Back without Save preserves persisted A+B', (tester) async {
      final harness = await pumpApp(
        tester,
        draft: baseDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
      );
      await openEditViaPencil(tester);
      await scrollToPeopleSection(tester);
      await tester.ensureVisible(
        find.byKey(Key('remove-event-person-$contactB')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('remove-event-person-$contactB')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      final links = await harness.database
          .select(harness.database.eventContactLinks)
          .get();
      expect(links.map((row) => row.contactId).toSet(), {
        contactA,
        contactB,
      });
    });

    testWidgets('A+B -> remove B -> Save -> reopen -> only A', (tester) async {
      final harness = await pumpApp(
        tester,
        draft: baseDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
      );
      await openEditViaPencil(tester);
      await scrollToPeopleSection(tester);
      await tester.ensureVisible(
        find.byKey(Key('remove-event-person-$contactB')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('remove-event-person-$contactB')));
      await tester.pumpAndSettle();
      await saveForm(tester);

      // Reopen the Edit Event form: only A remains in the mutable link state.
      await tester.tap(find.byKey(const Key('event-detail-sheet-edit-icon')));
      await tester.pumpAndSettle();
      await scrollToPeopleSection(tester);
      expect(find.byKey(Key('event-person-$contactA')), findsOneWidget);
      expect(find.byKey(Key('event-person-$contactB')), findsNothing);

      final links = await harness.database
          .select(harness.database.eventContactLinks)
          .get();
      expect(links.map((row) => row.contactId).toSet(), {contactA});
    });
  });

  group('G. EVENT DETAIL PEOPLE', () {
    testWidgets('linked People are visible on Event detail above Activity '
        'History', (tester) async {
      await pumpApp(
        tester,
        draft: baseDraft,
        contacts: <(String, String)>[
          (contactA, 'Ana Reyes'),
          (contactB, 'Ben Cruz'),
        ],
        peopleContactIds: const <String>[contactA, contactB],
      );
      final peopleSection = find.byKey(const Key('event-detail-people'));
      expect(peopleSection, findsOneWidget);
      expect(find.text('Ana Reyes'), findsOneWidget);
      expect(find.text('Ben Cruz'), findsOneWidget);

      final peopleDy = tester.getTopLeft(peopleSection).dy;
      final historyDy = tester
          .getTopLeft(find.byKey(const Key('event-activity-history-button')))
          .dy;
      expect(peopleDy, lessThan(historyDy));
    });

    testWidgets('zero People -> no empty People section on detail',
        (tester) async {
      await pumpApp(tester, draft: baseDraft);
      expect(find.byKey(const Key('event-detail-people')), findsNothing);
    });

    testWidgets('normal (non-report) Event also shows People on detail',
        (tester) async {
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
      expect(find.byKey(const Key('event-detail-people')), findsOneWidget);
      expect(find.text('Ana Reyes'), findsOneWidget);
      expect(find.textContaining('Meaningful'), findsNothing);
    });
  });
}
