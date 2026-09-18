import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/contact_multi_select_screen.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  testWidgets(
    'Post-C7: More keeps purpose-specific recipients and Select contacts is lifecycle-only',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final startup = buildTestRepository(database: database);
      final profile = await startup.completeOnboarding();
      final contacts = DriftContactRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 25, 12)),
        identifiers: SequenceIdentifierSource(<String>[
          '11111111-1111-4111-8111-111111111111',
          '11111111-1111-4111-8111-111111111112',
          '11111111-1111-4111-8111-111111111113',
          '22222222-2222-4222-8222-222222222222',
          '22222222-2222-4222-8222-222222222223',
          '22222222-2222-4222-8222-222222222224',
        ]),
      );
      await contacts.ensureBuiltInGroups(profile.id);
      final groups = await contacts.readGroups(profile.id);
      final family = groups.singleWhere((group) => group.name == 'Family');
      final other = groups.singleWhere((group) => group.name == 'Members');
      for (final draft in <ContactDraft>[
        const ContactDraft(
          id: '11111111-1111-4111-8111-111111111111',
          firstName: 'Visible',
          lastName: 'Contact',
          displayName: 'Visible Contact',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
          methods: <ContactMethodDraft>[
            ContactMethodDraft(
              type: ContactMethodType.phone,
              value: '0917 111 2222',
              receivesTexts: true,
            ),
            ContactMethodDraft(
              type: ContactMethodType.email,
              value: 'visible@example.com',
            ),
          ],
        ),
        const ContactDraft(
          id: '22222222-2222-4222-8222-222222222222',
          firstName: 'Hidden',
          lastName: 'Contact',
          displayName: 'Hidden Contact',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
          methods: <ContactMethodDraft>[
            ContactMethodDraft(
              type: ContactMethodType.phone,
              value: '0917 333 4444',
              receivesTexts: false,
            ),
            ContactMethodDraft(
              type: ContactMethodType.email,
              value: 'not-an-email',
            ),
          ],
        ),
      ]) {
        await contacts.createContact(profileId: profile.id, draft: draft);
        await contacts.setContactGroups(
          profileId: profile.id,
          contactId: draft.id,
          groupIds: <String>[family.id],
          primaryGroupId: family.id,
        );
      }
      const reassignedId = '33333333-3333-4333-8333-333333333333';
      await contacts.createContact(
        profileId: profile.id,
        draft: const ContactDraft(
          id: reassignedId,
          firstName: 'Moving',
          lastName: 'Contact',
          displayName: 'Moving Contact',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );
      await contacts.setContactGroups(
        profileId: profile.id,
        contactId: reassignedId,
        groupIds: <String>[other.id],
        primaryGroupId: other.id,
      );
      const ungroupedId = '44444444-4444-4444-8444-444444444444';
      await contacts.createContact(
        profileId: profile.id,
        draft: const ContactDraft(
          id: ungroupedId,
          firstName: 'Unassigned',
          lastName: 'Contact',
          displayName: 'Unassigned Contact',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );

      final privacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          contactRepository: contacts,
          plannerDateSource: const FixedPlannerDateSource(
            PlannerDate(year: 2026, month: 8, day: 25),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-contacts')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('contacts-overflow-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Archive contacts'), findsOneWidget);
      expect(find.text('Select contacts'), findsOneWidget);
      expect(find.text('Text contacts'), findsOneWidget);
      expect(find.text('Email contacts'), findsOneWidget);
      expect(find.text('Delete contacts'), findsNothing);
      await tester.tap(find.text('Text contacts'));
      await tester.pumpAndSettle();
      expect(find.text('Text Contacts'), findsOneWidget);
      await tester.tap(find.byKey(const Key('multi-select-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('contacts-overflow-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Email contacts'));
      await tester.pumpAndSettle();
      expect(find.text('Email Contacts'), findsOneWidget);
      await tester.tap(find.byKey(const Key('multi-select-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('contacts-overflow-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive contacts'));
      await tester.pumpAndSettle();
      expect(find.text('Archived'), findsOneWidget);
      expect(find.text('Recently Deleted'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('contacts-overflow-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select contacts'));
      await tester.pumpAndSettle();
      expect(find.text('Select Contacts'), findsOneWidget);
      expect(find.byKey(const Key('multi-select-archive')), findsOneWidget);
      expect(find.byKey(const Key('multi-select-delete')), findsOneWidget);
      expect(find.byKey(const Key('multi-select-text')), findsNothing);
      expect(find.byKey(const Key('multi-select-email')), findsNothing);
      await tester.tap(find.byKey(const Key('multi-select-close')));
      await tester.pumpAndSettle();
      unawaited(
        Navigator.of(
          tester.element(find.byKey(const Key('nav-contacts'))),
        ).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const ContactMultiSelectScreen(args: MultiSelectArgs()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Select Contacts'), findsOneWidget);
      expect(
        find.byKey(
          const Key('multi-select-row-11111111-1111-4111-8111-111111111111'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('multi-select-row-22222222-2222-4222-8222-222222222222'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(
          const Key('multi-select-row-11111111-1111-4111-8111-111111111111'),
        ),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('multi-select-search')),
        'Hidden',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('multi-select-all')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('multi-select-search')), '');
      await tester.pumpAndSettle();
      expect(find.text('Done (2)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('multi-select-text')));
      await tester.pumpAndSettle();
      expect(find.text('1 contact ready to text'), findsOneWidget);
      expect(find.text('1 contact excluded'), findsOneWidget);
      expect(find.text('No text-capable phone'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recipient-review-cancel')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('multi-select-email')));
      await tester.pumpAndSettle();
      expect(find.text('1 contact ready to email'), findsOneWidget);
      expect(find.text('Invalid email address'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recipient-review-cancel')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('multi-select-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contacts-overflow-menu')), findsOneWidget);

      await tester.tap(find.byKey(const Key('contacts-groups-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('group-open-${family.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('group-add-members-${family.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Already in Family'), findsNWidgets(2));
      expect(find.text('Members'), findsOneWidget);
      await tester.tap(find.byKey(Key('multi-select-row-$reassignedId')));
      await tester.tap(find.byKey(Key('multi-select-row-$ungroupedId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('multi-select-done')));
      await tester.pumpAndSettle();
      expect(find.text('Add 2 contacts to Family?'), findsOneWidget);
      expect(find.text('Moving Contact — Members'), findsOneWidget);
      expect(find.text('1 contact currently have no group.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('group-reassignment-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Members (4)'), findsOneWidget);
      final reassigned = await contacts.readContactDetail(
        profileId: profile.id,
        contactId: reassignedId,
      );
      expect(reassigned.primaryGroupId, family.id);
      final ungrouped = await contacts.readContactDetail(
        profileId: profile.id,
        contactId: ungroupedId,
      );
      expect(ungrouped.primaryGroupId, family.id);
      expect(
        await contacts.readContactDetail(
          profileId: profile.id,
          contactId: '11111111-1111-4111-8111-111111111111',
        ),
        isNotNull,
      );
      expect(
        await contacts.readContactDetail(
          profileId: profile.id,
          contactId: '22222222-2222-4222-8222-222222222222',
        ),
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
