import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  final clock = FixedClock(DateTime.utc(2026, 8, 3, 12));
  const today = PlannerDate(year: 2026, month: 8, day: 3);
  final identifiers = UuidIdentifierSource();

  DriftContactRepository createContacts(AppDatabase database) {
    return DriftContactRepository(
      database: database,
      clock: clock,
      identifiers: identifiers,
    );
  }

  DriftCalendarEventRepository createCalendar(AppDatabase database) {
    return DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
    );
  }

  Future<
    (AppDatabase, DriftContactRepository, DriftCalendarEventRepository, String)
  >
  arrange() async {
    final database = openMemoryDatabase();
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    return (
      database,
      createContacts(database),
      createCalendar(database),
      profile.id,
    );
  }

  ContactDraft draftFor({
    required String id,
    String first = 'Marilyn',
    String last = 'Gomez',
    String? phone,
    String? email,
    String? note,
    List<String> tagNames = const <String>[],
  }) {
    return ContactDraft(
      id: id,
      firstName: first,
      lastName: last,
      displayName: '$first $last'.trim(),
      preferredContactMethod: ContactPreferredMethod.message,
      isFavorite: false,
      methods: <ContactMethodDraft>[
        if (phone != null)
          ContactMethodDraft(type: ContactMethodType.phone, value: phone),
        if (email != null)
          ContactMethodDraft(type: ContactMethodType.email, value: email),
      ],
      initialNoteText: note,
      tagNames: tagNames,
    );
  }

  test('create, edit, archive, and restore keep one stable identity', () async {
    final (database, contacts, _, profileId) = await arrange();
    addTearDown(database.close);

    final created = await contacts.createContact(
      profileId: profileId,
      draft: draftFor(
        id: 'contact-marilyn',
        phone: '+1 555 0100',
        note: 'Met at the retreat.',
      ),
    );
    expect(created.id, 'contact-marilyn');
    expect(created.displayName, 'Marilyn Gomez');
    expect(created.lifecycleState, ContactLifecycleState.active);
    expect(created.source, ContactSource.manual);

    final detail = await contacts.readContactDetail(
      profileId: profileId,
      contactId: 'contact-marilyn',
    );
    expect(detail.methods.single.type, ContactMethodType.phone);
    expect(detail.notes.single.noteText, 'Met at the retreat.');

    await contacts.setFavorite(
      profileId: profileId,
      contactId: 'contact-marilyn',
      favorite: true,
    );
    await contacts.archiveContact(
      profileId: profileId,
      contactId: 'contact-marilyn',
    );
    final archived = await contacts.readContactDetail(
      profileId: profileId,
      contactId: 'contact-marilyn',
    );
    expect(archived.contact.lifecycleState, ContactLifecycleState.archived);
    expect(archived.contact.isFavorite, isTrue);

    final restored = await contacts.restoreContact(
      profileId: profileId,
      contactId: 'contact-marilyn',
    );
    expect(restored.id, 'contact-marilyn');
    expect(restored.lifecycleState, ContactLifecycleState.active);
    expect(restored.isFavorite, isTrue);
  });

  test('historical Event Preview projection falls back to its own canonical '
      'live link when no participant snapshot exists', () async {
    final (database, contacts, calendar, profileId) = await arrange();
    addTearDown(database.close);
    const eventA = '11111111-1111-4111-8111-111111111119';
    const eventB = '22222222-2222-4222-8222-222222222229';
    const date = PlannerDate(year: 2026, month: 7, day: 30);
    await contacts.createContact(
      profileId: profileId,
      draft: draftFor(id: 'aa-gomez', first: 'Aa', last: 'Gomez'),
    );
    await contacts.createContact(
      profileId: profileId,
      draft: draftFor(id: 'other-event-person', first: 'Other', last: 'Event'),
    );
    for (final event in <(String, String)>[
      (eventA, 'Temple Visit'),
      (eventB, 'Contact'),
    ]) {
      await calendar.saveEvent(
        profileId: profileId,
        draft: CalendarEventDraft(
          id: event.$1,
          title: event.$2,
          timing: CalendarEventTiming.allDay,
          startDate: date,
          requiresReport: false,
        ),
      );
    }
    await contacts.setEventPeople(
      profileId: profileId,
      eventId: eventA,
      occurrenceId: DriftContactRepository.seriesOccurrenceId,
      contactIds: const <String>['aa-gomez'],
    );
    await contacts.setEventPeople(
      profileId: profileId,
      eventId: eventB,
      occurrenceId: DriftContactRepository.seriesOccurrenceId,
      contactIds: const <String>['other-event-person'],
    );

    final people = await contacts.readEventParticipantPresentation(
      profileId: profileId,
      eventId: eventA,
      occurrenceId: CalendarEventOccurrenceIdentity.forDate(
        eventId: eventA,
        originalDate: date,
      ),
      historical: true,
    );
    expect(people.map((person) => person.displayName), <String>['Aa Gomez']);
    expect(
      people.map((person) => person.displayName),
      isNot(contains('Other Event')),
    );

    await contacts.setEventPeople(
      profileId: profileId,
      eventId: eventA,
      occurrenceId: DriftContactRepository.seriesOccurrenceId,
      contactIds: const <String>[],
    );
    final removed = await contacts.readEventParticipantPresentation(
      profileId: profileId,
      eventId: eventA,
      occurrenceId: CalendarEventOccurrenceIdentity.forDate(
        eventId: eventA,
        originalDate: date,
      ),
      // Removal is a current relationship projection. Historical snapshot
      // preservation remains a separately frozen Timeline law.
      historical: false,
    );
    expect(removed, isEmpty);
  });

  test(
    'duplicate candidates include exact and conservative contained names',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);
      for (final entry in <(String, String)>[
        ('exact-a', 'Aa Papa Gomez'),
        ('exact-b', 'Aa, Papa   Gomez'),
        ('contained', 'Papa Gomez'),
        ('surname-only', 'Gomez'),
      ]) {
        await contacts.createContact(
          profileId: profileId,
          draft: draftFor(id: entry.$1, first: entry.$2, last: ''),
        );
      }
      final candidates = await contacts.readDuplicateCandidates(profileId);
      bool hasPair(String first, String second) => candidates.any(
        (group) => group.map((contact) => contact.id).toSet().containsAll(
          <String>[first, second],
        ),
      );
      expect(hasPair('exact-a', 'exact-b'), isTrue);
      expect(hasPair('exact-a', 'contained'), isTrue);
      expect(hasPair('exact-a', 'surname-only'), isFalse);
    },
  );

  test(
    'hard deleting a group removes every membership while retaining Contacts',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      final deletedGroup = await contacts.createGroup(
        profileId: profileId,
        name: 'Family',
        colorValue: 0xFFE91E63,
      );
      final retainedGroup = await contacts.createGroup(
        profileId: profileId,
        name: 'Friends',
        colorValue: 0xFF4CAF50,
      );
      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(id: 'contact-ashley', first: 'Ashley', last: 'Gomez'),
      );
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: 'contact-ashley',
        groupIds: <String>[deletedGroup.id, retainedGroup.id],
        primaryGroupId: deletedGroup.id,
      );
      final summary = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
      );
      final ashley = summary.singleWhere(
        (s) => s.contact.id == 'contact-ashley',
      );
      expect(ashley.primaryGroup?.id, deletedGroup.id);
      expect(ashley.colorValue.value, 0xFFE91E63);

      await contacts.hardDeleteGroup(
        profileId: profileId,
        groupId: deletedGroup.id,
      );
      final afterDelete = await contacts.readContactDetail(
        profileId: profileId,
        contactId: 'contact-ashley',
      );
      expect(afterDelete.contact.id, 'contact-ashley');
      expect(afterDelete.primaryGroupId, isNull);
      expect(afterDelete.groups.map((group) => group.id), <String>[
        retainedGroup.id,
      ]);
      final allGroups = await contacts.readGroups(
        profileId,
        includeArchived: true,
      );
      expect(
        allGroups.map((group) => group.id),
        isNot(contains(deletedGroup.id)),
      );
      final deletedMemberships = await (database.select(
        database.contactGroupMemberships,
      )..where((table) => table.groupId.equals(deletedGroup.id))).get();
      expect(deletedMemberships, isEmpty);
    },
  );

  test('hard deleting a group is profile scoped', () async {
    final (database, contacts, _, profileId) = await arrange();
    addTearDown(database.close);

    final group = await contacts.createGroup(
      profileId: profileId,
      name: 'Work',
      colorValue: 0xFF1E88E5,
    );

    await expectLater(
      contacts.hardDeleteGroup(profileId: 'another-profile', groupId: group.id),
      throwsA(isA<ContactValidationException>()),
    );
    final remaining = await contacts.readGroups(
      profileId,
      includeArchived: true,
    );
    expect(remaining.single.id, group.id);
  });

  test(
    'RELEASE-BLOCKING: removing a Contact from a future series keeps their '
    'past occurrence on the Timeline (occurrence snapshot stability)',
    () async {
      final (database, contacts, calendar, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(id: 'contact-marilyn'),
      );

      // Weekly Dinner starting Saturday 2026-07-25 with Marilyn on the series.
      await calendar.saveEvent(
        profileId: profileId,
        draft: CalendarEventDraft(
          id: '11111111-1111-4111-8111-111111111111',
          title: 'Dinner with Family',
          timing: CalendarEventTiming.timed,
          startDate: const PlannerDate(year: 2026, month: 7, day: 25),
          startMinute: 18 * 60,
          endMinute: 19 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
          recurrence: const CalendarRecurrenceRule(
            frequency: CalendarRecurrenceFrequency.weekly,
          ),
        ),
      );
      await contacts.setEventPeople(
        profileId: profileId,
        eventId: '11111111-1111-4111-8111-111111111111',
        occurrenceId: 'series',
        contactIds: <String>['contact-marilyn'],
      );

      final before = await contacts.readTimeline(
        profileId: profileId,
        contactId: 'contact-marilyn',
        today: today,
      );
      expect(
        before.history.map((e) => e.date.iso8601),
        containsAll(<String>['2026-07-25', '2026-08-01']),
      );
      expect(
        before.upcoming.map((e) => e.date.iso8601),
        contains('2026-08-08'),
      );

      // The user edits the FUTURE series and removes Marilyn.
      await contacts.setEventPeople(
        profileId: profileId,
        eventId: '11111111-1111-4111-8111-111111111111',
        occurrenceId: 'series',
        contactIds: const <String>[],
      );

      final after = await contacts.readTimeline(
        profileId: profileId,
        contactId: 'contact-marilyn',
        today: today,
      );
      expect(after.upcoming, isEmpty);
      // Historical participation MUST remain â€” this is the release gate.
      expect(
        after.history.map((e) => e.date.iso8601),
        containsAll(<String>['2026-07-25', '2026-08-01']),
      );
      // No duplicate occurrence entries from link + snapshot.
      final augustFirst = after.history
          .where((e) => e.date.iso8601 == '2026-08-01')
          .toList();
      expect(augustFirst, hasLength(1));

      // The frozen occurrence still resolves its people.
      final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
        eventId: '11111111-1111-4111-8111-111111111111',
        originalDate: const PlannerDate(year: 2026, month: 8, day: 1),
      );
      final people = await contacts.readEventPeople(
        profileId: profileId,
        eventId: '11111111-1111-4111-8111-111111111111',
        occurrenceId: occurrenceId,
        today: today,
      );
      expect(
        people.map((summary) => summary.contact.id),
        contains('contact-marilyn'),
      );
    },
  );

  test(
    'merge preserves links, timeline, notes, and historical identity',
    () async {
      final (database, contacts, calendar, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(
          id: 'contact-a',
          first: 'Marilyn',
          last: 'Gomez',
          phone: '+1 555 0100',
        ),
      );
      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(
          id: 'contact-b',
          first: 'Marilyn',
          last: 'Gomez',
          phone: '+1 555 0100',
        ),
      );
      await contacts.addNote(
        profileId: profileId,
        contactId: 'contact-b',
        text: 'Met at the retreat.',
      );

      await calendar.saveEvent(
        profileId: profileId,
        draft: CalendarEventDraft(
          id: '22222222-2222-4222-8222-222222222222',
          title: 'Lunch Meeting',
          timing: CalendarEventTiming.timed,
          startDate: const PlannerDate(year: 2026, month: 7, day: 28),
          startMinute: 12 * 60,
          endMinute: 13 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
        ),
      );
      await contacts.setEventPeople(
        profileId: profileId,
        eventId: '22222222-2222-4222-8222-222222222222',
        occurrenceId: 'series',
        contactIds: <String>['contact-a', 'contact-b'],
      );

      final candidates = await contacts.readDuplicateCandidates(profileId);
      expect(candidates, isNotEmpty);
      expect(
        candidates.any(
          (group) => group.map((c) => c.id).toSet().containsAll(<String>[
            'contact-a',
            'contact-b',
          ]),
        ),
        isTrue,
      );

      final plan = await contacts.readMergePlan(
        profileId: profileId,
        survivorId: 'contact-a',
        absorbedIds: <String>['contact-b'],
      );
      expect(plan.survivor.id, 'contact-a');
      expect(plan.absorbed.single.id, 'contact-b');

      final merged = await contacts.mergeContacts(
        profileId: profileId,
        survivorId: 'contact-a',
        absorbedIds: <String>['contact-b'],
        choices: const ContactMergeChoices(<String, String>{}),
      );
      expect(merged.id, 'contact-a');

      // Event links survive under the survivor without duplication.
      final people = await contacts.readEventPeople(
        profileId: profileId,
        eventId: '22222222-2222-4222-8222-222222222222',
        occurrenceId: 'series',
        today: today,
      );
      expect(people.map((s) => s.contact.id), <String>['contact-a']);

      // The absorbed identity is traceable, not deleted as data loss.
      final absorbed = await contacts.readContactDetail(
        profileId: profileId,
        contactId: 'contact-b',
      );
      expect(absorbed.contact.mergedIntoContactId, 'contact-a');

      // Timeline under the survivor includes the past occurrence and both notes
      // (the absorbed note is preserved).
      final timeline = await contacts.readTimeline(
        profileId: profileId,
        contactId: 'contact-a',
        today: today,
      );
      expect(timeline.history.map((e) => e.title), contains('Lunch Meeting'));
      final detail = await contacts.readContactDetail(
        profileId: profileId,
        contactId: 'contact-a',
      );
      expect(
        detail.notes.map((n) => n.noteText),
        contains('Met at the retreat.'),
      );
    },
  );

  test(
    'device import is selected-only and flags duplicates without merging',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(
          id: 'existing',
          first: 'Marilyn',
          last: 'Gomez',
          phone: '+1 555 0100',
        ),
      );

      final result = await contacts.importDeviceContacts(
        profileId: profileId,
        drafts: const <DeviceContactDraft>[
          DeviceContactDraft(
            displayName: 'Marilyn Gomez',
            firstName: 'Marilyn',
            lastName: 'Gomez',
            phones: <String>['+1 555 0100'],
          ),
          DeviceContactDraft(
            displayName: 'Simon Rufino',
            firstName: 'Simon',
            lastName: 'Rufino',
            phones: <String>['+1 555 0200'],
          ),
        ],
      );
      expect(result.createdCount, 1);
      expect(result.skippedCount, 1);
      expect(result.duplicateContactIds, contains('Marilyn Gomez'));

      final summaries = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
      );
      expect(summaries, hasLength(2));
      final simon = summaries.singleWhere(
        (s) => s.contact.firstName == 'Simon',
      );
      expect(simon.contact.source, ContactSource.deviceImport);
    },
  );

  test('saved filters persist criteria and are deletable', () async {
    final (database, contacts, _, profileId) = await arrange();
    addTearDown(database.close);

    final legacy = SavedContactFilterDocument.decode(
      const ContactFilterCriteria(favoritesOnly: true).encode(),
    );
    expect(legacy.criteria.favoritesOnly, isTrue);
    expect(legacy.description, isEmpty);

    final saved = await contacts.saveSavedFilter(
      profileId: profileId,
      draft: const SavedContactFilterDraft(
        name: 'Family weekend',
        criteria: ContactFilterCriteria(groupIds: <String>['family']),
        sortBy: ContactSortBy.recentlyAdded,
        description: 'Family contacts for the weekend',
        displayedFields: <ContactDisplayedField>[
          ContactDisplayedField.currentGroup,
          ContactDisplayedField.nextEvent,
        ],
      ),
    );
    final filters = await contacts.readSavedFilters(profileId);
    expect(filters.single.id, saved.id);
    expect(filters.single.name, 'Family weekend');
    expect(filters.single.criteria.groupIds, <String>['family']);
    expect(filters.single.sortBy, ContactSortBy.recentlyAdded);
    expect(filters.single.description, 'Family contacts for the weekend');
    expect(filters.single.displayedFields, <ContactDisplayedField>[
      ContactDisplayedField.currentGroup,
      ContactDisplayedField.nextEvent,
    ]);

    final updated = await contacts.updateSavedFilter(
      profileId: profileId,
      filterId: saved.id,
      draft: const SavedContactFilterDraft(
        name: 'Family weekend updated',
        criteria: ContactFilterCriteria(groupIds: <String>['family']),
        description: 'Updated description',
        displayedFields: <ContactDisplayedField>[ContactDisplayedField.address],
      ),
    );
    expect(updated.name, 'Family weekend updated');
    expect(updated.description, 'Updated description');
    expect(updated.displayedFields, <ContactDisplayedField>[
      ContactDisplayedField.address,
    ]);

    await contacts.deleteSavedFilter(profileId: profileId, filterId: saved.id);
    expect(await contacts.readSavedFilters(profileId), isEmpty);
  });

  test(
    'standard filters use the persisted view stamp and 30-day cutoff',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(id: 'recent-view'),
      );
      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(id: 'old-view', first: 'Ashley'),
      );
      await (database.update(
        database.contacts,
      )..where((table) => table.id.equals('recent-view'))).write(
        ContactsCompanion(lastViewedAtUtc: Value(DateTime.utc(2026, 7, 5, 12))),
      );
      await (database.update(
        database.contacts,
      )..where((table) => table.id.equals('old-view'))).write(
        ContactsCompanion(lastViewedAtUtc: Value(DateTime.utc(2026, 7, 2, 12))),
      );

      final viewed = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
        standardView: const ContactStandardView(
          filter: ContactStandardFilter.recentlyViewed,
        ),
      );
      expect(viewed.map((item) => item.contact.id), contains('recent-view'));
      expect(
        viewed.map((item) => item.contact.id),
        isNot(contains('old-view')),
      );

      final created = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
        standardView: const ContactStandardView(
          filter: ContactStandardFilter.recentlyCreated,
        ),
      );
      expect(created, hasLength(2));
    },
  );

  test(
    'Status and Recent Contact use non-cancelled Event participation facts',
    () async {
      final (database, contacts, calendar, profileId) = await arrange();
      addTearDown(database.close);

      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(id: 'contact-interacted'),
      );
      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(id: 'contact-never', first: 'Ashley'),
      );
      await calendar.saveEvent(
        profileId: profileId,
        draft: CalendarEventDraft(
          id: '44444444-4444-4444-8444-444444444444',
          title: 'Planning conversation',
          timing: CalendarEventTiming.timed,
          startDate: const PlannerDate(year: 2026, month: 7, day: 25),
          startMinute: 12 * 60,
          endMinute: 13 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
          recurrence: const CalendarRecurrenceRule(
            frequency: CalendarRecurrenceFrequency.none,
          ),
        ),
      );
      await contacts.setEventPeople(
        profileId: profileId,
        eventId: '44444444-4444-4444-8444-444444444444',
        occurrenceId: 'series',
        contactIds: const <String>['contact-interacted'],
      );

      final contacted = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
        standardView: const ContactStandardView(
          filter: ContactStandardFilter.recentlyContacted,
        ),
      );
      expect(
        contacted.map((item) => item.contact.id),
        contains('contact-interacted'),
      );
      expect(
        contacted.map((item) => item.contact.id),
        isNot(contains('contact-never')),
      );

      final available = await contacts.readAvailableStatusBuckets(
        profileId: profileId,
      );
      expect(available, contains(ContactStatusBucket.notInteractedYet));
      expect(available, contains(ContactStatusBucket.oneToThreeMonthsAgo));
      expect(available, isNot(contains(ContactStatusBucket.interactedToday)));

      final status = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
        standardView: const ContactStandardView(
          filter: ContactStandardFilter.status,
          statusBucket: ContactStatusBucket.oneToThreeMonthsAgo,
        ),
      );
      expect(status.single.contact.id, 'contact-interacted');
      expect(
        status.single.statusBucket,
        ContactStatusBucket.oneToThreeMonthsAgo,
      );

      final aggregateStatus = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
        standardView: const ContactStandardView(
          filter: ContactStandardFilter.status,
        ),
      );
      expect(
        aggregateStatus.map((item) => item.contact.id),
        unorderedEquals(<String>['contact-interacted', 'contact-never']),
      );
      expect(
        aggregateStatus
            .singleWhere((item) => item.contact.id == 'contact-interacted')
            .statusBucket,
        ContactStatusBucket.oneToThreeMonthsAgo,
      );
      expect(
        aggregateStatus
            .singleWhere((item) => item.contact.id == 'contact-never')
            .statusBucket,
        ContactStatusBucket.notInteractedYet,
      );
    },
  );

  test(
    'search matches visible fields but excludes dormant Tag names',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      final group = await contacts.createGroup(
        profileId: profileId,
        name: 'Work',
        colorValue: 0xFF2196F3,
      );
      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(
          id: 'c-1',
          first: 'Ashley',
          last: 'Gomez',
          phone: '+1 555 0300',
          tagNames: const <String>['Dormant-only label'],
        ),
      );
      await contacts.setContactGroups(
        profileId: profileId,
        contactId: 'c-1',
        groupIds: <String>[group.id],
        primaryGroupId: group.id,
      );
      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(
          id: 'c-2',
          first: 'Simon',
          last: 'Rufino',
          email: 'simon@example.com',
        ),
      );

      final byName = await contacts.searchContacts(
        profileId: profileId,
        query: 'ash',
        today: today,
      );
      expect(byName.map((s) => s.contact.id), contains('c-1'));

      final byPhone = await contacts.searchContacts(
        profileId: profileId,
        query: '0300',
        today: today,
      );
      expect(byPhone.map((s) => s.contact.id), contains('c-1'));

      final byEmail = await contacts.searchContacts(
        profileId: profileId,
        query: 'simon@example',
        today: today,
      );
      expect(byEmail.map((s) => s.contact.id), contains('c-2'));

      final byGroup = await contacts.searchContacts(
        profileId: profileId,
        query: 'work',
        today: today,
      );
      expect(byGroup.map((s) => s.contact.id), contains('c-1'));

      final byDormantTag = await contacts.searchContacts(
        profileId: profileId,
        query: 'dormant-only',
        today: today,
      );
      expect(byDormantTag, isEmpty);
    },
  );

  test(
    'phone filter distinguishes No Phone, typed labels, and Other fallback',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      Future<void> addPhone(String id, String number, {String? label}) async {
        await contacts.createContact(
          profileId: profileId,
          draft: draftFor(id: id, phone: number),
        );
        await (database.update(database.contactMethods)
              ..where((t) => t.contactId.equals(id)))
            .write(ContactMethodsCompanion(label: Value<String?>(label)));
      }

      await addPhone('p-mobile', '+1 555 0100', label: 'mobile');
      await addPhone('p-home', '+1 555 0200', label: 'home');
      await addPhone('p-work', '+1 555 0300', label: 'work');
      await addPhone('p-custom', '+1 555 0400', label: 'custom');
      await addPhone('p-null', '+1 555 0500');
      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(id: 'p-none'),
      );

      Future<Set<String>> idsFor(List<String> phoneLabels) async {
        final rows = await contacts.readContacts(
          profileId: profileId,
          criteria: ContactFilterCriteria(phoneLabels: phoneLabels),
          sortBy: ContactSortBy.name,
          today: today,
        );
        return rows.map((s) => s.contact.id).toSet();
      }

      expect(
        await idsFor(const <String>[]),
        isNotEmpty,
        reason: 'All is neutral',
      );
      expect(await idsFor(const <String>[ContactPhoneFilterKeys.mobile]), {
        'p-mobile',
      });
      expect(await idsFor(const <String>[ContactPhoneFilterKeys.home]), {
        'p-home',
      });
      expect(await idsFor(const <String>[ContactPhoneFilterKeys.work]), {
        'p-work',
      });
      // Other catches null/blank/custom/unrecognized labels only.
      expect(await idsFor(const <String>[ContactPhoneFilterKeys.other]), {
        'p-custom',
        'p-null',
      });
      // No Phone = zero phone methods.
      expect(await idsFor(const <String>[ContactPhoneFilterKeys.noPhone]), {
        'p-none',
      });
      // No Phone + Mobile ORs within the category.
      expect(
        await idsFor(const <String>[
          ContactPhoneFilterKeys.noPhone,
          ContactPhoneFilterKeys.mobile,
        ]),
        {'p-none', 'p-mobile'},
      );
    },
  );

  test(
    'email filter maps personal/home, work, family, and Other fallback',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      Future<void> addEmail(String id, String address, {String? label}) async {
        await contacts.createContact(
          profileId: profileId,
          draft: draftFor(id: id, email: address),
        );
        await (database.update(database.contactMethods)
              ..where((t) => t.contactId.equals(id)))
            .write(ContactMethodsCompanion(label: Value<String?>(label)));
      }

      await addEmail('e-personal', 'person@example.com', label: 'personal');
      await addEmail('e-home', 'home@example.com', label: 'home');
      await addEmail('e-work', 'work@example.com', label: 'work');
      await addEmail('e-family', 'family@example.com', label: 'family');
      await addEmail('e-custom', 'custom@example.com', label: 'custom');
      await addEmail('e-null', 'null@example.com');

      Future<Set<String>> idsFor(List<String> emailLabels) async {
        final rows = await contacts.readContacts(
          profileId: profileId,
          criteria: ContactFilterCriteria(emailLabels: emailLabels),
          sortBy: ContactSortBy.name,
          today: today,
        );
        return rows.map((s) => s.contact.id).toSet();
      }

      expect(
        await idsFor(const <String>[ContactEmailFilterKeys.personal]),
        {'e-personal', 'e-home'},
        reason: 'Personal accepts both personal and device-home labels',
      );
      expect(await idsFor(const <String>[ContactEmailFilterKeys.work]), {
        'e-work',
      });
      expect(await idsFor(const <String>[ContactEmailFilterKeys.family]), {
        'e-family',
      });
      expect(await idsFor(const <String>[ContactEmailFilterKeys.other]), {
        'e-custom',
        'e-null',
      });
      expect(
        await idsFor(const <String>[ContactEmailFilterKeys.noEmail]),
        isEmpty,
      );
    },
  );

  test('address filter uses stored addressText only, not map pins', () async {
    final (database, contacts, _, profileId) = await arrange();
    addTearDown(database.close);

    await contacts.createContact(
      profileId: profileId,
      draft: const ContactDraft(
        id: 'a-recorded',
        firstName: 'A',
        lastName: 'One',
        displayName: 'A One',
        preferredContactMethod: ContactPreferredMethod.message,
        isFavorite: false,
        addressText: '123 Main St',
      ),
    );
    // Whitespace-only addressText is treated as not recorded.
    await contacts.createContact(
      profileId: profileId,
      draft: const ContactDraft(
        id: 'a-space',
        firstName: 'A',
        lastName: 'Two',
        displayName: 'A Two',
        preferredContactMethod: ContactPreferredMethod.message,
        isFavorite: false,
        addressText: '   ',
      ),
    );
    await contacts.createContact(
      profileId: profileId,
      draft: draftFor(id: 'a-none', first: 'A', last: 'Three'),
    );

    Future<Set<String>> idsFor(List<String> addressLabels) async {
      final rows = await contacts.readContacts(
        profileId: profileId,
        criteria: ContactFilterCriteria(addressLabels: addressLabels),
        sortBy: ContactSortBy.name,
        today: today,
      );
      return rows.map((s) => s.contact.id).toSet();
    }

    expect(await idsFor(const <String>[]), isNotEmpty);
    expect(await idsFor(const <String>[ContactAddressFilterKeys.recorded]), {
      'a-recorded',
    });
    expect(await idsFor(const <String>[ContactAddressFilterKeys.notRecorded]), {
      'a-space',
      'a-none',
    });
  });

  test(
    'social filter matches canonical platforms and Other fallback',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      Future<void> addSocial(String id, String value, {String? label}) async {
        await contacts.createContact(
          profileId: profileId,
          draft: ContactDraft(
            id: id,
            firstName: id,
            lastName: '',
            displayName: id,
            preferredContactMethod: ContactPreferredMethod.message,
            isFavorite: false,
            methods: <ContactMethodDraft>[
              ContactMethodDraft(type: ContactMethodType.social, value: value),
            ],
          ),
        );
        await (database.update(database.contactMethods)
              ..where((t) => t.contactId.equals(id)))
            .write(ContactMethodsCompanion(label: Value<String?>(label)));
      }

      await addSocial('s-wa', 'wa_user', label: 'whatsapp');
      await addSocial('s-fb', 'fb_user', label: 'facebook');
      await addSocial('s-x', 'x_user', label: 'x');
      await addSocial('s-kakao', 'kakao_user', label: 'kakaotalk');
      await addSocial('s-hello', 'hello_user', label: 'hellotalk');
      await addSocial('s-custom', 'custom_user', label: 'custom');
      await addSocial('s-null', 'null_user');

      Future<Set<String>> idsFor(List<String> socialLabels) async {
        final rows = await contacts.readContacts(
          profileId: profileId,
          criteria: ContactFilterCriteria(socialLabels: socialLabels),
          sortBy: ContactSortBy.name,
          today: today,
        );
        return rows.map((s) => s.contact.id).toSet();
      }

      expect(await idsFor(const <String>[]), isNotEmpty);
      expect(await idsFor(const <String>[ContactSocialFilterKeys.whatsapp]), {
        's-wa',
      });
      expect(await idsFor(const <String>[ContactSocialFilterKeys.facebook]), {
        's-fb',
      });
      expect(await idsFor(const <String>[ContactSocialFilterKeys.x]), {'s-x'});
      expect(await idsFor(const <String>[ContactSocialFilterKeys.kakaoTalk]), {
        's-kakao',
      });
      expect(await idsFor(const <String>[ContactSocialFilterKeys.helloTalk]), {
        's-hello',
      });
      expect(await idsFor(const <String>[ContactSocialFilterKeys.other]), {
        's-custom',
        's-null',
      });
      expect(
        await idsFor(const <String>[ContactSocialFilterKeys.noSocial]),
        isEmpty,
      );
    },
  );

  test(
    'new sort options order deterministically with stable tie-breakers',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      final base = DateTime.utc(2026, 8, 3, 12);
      Future<void> addContact(String id, String name, Duration offset) async {
        await contacts.createContact(
          profileId: profileId,
          draft: draftFor(id: id, first: name, last: ''),
        );
        await (database.update(
          database.contacts,
        )..where((t) => t.id.equals(id))).write(
          ContactsCompanion(createdAtUtc: Value<DateTime>(base.add(offset))),
        );
      }

      await addContact('c-b', 'Beta', const Duration(minutes: 10));
      await addContact('c-a', 'Alpha', Duration.zero);
      await addContact('c-c', 'Charlie', const Duration(minutes: 5));

      Future<List<String>> sorted(ContactSortBy sortBy) async {
        final rows = await contacts.readContacts(
          profileId: profileId,
          criteria: const ContactFilterCriteria(),
          sortBy: sortBy,
          today: today,
        );
        return rows.map((s) => s.contact.displayName).toList();
      }

      expect(await sorted(ContactSortBy.name), <String>[
        'Alpha',
        'Beta',
        'Charlie',
      ]);
      expect(await sorted(ContactSortBy.nameDesc), <String>[
        'Charlie',
        'Beta',
        'Alpha',
      ]);
      expect(await sorted(ContactSortBy.oldestAdded), <String>[
        'Alpha',
        'Charlie',
        'Beta',
      ]);
      expect(await sorted(ContactSortBy.recentlyAdded), <String>[
        'Beta',
        'Charlie',
        'Alpha',
      ]);
    },
  );

  test('R2 final sort and Displayed Fields contracts are durable', () {
    expect(ContactSortBy.activeOptions, <ContactSortBy>[
      ContactSortBy.name,
      ContactSortBy.nameDesc,
      ContactSortBy.recentlyAdded,
      ContactSortBy.oldestAdded,
      ContactSortBy.mostRecentlyInteracted,
      ContactSortBy.leastRecentlyInteracted,
    ]);
    expect(
      ContactDisplayedField.values,
      containsAll(<ContactDisplayedField>[
        ContactDisplayedField.currentGroup,
        ContactDisplayedField.tags,
        ContactDisplayedField.nextEvent,
        ContactDisplayedField.lastEvent,
        ContactDisplayedField.lastHappenedEvent,
        ContactDisplayedField.contactMethod,
        ContactDisplayedField.address,
        ContactDisplayedField.lastInteraction,
        ContactDisplayedField.lastViewed,
        ContactDisplayedField.createdDate,
      ]),
    );
    expect(
      ContactDisplayedFieldCodec.defaults,
      ContactDisplayedField.values
          .where((field) => field != ContactDisplayedField.tags)
          .toList(growable: false),
    );
  });

  test(
    'Last Viewed puts recorded Contacts newest-first and nulls last',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);
      for (final entry in <(String, String)>[
        ('a', 'Alpha'),
        ('b', 'Beta'),
        ('c', 'Charlie'),
      ]) {
        await contacts.createContact(
          profileId: profileId,
          draft: draftFor(id: entry.$1, first: entry.$2, last: ''),
        );
      }
      await (database.update(
        database.contacts,
      )..where((t) => t.id.equals('a'))).write(
        ContactsCompanion(lastViewedAtUtc: Value(DateTime.utc(2026, 8, 1))),
      );
      await (database.update(
        database.contacts,
      )..where((t) => t.id.equals('b'))).write(
        ContactsCompanion(lastViewedAtUtc: Value(DateTime.utc(2026, 8, 2))),
      );
      final rows = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.lastViewed,
        today: today,
      );
      expect(rows.map((row) => row.contact.displayName), <String>[
        'Beta',
        'Alpha',
        'Charlie',
      ]);
    },
  );

  test(
    'Next Event / Last Event sorts use canonical event context with nulls last',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      Future<void> addContact(String id, String name) async {
        await contacts.createContact(
          profileId: profileId,
          draft: draftFor(id: id, first: name, last: ''),
        );
      }

      Future<void> addEventLink({
        required String linkId,
        required String eventId,
        required String contactId,
        required String date,
      }) async {
        await database
            .into(database.calendarEvents)
            .insert(
              CalendarEventsCompanion.insert(
                id: eventId,
                profileId: profileId,
                title: 'Event $eventId',
                timing: 'morning',
                startDate: date,
                createdAtUtc: DateTime.utc(2026, 7, 1, 12),
                updatedAtUtc: DateTime.utc(2026, 7, 1, 12),
              ),
            );
        await database
            .into(database.eventContactLinks)
            .insert(
              EventContactLinksCompanion.insert(
                id: linkId,
                profileId: profileId,
                eventId: eventId,
                occurrenceId: Value(linkId),
                originalDate: Value(date),
                contactId: contactId,
                status: const Value('active'),
                createdAtUtc: DateTime.utc(2026, 7, 1, 12),
                updatedAtUtc: DateTime.utc(2026, 7, 1, 12),
              ),
            );
      }

      await addContact('c-alpha', 'Alpha');
      await addContact('c-beta', 'Beta');
      await addContact('c-charlie', 'Charlie');
      await addContact('c-delta', 'Delta');

      // Alpha: next 2026-08-20, last 2026-07-01.
      await addEventLink(
        linkId: 'l-a1',
        eventId: 'e-a-next',
        contactId: 'c-alpha',
        date: '2026-08-20',
      );
      await addEventLink(
        linkId: 'l-a2',
        eventId: 'e-a-past',
        contactId: 'c-alpha',
        date: '2026-07-01',
      );
      // Beta: next 2026-08-15 (earliest upcoming).
      await addEventLink(
        linkId: 'l-b1',
        eventId: 'e-b-next',
        contactId: 'c-beta',
        date: '2026-08-15',
      );
      // Charlie: last 2026-06-01 only.
      await addEventLink(
        linkId: 'l-c1',
        eventId: 'e-c-past',
        contactId: 'c-charlie',
        date: '2026-06-01',
      );
      // Delta: no event context at all.

      Future<List<String>> sorted(ContactSortBy sortBy) async {
        final rows = await contacts.readContacts(
          profileId: profileId,
          criteria: const ContactFilterCriteria(),
          sortBy: sortBy,
          today: today,
        );
        return rows.map((s) => s.contact.displayName).toList();
      }

      // Next Event: earliest upcoming first, missing-next contacts last by name.
      expect(await sorted(ContactSortBy.nextEvent), <String>[
        'Beta',
        'Alpha',
        'Charlie',
        'Delta',
      ]);
      // Last Event: most recent historical first, missing-last contacts last by name.
      expect(await sorted(ContactSortBy.lastEvent), <String>[
        'Alpha',
        'Charlie',
        'Beta',
        'Delta',
      ]);
      expect(await sorted(ContactSortBy.leastRecentEvent), <String>[
        'Charlie',
        'Alpha',
        'Beta',
        'Delta',
      ]);
    },
  );

  test(
    'event-derived sorts tie-break by displayName then stable contact id',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      Future<void> addContact(String id, String first, String last) async {
        await contacts.createContact(
          profileId: profileId,
          draft: draftFor(id: id, first: first, last: last),
        );
      }

      Future<void> addSameDateEventLink(
        String linkId,
        String eventId,
        String contactId,
      ) async {
        await database
            .into(database.calendarEvents)
            .insert(
              CalendarEventsCompanion.insert(
                id: eventId,
                profileId: profileId,
                title: 'Event $eventId',
                timing: 'morning',
                startDate: '2026-08-15',
                createdAtUtc: DateTime.utc(2026, 7, 1, 12),
                updatedAtUtc: DateTime.utc(2026, 7, 1, 12),
              ),
            );
        await database
            .into(database.eventContactLinks)
            .insert(
              EventContactLinksCompanion.insert(
                id: linkId,
                profileId: profileId,
                eventId: eventId,
                occurrenceId: Value(linkId),
                originalDate: const Value('2026-08-15'),
                contactId: contactId,
                status: const Value('active'),
                createdAtUtc: DateTime.utc(2026, 7, 1, 12),
                updatedAtUtc: DateTime.utc(2026, 7, 1, 12),
              ),
            );
      }

      // Same next date: displayName ascending decides.
      await addContact('id-zzz', 'Zulu', '');
      await addContact('id-aaa', 'Alpha', '');
      await addSameDateEventLink('l-z', 'e-z', 'id-zzz');
      await addSameDateEventLink('l-a', 'e-a', 'id-aaa');

      Future<List<String>> sorted(ContactSortBy sortBy) async {
        final rows = await contacts.readContacts(
          profileId: profileId,
          criteria: const ContactFilterCriteria(),
          sortBy: sortBy,
          today: today,
        );
        return rows.map((s) => s.contact.displayName).toList();
      }

      expect(await sorted(ContactSortBy.nextEvent), <String>['Alpha', 'Zulu']);

      // Equal display names: stable contact id ascending decides.
      await addContact('id-b', 'Same', 'Name');
      await addContact('id-a', 'Same', 'Name');
      await addSameDateEventLink('l-b', 'e-b', 'id-b');
      await addSameDateEventLink('l-a2', 'e-a2', 'id-a');

      final byId = await contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.nextEvent,
        today: today,
      );
      final sameNameIds = byId
          .where((s) => s.contact.displayName == 'Same Name')
          .map((s) => s.contact.id)
          .toList();
      expect(sameNameIds, <String>['id-a', 'id-b']);
    },
  );

  test(
    'Last Happened and least-event sorts use effective occurrence status in one batched context read',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      Future<void> addHistoricalEvent({
        required String contactId,
        required String name,
        required String eventId,
        required PlannerDate date,
        required CalendarEventStatus status,
        CalendarEventStatus? exceptionStatus,
      }) async {
        await contacts.createContact(
          profileId: profileId,
          draft: draftFor(id: contactId, first: name, last: ''),
        );
        await database
            .into(database.calendarEvents)
            .insert(
              CalendarEventsCompanion.insert(
                id: eventId,
                profileId: profileId,
                title: 'Event $eventId',
                timing: CalendarEventTiming.timed.name,
                startDate: date.toString(),
                status: Value(status.name),
                createdAtUtc: DateTime.utc(2026, 7, 1, 12),
                updatedAtUtc: DateTime.utc(2026, 7, 1, 12),
              ),
            );
        await database
            .into(database.eventContactLinks)
            .insert(
              EventContactLinksCompanion.insert(
                id: 'link-$contactId',
                profileId: profileId,
                eventId: eventId,
                occurrenceId: Value('single-$contactId'),
                originalDate: Value(date.toString()),
                contactId: contactId,
                status: const Value('active'),
                createdAtUtc: DateTime.utc(2026, 7, 1, 12),
                updatedAtUtc: DateTime.utc(2026, 7, 1, 12),
              ),
            );
        if (exceptionStatus != null) {
          await database
              .into(database.calendarEventExceptions)
              .insert(
                CalendarEventExceptionsCompanion.insert(
                  id: 'exception-$contactId',
                  profileId: profileId,
                  eventId: eventId,
                  occurrenceId: CalendarEventOccurrenceIdentity.forDate(
                    eventId: eventId,
                    originalDate: date,
                  ),
                  originalDate: date.toString(),
                  effectiveDate: date.toString(),
                  title: 'Event $eventId',
                  timing: CalendarEventTiming.timed.name,
                  status: exceptionStatus.name,
                  createdAtUtc: DateTime.utc(2026, 7, 1, 12),
                ),
              );
        }
      }

      await addHistoricalEvent(
        contactId: 'alpha',
        name: 'Alpha',
        eventId: 'happened-alpha',
        date: const PlannerDate(year: 2026, month: 6, day: 1),
        status: CalendarEventStatus.completedHappened,
      );
      await addHistoricalEvent(
        contactId: 'beta',
        name: 'Beta',
        eventId: 'happened-beta',
        date: const PlannerDate(year: 2026, month: 7, day: 1),
        status: CalendarEventStatus.partiallyCompleted,
      );
      await addHistoricalEvent(
        contactId: 'charlie',
        name: 'Charlie',
        eventId: 'scheduled-charlie',
        date: const PlannerDate(year: 2026, month: 7, day: 15),
        status: CalendarEventStatus.scheduled,
      );
      await addHistoricalEvent(
        contactId: 'delta',
        name: 'Delta',
        eventId: 'overridden-delta',
        date: const PlannerDate(year: 2026, month: 7, day: 20),
        status: CalendarEventStatus.completedHappened,
        exceptionStatus: CalendarEventStatus.didNotHappen,
      );

      Future<List<ContactSummary>> sorted(ContactSortBy sortBy) {
        return contacts.readContacts(
          profileId: profileId,
          criteria: const ContactFilterCriteria(),
          sortBy: sortBy,
          today: today,
        );
      }

      expect(
        (await sorted(
          ContactSortBy.lastHappenedEvent,
        )).map((summary) => summary.contact.displayName),
        <String>['Beta', 'Alpha', 'Charlie', 'Delta'],
      );
      expect(
        (await sorted(
          ContactSortBy.leastRecentEvent,
        )).map((summary) => summary.contact.displayName),
        <String>['Alpha', 'Beta', 'Charlie', 'Delta'],
      );
      expect(
        (await sorted(
          ContactSortBy.leastRecentHappenedEvent,
        )).map((summary) => summary.contact.displayName),
        <String>['Alpha', 'Beta', 'Charlie', 'Delta'],
      );
      final delta = (await sorted(
        ContactSortBy.name,
      )).singleWhere((summary) => summary.contact.id == 'delta');
      expect(delta.context.lastHappenedEventDate, isNull);
      expect(
        delta.context.leastRecentEventDate,
        const PlannerDate(year: 2026, month: 7, day: 20),
      );
    },
  );

  test(
    'saved filter codec round-trips the new event-derived sort values',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      for (final sortBy in <ContactSortBy>[
        ContactSortBy.status,
        ContactSortBy.lastViewed,
        ContactSortBy.nextEvent,
        ContactSortBy.lastEvent,
        ContactSortBy.lastHappenedEvent,
        ContactSortBy.leastRecentEvent,
        ContactSortBy.leastRecentHappenedEvent,
      ]) {
        final saved = await contacts.saveSavedFilter(
          profileId: profileId,
          draft: SavedContactFilterDraft(
            name: 'sort ${sortBy.name}',
            criteria: const ContactFilterCriteria(),
            sortBy: sortBy,
          ),
        );
        expect(saved.sortBy, sortBy);
        final loaded = await contacts.readSavedFilters(profileId);
        expect(loaded.map((f) => f.sortBy).toList(), contains(sortBy));
      }
    },
  );

  test(
    'saved filter codec round-trips the new presence/type criteria and decodes legacy JSON',
    () {
      const criteria = ContactFilterCriteria(
        tagIds: <String>['legacy-tag-id'],
        tagSelectionMode: ContactFilterSelectionMode.some,
        phoneLabels: <String>[
          ContactPhoneFilterKeys.noPhone,
          ContactPhoneFilterKeys.mobile,
        ],
        emailLabels: <String>[ContactEmailFilterKeys.personal],
        addressLabels: <String>[ContactAddressFilterKeys.recorded],
        socialLabels: <String>[ContactSocialFilterKeys.whatsapp],
        withFutureEvents: true,
      );
      final encoded = criteria.encode();
      final decoded = ContactFilterCriteria.decode(encoded);
      expect(decoded.phoneLabels, <String>['noPhone', 'mobile']);
      expect(decoded.emailLabels, <String>['personal']);
      expect(decoded.addressLabels, <String>['recorded']);
      expect(decoded.socialLabels, <String>['whatsapp']);
      expect(decoded.withFutureEvents, isTrue);
      expect(decoded.tagIds, <String>['legacy-tag-id']);
      expect(decoded.tagSelectionMode, ContactFilterSelectionMode.some);

      // Legacy JSON without the new keys decodes to neutral (empty) lists.
      final legacy = ContactFilterCriteria.decode(
        '{"groupIds":[],"favoritesOnly":true}',
      );
      expect(legacy.phoneLabels, isEmpty);
      expect(legacy.emailLabels, isEmpty);
      expect(legacy.addressLabels, isEmpty);
      expect(legacy.socialLabels, isEmpty);
      expect(legacy.favoritesOnly, isTrue);

      // Saved filter document envelope round-trips the new criteria.
      const document = SavedContactFilterDocument(
        criteria: criteria,
        description: 'filter with phone + email + address + social',
        displayedFields: <ContactDisplayedField>[
          ContactDisplayedField.tags,
          ContactDisplayedField.lastInteraction,
          ContactDisplayedField.lastViewed,
          ContactDisplayedField.createdDate,
          ContactDisplayedField.lastHappenedEvent,
        ],
      );
      final docDecoded = SavedContactFilterDocument.decode(document.encode());
      expect(docDecoded.criteria.phoneLabels, <String>['noPhone', 'mobile']);
      expect(docDecoded.criteria.socialLabels, <String>['whatsapp']);
      expect(docDecoded.criteria.tagIds, <String>['legacy-tag-id']);
      expect(
        docDecoded.criteria.tagSelectionMode,
        ContactFilterSelectionMode.some,
      );
      expect(docDecoded.displayedFields, <ContactDisplayedField>[
        ContactDisplayedField.lastInteraction,
        ContactDisplayedField.lastViewed,
        ContactDisplayedField.createdDate,
        ContactDisplayedField.lastHappenedEvent,
      ]);
      expect(
        docDecoded.description,
        'filter with phone + email + address + social',
      );
      final normalizedActiveCriteria = docDecoded.criteria.withoutRetiredTags();
      expect(normalizedActiveCriteria.tagIds, isEmpty);
      expect(
        normalizedActiveCriteria.tagSelectionMode,
        ContactFilterSelectionMode.all,
      );
    },
  );

  test(
    'C4 explicit None is empty across repository views while All and Some retain their query meanings',
    () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);
      await contacts.createContact(
        profileId: profileId,
        draft: ContactDraft(
          id: 'mobile-contact',
          firstName: 'Mobile',
          lastName: 'Contact',
          displayName: 'Mobile Contact',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: true,
          methods: const <ContactMethodDraft>[
            ContactMethodDraft(
              type: ContactMethodType.phone,
              value: '+1 555 0100',
              label: ContactPhoneFilterKeys.mobile,
            ),
          ],
        ),
      );
      await contacts.createContact(
        profileId: profileId,
        draft: draftFor(id: 'no-phone-contact', first: 'No', last: 'Phone'),
      );

      Future<List<ContactSummary>> read(
        ContactFilterCriteria criteria, {
        ContactStandardView? standardView,
      }) {
        return contacts.readContacts(
          profileId: profileId,
          criteria: criteria,
          sortBy: ContactSortBy.name,
          today: today,
          standardView: standardView,
        );
      }

      expect(
        (await read(
          const ContactFilterCriteria(),
        )).map((item) => item.contact.id),
        <String>['mobile-contact', 'no-phone-contact'],
      );
      expect(
        (await read(
          const ContactFilterCriteria(
            phoneLabels: <String>[ContactPhoneFilterKeys.mobile],
            phoneSelectionMode: ContactFilterSelectionMode.some,
          ),
        )).map((item) => item.contact.id),
        <String>['mobile-contact'],
      );

      const explicitNone = ContactFilterCriteria(
        phoneSelectionMode: ContactFilterSelectionMode.none,
      );
      expect(await read(explicitNone), isEmpty);
      for (final standard in ContactStandardFilter.values) {
        expect(
          await read(
            explicitNone,
            standardView: ContactStandardView(filter: standard),
          ),
          isEmpty,
          reason: 'explicit None must remain empty in ${standard.name}',
        );
      }

      final saved = await contacts.saveSavedFilter(
        profileId: profileId,
        draft: const SavedContactFilterDraft(
          name: 'Explicit phone none',
          criteria: explicitNone,
        ),
      );
      final reopened = (await contacts.readSavedFilters(profileId)).single;
      expect(reopened.id, saved.id);
      expect(
        reopened.criteria.phoneSelectionMode,
        ContactFilterSelectionMode.none,
      );
      expect(await read(reopened.criteria), isEmpty);
    },
  );

  // POST-M7 CLOSURE (2026-09-16) — device-import count contract.
  //
  // The bulk import used to be a fail-fast sequential batch: the first draft
  // that repeated a normalized method WITHIN ONE device contact raised a
  // validation error out of the loop, so every remaining draft was silently
  // never attempted and only the prefix before the offender persisted
  // (owner-observed ~10 of 974).  N valid selected drafts must always persist N.
  group('device import count contract', () {
    List<DeviceContactDraft> cleanDrafts(int count) => <DeviceContactDraft>[
      for (var i = 0; i < count; i++)
        DeviceContactDraft(
          displayName: 'Person $i',
          firstName: 'Person',
          lastName: '$i',
          phoneDetails: <DeviceContactPhone>[
            DeviceContactPhone(
              value: '+1 555 ${i.toString().padLeft(4, '0')}',
              sourceLabel: 'mobile',
            ),
          ],
        ),
    ];

    // One device contact carrying the SAME number under two labels — routine on
    // Android when a SIM row and a Google row merge.  It must consolidate to a
    // single method, never abort the batch.
    const duplicateLabelDraft = DeviceContactDraft(
      displayName: 'Person offender',
      firstName: 'Person',
      lastName: 'offender',
      phoneDetails: <DeviceContactPhone>[
        DeviceContactPhone(value: '+1 555 0999', sourceLabel: 'mobile'),
        DeviceContactPhone(value: '(1) 555-0999', sourceLabel: 'work'),
      ],
    );

    Future<List<ContactSummary>> readAll(
      DriftContactRepository contacts,
      String profileId,
    ) {
      return contacts.readContacts(
        profileId: profileId,
        criteria: const ContactFilterCriteria(),
        sortBy: ContactSortBy.name,
        today: today,
      );
    }

    test('N unique valid drafts persist exactly N', () async {
      for (final n in <int>[10, 11, 100, 500, 1000]) {
        final (database, contacts, _, profileId) = await arrange();
        final result = await contacts.importDeviceContacts(
          profileId: profileId,
          drafts: cleanDrafts(n),
        );
        expect(result.createdCount, n, reason: 'created for n=$n');
        expect(
          await readAll(contacts, profileId),
          hasLength(n),
          reason: 'visible for n=$n',
        );
        await database.close();
      }
    });

    test(
      '1000 drafts with a duplicate-label phone at index 500 persist 1000',
      () async {
        final (database, contacts, _, profileId) = await arrange();
        addTearDown(database.close);
        final drafts = cleanDrafts(1000);
        drafts[500] = duplicateLabelDraft;

        final result = await contacts.importDeviceContacts(
          profileId: profileId,
          drafts: drafts,
        );

        expect(result.createdCount, 1000);
        final visible = await readAll(contacts, profileId);
        expect(visible, hasLength(1000));

        // The repeated method consolidated to ONE phone on that one Contact.
        final target = visible.singleWhere(
          (summary) => summary.contact.displayName == 'Person offender',
        );
        final detail = await contacts.readContactDetail(
          profileId: profileId,
          contactId: target.contact.id,
        );
        expect(
          detail.methods.where(
            (method) => method.type == ContactMethodType.phone,
          ),
          hasLength(1),
        );
      },
    );

    for (final index in <int>[0, 10, 999]) {
      test('an offender at index $index still persists every draft', () async {
        final (database, contacts, _, profileId) = await arrange();
        addTearDown(database.close);
        final drafts = cleanDrafts(1000);
        drafts[index] = duplicateLabelDraft;

        final result = await contacts.importDeviceContacts(
          profileId: profileId,
          drafts: drafts,
        );

        expect(result.createdCount, 1000, reason: 'offender at $index');
        expect(await readAll(contacts, profileId), hasLength(1000));
      });
    }

    test('repeated emails inside one draft consolidate too', () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      final result = await contacts.importDeviceContacts(
        profileId: profileId,
        drafts: const <DeviceContactDraft>[
          DeviceContactDraft(
            displayName: 'Ada Lovelace',
            firstName: 'Ada',
            lastName: 'Lovelace',
            emails: <String>['Ada@example.com', ' ada@example.com '],
          ),
        ],
      );

      expect(result.createdCount, 1);
      final visible = await readAll(contacts, profileId);
      expect(visible, hasLength(1));
      final detail = await contacts.readContactDetail(
        profileId: profileId,
        contactId: visible.single.contact.id,
      );
      expect(
        detail.methods.where(
          (method) => method.type == ContactMethodType.email,
        ),
        hasLength(1),
      );
    });

    test('every submitted draft is accounted for in a mixed batch', () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      final drafts = <DeviceContactDraft>[
        ...cleanDrafts(9),
        const DeviceContactDraft(displayName: '   '),
        duplicateLabelDraft,
      ];

      final result = await contacts.importDeviceContacts(
        profileId: profileId,
        drafts: drafts,
      );

      expect(result.createdCount, 10);
      expect(result.skippedCount, 1);
      expect(
        result.createdCount + result.skippedCount,
        drafts.length,
        reason: 'created + skipped must equal submitted',
      );
    });

    test('two different contacts sharing one phone are both created', () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      final result = await contacts.importDeviceContacts(
        profileId: profileId,
        drafts: const <DeviceContactDraft>[
          DeviceContactDraft(
            displayName: 'Shared Landline One',
            phones: <String>['+1 555 0404'],
          ),
          DeviceContactDraft(
            displayName: 'Shared Landline Two',
            phones: <String>['+1 555 0404'],
          ),
        ],
      );

      expect(result.createdCount, 2);
      expect(result.duplicateContactIds, isEmpty);
      expect(await readAll(contacts, profileId), hasLength(2));
    });

    test('drafts with no contact method at all are still created', () async {
      final (database, contacts, _, profileId) = await arrange();
      addTearDown(database.close);

      final result = await contacts.importDeviceContacts(
        profileId: profileId,
        drafts: const <DeviceContactDraft>[
          DeviceContactDraft(displayName: 'Name Only One'),
          DeviceContactDraft(displayName: 'Name Only Two'),
        ],
      );

      expect(result.createdCount, 2);
      expect(await readAll(contacts, profileId), hasLength(2));
    });
  });
}
