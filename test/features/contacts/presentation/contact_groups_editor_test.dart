import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/contact_groups_editor.dart';

void main() {
  final family = ContactGroup(
    id: 'family',
    profileId: 'profile',
    name: 'Family',
    colorValue: 0xFF1565C0,
    isArchived: false,
    sortOrder: 0,
    createdAtUtc: DateTime.utc(2026, 8, 24),
    updatedAtUtc: DateTime.utc(2026, 8, 24),
  );
  final friends = ContactGroup(
    id: 'friends',
    profileId: 'profile',
    name: 'Friends',
    colorValue: 0xFF6A1B9A,
    isArchived: false,
    sortOrder: 1,
    createdAtUtc: DateTime.utc(2026, 8, 24),
    updatedAtUtc: DateTime.utc(2026, 8, 24),
  );

  testWidgets('A3 exposes only No Group and current Groups as radios', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ContactGroupsEditor(
          groups: <ContactGroup>[family, friends],
          initialPrimaryGroupId: 'family',
        ),
      ),
    );

    // The ungrouped state is a real, named choice with its canonical colour.
    expect(find.text('No Group'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(
      tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(const Key('groups-editor-none')),
              matching: find.byType(Container),
            ),
          )
          .any(
            (container) =>
                (container.decoration as BoxDecoration?)?.color ==
                const Color(ContactUngroupedColor.argb),
          ),
      isTrue,
      reason: 'the ungrouped row carries the canonical #EBC766 swatch',
    );
    expect(find.text('Friends'), findsOneWidget);
    expect(find.byType(RadioListTile<String?>), findsNWidgets(3));
    expect(find.text('Address'), findsNothing);
    expect(find.text('Availability'), findsNothing);
    expect(find.text('Notes'), findsNothing);
    expect(find.text('Tags'), findsNothing);
  });

  testWidgets(
    'A3 legacy no-primary state selects No Group and cancel writes no result',
    (tester) async {
      ContactGroupsEditResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await Navigator.of(context)
                    .push<ContactGroupsEditResult>(
                      MaterialPageRoute<ContactGroupsEditResult>(
                        builder: (_) => ContactGroupsEditor(
                          groups: <ContactGroup>[family, friends],
                          initialPrimaryGroupId: null,
                        ),
                      ),
                    );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final radioGroup = tester.widget<RadioGroup<String?>>(
        find.byType(RadioGroup<String?>),
      );
      expect(radioGroup.groupValue, isNull);
      await tester.tap(find.byKey(const Key('groups-editor-cancel')));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );
}
