import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 8, day: 23);

  Future<void> revealTaskControl(
    WidgetTester tester,
    Finder target, {
    ScrollableState? formState,
  }) async {
    final formScroll = find.byKey(const Key('task-form-scroll'));
    if (formState == null) {
      expect(formScroll, findsOneWidget);
    }
    for (var attempt = 0; attempt < 16; attempt++) {
      if (target.evaluate().isNotEmpty) {
        await tester.ensureVisible(target.first);
        await tester.pumpAndSettle();
        return;
      }
      if (formState == null) {
        await tester.drag(formScroll, const Offset(0, -260));
      } else {
        formState.position.jumpTo(
          (formState.position.pixels + 260)
              .clamp(0, formState.position.maxScrollExtent)
              .toDouble(),
        );
      }
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(target, findsOneWidget);
  }

  String textWithin(WidgetTester tester, Finder ancestor) {
    final values = <String>[
      for (final element in ancestor.evaluate())
        if (element.widget is Text)
          (element.widget as Text).data ??
              (element.widget as Text).textSpan?.toPlainText() ??
              '',
      ...tester
          .widgetList<Text>(
            find.descendant(of: ancestor, matching: find.byType(Text)),
          )
          .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
          .where((value) => value.isNotEmpty),
    ].where((value) => value.isNotEmpty).toList(growable: false);
    expect(values, isNotEmpty);
    return values.join('\n');
  }

  Future<void> createValidContact(
    WidgetTester tester, {
    required String firstName,
    required String lastName,
  }) async {
    expect(find.text('Add Contact'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('contact-first-name')),
      firstName,
    );
    await tester.enterText(
      find.byKey(const Key('contact-last-name')),
      lastName,
    );
    await tester.tap(find.byKey(const Key('add-phone-row')));
    await tester.pumpAndSettle();
    final phoneField = find.byWidgetPredicate(
      (widget) =>
          widget is TextFormField &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'contact-method-phone-',
          ),
    );
    expect(phoneField, findsOneWidget);
    await tester.enterText(phoneField, '555 0101');
    await tester.tap(find.byKey(const Key('save-contact-button')));
    await tester.pumpAndSettle();
  }

  testWidgets('C4-B Task draft survives Add People -> New Contact -> Done and '
      'saves a canonical Contact link', (tester) async {
    tester.view.physicalSize = const Size(862, 1824);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
        plannerDateSource: const FixedPlannerDateSource(selected),
        plannerIdentifierSource: SequenceIdentifierSource(<String>[
          'b1000000-0000-4000-8000-000000000001',
          'b1000000-0000-4000-8000-000000000002',
          'b1000000-0000-4000-8000-000000000003',
        ]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-task-action')));
    await tester.pumpAndSettle();

    const taskTitle = 'C4 Task draft survives';
    const taskNotes = 'Keep this Task draft intact.';
    await tester.enterText(
      find.byKey(const Key('task-title-field')),
      taskTitle,
    );
    await tester.enterText(
      find.byKey(const Key('task-notes-field')),
      taskNotes,
    );
    final dueDate = find.byKey(const Key('task-due-date-field'));
    final dueTime = find.byKey(const Key('task-due-time-field'));
    await revealTaskControl(tester, dueDate);
    final dueDateBefore = textWithin(tester, dueDate.first);
    await revealTaskControl(tester, dueTime);
    final dueTimeBefore = textWithin(tester, dueTime.first);

    final peopleButton = find.byKey(const Key('task-add-people-button'));
    await revealTaskControl(tester, peopleButton);
    await tester.tap(peopleButton);
    await tester.pumpAndSettle();
    expect(find.text('Add People'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-people-new-contact')));
    await tester.pumpAndSettle();

    await createValidContact(tester, firstName: 'Tara', lastName: 'Task');
    expect(find.text('Add People'), findsOneWidget);
    expect(find.text('Tara Task'), findsOneWidget);
    expect(find.text('People Added (1)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-people-done')));
    await tester.pumpAndSettle();

    final contact = await (database.select(
      database.contacts,
    )..where((row) => row.displayName.equals('Tara Task'))).getSingle();
    final selectedPerson = find.byKey(Key('task-contact-${contact.id}'));
    expect(selectedPerson, findsOneWidget);
    expect(find.text('Tara Task'), findsOneWidget);

    final formState = tester.state<ScrollableState>(
      find
          .ancestor(of: selectedPerson, matching: find.byType(Scrollable))
          .first,
    );
    formState.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('task-title-field')))
          .controller!
          .text,
      taskTitle,
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('task-notes-field')))
          .controller!
          .text,
      taskNotes,
    );
    await revealTaskControl(tester, dueDate, formState: formState);
    expect(textWithin(tester, dueDate.first), dueDateBefore);
    await revealTaskControl(tester, dueTime, formState: formState);
    expect(textWithin(tester, dueTime.first), dueTimeBefore);

    await tester.tap(find.byKey(const Key('save-task-button')));
    await tester.pumpAndSettle();

    final task = await (database.select(
      database.plannerTasks,
    )..where((row) => row.title.equals(taskTitle))).getSingle();
    expect(task.notes, taskNotes);
    expect(
      task.peopleJson,
      '[]',
      reason: 'Contact ids must not leak into the legacy peopleJson field.',
    );
    final links = await (database.select(
      database.taskContactLinks,
    )..where((row) => row.taskId.equals(task.id))).get();
    expect(links, hasLength(1));
    expect(links.single.contactId, contact.id);
    expect(tester.takeException(), isNull);
  });
}
