import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// C2 canonical ContactGroup color wiring tests (implementation pack
/// 2026-08-19). Real ContactGroup rows are the canonical live color source;
/// built-in defaults are seeded idempotently with deterministic identity;
/// one visible/current group per Contact (primary only); dormant legacy
/// secondary memberships are preserved; Store A stays dormant.
void main() {
  final clock = FixedClock(DateTime.utc(2026, 8, 19, 12));
  const today = PlannerDate(year: 2026, month: 8, day: 19);
  final identifiers = UuidIdentifierSource();

  DriftContactRepository createContacts(AppDatabase database) {
    return DriftContactRepository(
      database: database,
      clock: clock,
      identifiers: identifiers,
    );
  }

  Future<(AppDatabase, DriftContactRepository, String)> arrange() async {
    final database = openMemoryDatabase();
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    return (database, createContacts(database), profile.id);
  }

  ContactDraft draftFor(String id, {String first = 'Marilyn'}) {
    return ContactDraft(
      id: id,
      firstName: first,
      lastName: 'Gomez',
      displayName: '$first Gomez',
      preferredContactMethod: ContactPreferredMethod.message,
      isFavorite: false,
    );
  }

  group('C2 built-in default groups', () {
    test(
        'seeds the five canonical defaults idempotently, in owner order, and '
        'never seeds the retired Other row', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.ensureBuiltInGroups(profileId);
      await contacts.ensureBuiltInGroups(profileId);

      final rows = await contacts.readGroups(profileId);
      expect(
        rows.map((row) => row.name).toList(growable: false),
        <String>[
          'Family',
          'Friends',
          'Ministering Assignments',
          'Members',
          'Avoid',
        ],
        reason: 'canonical order, with no legacy Other row',
      );
      final byName = {for (final row in rows) row.name: row};
      // Owner-transcribed PMG literals (2026-09-18 lock): a new profile's real
      // rows must carry exactly these stored ARGB values.
      expect(byName['Family']!.colorValue, 0xFF76B181);
      expect(byName['Friends']!.colorValue, 0xFFE89C72);
      expect(byName['Ministering Assignments']!.colorValue, 0xFF98CED8);
      expect(byName['Members']!.colorValue, 0xFF29646C);
      expect(byName['Avoid']!.colorValue, 0xFFC7566A);
      expect(
        byName.containsKey('Other'),
        isFalse,
        reason: 'Other is retired as a default',
      );
      // Deterministic identity and canonical order use the profile context.
      for (final group in ContactBuiltInGroupDefaults.ordered) {
        expect(
          byName[group.name]!.id,
          ContactBuiltInGroupIdentity.idForProfile(profileId, group.key),
        );
        expect(byName[group.name]!.sortOrder, group.canonicalOrder);
      }
    });

    test('built-in identity differs across profiles', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.ensureBuiltInGroups(profileId);
      const secondProfile = '00000000-0000-4000-8000-000000000002';
      final idA = ContactBuiltInGroupIdentity.idForProfile(
        profileId,
        'family',
      );
      final idB = ContactBuiltInGroupIdentity.idForProfile(
        secondProfile,
        'family',
      );
      expect(idA, isNot(idB));
    });

    test('legacy Store A override imported only when creating missing built-in',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      // A canonical row is seeded at profile creation now, so simulate a
      // pre-C2 install by removing exactly that one identity first.
      await (database.delete(database.contactGroups)..where(
            (table) =>
                table.id.equals(
                  ContactBuiltInGroupIdentity.idForProfile(profileId, 'family'),
                ),
          ))
          .go();

      // Write a legacy Store A group override for Family.
      final document = EventColorPreferenceCodec.encodeDocument(
        events: const <String, EventColorPreference>{},
        groups: const <String, int>{'family': 0xFF123456},
      );
      await database
          .into(database.plannerPreferences)
          .insertOnConflictUpdate(
            PlannerPreferencesCompanion.insert(
              profileId: profileId,
              eventColorPreferencesJson: Value<String?>(document),
              updatedAtUtc: clock.nowUtc(),
            ),
          );

      await contacts.ensureBuiltInGroups(profileId);
      final rows = await contacts.readGroups(profileId);
      final family = rows.singleWhere((row) => row.name == 'Family');
      expect(family.colorValue, 0xFF123456, reason: 'override imported');
    });

    test('existing real built-in row wins over legacy Store A', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      final familyId = ContactBuiltInGroupIdentity.idForProfile(
        profileId,
        'family',
      );

      final document = EventColorPreferenceCodec.encodeDocument(
        events: const <String, EventColorPreference>{},
        groups: const <String, int>{'family': 0xFF123456},
      );
      await database
          .into(database.plannerPreferences)
          .insertOnConflictUpdate(
            PlannerPreferencesCompanion.insert(
              profileId: profileId,
              eventColorPreferencesJson: Value<String?>(document),
              updatedAtUtc: clock.nowUtc(),
            ),
          );

      await contacts.ensureBuiltInGroups(profileId);
      final rows = await contacts.readGroups(profileId);
      final family = rows.singleWhere((row) => row.name == 'Family');
      expect(family.id, familyId);
      expect(
        family.colorValue,
        ContactBuiltInGroupDefaults.family.colorArgb,
        reason: 'the real canonical row is never rewritten from Store A',
      );
    });

    test(
        'a same-name collision is SKIPPED and REPORTED, never thrown — the '
        'post-restore seeding path must not fail', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      // Simulate a real pre-existing custom row that owns a canonical name.
      await (database.delete(database.contactGroups)..where(
            (table) =>
                table.id.equals(
                  ContactBuiltInGroupIdentity.idForProfile(profileId, 'family'),
                ),
          ))
          .go();
      final now = clock.nowUtc();
      await database
          .into(database.contactGroups)
          .insert(
            ContactGroupsCompanion.insert(
              id: 'custom-family-id',
              profileId: profileId,
              name: 'Family',
              colorValue: 0xFF999999,
              isArchived: const Value<bool>(false),
              sortOrder: const Value<int>(0),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );

      // STOP C2 replaced: never throw, never convert the custom identity.
      await expectLater(contacts.ensureBuiltInGroups(profileId), completes);
      final rows = await contacts.readGroups(profileId);
      expect(
        rows.where((row) => row.name == 'Family').single.id,
        'custom-family-id',
      );

      final outcome = await contacts.applyDefaultGroups(profileId);
      expect(outcome.collidingNames, <String>['Family']);
      expect(outcome.addedNames, isNot(contains('Family')));
      final after = await contacts.readGroups(profileId);
      expect(after.where((row) => row.name == 'Family').single.colorValue,
          0xFF999999);
    });

    test('restore defaults touches built-ins only and leaves custom untouched',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.ensureBuiltInGroups(profileId);
      final custom = await contacts.createGroup(
        profileId: profileId,
        name: 'Work',
        colorValue: 0xFF555555,
      );
      // Change a built-in color and a custom color.
      final familyId = ContactBuiltInGroupIdentity.idForProfile(
        profileId,
        'family',
      );
      await contacts.updateGroup(
        profileId: profileId,
        groupId: familyId,
        name: 'Family',
        colorValue: 0xFF111111,
      );
      await contacts.updateGroup(
        profileId: profileId,
        groupId: custom.id,
        name: 'Work',
        colorValue: 0xFF222222,
      );

      await contacts.restoreBuiltInGroupColorDefaults(profileId);

      final rows = await contacts.readGroups(profileId);
      final byId = {for (final row in rows) row.id: row};
      expect(
        byId[familyId]!.colorValue,
        ContactBuiltInGroupDefaults.family.colorArgb,
      );
      expect(byId[custom.id]!.colorValue, 0xFF222222, reason: 'custom kept');
    });
  });

  group('C2 one-group V1 and dormant secondary memberships', () {
    test('setContactGroups preserves dormant secondary memberships', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.ensureBuiltInGroups(profileId);
      final rows = await contacts.readGroups(profileId);
      final family = rows.singleWhere((row) => row.name == 'Family');
      final friends = rows.singleWhere((row) => row.name == 'Friends');

      final contact = await contacts.createContact(
        profileId: profileId,
        draft: draftFor('c1'),
      );
      // Simulate a legacy multi-membership contact: Family primary + Friends.
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: <String>[family.id, friends.id],
        primaryGroupId: family.id,
      );

      // User changes the visible group to Friends.
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: <String>[friends.id],
        primaryGroupId: friends.id,
      );

      final detail = await contacts.readContactDetail(
        profileId: profileId,
        contactId: contact.id,
      );
      expect(detail.primaryGroupId, friends.id);
      expect(
        detail.groups.map((g) => g.id).toSet(),
        containsAll(<String>[family.id, friends.id]),
        reason: 'dormant Family membership preserved',
      );
    });

    test('clearing the primary keeps dormant secondary rows', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.ensureBuiltInGroups(profileId);
      final rows = await contacts.readGroups(profileId);
      final family = rows.singleWhere((row) => row.name == 'Family');
      final friends = rows.singleWhere((row) => row.name == 'Friends');

      final contact = await contacts.createContact(
        profileId: profileId,
        draft: draftFor('c2'),
      );
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: <String>[family.id, friends.id],
        primaryGroupId: family.id,
      );
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: const <String>[],
        primaryGroupId: null,
      );

      final detail = await contacts.readContactDetail(
        profileId: profileId,
        contactId: contact.id,
      );
      expect(detail.primaryGroupId, isNull);
      expect(
        detail.groups.map((g) => g.id).toSet(),
        containsAll(<String>[family.id, friends.id]),
        reason: 'dormant rows preserved when clearing',
      );
    });

    test('group filter matches the PRIMARY membership only', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.ensureBuiltInGroups(profileId);
      final rows = await contacts.readGroups(profileId);
      final family = rows.singleWhere((row) => row.name == 'Family');
      final friends = rows.singleWhere((row) => row.name == 'Friends');

      final contact = await contacts.createContact(
        profileId: profileId,
        draft: draftFor('c3'),
      );
      // Family is a dormant secondary; Friends is the visible primary.
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: <String>[family.id, friends.id],
        primaryGroupId: friends.id,
      );

      final friendsView = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(groupIds: <String>[]),
        sortBy: ContactSortBy.name,
        today: today,
      );
      expect(friendsView, hasLength(1));

      // A Family filter must NOT surface this contact (primary is Friends).
      final familyFilter = await contacts.readContacts(
        profileId: profileId,
        criteria: ContactFilterCriteria(groupIds: <String>[family.id]),
        sortBy: ContactSortBy.name,
        today: today,
      );
      expect(familyFilter, isEmpty, reason: 'dormant secondary ignored');

      final friendsFilter = await contacts.readContacts(
        profileId: profileId,
        criteria: ContactFilterCriteria(groupIds: <String>[friends.id]),
        sortBy: ContactSortBy.name,
        today: today,
      );
      expect(friendsFilter, hasLength(1));
    });

    test('ContactSummary subtitle shows only the primary group', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.ensureBuiltInGroups(profileId);
      final rows = await contacts.readGroups(profileId);
      final family = rows.singleWhere((row) => row.name == 'Family');
      final friends = rows.singleWhere((row) => row.name == 'Friends');

      final contact = await contacts.createContact(
        profileId: profileId,
        draft: draftFor('c4'),
      );
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: <String>[family.id, friends.id],
        primaryGroupId: friends.id,
      );

      final list = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
      );
      final summary = list.single;
      expect(summary.primaryGroup!.id, friends.id);
      expect(summary.subtitle, 'Friends', reason: 'primary only');
    });
  });

  group('C2 rename preserves color and stable id', () {
    test('rename keeps id and colorValue', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.ensureBuiltInGroups(profileId);
      final custom = await contacts.createGroup(
        profileId: profileId,
        name: 'Old Name',
        colorValue: 0xFFABCDEF,
      );
      final renamed = await contacts.updateGroup(
        profileId: profileId,
        groupId: custom.id,
        name: 'New Name',
        colorValue: 0xFFABCDEF,
      );
      expect(renamed.id, custom.id);
      expect(renamed.name, 'New Name');
      expect(renamed.colorValue, 0xFFABCDEF);
    });
  });

  group('C3 truthful archived-only view', () {
    test('archivedOnly returns archived contacts only', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      final active = await contacts.createContact(
        profileId: profileId,
        draft: draftFor('active'),
      );
      final archived = await contacts.createContact(
        profileId: profileId,
        draft: draftFor('archived', first: 'Archived'),
      );
      await contacts.archiveContact(
        profileId: profileId,
        contactId: archived.id,
      );

      final archivedView = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(archivedOnly: true),
        sortBy: ContactSortBy.name,
        today: today,
      );
      expect(
        archivedView.map((s) => s.contact.id),
        <String>[archived.id],
        reason: 'only archived contacts',
      );
      expect(active.lifecycleState, ContactLifecycleState.active);

      final allView = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
      );
      expect(allView.map((s) => s.contact.id), contains(active.id));
    });
  });

  group('Post-C7 Group detail membership removal', () {
    test('removes only the selected membership and never the Contact',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.ensureBuiltInGroups(profileId);
      final groups = await contacts.readGroups(profileId);
      final family = groups.singleWhere((group) => group.name == 'Family');
      final friends = groups.singleWhere((group) => group.name == 'Friends');
      final contact = await contacts.createContact(
        profileId: profileId,
        draft: draftFor('group-detail-removal'),
      );
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: <String>[family.id, friends.id],
        primaryGroupId: family.id,
      );

      await contacts.removeContactFromGroup(
        profileId: profileId,
        contactId: contact.id,
        groupId: family.id,
      );

      final memberships = await (database.select(
        database.contactGroupMemberships,
      )..where((row) => row.contactId.equals(contact.id))).get();
      final savedContact = await contacts.readContactDetail(
        profileId: profileId,
        contactId: contact.id,
      );
      expect(
        memberships.map((row) => row.groupId),
        <String>[friends.id],
        reason: 'only the exact membership is removed',
      );
      expect(memberships.single.isPrimary, isFalse);
      expect(savedContact.contact.id, contact.id);
      expect(savedContact.primaryGroupId, isNull);
    });
  });
}
