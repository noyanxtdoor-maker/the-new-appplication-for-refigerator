// OWNER LAW (2026-09-17) — canonical default Contact Groups.
//
//   New profile        -> the five canonical defaults, in owner order, no Other.
//   Existing profile   -> NOTHING changes until the user explicitly opts in
//                         ("Use default groups" / "Restore default groups").
//
// The beta is already in use, so the migration must be additive and must never
// rewrite a user's own groups, colours or memberships. The engine also replaced
// the old STOP-C2 throw on a same-name collision, because that throw also broke
// the post-restore seeding path.
//
// Fail-first note: every assertion below fails against the pre-change source
// (four defaults including Other, `ensureBuiltInGroups` throwing on a name
// collision, alphabetical/undefined order).
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  final clock = FixedClock(DateTime.utc(2026, 9, 17, 12));
  const today = PlannerDate(year: 2026, month: 9, day: 17);

  DriftContactRepository createContacts(AppDatabase database) {
    return DriftContactRepository(
      database: database,
      clock: clock,
      identifiers: UuidIdentifierSource(),
    );
  }

  Future<(AppDatabase, DriftContactRepository, String)> arrange() async {
    final database = openMemoryDatabase();
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    return (database, createContacts(database), profile.id);
  }

  String builtInId(String profileId, String key) =>
      ContactBuiltInGroupIdentity.idForProfile(profileId, key);

  Future<void> insertGroup(
    AppDatabase database, {
    required String id,
    required String profileId,
    required String name,
    required int colorValue,
    int sortOrder = 0,
    bool isArchived = false,
  }) async {
    final now = clock.nowUtc();
    await database
        .into(database.contactGroups)
        .insert(
          ContactGroupsCompanion.insert(
            id: id,
            profileId: profileId,
            name: name,
            colorValue: colorValue,
            isArchived: Value<bool>(isArchived),
            sortOrder: Value<int>(sortOrder),
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
  }

  Future<void> deleteGroup(AppDatabase database, String id) =>
      (database.delete(database.contactGroups)
            ..where((table) => table.id.equals(id)))
          .go();

  /// Turns a freshly created profile into one that predates the canonical set:
  /// the two new defaults do not exist, and the surviving built-ins carry the
  /// user's own edits.
  Future<void> makeLegacyProfile(
    AppDatabase database,
    String profileId,
  ) async {
    await deleteGroup(database, builtInId(profileId, 'ministering_assignments'));
    await deleteGroup(database, builtInId(profileId, 'members'));
    await (database.update(database.contactGroups)..where(
          (table) => table.id.equals(builtInId(profileId, 'family')),
        ))
        .write(
          ContactGroupsCompanion(
            name: Value<String>('My Family'),
            colorValue: const Value<int>(0xFF123456),
            updatedAtUtc: Value<DateTime>(clock.nowUtc()),
          ),
        );
  }

  group('new profile', () {
    test('receives exactly the five canonical defaults, in owner order', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

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
      );
      expect(
        rows.any((row) => row.name == 'Other'),
        isFalse,
        reason: 'Other is retired as a default',
      );
    });

    test('does not re-seed a default group the user deleted', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);

      await deleteGroup(database, builtInId(profileId, 'members'));
      // A read path must never resurrect it.
      final rows = await contacts.readGroups(profileId);
      expect(rows.any((row) => row.name == 'Members'), isFalse);
      expect(
        rows.map((row) => row.name),
        isNot(contains('Members')),
        reason: 'reading Groups never seeds',
      );
    });
  });

  group('existing profile — opt-in only', () {
    test('nothing changes until the user opts in', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await makeLegacyProfile(database, profileId);
      final custom = await contacts.createGroup(
        profileId: profileId,
        name: 'Client',
        colorValue: 0xFF0A0B0C,
      );

      final before = await contacts.readGroups(profileId);
      expect(
        before.map((row) => row.name).toList(growable: false),
        <String>['My Family', 'Friends', 'Avoid', 'Client'],
        reason: 'canonical identities lead in canonical order, then the rest',
      );
      expect(
        ContactDefaultGroupsStatus.evaluate(
          groups: before,
          profileId: profileId,
        ).missingNames,
        <String>['Ministering Assignments', 'Members'],
      );

      // The read path above is the whole of the automatic behaviour: no row was
      // created, so an existing profile is genuinely unchanged.
      final after = await contacts.readGroups(profileId);
      expect(after.length, before.length);
      expect(
        after.singleWhere((row) => row.id == custom.id).colorValue,
        0xFF0A0B0C,
      );
    });

    test('opting in adds the missing defaults and places them canonically',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await makeLegacyProfile(database, profileId);
      final custom = await contacts.createGroup(
        profileId: profileId,
        name: 'Client',
        colorValue: 0xFF0A0B0C,
      );

      final outcome = await contacts.applyDefaultGroups(profileId);

      expect(
        outcome.addedNames,
        <String>['Ministering Assignments', 'Members'],
      );
      expect(outcome.collidingNames, isEmpty);
      final rows = await contacts.readGroups(profileId);
      expect(
        rows.map((row) => row.name).toList(growable: false),
        <String>[
          'My Family',
          'Friends',
          'Ministering Assignments',
          'Members',
          'Avoid',
          'Client',
        ],
      );
      // The user's own edits survive untouched.
      expect(
        rows.singleWhere((row) => row.name == 'My Family').colorValue,
        0xFF123456,
        reason: 'a customized built-in colour is never overwritten',
      );
      expect(
        rows.singleWhere((row) => row.id == custom.id).colorValue,
        0xFF0A0B0C,
      );
      expect(
        rows.singleWhere((row) => row.id == custom.id).name,
        'Client',
      );
      // The two newly installed defaults carry the exact owner-locked PMG
      // values (2026-09-18 literals).
      expect(
        rows
            .singleWhere((row) => row.name == 'Ministering Assignments')
            .colorValue,
        0xFF98CED8,
      );
      expect(
        rows.singleWhere((row) => row.name == 'Members').colorValue,
        0xFF29646C,
      );
      // The pre-existing canonical rows the user never customised keep their
      // shipped identity; only an explicit restore rewrites those.
      expect(
        rows.singleWhere((row) => row.name == 'Friends').colorValue,
        ContactBuiltInGroupDefaults.friends.colorArgb,
      );
      expect(
        rows.singleWhere((row) => row.name == 'Avoid').colorValue,
        ContactBuiltInGroupDefaults.avoid.colorArgb,
      );
    });

    test('is idempotent — a second run adds nothing and creates no duplicates',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await makeLegacyProfile(database, profileId);

      await contacts.applyDefaultGroups(profileId);
      final second = await contacts.applyDefaultGroups(profileId);

      expect(second.addedNames, isEmpty);
      expect(second.collidingNames, isEmpty);
      expect(second.reappliedNames, isEmpty);
      final rows = await contacts.readGroups(profileId);
      expect(rows.map((row) => row.name).toSet(), hasLength(rows.length));
    });

    test('preserves memberships — no Contact becomes unassigned', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await makeLegacyProfile(database, profileId);
      final contact = await contacts.createContact(
        profileId: profileId,
        draft: const ContactDraft(
          id: 'contact-1',
          firstName: 'Marilyn',
          lastName: 'Gomez',
          displayName: 'Marilyn Gomez',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );
      final familyId = builtInId(profileId, 'family');
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: <String>[familyId],
        primaryGroupId: familyId,
      );

      await contacts.applyDefaultGroups(profileId);

      final detail = await contacts.readContactDetail(
        profileId: profileId,
        contactId: contact.id,
      );
      expect(detail.primaryGroupId, familyId);
      expect(detail.groups.map((group) => group.id), contains(familyId));
      expect(
        await contacts.readGroups(profileId),
        hasLength(5),
        reason: 'the three surviving built-ins plus the two added defaults',
      );
    });

    test('keeps the legacy Other row and its memberships, after the defaults',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await insertGroup(
        database,
        id: builtInId(profileId, 'other'),
        profileId: profileId,
        name: 'Other',
        colorValue: 0xFFB373A2,
      );
      final otherId = builtInId(profileId, 'other');
      final contact = await contacts.createContact(
        profileId: profileId,
        draft: const ContactDraft(
          id: 'contact-other',
          firstName: 'Ada',
          lastName: 'Reyes',
          displayName: 'Ada Reyes',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: <String>[otherId],
        primaryGroupId: otherId,
      );

      await contacts.applyDefaultGroups(profileId);

      final rows = await contacts.readGroups(profileId);
      expect(
        rows.map((row) => row.name).toList(growable: false),
        <String>[
          'Family',
          'Friends',
          'Ministering Assignments',
          'Members',
          'Avoid',
          'Other',
        ],
        reason: 'Other is preserved, treated like a custom group',
      );
      final detail = await contacts.readContactDetail(
        profileId: profileId,
        contactId: contact.id,
      );
      expect(detail.primaryGroupId, otherId);
      expect(
        rows.singleWhere((row) => row.id == otherId).colorValue,
        0xFFB373A2,
      );
    });

    test('preserves the relative order of custom groups', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await insertGroup(
        database,
        id: 'custom-late',
        profileId: profileId,
        name: 'Zulu',
        colorValue: 0xFF222222,
        sortOrder: 7,
      );
      await insertGroup(
        database,
        id: 'custom-early',
        profileId: profileId,
        name: 'Alpha',
        colorValue: 0xFF333333,
        sortOrder: 2,
      );

      final rows = await contacts.readGroups(profileId);
      expect(
        rows.map((row) => row.name).toList(growable: false),
        <String>[
          'Family',
          'Friends',
          'Ministering Assignments',
          'Members',
          'Avoid',
          'Alpha',
          'Zulu',
        ],
        reason: 'the canonical five lead; existing custom order is preserved',
      );
    });
  });

  group('same-name collision — fail closed, never throw', () {
    test('a custom group named Members is kept and the default is skipped',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await deleteGroup(database, builtInId(profileId, 'members'));
      await insertGroup(
        database,
        id: 'custom-members',
        profileId: profileId,
        name: 'Members',
        colorValue: 0xFF444444,
      );

      // The post-restore path used to THROW here and abort the whole seeding.
      await expectLater(contacts.ensureBuiltInGroups(profileId), completes);

      final outcome = await contacts.applyDefaultGroups(profileId);
      expect(outcome.collidingNames, <String>['Members']);
      expect(outcome.addedNames, isEmpty);

      final rows = await contacts.readGroups(profileId);
      final members = rows.where((row) => row.name == 'Members').toList();
      expect(members, hasLength(1), reason: 'no duplicate row was invented');
      expect(members.single.id, 'custom-members');
      expect(members.single.colorValue, 0xFF444444);
    });

    test(
        'a custom group named Ministering Assignments is kept and reported, '
        'and the other defaults still land', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await deleteGroup(
        database,
        builtInId(profileId, 'ministering_assignments'),
      );
      await insertGroup(
        database,
        id: 'custom-ministering',
        profileId: profileId,
        name: 'Ministering Assignments',
        colorValue: 0xFF555555,
      );

      final outcome = await contacts.applyDefaultGroups(profileId);

      expect(outcome.collidingNames, <String>['Ministering Assignments']);
      final rows = await contacts.readGroups(profileId);
      expect(
        rows.where((row) => row.name == 'Ministering Assignments').single.id,
        'custom-ministering',
      );
      expect(rows.any((row) => row.name == 'Members'), isTrue);
    });

    test('the collision is reported in status so the UI can explain it',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await deleteGroup(database, builtInId(profileId, 'members'));
      await insertGroup(
        database,
        id: 'custom-members',
        profileId: profileId,
        name: '  members  ',
        colorValue: 0xFF444444,
      );

      final status = ContactDefaultGroupsStatus.evaluate(
        groups: await contacts.readGroups(profileId),
        profileId: profileId,
      );
      expect(
        status.collidingNames,
        <String>['Members'],
        reason: 'name matching is trimmed and case-insensitive',
      );
      expect(status.needsAttention, isFalse);
    });
  });

  group('restore default groups', () {
    test('re-applies canonical name, order and colour to canonical ids only',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await makeLegacyProfile(database, profileId);
      final custom = await contacts.createGroup(
        profileId: profileId,
        name: 'Client',
        colorValue: 0xFF0A0B0C,
      );

      final outcome = await contacts.applyDefaultGroups(
        profileId,
        restoreCanonicalValues: true,
      );

      expect(outcome.reappliedNames, contains('Family'));
      expect(
        outcome.addedNames,
        <String>['Ministering Assignments', 'Members'],
      );
      final rows = await contacts.readGroups(profileId);
      final family = rows.singleWhere(
        (row) => row.id == builtInId(profileId, 'family'),
      );
      expect(family.name, 'Family', reason: 'canonical name restored');
      expect(family.colorValue, ContactBuiltInGroupDefaults.family.colorArgb);
      expect(family.sortOrder, 0);
      // The explicit restore re-applies the exact owner-locked PMG values to
      // the canonical ids (2026-09-18 literals).
      final restoredById = {
        for (final row in rows) row.id: row.colorValue,
      };
      expect(restoredById[builtInId(profileId, 'family')], 0xFF76B181);
      expect(restoredById[builtInId(profileId, 'friends')], 0xFFE89C72);
      expect(restoredById[builtInId(profileId, 'ministering_assignments')],
          0xFF98CED8);
      expect(restoredById[builtInId(profileId, 'members')], 0xFF29646C);
      expect(restoredById[builtInId(profileId, 'avoid')], 0xFFC7566A);
      // The unrelated custom group is untouched by an explicit restore.
      expect(rows.singleWhere((row) => row.id == custom.id).colorValue,
          0xFF0A0B0C);
      expect(rows.singleWhere((row) => row.id == custom.id).name, 'Client');
    });
  });

  group('ungrouped is a visual state, not a group', () {
    test('no Ungrouped row is ever created, and no primary group uses its colour',
        () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      await contacts.applyDefaultGroups(profileId);

      final rows = await contacts.readGroups(profileId);
      expect(rows.any((row) => row.name.toLowerCase() == 'ungrouped'), isFalse);
      expect(
        rows.any((row) => row.colorValue == ContactUngroupedColor.argb),
        isFalse,
        reason: 'the ungrouped colour is never persisted as a group colour',
      );
    });

    test('a grouped Contact resolves its real group colour; an ungrouped one '
        'resolves the ungrouped state', () async {
      final (database, contacts, profileId) = await arrange();
      addTearDown(database.close);
      final familyId = builtInId(profileId, 'family');
      final contact = await contacts.createContact(
        profileId: profileId,
        draft: const ContactDraft(
          id: 'contact-2',
          firstName: 'Ben',
          lastName: 'Cruz',
          displayName: 'Ben Cruz',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );

      final ungrouped = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
      );
      final ungroupedSummary = ungrouped.singleWhere(
        (summary) => summary.contact.id == contact.id,
      );
      expect(ungroupedSummary.primaryGroup, isNull);
      expect(ungroupedSummary.colorValue.isNeutral, isTrue);
      expect(ungroupedSummary.colorValue.value, ContactUngroupedColor.argb);

      await contacts.setContactGroups(
        profileId: profileId,
        contactId: contact.id,
        groupIds: <String>[familyId],
        primaryGroupId: familyId,
      );

      final grouped = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
      );
      final groupedSummary = grouped.singleWhere(
        (summary) => summary.contact.id == contact.id,
      );
      expect(groupedSummary.primaryGroup?.id, familyId);
      expect(
        groupedSummary.colorValue.value,
        ContactBuiltInGroupDefaults.family.colorArgb,
      );
      expect(groupedSummary.colorValue.isNeutral, isFalse);
    });
  });
}
