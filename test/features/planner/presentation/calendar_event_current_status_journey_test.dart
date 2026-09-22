import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/widgets/contact_widgets.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);
  const eventId = '88888888-8888-4888-8888-888888888888';
  const contributionRule = 'life-indicator:exercise:1:0:count';

  testWidgets('Event Current Status stages in Preview, locks Unreported, and '
      'commits only on Save', (tester) async {
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
    final contacts = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      identifiers: SequenceIdentifierSource(<String>[
        '70000000-0000-4000-8000-000000000001',
      ]),
    );
    const contactId = '60000000-0000-4000-8000-000000000001';
    await contacts.createContact(
      profileId: profile.id,
      draft: const ContactDraft(
        id: contactId,
        firstName: 'Preview',
        lastName: 'Contact',
        displayName: 'Preview Contact',
        preferredContactMethod: ContactPreferredMethod.message,
        isFavorite: false,
      ),
    );
    await calendarRepository.saveEvent(
      profileId: profile.id,
      draft: const CalendarEventDraft(
        id: eventId,
        title: 'Current Status fixture',
        timing: CalendarEventTiming.timed,
        startDate: selected,
        startMinute: 9 * 60,
        endMinute: 11 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: true,
        contributionRuleKey: contributionRule,
      ),
    );
    await contacts.setEventPeople(
      profileId: profile.id,
      eventId: eventId,
      occurrenceId: CalendarEventOccurrenceIdentity.forDate(
        eventId: eventId,
        originalDate: selected,
      ),
      originalDate: selected,
      contactIds: const <String>[contactId],
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
        contactRepository: contacts,
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

    // The real Event Preview surface remains paired with Task Preview across
    // the owner phone/tablet matrix: status controls and Contact identity do
    // not overflow, and the sheet stops expanding beyond its readable width.
    for (final width in <double>[360, 400, 480, 600, 800, 1024]) {
      tester.view.physicalSize = Size(width, 912);
      tester.view.devicePixelRatio = 1;
      await tester.pump();
      expect(find.byKey(const Key('event-status-control')), findsOneWidget);
      expect(
        find.byKey(const Key('event-preview-contact-$contactId')),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(
              find.byKey(const Key('calendar-event-existing-detail-sheet')),
            )
            .width,
        lessThanOrEqualTo(width <= 720 ? width : 720),
      );
      expect(tester.takeException(), isNull);
    }

    // Normal preview mode: the compact status row sits below the app bar,
    // the pencil and overflow remain visible, and there is no Save action.
    // No reporting write occurs merely by opening the preview.
    expect(find.byKey(const Key('event-status-control')), findsOneWidget);
    expect(find.byKey(const Key('event-status-current-label')), findsOneWidget);
    expect(find.text('Unreported'), findsOneWidget);
    // An initially unreported Event offers the complete owner-approved set.
    for (final key in <String>[
      'event-status-option-scheduled',
      'event-status-option-didNotHappen',
      'event-status-option-partiallyCompleted',
      'event-status-option-completedHappened',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    expect(find.byKey(const Key('event-status-save')), findsNothing);
    expect(
      find.byKey(const Key('event-preview-contact-$contactId')),
      findsOneWidget,
    );
    expect(find.byType(ContactGroupDot), findsOneWidget);
    expect(
      find.byKey(const Key('event-detail-sheet-edit-icon')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('event-detail-sheet-overflow-icon')),
      findsOneWidget,
    );
    expect(find.text('Did Not Attend'), findsNothing);
    expect(find.text('Schedule Next Appointment'), findsNothing);
    expect(find.text('Reschedule'), findsNothing);

    // Preview identity must be sourced from the canonical Contact record.
    // Reopening after Favorite changes the normal neutral circle into the
    // canonical neutral star; no Event-owned marker state participates.
    await tester.tap(find.byKey(const Key('event-detail-sheet-close')));
    await tester.pumpAndSettle();
    await contacts.setFavorite(
      profileId: profile.id,
      contactId: contactId,
      favorite: true,
    );
    await tester.tap(find.byKey(Key('planner-timed-event-$occurrenceId')));
    await tester.pumpAndSettle();
    expect(find.byType(ContactGroupDot), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);

    // The Preview pencil is ordinary Event edit.  It must not infer a
    // reporting session merely because this occurrence is report-eligible.
    await tester.tap(find.byKey(const Key('event-detail-sheet-edit-icon')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-event-form-scroll')), findsOneWidget);
    // P2-B (owner decision 2026-09-21) separates VISIBILITY from SUBMISSION
    // ARMING: this occurrence has ENDED, so ordinary edit now renders Current
    // Status under the owner's END-based rule.  Visibility is still not a
    // reporting session — nothing is staged, and merely opening the editor
    // writes no report.
    expect(find.byKey(const Key('event-status-section')), findsOneWidget);
    expect(find.byKey(const Key('event-status-save')), findsNothing);
    expect(await database.select(database.outcomeReports).get(), isEmpty);
    expect(
      find.text('Notes: What do you need to remember about this?'),
      findsOneWidget,
    );
    final normalNotes = find.byKey(const Key('event-notes-field'));
    expect(
      tester.getRect(normalNotes).height,
      greaterThanOrEqualTo(96),
      reason:
          'the normal Event Notes prompt belongs in a multiline input body, '
          'not in the single-line outline-label region.',
    );
    await tester.tap(find.byKey(const Key('event-notes-field')));
    await tester.pump();
    expect(
      find.text('Notes: What do you need to remember about this?'),
      findsOneWidget,
      reason: 'an empty focused normal Event Notes box keeps its body hint.',
    );
    await tester.enterText(
      find.byKey(const Key('event-notes-field')),
      'Typed normal Event notes',
    );
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: normalNotes,
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      'Typed normal Event notes',
      reason: 'the normal Notes controller still owns the entered value.',
    );
    await tester.enterText(find.byKey(const Key('event-notes-field')), '');
    await tester.pump();
    expect(
      find.text('Notes: What do you need to remember about this?'),
      findsOneWidget,
      reason: 'clearing normal Event Notes restores its wrapping body hint.',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // A Preview status choice enters the canonical Event editor with the
    // outcome staged; Preview itself never owns an Event reporting save.
    await tester.tap(
      find.byKey(const Key('event-status-option-completedHappened')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-event-form-scroll')), findsOneWidget);
    expect(find.byKey(const Key('event-status-save')), findsNothing);
    expect(find.byKey(const Key('event-status-section')), findsOneWidget);
    expect(
      find.text('Notes: What happened? What went well?'),
      findsOneWidget,
      reason:
          'the real status-tap Event editor uses the staged Completed Notes '
          'helper without persisting from Preview.',
    );
    expect(await database.select(database.outcomeReports).get(), isEmpty);
    expect(
      await database.select(database.activityLedgerEntries).get(),
      isEmpty,
    );

    // Corrections stay local to the canonical Event editor until Save.
    await tester.tap(find.byKey(const Key('event-status-option-didNotHappen')));
    await tester.pump();
    expect(find.text('Did Not Attempt'), findsOneWidget);
    expect(find.text("Notes: Why wasn't this attempted?"), findsOneWidget);
    expect(await database.select(database.outcomeReports).get(), isEmpty);
    await tester.tap(
      find.byKey(const Key('event-status-option-completedHappened')),
    );
    await tester.pump();
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Notes: What happened? What went well?'), findsOneWidget);
    expect(await database.select(database.outcomeReports).get(), isEmpty);

    // Save performs exactly one canonical reporting transaction and returns
    // to the Event preview.
    final saveEvent = find.byKey(const Key('save-event-button'));
    await tester.ensureVisible(saveEvent);
    await tester.tap(saveEvent);
    await tester.pumpAndSettle();
    expect(find.text('Completed'), findsOneWidget);
    expect(
      find.byKey(const Key('event-status-option-scheduled')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('event-detail-sheet-edit-icon')),
      findsOneWidget,
    );
    var reports = await database.select(database.outcomeReports).get();
    expect(reports, hasLength(1));
    expect(reports.single.outcome, OutcomeKind.completedHappened.name);
    var ledger = await database.select(database.activityLedgerEntries).get();
    expect(ledger, hasLength(1));

    // Re-selecting the current status is a no-op: no new write.
    await tester.tap(
      find.byKey(const Key('event-status-option-completedHappened')),
    );
    await tester.pumpAndSettle();
    reports = await database.select(database.outcomeReports).get();
    ledger = await database.select(database.activityLedgerEntries).get();
    expect(reports, hasLength(1));
    expect(ledger, hasLength(1));

    // A correction opens the canonical editor; close abandons it and leaves
    // the persisted report unchanged.
    await tester.tap(find.byKey(const Key('event-status-option-didNotHappen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-event-form-scroll')), findsOneWidget);
    reports = await database.select(database.outcomeReports).get();
    expect(reports, hasLength(1));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Completed'), findsOneWidget);
    reports = await database.select(database.outcomeReports).get();
    ledger = await database.select(database.activityLedgerEntries).get();
    expect(reports, hasLength(1));
    expect(ledger, hasLength(1));

    final activityHistory = find.byKey(
      const Key('event-activity-history-button'),
    );
    await tester.ensureVisible(activityHistory);
    await tester.pumpAndSettle();
    await tester.tap(activityHistory);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('activity-history-list')), findsOneWidget);
    expect(find.text('Correct Report'), findsNothing);
    expect(find.byKey(const Key('correct-report-unknown')), findsNothing);
  });

  testWidgets('Contact Events keep the four-state Current Status set and '
      'stage their report in the canonical Event editor', (tester) async {
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
    await calendarRepository.saveEvent(
      profileId: profile.id,
      draft: const CalendarEventDraft(
        id: eventId,
        title: 'Contact follow-up',
        timing: CalendarEventTiming.timed,
        startDate: selected,
        startMinute: 9 * 60,
        endMinute: 10 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: true,
        // The real form always persists an activityTypeId; the snapshot
        // pair rides along so the occurrence resolves as a Contact Event.
        activityTypeId: 'contact-type-id',
        activityTypeStableKeySnapshot: 'contact',
        activityTypeLabelSnapshot: 'Contact',
      ),
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

    // Contact keeps the full four-state set.
    for (final key in <String>[
      'event-status-option-scheduled',
      'event-status-option-didNotHappen',
      'event-status-option-partiallyCompleted',
      'event-status-option-completedHappened',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }

    // A Contact Event keeps Did Not Attempt and Missed. Selecting a status
    // opens the canonical editor with its status staged; the canonical report
    // is absent until Save.
    await tester.tap(find.byKey(const Key('event-status-option-didNotHappen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-event-form-scroll')), findsOneWidget);
    expect(find.byKey(const Key('event-status-save')), findsNothing);
    expect(
      find.byKey(const Key('event-status-option-scheduled')),
      findsOneWidget,
    );
    for (final key in <String>[
      'event-status-option-didNotHappen',
      'event-status-option-partiallyCompleted',
      'event-status-option-completedHappened',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    expect(await database.select(database.outcomeReports).get(), isEmpty);
    final saveEvent = find.byKey(const Key('save-event-button'));
    await tester.ensureVisible(saveEvent);
    await tester.tap(saveEvent);
    await tester.pumpAndSettle();
    final reports = await database.select(database.outcomeReports).get();
    expect(reports, hasLength(1));
    expect(reports.single.outcome, OutcomeKind.didNotHappen.name);
    expect(find.text('Did Not Attempt'), findsOneWidget);
  });
}
