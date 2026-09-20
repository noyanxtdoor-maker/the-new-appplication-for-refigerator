import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/next_transfer_app.dart';
import 'package:rmplanner/app/router/app_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/contact_detail_screen.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

/// An attached Contact that is visible in a Planner Preview is always the same
/// affordance.  The Event Preview has always opened the canonical Contact
/// Profile; these tests pin that the Task Preview does too, so a Task can never
/// again show an attached Contact that is inert.
void main() {
  const selected = PlannerDate(year: 2026, month: 9, day: 19);
  const taskId = 'task-with-attached-people';
  const taskTitle = 'Call the ward clerk';
  const contactA = '30000000-0000-4000-8000-0000000000a1';
  const contactB = '30000000-0000-4000-8000-0000000000a2';

  const juana = (id: contactA, name: 'Juan Dela Cruz');
  const maria = (id: contactB, name: 'Maria Santos');

  Future<({DriftContactRepository contacts, String profileId})> pumpTaskPreview(
    WidgetTester tester, {
    required List<({String id, String name})> people,
    Future<void> Function(DriftContactRepository contacts, String profileId)?
    afterLinking,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
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
      clock: FixedClock(DateTime.utc(2026, 9, 19, 12)),
    );
    final contacts = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 19, 12)),
      identifiers: UuidIdentifierSource(),
    );
    await planner.saveTask(
      profileId: profile.id,
      draft: const PlannerTaskDraft(
        id: taskId,
        title: taskTitle,
        dueDate: selected,
        requiresReport: false,
      ),
    );
    for (final person in people) {
      await contacts.createContact(
        profileId: profile.id,
        draft: ContactDraft(
          id: person.id,
          firstName: person.name,
          lastName: 'Person',
          displayName: person.name,
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );
    }
    if (people.isNotEmpty) {
      await contacts.setTaskContacts(
        profileId: profile.id,
        taskId: taskId,
        contactIds: people.map((person) => person.id).toList(growable: false),
      );
    }
    if (afterLinking != null) {
      await afterLinking(contacts, profile.id);
    }

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
    await tester.tap(find.text(taskTitle).first);
    await tester.pumpAndSettle();
    return (contacts: contacts, profileId: profile.id);
  }

  Finder taskSheet() => find.byKey(const Key('task-preview-sheet'));

  Future<void> tapRow(WidgetTester tester, Finder row) async {
    await tester.ensureVisible(row);
    // Deliberately bounded pumps rather than pumpAndSettle: the Preview shell
    // hosts status and notification affordances that animate indefinitely, so
    // the surface never reports itself settled.  A handful of frames is what
    // the claim "the tap navigates" actually needs.
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(row);
    await tester.pump();
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('TC1 Task Preview attached Contact opens that Contact Profile', (
    tester,
  ) async {
    await pumpTaskPreview(
      tester,
      people: const <({String id, String name})>[juana],
    );

    final row = find.byKey(const Key('task-preview-contact-$contactA'));
    expect(row, findsOneWidget);
    // The row lives inside the shared Planner Preview shell, not a lookalike.
    expect(
      find.descendant(of: taskSheet(), matching: row),
      findsOneWidget,
      reason: 'the attached Contact belongs to the Task Preview surface',
    );
    // Presentation is shared with the Event Preview; the tap target is what
    // makes an attached Contact navigable.  Proven while the row is still on
    // the Preview, because navigating replaces the surface it lived on.
    expect(
      find.descendant(of: row, matching: find.byType(InkWell)),
      findsOneWidget,
      reason: 'a visible attached Contact must be tappable',
    );

    await tapRow(tester, row);

    expect(
      tester
          .widget<ContactDetailScreen>(find.byType(ContactDetailScreen))
          .contactId,
      contactA,
      reason: 'tapping a visible attached Contact must open its Profile',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TC2 each attached Contact opens its own Profile', (
    tester,
  ) async {
    await pumpTaskPreview(
      tester,
      people: const <({String id, String name})>[juana, maria],
    );

    final rowB = find.byKey(const Key('task-preview-contact-$contactB'));
    expect(
      find.byKey(const Key('task-preview-contact-$contactA')),
      findsOneWidget,
    );
    expect(rowB, findsOneWidget);

    await tapRow(tester, rowB);

    expect(
      tester
          .widget<ContactDetailScreen>(find.byType(ContactDetailScreen))
          .contactId,
      contactB,
      reason: 'tapping the second Contact must not open the first',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TC3 Event Preview attached Contact navigation is unchanged', (
    tester,
  ) async {
    const eventDate = PlannerDate(year: 2026, month: 9, day: 19);
    const eventId = '30000000-0000-4000-8000-0000000000e1';

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startupRepository = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    final profile = await startupRepository.completeOnboarding();
    final contacts = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 19, 12)),
      identifiers: UuidIdentifierSource(),
    );
    final calendar = DriftCalendarEventRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 19, 12)),
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
    );
    await contacts.createContact(
      profileId: profile.id,
      draft: const ContactDraft(
        id: contactA,
        firstName: 'Juan Dela Cruz',
        lastName: 'Person',
        displayName: 'Juan Dela Cruz',
        preferredContactMethod: ContactPreferredMethod.message,
        isFavorite: false,
      ),
    );
    await calendar.saveEvent(
      profileId: profile.id,
      draft: const CalendarEventDraft(
        id: eventId,
        title: 'District Meeting',
        timing: CalendarEventTiming.timed,
        startDate: eventDate,
        startMinute: 10 * 60,
        endMinute: 11 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: false,
      ),
    );
    await contacts.setEventPeople(
      profileId: profile.id,
      eventId: eventId,
      occurrenceId: DriftContactRepository.seriesOccurrenceId,
      contactIds: const <String>[contactA],
    );

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        calendarEventRepository: calendar,
        contactRepository: contacts,
        plannerDateSource: const FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NextTransferApp)),
    );
    final router = container.read(appRouterProvider);
    router.go(RoutePaths.calendarEventDetail(eventId, eventDate));
    await tester.pump();

    final row = find.byKey(const Key('event-preview-contact-$contactA'));
    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (row.evaluate().isNotEmpty) break;
    }
    expect(row, findsOneWidget);

    await tapRow(tester, row);

    expect(
      tester
          .widget<ContactDetailScreen>(find.byType(ContactDetailScreen))
          .contactId,
      contactA,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TC4 the Preview offers exactly the live attached links', (
    tester,
  ) async {
    // Archived Contacts are restorable rather than removed, and the canonical
    // Task People projection deliberately resolves them; what must never
    // happen is an affordance outliving its *link*.
    await pumpTaskPreview(
      tester,
      people: const <({String id, String name})>[juana, maria],
      afterLinking: (contacts, profileId) => contacts.setTaskContacts(
        profileId: profileId,
        taskId: taskId,
        contactIds: const <String>[contactA],
      ),
    );

    expect(
      find.byKey(const Key('task-preview-contact-$contactA')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('task-preview-contact-$contactB')),
      findsNothing,
      reason: 'a removed link must leave no affordance behind',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TC5 a Task with no attached People offers no Contact row', (
    tester,
  ) async {
    await pumpTaskPreview(tester, people: const <({String id, String name})>[]);

    expect(taskSheet(), findsOneWidget);
    expect(
      find.descendant(
        of: taskSheet(),
        matching: find.byKey(const Key('task-preview-contact-$contactA')),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TC7 the Profile opened from a Task returns to that Task', (
    tester,
  ) async {
    await pumpTaskPreview(
      tester,
      people: const <({String id, String name})>[juana],
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NextTransferApp)),
    );
    final router = container.read(appRouterProvider);

    await tapRow(
      tester,
      find.byKey(const Key('task-preview-contact-$contactA')),
    );
    expect(find.byType(ContactDetailScreen), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();

    expect(find.byType(ContactDetailScreen), findsNothing);
    expect(
      taskSheet(),
      findsOneWidget,
      reason: 'popping the Profile must restore the Task Preview surface',
    );
    expect(find.text(taskTitle), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
