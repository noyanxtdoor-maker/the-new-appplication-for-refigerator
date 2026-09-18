import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 8, day: 23);

  Future<void> revealEventControl(
    WidgetTester tester,
    Finder target, {
    ScrollableState? formState,
  }) async {
    final formScroll = find.byKey(const Key('calendar-event-form-scroll'));
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

  Future<void> scrollEventFormToTop(
    WidgetTester tester,
    ScrollableState formState,
  ) async {
    formState.position.jumpTo(0);
    await tester.pumpAndSettle();
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
    await tester.enterText(phoneField, '555 0100');
    await tester.tap(find.byKey(const Key('save-contact-button')));
    await tester.pumpAndSettle();
  }

  testWidgets('C4-B Event draft survives Add People -> New Contact -> Done', (
    tester,
  ) async {
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
          'a1000000-0000-4000-8000-000000000001',
          'a1000000-0000-4000-8000-000000000002',
          'a1000000-0000-4000-8000-000000000003',
        ]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-calendar-event-action')));
    await tester.pumpAndSettle();
    final otherEventType = find.byKey(const Key('event-type-option-other'));
    await tester.ensureVisible(otherEventType);
    await tester.pumpAndSettle();
    await tester.tap(otherEventType);
    await tester.pumpAndSettle();

    const eventTitle = 'C4 Event draft survives';
    const eventNotes = 'Keep this Event draft intact.';
    await tester.enterText(
      find.byKey(const Key('event-title-field')),
      eventTitle,
    );
    await tester.enterText(
      find.byKey(const Key('event-notes-field')),
      eventNotes,
    );
    final typeBefore = textWithin(
      tester,
      find.byKey(const Key('selected-event-type-label')),
    );
    final eventDate = find.byKey(const Key('event-date-field'));
    final eventStart = find.byKey(const Key('event-start-time'));
    final eventEnd = find.byKey(const Key('event-end-time'));
    await revealEventControl(tester, eventDate);
    final dateBefore = textWithin(tester, eventDate.first);
    await revealEventControl(tester, eventStart);
    final startBefore = textWithin(tester, eventStart.first);
    await revealEventControl(tester, eventEnd);
    final endBefore = textWithin(tester, eventEnd.first);
    expect(typeBefore, 'Other');

    final peopleButton = find.byKey(const Key('add-people-button'));
    await revealEventControl(tester, peopleButton);
    await tester.tap(peopleButton);
    await tester.pumpAndSettle();
    expect(find.text('Add People'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-people-new-contact')));
    await tester.pumpAndSettle();

    await createValidContact(tester, firstName: 'Ema', lastName: 'Event');
    expect(find.text('Add People'), findsOneWidget);
    expect(find.text('Ema Event'), findsOneWidget);
    expect(find.text('People Added (1)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-people-done')));
    await tester.pumpAndSettle();

    final contact = await (database.select(
      database.contacts,
    )..where((row) => row.displayName.equals('Ema Event'))).getSingle();
    final selectedPerson = find.byKey(Key('event-person-${contact.id}'));
    expect(selectedPerson, findsOneWidget);
    expect(find.text('Ema Event'), findsOneWidget);

    final formState = tester.state<ScrollableState>(
      find
          .ancestor(of: selectedPerson, matching: find.byType(Scrollable))
          .first,
    );
    await scrollEventFormToTop(tester, formState);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('event-title-field')))
          .controller!
          .text,
      eventTitle,
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('event-notes-field')))
          .controller!
          .text,
      eventNotes,
    );
    expect(
      textWithin(tester, find.byKey(const Key('selected-event-type-label'))),
      typeBefore,
    );
    await revealEventControl(tester, eventDate, formState: formState);
    expect(
      textWithin(tester, find.byKey(const Key('event-date-field')).first),
      dateBefore,
    );
    await revealEventControl(tester, eventStart, formState: formState);
    expect(
      textWithin(tester, find.byKey(const Key('event-start-time')).first),
      startBefore,
    );
    await revealEventControl(tester, eventEnd, formState: formState);
    expect(
      textWithin(tester, find.byKey(const Key('event-end-time')).first),
      endBefore,
    );
    expect(tester.takeException(), isNull);
  });
}
