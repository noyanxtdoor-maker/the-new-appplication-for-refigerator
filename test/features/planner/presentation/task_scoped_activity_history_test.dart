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
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/widgets/anchored_top_bar_popup.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_current_status_controls.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_detail_primitives.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 8, day: 28);

  testWidgets(
    'Task Preview renders only its canonical source-slot history and keeps '
    'correction and clear records factual',
    (tester) async {
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
      final planner = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 28, 12)),
      );
      final reports = DriftOutcomeReportingRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 28, 12)),
      );
      final events = DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 28, 12)),
        timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
        reportSource: reports,
      );

      await planner.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'task-a',
          title: 'Task A canonical history',
          dueDate: selected,
          // A legacy false value must not suppress Task reporting, report
          // driven completion, Preview status, or scoped history.
          requiresReport: false,
        ),
      );
      await planner.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'task-b',
          title: 'Task B must stay absent',
          dueDate: selected,
          requiresReport: true,
        ),
      );
      await events.saveEvent(
        profileId: profile.id,
        draft: const CalendarEventDraft(
          id: '30000000-0000-4000-8000-000000000001',
          title: 'Event history must stay absent',
          timing: CalendarEventTiming.allDay,
          startDate: selected,
          requiresReport: true,
        ),
      );

      final taskA = (await reports.readTaskSource(
        profileId: profile.id,
        taskId: 'task-a',
      ))!;
      final taskB = (await reports.readTaskSource(
        profileId: profile.id,
        taskId: 'task-b',
      ))!;
      final event = (await reports.readEventSource(
        profileId: profile.id,
        eventId: '30000000-0000-4000-8000-000000000001',
        originalDate: selected,
      ))!;

      const firstTaskAReport = '10000000-0000-4000-8000-000000000001';
      const secondTaskAReport = '10000000-0000-4000-8000-000000000002';
      await reports.submit(
        profileId: profile.id,
        draft: OutcomeReportDraft(
          id: firstTaskAReport,
          source: taskA,
          activityDate: selected,
          outcome: OutcomeKind.didNotHappen,
          allowUnstructuredPartial: true,
        ),
        operationId: '20000000-0000-4000-8000-000000000001',
      );
      await reports.submit(
        profileId: profile.id,
        draft: OutcomeReportDraft(
          id: secondTaskAReport,
          source: taskA,
          activityDate: selected,
          outcome: OutcomeKind.completedHappened,
          correctsReportId: firstTaskAReport,
          correctionReason: 'Task Current Status corrected directly.',
          allowUnstructuredPartial: true,
        ),
        operationId: '20000000-0000-4000-8000-000000000002',
      );
      await reports.clearSubmittedStatus(
        profileId: profile.id,
        source: taskA,
        operationId: '20000000-0000-4000-8000-000000000003',
        correctionReason: 'Task Current Status returned to Unreported.',
      );
      await reports.submit(
        profileId: profile.id,
        draft: OutcomeReportDraft(
          id: '10000000-0000-4000-8000-000000000003',
          source: taskB,
          activityDate: selected,
          outcome: OutcomeKind.completedHappened,
          allowUnstructuredPartial: true,
        ),
        operationId: '20000000-0000-4000-8000-000000000004',
      );
      await reports.submit(
        profileId: profile.id,
        draft: OutcomeReportDraft(
          id: '10000000-0000-4000-8000-000000000004',
          source: event,
          activityDate: selected,
          outcome: OutcomeKind.completedHappened,
          allowUnstructuredPartial: true,
        ),
        operationId: '20000000-0000-4000-8000-000000000005',
      );
      await reports.submit(
        profileId: profile.id,
        draft: const OutcomeReportDraft(
          id: '10000000-0000-4000-8000-000000000005',
          source: OutcomeReportSource(
            type: OutcomeSourceType.manual,
            sourceId: 'global-only-history',
            label: 'Global history must stay absent',
            activityDate: selected,
          ),
          activityDate: selected,
          outcome: OutcomeKind.completedHappened,
          allowUnstructuredPartial: true,
        ),
        operationId: '20000000-0000-4000-8000-000000000006',
      );

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: planner,
          calendarEventRepository: events,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-filter-completed-tasks')));
      await tester.tap(find.byKey(const Key('planner-filter-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-tasks')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Report required'), findsNothing);
      await tester.tap(find.text('Task A canonical history'));
      await tester.pumpAndSettle();

      expect(
        find.text('Task A canonical history').first,
        findsOneWidget,
        reason: 'The canonical Preview header carries the factual Task title.',
      );
      expect(find.text('Current Status'), findsOneWidget);
      expect(
        find.byType(SharedPlannerPreviewSheet),
        findsOneWidget,
        reason: 'Task renders through the Event Preview production shell.',
      );
      expect(find.byType(PlannerCurrentStatusControlRow), findsOneWidget);
      expect(find.byKey(const Key('task-preview-sheet-close')), findsOneWidget);
      expect(
        find.byKey(const Key('task-status-option-partiallyCompleted')),
        findsOneWidget,
        reason: 'Task restores the owner-approved Missed outcome.',
      );
      await tester.tap(find.byKey(const Key('task-detail-sheet-overflow-icon')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-overflow-duplicate')), findsOneWidget);
      expect(find.byKey(const Key('task-overflow-delete')), findsOneWidget);
      anchoredTopBarPopupController.dismiss();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('task-status-option-unreported')),
        findsOneWidget,
        reason:
            'An older clear record remains in Activity History, while '
            'Unreported stays visibly disabled in its original slot.',
      );
      expect(find.text('Activity History'), findsOneWidget);
      expect(
        find.byKey(const Key('task-activity-history-button')),
        findsOneWidget,
        reason: 'Preview presents the same navigation row as Event Preview.',
      );
      expect(
        find.byKey(
          const Key(
            'task-scoped-history-entry-10000000-0000-4000-8000-000000000001',
          ),
        ),
        findsNothing,
        reason: 'Task Preview must not expand an accumulating inline history.',
      );
      await tester.tap(find.byKey(const Key('task-activity-history-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const Key('activity-history-entry-10000000-0000-4000-8000-000000000001'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('activity-history-entry-10000000-0000-4000-8000-000000000002'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(
          const Key('activity-history-entry-10000000-0000-4000-8000-000000000002'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Corrected status'), findsOneWidget);
      expect(
        find.textContaining('Task Current Status returned to Unreported.'),
        findsOneWidget,
      );
      expect(find.text('Task B must stay absent'), findsNothing);
      expect(find.text('Event history must stay absent'), findsNothing);
      expect(find.text('Global history must stay absent'), findsNothing);
      expect(
        find.byTooltip('Manage linked Calendar Events'),
        findsNothing,
        reason: 'Task Preview no longer exposes the rejected chain action.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Task Preview keeps the shared Activity History navigation row with no reports',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final planner = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 28, 12)),
      );
      await planner.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'empty-history-task',
          title: 'No Task history yet',
          dueDate: selected,
          requiresReport: true,
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
          plannerRepository: planner,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-tasks')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No Task history yet'));
      await tester.pumpAndSettle();

      expect(find.text('Activity History'), findsOneWidget);
      expect(
        find.byKey(const Key('task-activity-history-button')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('task-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-preview-sheet')), findsOneWidget);
      expect(find.byKey(const Key('task-detail-title')), findsOneWidget);
      expect(find.byKey(const Key('event-status-save')), findsNothing);
      expect(find.byKey(const Key('task-status-save')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const Key('task-status-option-unreported')), findsOneWidget);
      // Unreported remains in its original position after a direct outcome,
      // but is a non-actionable history-preserving control.
      await tester.tap(find.byKey(const Key('task-status-option-unreported')));
      await tester.pumpAndSettle();
      expect(
        (await database.select(database.outcomeReports).get()).single.outcome,
        OutcomeKind.completedHappened.name,
      );
      expect(find.byKey(const Key('task-status-option-unreported')), findsOneWidget);
      expect(find.byKey(const Key('task-status-option-unreported')), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('task-status-option-partiallyCompleted')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-preview-sheet')), findsOneWidget);
      expect(find.byKey(const Key('calendar-event-form-scroll')), findsNothing);
      final afterMissed = await database.select(database.outcomeReports).get();
      expect(afterMissed, hasLength(2));
      expect(afterMissed.last.outcome, OutcomeKind.partiallyCompleted.name);
      await tester.tap(find.byKey(const Key('task-status-option-didNotHappen')));
      await tester.pumpAndSettle();
      expect(find.text('Did Not Attempt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Task Preview reopens canonical Task contacts with the shared favorite '
    'star and grouped or neutral marker identity',
    (tester) async {
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
      final planner = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 28, 12)),
      );
      final contacts = DriftContactRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 28, 12)),
        identifiers: SequenceIdentifierSource(<String>[
          '20000000-0000-4000-8000-000000000011',
          '20000000-0000-4000-8000-000000000012',
          '20000000-0000-4000-8000-000000000013',
        ]),
      );
      await planner.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'task-with-canonical-contacts',
          title: 'Task with canonical contacts',
          dueDate: selected,
          requiresReport: true,
        ),
      );
      const groupedContactId = '10000000-0000-4000-8000-000000000011';
      const ungroupedContactId = '10000000-0000-4000-8000-000000000012';
      await contacts.createContact(
        profileId: profile.id,
        draft: const ContactDraft(
          id: groupedContactId,
          firstName: 'Grouped',
          lastName: 'Contact',
          displayName: 'Grouped Contact',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );
      await contacts.createContact(
        profileId: profile.id,
        draft: const ContactDraft(
          id: ungroupedContactId,
          firstName: 'Ungrouped',
          lastName: 'Contact',
          displayName: 'Ungrouped Contact',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );
      final group = await contacts.createGroup(
        profileId: profile.id,
        name: 'Preview marker group',
        colorValue: ContactGroupColorPalette.tealArgb,
      );
      await contacts.setContactGroups(
        profileId: profile.id,
        contactId: groupedContactId,
        groupIds: <String>[group.id],
        primaryGroupId: group.id,
      );
      await contacts.setTaskContacts(
        profileId: profile.id,
        taskId: 'task-with-canonical-contacts',
        contactIds: const <String>[groupedContactId, ungroupedContactId],
      );

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: planner,
          contactRepository: contacts,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-tasks')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Task with canonical contacts'));
      await tester.pumpAndSettle();

      // Exercise the same production Preview row, markers, and Current
      // Status controls at the required phone/tablet widths. The narrow
      // status row remains compact; wide sheets preserve readable bounds.
      for (final width in <double>[360, 400, 480, 600, 800, 1024]) {
        tester.view.physicalSize = Size(width, 912);
        tester.view.devicePixelRatio = 1;
        await tester.pump();
        expect(find.byKey(const Key('task-status-control')), findsOneWidget);
        expect(find.byType(ContactGroupDot), findsNWidgets(2));
        expect(
          tester.getSize(find.byKey(const Key('task-preview-sheet'))).width,
          lessThanOrEqualTo(width <= 720 ? width : 720),
        );
        expect(tester.takeException(), isNull);
      }

      expect(find.text('Contacts'), findsWidgets);
      expect(find.byKey(const Key('task-preview-contact-$groupedContactId')), findsOneWidget);
      expect(find.byKey(const Key('task-preview-contact-$ungroupedContactId')), findsOneWidget);
      expect(find.byType(ContactGroupDot), findsNWidgets(2));
      expect(find.byIcon(Icons.star_rounded), findsNothing);
      await tester.tap(find.byKey(const Key('task-preview-sheet-close')));
      await tester.pumpAndSettle();
      await contacts.setFavorite(
        profileId: profile.id,
        contactId: groupedContactId,
        favorite: true,
      );
      await contacts.setFavorite(
        profileId: profile.id,
        contactId: ungroupedContactId,
        favorite: true,
      );
      await tester.tap(find.text('Task with canonical contacts'));
      await tester.pumpAndSettle();
      expect(find.text('Grouped Contact'), findsOneWidget);
      expect(find.text('Ungrouped Contact'), findsOneWidget);
      expect(find.byType(ContactGroupDot), findsNWidgets(2));
      expect(
        find.byIcon(Icons.star_rounded),
        findsNWidgets(2),
        reason:
            'Favorite keeps the canonical group or neutral color but changes '
            'only the shared Contacts identity shape to a star.',
      );
    },
  );
}
