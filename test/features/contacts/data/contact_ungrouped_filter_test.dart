// OWNER LAW (2026-09-18) — the virtual "No Group" state.
//
// No Group is NOT a Group row, a membership, a stored identity or a fake filter
// id. It is the single fact the whole Contacts surface already agrees on: a
// Contact holds no ACTIVE (primary) Group membership. Dormant legacy secondary
// rows are historical data and must never make a Contact look grouped.
//
// Fail-first note: against the pre-change source there is no `ungroupedOnly`
// criterion at all, so this file does not compile.
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  final clock = FixedClock(DateTime.utc(2026, 9, 18, 12));
  const today = PlannerDate(year: 2026, month: 9, day: 18);

  Future<(AppDatabase, DriftContactRepository, String)> arrange() async {
    final database = openMemoryDatabase();
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    return (
      database,
      DriftContactRepository(
        database: database,
        clock: clock,
        identifiers: UuidIdentifierSource(),
      ),
      profile.id,
    );
  }

  Future<void> addContact(
    DriftContactRepository contacts,
    String profileId,
    String id,
    String displayName,
  ) => contacts.createContact(
    profileId: profileId,
    draft: ContactDraft(
      id: id,
      firstName: displayName.split(' ').first,
      lastName: displayName.split(' ').last,
      displayName: displayName,
      preferredContactMethod: ContactPreferredMethod.message,
      isFavorite: false,
    ),
  );

  Future<List<ContactSummary>> readWith(
    DriftContactRepository contacts,
    String profileId,
    ContactFilterCriteria criteria,
  ) => contacts.readContacts(
    profileId: profileId,
    criteria: criteria,
    sortBy: ContactSortBy.name,
    today: today,
  );

  test('ungroupedOnly matches exactly the Contacts with no active Group',
      () async {
    final (database, contacts, profileId) = await arrange();
    addTearDown(database.close);
    await addContact(contacts, profileId, 'c-grouped', 'Ada Reyes');
    await addContact(contacts, profileId, 'c-loose', 'Ben Cruz');
    final familyId = ContactBuiltInGroupIdentity.idForProfile(
      profileId,
      'family',
    );
    await contacts.setContactGroups(
      profileId: profileId,
      contactId: 'c-grouped',
      groupIds: <String>[familyId],
      primaryGroupId: familyId,
    );

    final ungrouped = await readWith(
      contacts,
      profileId,
      const ContactFilterCriteria(ungroupedOnly: true),
    );
    expect(
      ungrouped.map((summary) => summary.contact.id).toList(growable: false),
      <String>['c-loose'],
      reason: 'a grouped Contact is never reported as No Group',
    );

    // The criterion is a real filter, so it composes with the rest.
    final all = await readWith(
      contacts,
      profileId,
      const ContactFilterCriteria(),
    );
    expect(all, hasLength(2));
  });

  test('a dormant legacy secondary row does not make a Contact look grouped',
      () async {
    final (database, contacts, profileId) = await arrange();
    addTearDown(database.close);
    await addContact(contacts, profileId, 'c-dormant', 'Ada Reyes');
    final familyId = ContactBuiltInGroupIdentity.idForProfile(
      profileId,
      'family',
    );
    // A stored membership with NO primary: the historical state the C2
    // one-group law keeps as evidence rather than deleting.
    await contacts.setContactGroups(
      profileId: profileId,
      contactId: 'c-dormant',
      groupIds: <String>[familyId],
      primaryGroupId: null,
    );
    final stored = await readWith(
      contacts,
      profileId,
      const ContactFilterCriteria(),
    );
    expect(
      stored.single.primaryGroup,
      isNull,
      reason: 'the dormant row is not the visible group',
    );

    final ungrouped = await readWith(
      contacts,
      profileId,
      const ContactFilterCriteria(ungroupedOnly: true),
    );
    expect(ungrouped.single.contact.id, 'c-dormant');
    expect(
      ungrouped.single.colorValue.value,
      ContactUngroupedColor.argb,
      reason: 'the ungrouped presentation uses the canonical colour',
    );
    // The real membership row was never destroyed by the filter or the state.
    final memberships = await (database.select(
      database.contactGroupMemberships,
    )).get();
    expect(memberships, hasLength(1));
    expect(memberships.single.isPrimary, isFalse);
  });

  test('the criterion survives a save/restore round trip inside the app state',
      () async {
    const criteria = ContactFilterCriteria(
      ungroupedOnly: true,
      favoritesOnly: true,
    );
    expect(criteria.isEmpty, isFalse);
    final restored = ContactFilterCriteria.decode(criteria.encode());
    expect(restored.ungroupedOnly, isTrue);
    expect(restored.favoritesOnly, isTrue);
    expect(
      const ContactFilterCriteria().copyWith(ungroupedOnly: true).ungroupedOnly,
      isTrue,
    );
    expect(
      const ContactFilterCriteria(ungroupedOnly: true)
          .copyWith(ungroupedOnly: false)
          .ungroupedOnly,
      isFalse,
    );
  });
}
