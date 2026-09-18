import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/c3_contact_primitives.dart';
import 'package:rmplanner/features/contacts/presentation/widgets/contact_widgets.dart';

void main() {
  final timestamp = DateTime.utc(2026, 8, 24);

  Contact contact(String id, String name, {bool isFavorite = false}) {
    final parts = name.split(' ');
    return Contact(
      id: id,
      profileId: 'profile',
      firstName: parts.first,
      lastName: parts.last,
      displayName: name,
      preferredContactMethod: ContactPreferredMethod.message,
      isFavorite: isFavorite,
      lifecycleState: ContactLifecycleState.active,
      source: ContactSource.manual,
      createdAtUtc: timestamp,
      updatedAtUtc: timestamp,
    );
  }

  final family = ContactGroup(
    id: 'family',
    profileId: 'profile',
    name: 'Family',
    colorValue: 0xFFEBC766,
    isArchived: false,
    sortOrder: 0,
    createdAtUtc: timestamp,
    updatedAtUtc: timestamp,
  );

  testWidgets(
    'ungrouped Contact uses the neutral identity dot and stays aligned',
    (tester) async {
      final grouped = ContactSummary(
        contact: contact('grouped', 'Maria Santos'),
        primaryGroup: family,
      );
      final ungrouped = ContactSummary(
        contact: contact('ungrouped', 'John Reyes'),
      );
      final favorite = ContactSummary(
        contact: contact('favorite', 'Lia Cruz', isFavorite: true),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                ContactListRow(summary: grouped),
                ContactListRow(summary: ungrouped),
                ContactListRow(summary: favorite),
              ],
            ),
          ),
        ),
      );

      final groupedRow = find.byKey(const Key('contact-row-grouped'));
      final ungroupedRow = find.byKey(const Key('contact-row-ungrouped'));
      final favoriteRow = find.byKey(const Key('contact-row-favorite'));

      expect(
        find.descendant(
          of: groupedRow,
          matching: find.byType(ContactGroupIdentityDot),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: ungroupedRow,
          matching: find.byType(ContactGroupIdentityDot),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ContactGroupIdentityDot>(
              find.descendant(
                of: ungroupedRow,
                matching: find.byType(ContactGroupIdentityDot),
              ),
            )
            .colorValue
            .isNeutral,
        isTrue,
        reason: 'ungrouped is the canonical neutral fallback, not a Group',
      );
      expect(
        find.descendant(
          of: ungroupedRow,
          matching: find.byIcon(Icons.star_rounded),
        ),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.text('Maria Santos')).dx,
        tester.getTopLeft(find.text('John Reyes')).dx,
        reason:
            'the neutral ungrouped dot must preserve the group-dot x-offset',
      );
      expect(
        tester.getTopLeft(find.text('Maria Santos')).dx,
        tester.getTopLeft(find.text('Lia Cruz')).dx,
        reason: 'the favorite star must use the same identity-slot footprint',
      );
      expect(
        find.descendant(
          of: favoriteRow,
          matching: find.byIcon(Icons.star_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: favoriteRow,
          matching: find.byType(ContactGroupIdentityDot),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Contacts Main favorite star follows the canonical active primary Group color',
    (tester) async {
      final greenGroup = ContactGroup(
        id: 'green-group',
        profileId: 'profile',
        name: 'Green Group',
        colorValue: 0xFF2F9E44,
        isArchived: false,
        sortOrder: 0,
        createdAtUtc: timestamp,
        updatedAtUtc: timestamp,
      );
      final groupedFavorite = ContactSummary(
        contact: contact('group-favorite', 'Green Favorite', isFavorite: true),
        primaryGroup: greenGroup,
      );
      final ungroupedFavorite = ContactSummary(
        contact: contact(
          'neutral-favorite',
          'Neutral Favorite',
          isFavorite: true,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                ContactListRow(summary: groupedFavorite),
                ContactListRow(summary: ungroupedFavorite),
              ],
            ),
          ),
        ),
      );

      final groupedStar = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('contact-row-group-favorite')),
          matching: find.byIcon(Icons.star_rounded),
        ),
      );
      final ungroupedStar = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('contact-row-neutral-favorite')),
          matching: find.byIcon(Icons.star_rounded),
        ),
      );

      expect(groupedStar.color, const Color(0xFF2F9E44));
      expect(ungroupedStar.color, const Color(ContactUngroupedColor.argb));
    },
  );
}
