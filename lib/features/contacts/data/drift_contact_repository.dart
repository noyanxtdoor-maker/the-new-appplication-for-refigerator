import 'dart:async';

import 'package:drift/drift.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/colors/vs11_color_system.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/contacts/application/contact_repository.dart';
import 'package:rmplanner/features/contacts/data/contact_group_seeding.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

/// Drift-backed VS-11 Contacts repository.
///
/// Every multi-row operation uses batched queries (no N+1), and every write
/// that could affect history freezes occurrence-level participant snapshots
/// first so recurrence edits can never rewrite the past.
final class DriftContactRepository
    implements ContactRepository, CalendarEventDuplicateContextTransfer {
  DriftContactRepository({
    required this.database,
    required this.clock,
    required this.identifiers,
    this.reminderRepair,
  });

  final AppDatabase database;
  final AppClock clock;
  final IdentifierSource identifiers;

  /// M7 section 27 repair-intent port.  A Contact lifecycle or rename mutation
  /// can invalidate every calendarEvent/task reminder that names it, so the
  /// intent to reconcile commits INSIDE the mutation's own transaction: a later
  /// platform failure can no longer erase the fact that those reminders need a
  /// fresh look.  Absent in pure-read/test compositions.
  final ReminderRecoveryRequest? reminderRepair;

  static const String seriesOccurrenceId = 'series';
  static const String _activeEventContactStatus = 'active';
  static const String _removedEventContactStatus = 'removed';

  /// The Contact Timeline reads the same stored Event wall-time fields as
  /// Planner.  This converter is deliberately used only to classify the
  /// read-model; it does not create a second Event store or alter an Event.
  static final IanaCalendarEventTimeZones _timelineTimeZones =
      IanaCalendarEventTimeZones(displayTimeZoneId: 'Etc/UTC');

  // -- Change stream --------------------------------------------------------

  @override
  Stream<int> watchChanges(String profileId) {
    // The same lightweight change stream the Goals repository uses: table
    // update notifications instead of per-table QueryStreams, so widget-test
    // teardown never leaves drift cancel timers pending.  The counter is
    // never `void`: Riverpod 3 skips notifying listeners for consecutive
    // equal AsyncData states, so a void stream would only ever refresh once.
    var generation = 0;
    return database
        .tableUpdates(
          TableUpdateQuery.onAllTables(<ResultSetImplementation>[
            database.contacts,
            database.contactMethods,
            database.contactGroups,
            database.contactGroupMemberships,
            database.contactTags,
            database.contactTagMemberships,
            database.contactNotes,
            database.contactAvailabilities,
            database.eventContactLinks,
            database.eventOccurrenceParticipants,
            database.taskContactLinks,
            database.plannerTasks,
            database.outcomeReports,
            database.savedContactFilters,
          ]),
        )
        .map((_) => ++generation);
  }

  @override
  Stream<int> watchTimelineEventChanges(String profileId) {
    var generation = 0;
    return database
        .tableUpdates(
          TableUpdateQuery.onAllTables(<ResultSetImplementation>[
            database.calendarEvents,
            database.calendarEventExceptions,
          ]),
        )
        .map((_) => ++generation);
  }

  // -- Contacts -------------------------------------------------------------

  @override
  Future<Contact> createContact({
    required String profileId,
    required ContactDraft draft,
  }) async {
    if (draft.requiresNewManualContactValidation) {
      draft.validateNewManualContact();
    }
    final normalized = draft.normalized();
    final now = clock.nowUtc();
    return database.transaction(() async {
      await database
          .into(database.contacts)
          .insert(
            ContactsCompanion.insert(
              id: normalized.id,
              profileId: profileId,
              firstName: Value<String?>(
                normalized.firstName.isEmpty ? null : normalized.firstName,
              ),
              lastName: Value<String?>(
                normalized.lastName.isEmpty ? null : normalized.lastName,
              ),
              displayName: normalized.displayName,
              preferredContactMethod: Value<String>(
                ContactPreferredMethodCodec.encode(
                  normalized.preferredContactMethod,
                ),
              ),
              isFavorite: Value<bool>(normalized.isFavorite),
              lifecycleState: Value<String>(
                ContactLifecycleStateCodec.encode(ContactLifecycleState.active),
              ),
              source: Value<String>(
                ContactSourceCodec.encode(normalized.source),
              ),
              addressText: Value<String?>(normalized.addressText),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );
      await _replaceMethods(
        profileId,
        contactId: normalized.id,
        methods: normalized.methods,
      );
      await setContactGroups(
        profileId: profileId,
        contactId: normalized.id,
        groupIds: normalized.groupIds,
        primaryGroupId: normalized.primaryGroupId,
      );
      await _replaceTags(
        profileId,
        contactId: normalized.id,
        tagNames: normalized.tagNames,
      );
      await setAvailability(
        profileId: profileId,
        contactId: normalized.id,
        windows: normalized.availability,
      );
      final note = normalized.initialNoteText;
      if (note != null) {
        await database
            .into(database.contactNotes)
            .insert(
              ContactNotesCompanion.insert(
                id: identifiers.nextUuid(),
                contactId: normalized.id,
                noteText: note,
                createdAtUtc: now,
                updatedAtUtc: now,
              ),
            );
      }
      final detail = await readContactDetail(
        profileId: profileId,
        contactId: normalized.id,
      );
      return detail.contact;
    });
  }

  @override
  Future<Contact> updateContact({
    required String profileId,
    required String contactId,
    required ContactDraft draft,
  }) async {
    final normalized = draft.normalized();
    final now = clock.nowUtc();
    return database.transaction(() async {
      final existing =
          await (database.select(database.contacts)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(contactId),
              ))
              .getSingleOrNull();
      if (existing == null) {
        throw const ContactValidationException('Contact not found.');
      }
      final existingMethods = await (database.select(
        database.contactMethods,
      )..where((table) => table.contactId.equals(contactId))).get();
      final existingWasComplete =
          (existing.firstName?.trim().isNotEmpty ?? false) &&
          (existing.lastName?.trim().isNotEmpty ?? false) &&
          existingMethods.any(
            (method) => isValidNewManualContactMethod(
              ContactMethodDraft(
                id: method.id,
                type:
                    ContactMethodType.values.asNameMap()[method.type] ??
                    ContactMethodType.phone,
                value: method.rawValue,
                label: method.label,
                isPrimary: method.isPrimary,
                receivesTexts: method.receivesTexts,
                hasWhatsApp: method.hasWhatsApp,
              ),
            ),
          );
      if (existingWasComplete) {
        final candidateIsComplete =
            normalized.firstName.isNotEmpty &&
            normalized.lastName.isNotEmpty &&
            normalized.methods.any(isValidNewManualContactMethod);
        if (!candidateIsComplete) {
          throw const ContactValidationException(
            'A complete Contact cannot be saved without First Name, Last Name, and a valid contact method.',
          );
        }
      }
      final updated =
          await (database.update(database.contacts)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(contactId),
              ))
              .write(
                ContactsCompanion(
                  firstName: Value<String?>(
                    normalized.firstName.isEmpty ? null : normalized.firstName,
                  ),
                  lastName: Value<String?>(
                    normalized.lastName.isEmpty ? null : normalized.lastName,
                  ),
                  displayName: Value<String>(normalized.displayName),
                  preferredContactMethod: Value<String>(
                    ContactPreferredMethodCodec.encode(
                      normalized.preferredContactMethod,
                    ),
                  ),
                  isFavorite: Value<bool>(normalized.isFavorite),
                  addressText: Value<String?>(normalized.addressText),
                  updatedAtUtc: Value<DateTime>(now),
                ),
              );
      assert(updated == 1);
      await _replaceMethods(
        profileId,
        contactId: contactId,
        methods: normalized.methods,
      );
      await setContactGroups(
        profileId: profileId,
        contactId: contactId,
        groupIds: normalized.groupIds,
        primaryGroupId: normalized.primaryGroupId,
      );
      await _replaceTags(
        profileId,
        contactId: contactId,
        tagNames: normalized.tagNames,
      );
      await setAvailability(
        profileId: profileId,
        contactId: contactId,
        windows: normalized.availability,
      );
      // Section 27/33: a rename or identity edit changes the CURRENT resolved
      // Contact fingerprint that a deliverable follow-up reads at delivery
      // time, so the repair intent commits with the edit.
      await reminderRepair?.mark(database, profileId: profileId);
      final detail = await readContactDetail(
        profileId: profileId,
        contactId: contactId,
      );
      return detail.contact;
    });
  }

  @override
  Future<Contact> updateContactIdentityAndMethods({
    required String profileId,
    required String contactId,
    required String firstName,
    required String lastName,
    required String displayName,
    required ContactPreferredMethod preferredContactMethod,
    required List<ContactMethodDraft> methods,
  }) async {
    final chosenPrimaryTypes = <ContactMethodType>{};
    final scopedMethods = methods
        .map((method) {
          final isPrimary =
              method.isPrimary && chosenPrimaryTypes.add(method.type);
          return ContactMethodDraft(
            id: method.id,
            type: method.type,
            value: method.value,
            label: method.label,
            isPrimary: isPrimary,
            receivesTexts: method.receivesTexts,
            hasWhatsApp: method.hasWhatsApp,
          );
        })
        .toList(growable: false);
    final normalized = ContactDraft(
      id: contactId,
      firstName: firstName,
      lastName: lastName,
      displayName: displayName,
      preferredContactMethod: preferredContactMethod,
      isFavorite: false,
      methods: scopedMethods,
    ).normalized();
    return database.transaction(() async {
      final updated =
          await (database.update(database.contacts)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(contactId),
              ))
              .write(
                ContactsCompanion(
                  firstName: Value<String?>(
                    normalized.firstName.isEmpty ? null : normalized.firstName,
                  ),
                  lastName: Value<String?>(
                    normalized.lastName.isEmpty ? null : normalized.lastName,
                  ),
                  displayName: Value<String>(normalized.displayName),
                  preferredContactMethod: Value<String>(
                    ContactPreferredMethodCodec.encode(
                      normalized.preferredContactMethod,
                    ),
                  ),
                  updatedAtUtc: Value<DateTime>(clock.nowUtc()),
                ),
              );
      if (updated != 1) {
        throw const ContactValidationException('Contact not found.');
      }
      await _replaceMethods(
        profileId,
        contactId: contactId,
        methods: normalized.methods,
      );
      // Rename/identity edit: same section 27/33 repair intent as updateContact.
      await reminderRepair?.mark(database, profileId: profileId);
      return (await readContactDetail(
        profileId: profileId,
        contactId: contactId,
      )).contact;
    });
  }

  @override
  Future<Contact> updateContactAddress({
    required String profileId,
    required String contactId,
    String? addressText,
  }) async {
    final normalized = addressText?.trim();
    final updated =
        await (database.update(database.contacts)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.id.equals(contactId),
            ))
            .write(
              ContactsCompanion(
                addressText: Value<String?>(
                  normalized == null || normalized.isEmpty ? null : normalized,
                ),
                updatedAtUtc: Value<DateTime>(clock.nowUtc()),
              ),
            );
    if (updated != 1) {
      throw const ContactValidationException('Contact not found.');
    }
    return (await readContactDetail(
      profileId: profileId,
      contactId: contactId,
    )).contact;
  }

  @override
  Future<ContactDetail> readContactDetail({
    required String profileId,
    required String contactId,
  }) async {
    final row =
        await (database.select(database.contacts)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(contactId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (row == null) {
      throw const ContactValidationException('Contact not found.');
    }
    final contact = _contactFromRow(row);
    final methods = await (database.select(
      database.contactMethods,
    )..where((table) => table.contactId.equals(contactId))).get();
    final membershipRows =
        await (database.select(database.contactGroupMemberships).join([
              innerJoin(
                database.contactGroups,
                database.contactGroups.id.equalsExp(
                  database.contactGroupMemberships.groupId,
                ),
              ),
            ])..where(
              database.contactGroupMemberships.contactId.equals(contactId),
            ))
            .get();
    final groups = <ContactGroup>[];
    String? primaryGroupId;
    for (final row2 in membershipRows) {
      final group = row2.readTable(database.contactGroups);
      groups.add(_groupFromRow(group));
      if (row2.readTable(database.contactGroupMemberships).isPrimary) {
        primaryGroupId = group.id;
      }
    }
    final tags = await (database.select(database.contactTags).join(
      [
        innerJoin(
          database.contactTagMemberships,
          database.contactTagMemberships.tagId.equalsExp(
            database.contactTags.id,
          ),
        ),
      ],
    )..where(database.contactTagMemberships.contactId.equals(contactId))).get();
    final tagRows =
        tags.map((row) => row.readTable(database.contactTags)).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final notes =
        await (database.select(
          database.contactNotes,
        )..where((table) => table.contactId.equals(contactId))).get().then(
          (rows) =>
              rows.toList()
                ..sort((a, b) => b.createdAtUtc.compareTo(a.createdAtUtc)),
        );
    final availability =
        await (database.select(database.contactAvailabilities)
              ..where((table) => table.contactId.equals(contactId))
              ..orderBy([(table) => OrderingTerm.asc(table.weekday)]))
            .get();
    return ContactDetail(
      contact: contact,
      methods: methods.map(_methodFromRow).toList(growable: false),
      groups: groups,
      primaryGroupId: primaryGroupId,
      tags: tagRows.map(_tagFromRow).toList(growable: false),
      notes: notes.map(_noteFromRow).toList(growable: false),
      availability: availability
          .map(_availabilityFromRow)
          .toList(growable: false),
    );
  }

  @override
  Future<void> markContactViewed({
    required String profileId,
    required String contactId,
  }) async {
    await (database.update(database.contacts)..where(
          (table) =>
              table.profileId.equals(profileId) & table.id.equals(contactId),
        ))
        .write(
          ContactsCompanion(lastViewedAtUtc: Value<DateTime?>(clock.nowUtc())),
        );
  }

  @override
  Future<Contact> setFavorite({
    required String profileId,
    required String contactId,
    required bool favorite,
  }) async {
    await (database.update(database.contacts)..where(
          (table) =>
              table.profileId.equals(profileId) & table.id.equals(contactId),
        ))
        .write(
          ContactsCompanion(
            isFavorite: Value<bool>(favorite),
            updatedAtUtc: Value<DateTime>(clock.nowUtc()),
          ),
        );
    final detail = await readContactDetail(
      profileId: profileId,
      contactId: contactId,
    );
    return detail.contact;
  }

  @override
  Future<void> archiveContact({
    required String profileId,
    required String contactId,
  }) async {
    await database.transaction(() async {
      await (database.update(database.contacts)..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.id.equals(contactId) &
                table.lifecycleState.equals(ContactLifecycleState.active.name),
          ))
          .write(
            ContactsCompanion(
              lifecycleState: Value<String>(
                ContactLifecycleState.archived.name,
              ),
              archivedAtUtc: Value<DateTime?>(clock.nowUtc()),
              deletedAtUtc: const Value<DateTime?>(null),
              updatedAtUtc: Value<DateTime>(clock.nowUtc()),
            ),
          );
      // Section 10/27: archiving removes the Contact from live link truth, so
      // every reminder that named it is no longer deliverable as a follow-up.
      // The purpose rows and the repair intent commit with the lifecycle change.
      await _invalidateContactFollowUpPurposes(
        database,
        profileId: profileId,
        contactIds: <String>[contactId],
      );
      await reminderRepair?.mark(database, profileId: profileId);
    });
  }

  @override
  Future<Contact> restoreContact({
    required String profileId,
    required String contactId,
  }) async {
    final updated = await database.transaction(() async {
      final rows =
          await (database.update(database.contacts)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(contactId) &
                    table.lifecycleState.equals(
                      ContactLifecycleState.archived.name,
                    ),
              ))
              .write(
                ContactsCompanion(
                  lifecycleState: Value<String>(
                    ContactLifecycleState.active.name,
                  ),
                  archivedAtUtc: const Value<DateTime?>(null),
                  deletedAtUtc: const Value<DateTime?>(null),
                  updatedAtUtc: Value<DateTime>(clock.nowUtc()),
                ),
              );
      // A restored Contact is live link truth again, so reminders whose
      // follow-up target it become resolvable once more.
      await reminderRepair?.mark(database, profileId: profileId);
      return rows;
    });
    if (updated == 0) {
      throw const ContactValidationException('Contact not found.');
    }
    final detail = await readContactDetail(
      profileId: profileId,
      contactId: contactId,
    );
    return detail.contact;
  }

  @override
  Future<void> moveContactsToRecentlyDeleted({
    required String profileId,
    required Iterable<String> contactIds,
  }) async {
    final ids = contactIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final now = clock.nowUtc();
    await database.transaction(() async {
      await (database.update(database.contacts)..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.id.isIn(ids) &
                table.lifecycleState.equals(ContactLifecycleState.active.name),
          ))
          .write(
            ContactsCompanion(
              lifecycleState: Value<String>(
                ContactLifecycleState.recentlyDeleted.name,
              ),
              archivedAtUtc: const Value<DateTime?>(null),
              deletedAtUtc: Value<DateTime?>(now),
              updatedAtUtc: Value<DateTime>(now),
            ),
          );
      // Section 10/27: recently-deleted Contacts are likewise no longer live
      // link truth, so their follow-up purposes are invalidated in the same
      // transaction and the repair intent is committed alongside.
      await _invalidateContactFollowUpPurposes(
        database,
        profileId: profileId,
        contactIds: ids,
      );
      await reminderRepair?.mark(database, profileId: profileId);
    });
  }

  @override
  Future<Contact> restoreRecentlyDeletedContact({
    required String profileId,
    required String contactId,
  }) async {
    final updated = await database.transaction(() async {
      final rows =
          await (database.update(database.contacts)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(contactId) &
                    table.lifecycleState.equals(
                      ContactLifecycleState.recentlyDeleted.name,
                    ),
              ))
              .write(
                ContactsCompanion(
                  lifecycleState: Value<String>(
                    ContactLifecycleState.active.name,
                  ),
                  deletedAtUtc: const Value<DateTime?>(null),
                  updatedAtUtc: Value<DateTime>(clock.nowUtc()),
                ),
              );
      await reminderRepair?.mark(database, profileId: profileId);
      return rows;
    });
    if (updated == 0) {
      throw const ContactValidationException('Contact not found.');
    }
    return (await readContactDetail(
      profileId: profileId,
      contactId: contactId,
    )).contact;
  }

  @override
  Future<List<ContactSummary>> readLifecycleContacts({
    required String profileId,
    required ContactLifecycleState lifecycleState,
    required PlannerDate today,
  }) async {
    assert(
      lifecycleState == ContactLifecycleState.archived ||
          lifecycleState == ContactLifecycleState.recentlyDeleted,
      'Lifecycle screen may expose only recoverable archive/deletion states.',
    );
    final rows =
        await (database.select(database.contacts)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.lifecycleState.equals(lifecycleState.name),
            ))
            .get();
    if (rows.isEmpty) return const <ContactSummary>[];
    final summaries = await _summariesForContactRows(
      profileId: profileId,
      rows: rows,
      today: today,
    );
    final sorted = List<ContactSummary>.of(summaries)
      ..sort((a, b) {
        final aDate = lifecycleState == ContactLifecycleState.archived
            ? a.contact.archivedAtUtc
            : a.contact.deletedAtUtc;
        final bDate = lifecycleState == ContactLifecycleState.archived
            ? b.contact.archivedAtUtc
            : b.contact.deletedAtUtc;
        return _compareDatesNullLast(aDate, bDate, newestFirst: true);
      });
    return List<ContactSummary>.unmodifiable(sorted);
  }

  @override
  Future<List<ContactRecipientCandidate>> readRecipientCandidates({
    required String profileId,
  }) async {
    final rows =
        await (database.select(database.contacts)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.lifecycleState.equals(
                      ContactLifecycleState.active.name,
                    ),
              )
              ..orderBy(<OrderingTerm Function(Contacts)>[
                (table) => OrderingTerm.asc(table.displayName),
                (table) => OrderingTerm.asc(table.id),
              ]))
            .get();
    if (rows.isEmpty) return const <ContactRecipientCandidate>[];
    final ids = rows.map((row) => row.id).toList(growable: false);
    final methodRows =
        await (database.select(database.contactMethods)
              ..where((table) => table.contactId.isIn(ids))
              ..orderBy(<OrderingTerm Function(ContactMethods)>[
                (table) => OrderingTerm.asc(table.id),
              ]))
            .get();
    final methodsByContact = <String, List<ContactMethod>>{};
    for (final method in methodRows) {
      methodsByContact
          .putIfAbsent(method.contactId, () => <ContactMethod>[])
          .add(_methodFromRow(method));
    }
    final memberships =
        await (database.select(database.contactGroupMemberships).join([
          innerJoin(
            database.contactGroups,
            database.contactGroups.id.equalsExp(
              database.contactGroupMemberships.groupId,
            ),
          ),
        ])..where(database.contactGroupMemberships.contactId.isIn(ids))).get();
    final groupsByContact = <String, ContactGroup>{};
    for (final joined in memberships) {
      final membership = joined.readTable(database.contactGroupMemberships);
      final group = joined.readTable(database.contactGroups);
      if (membership.isPrimary && !group.isArchived) {
        groupsByContact[membership.contactId] = _groupFromRow(group);
      }
    }
    return List<ContactRecipientCandidate>.unmodifiable(
      <ContactRecipientCandidate>[
        for (final row in rows)
          ContactRecipientCandidate(
            summary: ContactSummary(
              contact: _contactFromRow(row),
              primaryGroup: groupsByContact[row.id],
            ),
            detail: ContactDetail(
              contact: _contactFromRow(row),
              methods: List<ContactMethod>.unmodifiable(
                methodsByContact[row.id] ?? const <ContactMethod>[],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Future<List<ContactSummary>> readContacts({
    required String profileId,
    required ContactFilterCriteria criteria,
    required ContactSortBy sortBy,
    required PlannerDate today,
    ContactStandardView? standardView,
    String? query,
  }) async {
    // An explicit None is an active user constraint, unlike legacy empty lists
    // which mean unrestricted All.  Returning before any base-view projection
    // keeps the result truthfully empty for every standard/saved view.
    if (<ContactFilterSelectionMode>[
      criteria.groupSelectionMode,
      criteria.tagSelectionMode,
      criteria.availabilitySelectionMode,
      criteria.contactMethodsSelectionMode,
      criteria.eventHistorySelectionMode,
      criteria.phoneSelectionMode,
      criteria.emailSelectionMode,
      criteria.addressSelectionMode,
      criteria.socialSelectionMode,
    ].contains(ContactFilterSelectionMode.none)) {
      return const <ContactSummary>[];
    }
    final baseQuery = database.select(database.contacts);
    var where =
        database.contacts.profileId.equals(profileId) &
        database.contacts.lifecycleState.isNotValue(
          ContactLifecycleState.merged.name,
        );
    if (criteria.archivedOnly) {
      // C3 truthful Archived view: archived contacts only.
      where =
          where &
          database.contacts.lifecycleState.equals(
            ContactLifecycleState.archived.name,
          );
    } else if (!criteria.includeArchived) {
      where =
          where &
          database.contacts.lifecycleState.equals(
            ContactLifecycleState.active.name,
          );
    }
    if (criteria.favoritesOnly) {
      where = where & database.contacts.isFavorite.equals(true);
    }
    final normalizedQuery = query?.trim();
    if (normalizedQuery != null && normalizedQuery.isNotEmpty) {
      where =
          where &
          database.contacts.displayName.lower().contains(
            normalizedQuery.toLowerCase(),
          );
    }
    if (criteria.source != null) {
      where =
          where &
          database.contacts.source.equals(
            ContactSourceCodec.encode(criteria.source!),
          );
    }
    if (criteria.hasAddress) {
      where = where & database.contacts.addressText.isNotNull();
    }
    baseQuery.where((table) => where);
    if (sortBy == ContactSortBy.name) {
      baseQuery.orderBy([
        (table) => OrderingTerm.asc(table.displayName),
        (table) => OrderingTerm.asc(table.id),
      ]);
    } else if (sortBy == ContactSortBy.nameDesc) {
      baseQuery.orderBy([
        (table) => OrderingTerm.desc(table.displayName),
        (table) => OrderingTerm.asc(table.id),
      ]);
    } else if (sortBy == ContactSortBy.oldestAdded) {
      baseQuery.orderBy([
        (table) => OrderingTerm.asc(table.createdAtUtc),
        (table) => OrderingTerm.asc(table.displayName),
        (table) => OrderingTerm.asc(table.id),
      ]);
    } else if (_isSummarySort(sortBy)) {
      // Event-derived sorts cannot be expressed without the batched event
      // context, which this repository loads after the base Contact query.
      // Keep a deterministic base order here and re-sort the final summaries
      // below once the canonical nextEventDate/lastEventDate facts are known.
      baseQuery.orderBy([
        (table) => OrderingTerm.asc(table.displayName),
        (table) => OrderingTerm.asc(table.id),
      ]);
    } else {
      baseQuery.orderBy([
        (table) => OrderingTerm.desc(table.createdAtUtc),
        (table) => OrderingTerm.asc(table.displayName),
        (table) => OrderingTerm.asc(table.id),
      ]);
    }
    final rows = await baseQuery.get();
    if (rows.isEmpty) {
      return const <ContactSummary>[];
    }
    final ids = rows.map((row) => row.id).toList(growable: false);
    final summaries = await _buildSummaries(
      profileId: profileId,
      contactRows: rows,
      ids: ids,
      criteria: criteria,
      today: today,
      standardView: standardView,
      includeStatusData:
          standardView?.filter == ContactStandardFilter.status ||
          _isSummarySort(sortBy),
    );
    if (standardView?.filter == ContactStandardFilter.status) {
      return _sortStatusSummaries(summaries);
    }
    if (_isSummarySort(sortBy)) {
      return _sortSummaries(summaries, sortBy);
    }
    return summaries;
  }

  @override
  Future<List<ContactStatusBucket>> readAvailableStatusBuckets({
    required String profileId,
  }) async {
    final rows =
        await (database.select(database.contacts)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.lifecycleState.equals(
                    ContactLifecycleState.active.name,
                  ),
            ))
            .get();
    if (rows.isEmpty) {
      return const <ContactStatusBucket>[];
    }
    final dates = await _historicalInteractionDatesForContacts(
      profileId: profileId,
      contactIds: rows.map((row) => row.id).toList(growable: false),
      today: PlannerDate.fromDateTime(clock.nowUtc().toLocal()),
    );
    final startOfWeek = await _readStartOfWeekDay(profileId);
    final available = <ContactStatusBucket>{};
    for (final row in rows) {
      available.add(
        _statusBucketFor(
          _latestInteractionDate(dates[row.id]),
          nowLocal: clock.nowUtc().toLocal(),
          startOfWeek: startOfWeek,
        ),
      );
    }
    return ContactStatusBucket.values
        .where(available.contains)
        .toList(growable: false);
  }

  DateTime? _latestInteractionDate(List<DateTime>? dates) =>
      dates == null || dates.isEmpty ? null : dates.last;

  bool _matchesStandardView({
    required ContactRow row,
    required ContactStandardView standardView,
    required DateTime? historicalInteractionDate,
    required ContactStatusBucket? canonicalStatusBucket,
  }) {
    final nowUtc = clock.nowUtc();
    final nowLocal = nowUtc.toLocal();
    final recentUtcCutoff = nowUtc.subtract(const Duration(days: 30));
    final todayLocal = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
    final recentDateCutoff = todayLocal.subtract(const Duration(days: 30));
    return switch (standardView.filter) {
      ContactStandardFilter.status =>
        standardView.statusBucket == null ||
            canonicalStatusBucket == standardView.statusBucket,
      ContactStandardFilter.recentlyViewed =>
        row.lastViewedAtUtc != null &&
            !row.lastViewedAtUtc!.isBefore(recentUtcCutoff),
      ContactStandardFilter.recentlyContacted =>
        historicalInteractionDate != null &&
            !historicalInteractionDate.isBefore(recentDateCutoff),
      ContactStandardFilter.noRecentContact =>
        historicalInteractionDate == null ||
            historicalInteractionDate.isBefore(recentDateCutoff),
      ContactStandardFilter.recentlyCreated => !row.createdAtUtc.isBefore(
        recentUtcCutoff,
      ),
    };
  }

  Future<int> _readStartOfWeekDay(String profileId) async {
    final row = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
    return row?.weekStartDay ?? DateTime.monday;
  }

  ContactStatusBucket _statusBucketFor(
    DateTime? interactionDate, {
    required DateTime nowLocal,
    required int startOfWeek,
  }) {
    if (interactionDate == null) {
      return ContactStatusBucket.notInteractedYet;
    }
    final today = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
    final date = DateTime(
      interactionDate.toLocal().year,
      interactionDate.toLocal().month,
      interactionDate.toLocal().day,
    );
    if (date == today) {
      return ContactStatusBucket.interactedToday;
    }
    final weekStart = today.subtract(
      Duration(days: (today.weekday - startOfWeek + 7) % 7),
    );
    if (!date.isBefore(weekStart)) {
      return ContactStatusBucket.interactedThisWeek;
    }
    final monthStart = DateTime(today.year, today.month);
    if (!date.isBefore(monthStart)) {
      return ContactStatusBucket.interactedThisMonth;
    }
    final oneToThreeCutoff = DateTime(today.year, today.month - 3, today.day);
    final threeToSixCutoff = DateTime(today.year, today.month - 6, today.day);
    final sixToTwelveCutoff = DateTime(today.year, today.month - 12, today.day);
    if (!date.isBefore(oneToThreeCutoff)) {
      return ContactStatusBucket.oneToThreeMonthsAgo;
    }
    if (!date.isBefore(threeToSixCutoff)) {
      return ContactStatusBucket.threeToSixMonthsAgo;
    }
    if (!date.isBefore(sixToTwelveCutoff)) {
      return ContactStatusBucket.sixToTwelveMonthsAgo;
    }
    return ContactStatusBucket.onePlusYearAgo;
  }

  ContactSmartStatus? _smartStatusFor(List<DateTime> dates) {
    if (dates.isEmpty) return null;
    final now = clock.nowUtc().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final last = dates.last;
    final daysSinceLast = today.difference(last).inDays;
    DateTime? reconnectReturn;
    for (var i = 1; i < dates.length; i++) {
      if (dates[i].difference(dates[i - 1]).inDays >= 90) {
        reconnectReturn = dates[i];
      }
    }
    if (reconnectReturn != null &&
        today.difference(reconnectReturn).inDays <= 30) {
      return ContactSmartStatus.recentlyReconnected;
    }
    final in30 = dates.where((date) => today.difference(date).inDays <= 30);
    if (in30.length >= 4) return ContactSmartStatus.frequentConnection;
    final in90 = dates
        .where((date) => today.difference(date).inDays <= 90)
        .toList();
    if (in90.length >= 3 &&
        in90.last.difference(in90.first).inDays >= 30 &&
        daysSinceLast <= 30) {
      return ContactSmartStatus.regularConnection;
    }
    final in180 = dates.where((date) => today.difference(date).inDays <= 180);
    if (daysSinceLast >= 31 && daysSinceLast <= 90 && in180.length >= 3) {
      return ContactSmartStatus.reconnectSoon;
    }
    return null;
  }

  /// Computes the latest non-cancelled historical Event occurrence for every
  /// requested Contact in one bounded query set. Active links cover retained
  /// participation; immutable occurrence snapshots preserve history after a
  /// repeating-event People edit removes a Contact.
  Future<Map<String, List<DateTime>>> _historicalInteractionDatesForContacts({
    required String profileId,
    required List<String> contactIds,
    required PlannerDate today,
  }) async {
    final result = <String, Set<DateTime>>{
      for (final id in contactIds) id: <DateTime>{},
    };
    if (contactIds.isEmpty) {
      return const <String, List<DateTime>>{};
    }
    final links =
        await (database.select(database.eventContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.contactId.isIn(contactIds) &
                  table.status.equals('active'),
            ))
            .get();
    final snapshots =
        await (database.select(database.eventOccurrenceParticipants)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.contactId.isIn(contactIds),
            ))
            .get();
    final eventIds = <String>{
      for (final link in links) link.eventId,
      for (final snapshot in snapshots) snapshot.eventId,
    };
    if (eventIds.isEmpty) {
      return <String, List<DateTime>>{
        for (final entry in result.entries) entry.key: const <DateTime>[],
      };
    }
    final events =
        await (database.select(database.calendarEvents)..where(
              (table) =>
                  table.profileId.equals(profileId) & table.id.isIn(eventIds),
            ))
            .get();
    final eventsById = <String, CalendarEventRow>{
      for (final event in events) event.id: event,
    };
    final exceptions =
        await (database.select(database.calendarEventExceptions)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.isIn(eventIds),
            ))
            .get();
    final exceptionsByKey = <String, CalendarEventExceptionRow>{
      for (final exception in exceptions)
        '${exception.eventId}:${exception.occurrenceId}': exception,
    };
    final todayLocal = today.asLocalDate;

    void consider(
      String contactId,
      CalendarEventRow event,
      PlannerDate date,
      String occurrenceId,
    ) {
      if (!date.asLocalDate.isBefore(todayLocal)) {
        return;
      }
      final exception = exceptionsByKey['${event.id}:$occurrenceId'];
      final effectiveStatus = _statusFromRow(exception?.status ?? event.status);
      if (effectiveStatus != CalendarEventStatus.scheduled &&
          effectiveStatus != CalendarEventStatus.completedHappened &&
          effectiveStatus != CalendarEventStatus.partiallyCompleted) {
        return;
      }
      final localDate = date.asLocalDate;
      result[contactId]!.add(localDate);
    }

    for (final link in links) {
      final event = eventsById[link.eventId];
      if (event == null) {
        continue;
      }
      final dates = link.occurrenceId == seriesOccurrenceId
          ? _seriesDates(event, today, nextLimit: 0, pastLimit: 2000)
          : <PlannerDate>[
              if (link.originalDate != null)
                PlannerDate.parse(link.originalDate!),
            ];
      for (final date in dates) {
        consider(
          link.contactId,
          event,
          date,
          CalendarEventOccurrenceIdentity.forDate(
            eventId: event.id,
            originalDate: date,
          ),
        );
      }
    }
    for (final snapshot in snapshots) {
      final event = eventsById[snapshot.eventId];
      if (event == null) {
        continue;
      }
      consider(
        snapshot.contactId,
        event,
        PlannerDate.parse(snapshot.originalDate),
        snapshot.occurrenceId,
      );
    }
    return <String, List<DateTime>>{
      for (final entry in result.entries)
        entry.key: (entry.value.toList()..sort()),
    };
  }

  bool _isSummarySort(ContactSortBy sortBy) => switch (sortBy) {
    ContactSortBy.mostRecentlyInteracted ||
    ContactSortBy.leastRecentlyInteracted ||
    ContactSortBy.status ||
    ContactSortBy.lastViewed ||
    ContactSortBy.nextEvent ||
    ContactSortBy.lastEvent ||
    ContactSortBy.lastHappenedEvent ||
    ContactSortBy.leastRecentEvent ||
    ContactSortBy.leastRecentHappenedEvent => true,
    _ => false,
  };

  /// Deterministic repository-owned ordering for facts loaded in the batched
  /// Contact summary context. Every null fact sorts LAST, followed by name and
  /// stable Contact id, so the presentation layer never reconstructs history.
  List<ContactSummary> _sortSummaries(
    List<ContactSummary> summaries,
    ContactSortBy sortBy,
  ) {
    final sorted = List<ContactSummary>.of(summaries);
    sorted.sort((a, b) {
      if (sortBy == ContactSortBy.status) {
        final byStatus = _statusSortRank(a).compareTo(_statusSortRank(b));
        return byStatus != 0 ? byStatus : _summaryNameThenId(a, b);
      }
      if (sortBy == ContactSortBy.lastViewed) {
        final byViewed = _compareDatesNullLast(
          a.contact.lastViewedAtUtc,
          b.contact.lastViewedAtUtc,
          newestFirst: true,
        );
        return byViewed != 0 ? byViewed : _summaryNameThenId(a, b);
      }
      if (sortBy == ContactSortBy.mostRecentlyInteracted ||
          sortBy == ContactSortBy.leastRecentlyInteracted) {
        final byInteraction = _compareDatesNullLast(
          a.latestQualifyingInteractionDate,
          b.latestQualifyingInteractionDate,
          newestFirst: sortBy == ContactSortBy.mostRecentlyInteracted,
        );
        return byInteraction != 0 ? byInteraction : _summaryNameThenId(a, b);
      }
      final PlannerDate? aDate = switch (sortBy) {
        ContactSortBy.nextEvent => a.context.nextEventDate,
        ContactSortBy.lastEvent => a.context.lastEventDate,
        ContactSortBy.lastHappenedEvent => a.context.lastHappenedEventDate,
        ContactSortBy.leastRecentEvent => a.context.leastRecentEventDate,
        ContactSortBy.leastRecentHappenedEvent =>
          a.context.leastRecentHappenedEventDate,
        _ => null,
      };
      final PlannerDate? bDate = switch (sortBy) {
        ContactSortBy.nextEvent => b.context.nextEventDate,
        ContactSortBy.lastEvent => b.context.lastEventDate,
        ContactSortBy.lastHappenedEvent => b.context.lastHappenedEventDate,
        ContactSortBy.leastRecentEvent => b.context.leastRecentEventDate,
        ContactSortBy.leastRecentHappenedEvent =>
          b.context.leastRecentHappenedEventDate,
        _ => null,
      };
      final int byDate;
      if (aDate == null && bDate == null) {
        byDate = 0;
      } else if (aDate == null) {
        byDate = 1;
      } else if (bDate == null) {
        byDate = -1;
      } else if (sortBy == ContactSortBy.lastEvent ||
          sortBy == ContactSortBy.lastHappenedEvent) {
        byDate = bDate.compareTo(aDate);
      } else {
        byDate = aDate.compareTo(bDate);
      }
      if (byDate != 0) {
        return byDate;
      }
      return _summaryNameThenId(a, b);
    });
    return List<ContactSummary>.unmodifiable(sorted);
  }

  List<ContactSummary> _sortStatusSummaries(List<ContactSummary> summaries) {
    const order = <ContactStatusBucket>[
      ContactStatusBucket.interactedToday,
      ContactStatusBucket.interactedThisWeek,
      ContactStatusBucket.interactedThisMonth,
      ContactStatusBucket.oneToThreeMonthsAgo,
      ContactStatusBucket.threeToSixMonthsAgo,
      ContactStatusBucket.sixToTwelveMonthsAgo,
      ContactStatusBucket.onePlusYearAgo,
      ContactStatusBucket.notInteractedYet,
    ];
    final ranks = <ContactStatusBucket, int>{
      for (var index = 0; index < order.length; index++) order[index]: index,
    };
    final sorted = List<ContactSummary>.of(summaries);
    sorted.sort((a, b) {
      final byBucket = (ranks[a.statusBucket] ?? order.length).compareTo(
        ranks[b.statusBucket] ?? order.length,
      );
      if (byBucket != 0) return byBucket;
      final byDate = _compareDatesNullLast(
        a.latestQualifyingInteractionDate,
        b.latestQualifyingInteractionDate,
        newestFirst: true,
      );
      return byDate != 0 ? byDate : _summaryNameThenId(a, b);
    });
    return List<ContactSummary>.unmodifiable(sorted);
  }

  int _summaryNameThenId(ContactSummary a, ContactSummary b) {
    final byName = a.contact.displayName.compareTo(b.contact.displayName);
    return byName != 0 ? byName : a.contact.id.compareTo(b.contact.id);
  }

  int _compareDatesNullLast(
    DateTime? a,
    DateTime? b, {
    required bool newestFirst,
  }) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return newestFirst ? b.compareTo(a) : a.compareTo(b);
  }

  int _statusSortRank(ContactSummary summary) {
    final smart = summary.smartStatus;
    if (smart != null) return smart.index;
    final bucket = summary.statusBucket;
    return bucket == null ? 99 : 4 + bucket.index;
  }

  /// Batches methods, memberships, tags, and event context for [ids] and
  /// applies the criteria that cannot be expressed cheaply in SQL
  /// (methods, tags, availability, event-based filters).
  Future<List<ContactSummary>> _buildSummaries({
    required String profileId,
    required List<ContactRow> contactRows,
    required List<String> ids,
    required ContactFilterCriteria criteria,
    required PlannerDate today,
    ContactStandardView? standardView,
    bool includeStatusData = false,
  }) async {
    final methods = await (database.select(
      database.contactMethods,
    )..where((table) => table.contactId.isIn(ids))).get();
    final methodsByContact = <String, List<ContactMethodRow>>{};
    for (final method in methods) {
      methodsByContact
          .putIfAbsent(method.contactId, () => <ContactMethodRow>[])
          .add(method);
    }
    final membershipRows =
        await (database.select(database.contactGroupMemberships).join([
          innerJoin(
            database.contactGroups,
            database.contactGroups.id.equalsExp(
              database.contactGroupMemberships.groupId,
            ),
          ),
        ])..where(database.contactGroupMemberships.contactId.isIn(ids))).get();
    final primaryGroupByContact = <String, ContactGroupRow>{};
    final groupNamesByContact = <String, List<String>>{};
    for (final row in membershipRows) {
      final membership = row.readTable(database.contactGroupMemberships);
      final group = row.readTable(database.contactGroups);
      if (group.isArchived) {
        continue;
      }
      if (membership.isPrimary) {
        primaryGroupByContact[membership.contactId] = group;
      } else {
        groupNamesByContact
            .putIfAbsent(membership.contactId, () => <String>[])
            .add(group.name);
      }
    }
    final tagRows = await (database.select(database.contactTags).join([
      innerJoin(
        database.contactTagMemberships,
        database.contactTagMemberships.tagId.equalsExp(database.contactTags.id),
      ),
    ])..where(database.contactTagMemberships.contactId.isIn(ids))).get();
    final tagNamesByContact = <String, List<String>>{};
    final tagIdsByContact = <String, Set<String>>{};
    for (final row in tagRows) {
      final membership = row.readTable(database.contactTagMemberships);
      final tag = row.readTable(database.contactTags);
      tagNamesByContact
          .putIfAbsent(membership.contactId, () => <String>[])
          .add(tag.name);
      tagIdsByContact
          .putIfAbsent(membership.contactId, () => <String>{})
          .add(tag.id);
    }
    final availabilityRows = await (database.select(
      database.contactAvailabilities,
    )..where((table) => table.contactId.isIn(ids))).get();
    final weekdaysByContact = <String, Set<int>>{};
    for (final row in availabilityRows) {
      weekdaysByContact
          .putIfAbsent(row.contactId, () => <int>{})
          .add(row.weekday);
    }

    final eventContext = await _eventContextForContacts(ids, today);
    final statusRead =
        includeStatusData ||
        standardView?.filter == ContactStandardFilter.status;
    final startOfWeek = statusRead
        ? await _readStartOfWeekDay(profileId)
        : DateTime.monday;
    // A single bounded canonical history read powers Status sorting and the
    // optional Last Interaction field. It avoids a UI-side reconstruction and
    // avoids N+1 reads.
    final historicalInteractionDates =
        await _historicalInteractionDatesForContacts(
          profileId: profileId,
          contactIds: ids,
          today: today,
        );
    final filtered = <ContactRow>[];
    final statusBucketsByContact = <String, ContactStatusBucket>{};
    final smartStatusesByContact = <String, ContactSmartStatus?>{};
    final aggregateStatus =
        standardView?.filter == ContactStandardFilter.status &&
        standardView?.statusBucket == null;
    final smartEligible =
        (aggregateStatus || includeStatusData) && contactRows.length >= 4;
    for (final row in contactRows) {
      final contactId = row.id;
      if (criteria.hasPhone &&
          !(methodsByContact[contactId]?.any((m) => m.type == 'phone') ??
              false)) {
        continue;
      }
      if (criteria.hasEmail &&
          !(methodsByContact[contactId]?.any((m) => m.type == 'email') ??
              false)) {
        continue;
      }
      // Address presence is truthful: a stored address must be non-empty.
      if (criteria.hasAddress && !_hasRecordedAddress(row)) {
        continue;
      }
      // Phone / Email / Address / Social Profile category selections.  Empty
      // lists are neutral ("All"); a non-empty list ORs its keys within the
      // category, including the absence keys (No Phone / No Email / etc.).
      if (criteria.phoneLabels.isNotEmpty &&
          !_matchesPhoneFilter(
            criteria.phoneLabels,
            methodsByContact[contactId] ?? const <ContactMethodRow>[],
          )) {
        continue;
      }
      if (criteria.emailLabels.isNotEmpty &&
          !_matchesEmailFilter(
            criteria.emailLabels,
            methodsByContact[contactId] ?? const <ContactMethodRow>[],
          )) {
        continue;
      }
      if (criteria.addressLabels.isNotEmpty &&
          !_matchesAddressFilter(criteria.addressLabels, row)) {
        continue;
      }
      if (criteria.socialLabels.isNotEmpty &&
          !_matchesSocialFilter(
            criteria.socialLabels,
            methodsByContact[contactId] ?? const <ContactMethodRow>[],
          )) {
        continue;
      }
      // C2 one-group V1: group filters match the PRIMARY membership only, so a
      // dormant legacy secondary membership can never surface a Contact in a
      // group view that contradicts its one visible/current group.
      final primaryGroupId = primaryGroupByContact[contactId]?.id;
      if (criteria.groupIds.isNotEmpty &&
          !criteria.groupIds.contains(primaryGroupId)) {
        continue;
      }
      // The virtual "No Group" view (owner law, 2026-09-18) is the same single
      // fact the Contacts dot and the Group manager already agree on: the
      // Contact holds no ACTIVE (primary) Group membership. A dormant legacy
      // secondary row is historical data and never makes a Contact look
      // grouped here — exactly as for the group filter above.
      if (criteria.ungroupedOnly && primaryGroupId != null) {
        continue;
      }
      // Tag membership remains loaded for dormant data compatibility, but Tags
      // no longer restrict active Contacts results after the C5 UX retirement.
      final weekdays = weekdaysByContact[contactId] ?? const <int>{};
      if (criteria.availabilityWeekdays.isNotEmpty &&
          !criteria.availabilityWeekdays.any(weekdays.contains)) {
        continue;
      }
      final context = eventContext[contactId] ?? const ContactListContext();
      final canonicalStatusBucket = statusRead
          ? _statusBucketFor(
              _latestInteractionDate(historicalInteractionDates[contactId]),
              nowLocal: clock.nowUtc().toLocal(),
              startOfWeek: startOfWeek,
            )
          : null;
      if (standardView != null &&
          !_matchesStandardView(
            row: row,
            standardView: standardView,
            historicalInteractionDate: _latestInteractionDate(
              historicalInteractionDates[contactId],
            ),
            canonicalStatusBucket: canonicalStatusBucket,
          )) {
        continue;
      }
      if (canonicalStatusBucket != null) {
        statusBucketsByContact[contactId] = canonicalStatusBucket;
        smartStatusesByContact[contactId] = smartEligible
            ? _smartStatusFor(
                historicalInteractionDates[contactId] ?? const <DateTime>[],
              )
            : null;
      }
      if (criteria.withEventsToday &&
          !(context.nextEventDate == today || context.lastEventDate == today)) {
        continue;
      }
      if (criteria.withFutureEvents && context.nextEventDate == null) {
        continue;
      }
      if (criteria.withoutFutureEvents && context.nextEventDate != null) {
        continue;
      }
      if (criteria.noInteractionYet &&
          context.nextEventDate != null &&
          context.lastEventDate != null) {
        continue;
      }
      if (criteria.eventHistoryAny && context.lastEventDate == null) {
        continue;
      }
      filtered.add(row);
    }
    return filtered
        .map((row) {
          final primary = primaryGroupByContact[row.id];
          return ContactSummary(
            contact: _contactFromRow(row),
            primaryGroup: primary == null ? null : _groupFromRow(primary),
            statusBucket: statusBucketsByContact[row.id],
            smartStatus: smartStatusesByContact[row.id],
            latestQualifyingInteractionDate: _latestInteractionDate(
              historicalInteractionDates[row.id],
            ),
            groupNames: List<String>.unmodifiable(
              groupNamesByContact[row.id] ?? const <String>[],
            ),
            tagNames: List<String>.unmodifiable(
              tagNamesByContact[row.id] ?? const <String>[],
            ),
            context: eventContext[row.id] ?? const ContactListContext(),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<ContactSummary>> searchContacts({
    required String profileId,
    required String query,
    required PlannerDate today,
  }) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return const <ContactSummary>[];
    }
    final rows =
        await (database.select(database.contacts)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.lifecycleState.equals(
                    ContactLifecycleState.active.name,
                  ),
            ))
            .get();
    final ids = rows.map((row) => row.id).toList(growable: false);
    if (ids.isEmpty) {
      return const <ContactSummary>[];
    }
    final methods = await (database.select(
      database.contactMethods,
    )..where((table) => table.contactId.isIn(ids))).get();
    final methodsByContact = <String, List<ContactMethodRow>>{};
    for (final method in methods) {
      methodsByContact
          .putIfAbsent(method.contactId, () => <ContactMethodRow>[])
          .add(method);
    }
    final membershipRows =
        await (database.select(database.contactGroupMemberships).join([
          innerJoin(
            database.contactGroups,
            database.contactGroups.id.equalsExp(
              database.contactGroupMemberships.groupId,
            ),
          ),
        ])..where(database.contactGroupMemberships.contactId.isIn(ids))).get();
    final groupNamesByContact = <String, List<String>>{};
    final primaryGroupByContact = <String, ContactGroupRow>{};
    for (final row in membershipRows) {
      final membership = row.readTable(database.contactGroupMemberships);
      final group = row.readTable(database.contactGroups);
      if (group.isArchived) {
        continue;
      }
      if (membership.isPrimary) {
        primaryGroupByContact[membership.contactId] = group;
        // Active Contacts search intentionally sees only the one visible
        // primary Group. Dormant historical memberships remain persisted but
        // must not make a Contact match hidden Group names.
        groupNamesByContact
            .putIfAbsent(membership.contactId, () => <String>[])
            .add(group.name);
      }
    }
    final matches = <ContactRow>[];
    for (final row in rows) {
      if (row.displayName.toLowerCase().contains(needle) ||
          (row.firstName ?? '').toLowerCase().contains(needle) ||
          (row.lastName ?? '').toLowerCase().contains(needle) ||
          (row.addressText ?? '').toLowerCase().contains(needle)) {
        matches.add(row);
        continue;
      }
      final methodValues =
          (methodsByContact[row.id] ?? const <ContactMethodRow>[])
              .map((m) => '${m.rawValue} ${m.normalizedValue} ${m.label ?? ''}')
              .join(' ')
              .toLowerCase();
      if (methodValues.contains(needle)) {
        matches.add(row);
        continue;
      }
      if ((groupNamesByContact[row.id] ?? const <String>[]).any(
        (name) => name.toLowerCase().contains(needle),
      )) {
        matches.add(row);
        continue;
      }
    }
    if (matches.isEmpty) {
      return const <ContactSummary>[];
    }
    final matchIds = matches.map((row) => row.id).toList(growable: false);
    final eventContext = await _eventContextForContacts(matchIds, today);
    return matches
        .map((row) {
          final primary = primaryGroupByContact[row.id];
          return ContactSummary(
            contact: _contactFromRow(row),
            primaryGroup: primary == null ? null : _groupFromRow(primary),
            groupNames: List<String>.unmodifiable(
              groupNamesByContact[row.id] ?? const <String>[],
            ),
            tagNames: const <String>[],
            context: eventContext[row.id] ?? const ContactListContext(),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<Map<String, ContactSummary>> readContactsByIds({
    required String profileId,
    required List<String> contactIds,
    required PlannerDate today,
  }) async {
    final ids = contactIds.toSet().toList(growable: false);
    if (ids.isEmpty) {
      return const <String, ContactSummary>{};
    }
    final rows = await (database.select(
      database.contacts,
    )..where((table) => table.id.isIn(ids))).get();
    if (rows.isEmpty) {
      return const <String, ContactSummary>{};
    }
    final summaries = await _summariesForContactRows(
      profileId: profileId,
      rows: rows,
      today: today,
    );
    return <String, ContactSummary>{
      for (final summary in summaries) summary.contact.id: summary,
    };
  }

  // -- Groups ---------------------------------------------------------------

  @override
  Future<List<ContactGroup>> readGroups(
    String profileId, {
    bool includeArchived = false,
  }) async {
    final query = database.select(database.contactGroups);
    var where = database.contactGroups.profileId.equals(profileId);
    if (!includeArchived) {
      where = where & database.contactGroups.isArchived.equals(false);
    }
    query
      ..where((table) => where)
      ..orderBy([
        (table) => OrderingTerm.asc(table.sortOrder),
        (table) => OrderingTerm.asc(table.name),
      ]);
    final rows = await query.get();
    // Owner order law: the five canonical built-ins occupy the first five
    // positions; every other row (custom groups and the legacy `Other`) follows
    // in the query's existing `sortOrder, name` order, preserved exactly.
    return ContactBuiltInGroupDefaults.canonicalFirst(
      rows.map(_groupFromRow).toList(growable: false),
      profileId,
    );
  }

  @override
  Future<ContactGroup> createGroup({
    required String profileId,
    required String name,
    required int colorValue,
  }) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw const ContactValidationException('Group name cannot be blank.');
    }
    await _ensureUniqueActiveGroupColor(
      profileId: profileId,
      proposedColor: colorValue,
    );
    final now = clock.nowUtc();
    final id = identifiers.nextUuid();
    await database
        .into(database.contactGroups)
        .insert(
          ContactGroupsCompanion.insert(
            id: id,
            profileId: profileId,
            name: normalized,
            colorValue: colorValue,
            isArchived: const Value<bool>(false),
            sortOrder: const Value<int>(0),
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    final row =
        await (database.select(database.contactGroups)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) & table.id.equals(id),
              )
              ..limit(1))
            .getSingle();
    return _groupFromRow(row);
  }

  @override
  Future<ContactGroup> updateGroup({
    required String profileId,
    required String groupId,
    required String name,
    required int colorValue,
  }) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw const ContactValidationException('Group name cannot be blank.');
    }
    await _ensureUniqueActiveGroupColor(
      profileId: profileId,
      proposedColor: colorValue,
      currentGroupId: groupId,
    );
    final updated =
        await (database.update(database.contactGroups)..where(
              (table) =>
                  table.profileId.equals(profileId) & table.id.equals(groupId),
            ))
            .write(
              ContactGroupsCompanion(
                name: Value<String>(normalized),
                colorValue: Value<int>(colorValue),
                updatedAtUtc: Value<DateTime>(clock.nowUtc()),
              ),
            );
    if (updated == 0) {
      throw const ContactValidationException('Group not found.');
    }
    final row =
        await (database.select(database.contactGroups)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(groupId),
              )
              ..limit(1))
            .getSingle();
    return _groupFromRow(row);
  }

  /// Newly deliberate Group choices cannot duplicate an active peer after
  /// opaque-RGB normalization. Existing legacy duplicates remain readable and
  /// may be saved unchanged; this check never recolors or migrates data.
  Future<void> _ensureUniqueActiveGroupColor({
    required String profileId,
    required int proposedColor,
    String? currentGroupId,
  }) async {
    final active =
        await (database.select(database.contactGroups)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.isArchived.equals(false),
            ))
            .get();
    final current = currentGroupId == null
        ? null
        : active.where((group) => group.id == currentGroupId).firstOrNull;
    // An unchanged legacy/current color is not a new choice, even when
    // another active Group already happens to use the same RGB.
    if (current != null &&
        Vs11ColorSystem.sameOpaqueRgb(current.colorValue, proposedColor)) {
      return;
    }
    final conflict = active.any(
      (group) =>
          group.id != currentGroupId &&
          Vs11ColorSystem.sameOpaqueRgb(group.colorValue, proposedColor),
    );
    if (conflict) {
      throw const ContactValidationException(
        'That color is already used by another active Group.',
      );
    }
  }

  @override
  Future<void> hardDeleteGroup({
    required String profileId,
    required String groupId,
  }) async {
    await database.transaction(() async {
      final group =
          await (database.select(database.contactGroups)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.id.equals(groupId),
                )
                ..limit(1))
              .getSingleOrNull();
      if (group == null) {
        throw const ContactValidationException('Group not found.');
      }

      // Remove every association for this exact group, including dormant
      // legacy memberships. The enclosing transaction ensures a failed group
      // delete rolls these membership removals back rather than leaving a
      // Contact in a partially updated state.
      await (database.delete(
        database.contactGroupMemberships,
      )..where((table) => table.groupId.equals(groupId))).go();
      final deleted =
          await (database.delete(database.contactGroups)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(groupId),
              ))
              .go();
      if (deleted != 1) {
        throw const ContactValidationException('Group could not be deleted.');
      }
    });
  }

  @override
  Future<void> setContactGroups({
    required String profileId,
    required String contactId,
    required List<String> groupIds,
    String? primaryGroupId,
  }) async {
    final normalizedIds = groupIds.toSet().toList(growable: false);
    final primary = normalizedIds.contains(primaryGroupId)
        ? primaryGroupId
        : null;
    await database.transaction(() async {
      // C2 one-group V1: preserve dormant legacy secondary membership rows.
      // Only add the newly selected group(s) and promote exactly one primary;
      // never bulk-delete the existing memberships.
      final existing = await (database.select(
        database.contactGroupMemberships,
      )..where((table) => table.contactId.equals(contactId))).get();
      final existingIds = existing.map((row) => row.groupId).toSet();
      final toAdd = normalizedIds
          .where((id) => !existingIds.contains(id))
          .toList(growable: false);
      await database.batch((batch) {
        for (final groupId in toAdd) {
          batch.insert(
            database.contactGroupMemberships,
            ContactGroupMembershipsCompanion.insert(
              contactId: contactId,
              groupId: groupId,
              isPrimary: Value<bool>(groupId == primary),
            ),
            mode: InsertMode.insertOrIgnore,
          );
        }
      });
      // Demote any current primary that is not the chosen one (or all when
      // clearing). Preserve every dormant row.
      await (database.update(database.contactGroupMemberships)..where(
            (table) =>
                table.contactId.equals(contactId) &
                table.isPrimary.equals(true) &
                (primary == null
                    ? const Constant(true)
                    : table.groupId.isNotValue(primary)),
          ))
          .write(
            const ContactGroupMembershipsCompanion(
              isPrimary: Value<bool>(false),
            ),
          );
      if (primary != null) {
        await (database.update(database.contactGroupMemberships)..where(
              (table) =>
                  table.contactId.equals(contactId) &
                  table.groupId.equals(primary),
            ))
            .write(
              const ContactGroupMembershipsCompanion(
                isPrimary: Value<bool>(true),
              ),
            );
      }
    });
  }

  @override
  Future<void> removeContactFromGroup({
    required String profileId,
    required String contactId,
    required String groupId,
  }) async {
    await database.transaction(() async {
      final group =
          await (database.select(database.contactGroups)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.id.equals(groupId),
                )
                ..limit(1))
              .getSingleOrNull();
      if (group == null) {
        throw const ContactValidationException('Group not found.');
      }
      final contact =
          await (database.select(database.contacts)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.id.equals(contactId),
                )
                ..limit(1))
              .getSingleOrNull();
      if (contact == null) {
        throw const ContactValidationException('Contact not found.');
      }
      await (database.delete(database.contactGroupMemberships)..where(
            (table) =>
                table.contactId.equals(contactId) &
                table.groupId.equals(groupId),
          ))
          .go();
    });
  }

  /// Creates any missing canonical default Group. Additive and non-throwing:
  /// a same-name collision is skipped, never raised, so this is safe on the
  /// post-restore reconciliation path as well.
  @override
  Future<void> ensureBuiltInGroups(String profileId) async {
    await seedCanonicalContactGroups(
      database,
      profileId: profileId,
      clock: clock,
    );
  }

  /// The explicit, user-initiated canonical-defaults action. Creates missing
  /// canonical groups and (only here) re-applies the canonical name, order and
  /// colour to the canonical ids. Never modifies any other row.
  @override
  Future<ContactGroupDefaultsOutcome> applyDefaultGroups(
    String profileId, {
    bool restoreCanonicalValues = false,
  }) {
    return seedCanonicalContactGroups(
      database,
      profileId: profileId,
      clock: clock,
      restoreCanonicalValues: restoreCanonicalValues,
    );
  }

  @override
  Future<void> restoreBuiltInGroupColorDefaults(String profileId) async {
    await ensureBuiltInGroups(profileId);
    final now = clock.nowUtc();
    for (final builtIn in ContactBuiltInGroupDefaults.ordered) {
      final expectedId = ContactBuiltInGroupIdentity.idForProfile(
        profileId,
        builtIn.key,
      );
      await (database.update(database.contactGroups)..where(
            (table) =>
                table.profileId.equals(profileId) & table.id.equals(expectedId),
          ))
          .write(
            ContactGroupsCompanion(
              colorValue: Value<int>(builtIn.colorArgb),
              updatedAtUtc: Value<DateTime>(now),
            ),
          );
    }
  }

  // -- Tags -----------------------------------------------------------------

  @override
  Future<List<ContactTag>> readTags(String profileId) async {
    final rows =
        await (database.select(database.contactTags)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy([(table) => OrderingTerm.asc(table.name)]))
            .get();
    return rows.map(_tagFromRow).toList(growable: false);
  }

  Future<void> _replaceTags(
    String profileId, {
    required String contactId,
    required List<String> tagNames,
  }) async {
    final tagIds = <String>[];
    for (final rawName in tagNames) {
      final name = rawName.trim();
      if (name.isEmpty) {
        continue;
      }
      var row =
          await (database.select(database.contactTags)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.name.equals(name),
                )
                ..limit(1))
              .getSingleOrNull();
      if (row == null) {
        final id = identifiers.nextUuid();
        await database
            .into(database.contactTags)
            .insert(
              ContactTagsCompanion.insert(
                id: id,
                profileId: profileId,
                name: name,
                createdAtUtc: clock.nowUtc(),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        row =
            await (database.select(database.contactTags)
                  ..where(
                    (table) =>
                        table.profileId.equals(profileId) &
                        table.name.equals(name),
                  )
                  ..limit(1))
                .getSingle();
      }
      tagIds.add(row.id);
    }
    await (database.delete(
      database.contactTagMemberships,
    )..where((table) => table.contactId.equals(contactId))).go();
    await database.batch((batch) {
      for (final tagId in tagIds) {
        batch.insert(
          database.contactTagMemberships,
          ContactTagMembershipsCompanion.insert(
            contactId: contactId,
            tagId: tagId,
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }

  // -- Notes ----------------------------------------------------------------

  @override
  Future<ContactNote> addNote({
    required String profileId,
    required String contactId,
    required String text,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      throw const ContactValidationException('Note cannot be blank.');
    }
    final now = clock.nowUtc();
    final id = identifiers.nextUuid();
    await database
        .into(database.contactNotes)
        .insert(
          ContactNotesCompanion.insert(
            id: id,
            contactId: contactId,
            noteText: normalized,
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
    final row =
        await (database.select(database.contactNotes)
              ..where((table) => table.id.equals(id))
              ..limit(1))
            .getSingle();
    return _noteFromRow(row);
  }

  Future<String> _ownedNoteContactId(String noteId, String profileId) async {
    final note =
        await (database.select(database.contactNotes)
              ..where((table) => table.id.equals(noteId))
              ..limit(1))
            .getSingleOrNull();
    if (note == null) {
      return '';
    }
    final contact =
        await (database.select(database.contacts)
              ..where((table) => table.id.equals(note.contactId))
              ..limit(1))
            .getSingleOrNull();
    if (contact == null || contact.profileId != profileId) {
      return '';
    }
    return note.contactId;
  }

  @override
  Future<ContactNote> updateNote({
    required String profileId,
    required String noteId,
    required String text,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      throw const ContactValidationException('Note cannot be blank.');
    }
    if (await _ownedNoteContactId(noteId, profileId) == '') {
      throw const ContactValidationException('Note not found.');
    }
    await (database.update(
      database.contactNotes,
    )..where((table) => table.id.equals(noteId))).write(
      ContactNotesCompanion(
        noteText: Value<String>(normalized),
        updatedAtUtc: Value<DateTime>(clock.nowUtc()),
      ),
    );
    final row =
        await (database.select(database.contactNotes)
              ..where((table) => table.id.equals(noteId))
              ..limit(1))
            .getSingle();
    return _noteFromRow(row);
  }

  @override
  Future<void> deleteNote({
    required String profileId,
    required String noteId,
  }) async {
    if (await _ownedNoteContactId(noteId, profileId) == '') {
      return;
    }
    await (database.delete(
      database.contactNotes,
    )..where((table) => table.id.equals(noteId))).go();
  }

  // -- Availability ---------------------------------------------------------

  @override
  Future<void> setAvailability({
    required String profileId,
    required String contactId,
    required List<ContactAvailability> windows,
  }) async {
    final valid = <ContactAvailability>[];
    for (final window in windows) {
      try {
        valid.add(window.normalized());
      } on ContactValidationException {
        // Ignore invalid windows on save; the form validates first.
      }
    }
    await database.transaction(() async {
      await (database.delete(
        database.contactAvailabilities,
      )..where((table) => table.contactId.equals(contactId))).go();
      if (valid.isEmpty) {
        return;
      }
      await database.batch((batch) {
        for (final window in valid) {
          batch.insert(
            database.contactAvailabilities,
            ContactAvailabilitiesCompanion.insert(
              id: identifiers.nextUuid(),
              contactId: contactId,
              weekday: window.weekday,
              startMinute: window.startMinute,
              endMinute: window.endMinute,
              createdAtUtc: clock.nowUtc(),
            ),
          );
        }
      });
    });
  }

  // -- Saved filters --------------------------------------------------------

  @override
  Future<List<SavedContactFilter>> readSavedFilters(String profileId) async {
    final rows =
        await (database.select(database.savedContactFilters)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy([(table) => OrderingTerm.asc(table.createdAtUtc)]))
            .get();
    return rows.map(_filterFromRow).toList(growable: false);
  }

  @override
  Future<SavedContactFilter> saveSavedFilter({
    required String profileId,
    required SavedContactFilterDraft draft,
  }) async {
    final name = draft.name.trim();
    if (name.isEmpty) {
      throw const ContactValidationException('Filter name cannot be blank.');
    }
    final now = clock.nowUtc();
    final id = identifiers.nextUuid();
    await database
        .into(database.savedContactFilters)
        .insert(
          SavedContactFiltersCompanion.insert(
            id: id,
            profileId: profileId,
            name: name,
            isSystem: Value<bool>(draft.isSystem),
            criteriaJson: SavedContactFilterDocument(
              criteria: draft.criteria,
              description: draft.description,
              displayedFields: draft.displayedFields,
            ).encode(),
            sortBy: Value<String>(draft.sortBy.name),
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
    final row =
        await (database.select(database.savedContactFilters)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) & table.id.equals(id),
              )
              ..limit(1))
            .getSingle();
    return _filterFromRow(row);
  }

  @override
  Future<SavedContactFilter> updateSavedFilter({
    required String profileId,
    required String filterId,
    required SavedContactFilterDraft draft,
  }) async {
    final name = draft.name.trim();
    if (name.isEmpty) {
      throw const ContactValidationException('Filter name cannot be blank.');
    }
    final existing =
        await (database.select(database.savedContactFilters)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(filterId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing == null) {
      throw const ContactValidationException('Saved filter was not found.');
    }
    if (existing.isSystem) {
      throw const ContactValidationException(
        'System filters cannot be edited.',
      );
    }
    final now = clock.nowUtc();
    await (database.update(database.savedContactFilters)..where(
          (table) =>
              table.profileId.equals(profileId) & table.id.equals(filterId),
        ))
        .write(
          SavedContactFiltersCompanion(
            name: Value<String>(name),
            criteriaJson: Value<String>(
              SavedContactFilterDocument(
                criteria: draft.criteria,
                description: draft.description,
                displayedFields: draft.displayedFields,
              ).encode(),
            ),
            sortBy: Value<String>(draft.sortBy.name),
            updatedAtUtc: Value<DateTime>(now),
          ),
        );
    final row =
        await (database.select(database.savedContactFilters)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(filterId),
              )
              ..limit(1))
            .getSingle();
    return _filterFromRow(row);
  }

  @override
  Future<void> deleteSavedFilter({
    required String profileId,
    required String filterId,
  }) async {
    final row =
        await (database.select(database.savedContactFilters)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(filterId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (row == null) {
      return;
    }
    if (row.isSystem) {
      throw const ContactValidationException(
        'System filters cannot be deleted.',
      );
    }
    await (database.delete(database.savedContactFilters)..where(
          (table) =>
              table.profileId.equals(profileId) & table.id.equals(filterId),
        ))
        .go();
  }

  // -- Planner links --------------------------------------------------------

  @override
  Future<void> setEventPeople({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    PlannerDate? originalDate,
    required List<String> contactIds,
    List<String> explicitlyRemovedSeriesContactIds = const <String>[],
  }) async {
    final normalizedIds = contactIds.toSet().toList(growable: false);
    final normalizedSet = normalizedIds.toSet();
    final explicitSeriesRemovals = occurrenceId == seriesOccurrenceId
        ? explicitlyRemovedSeriesContactIds.toSet()
        : const <String>{};
    await database.transaction(() async {
      final existingTargetRows =
          await (database.select(database.eventContactLinks)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.eventId.equals(eventId) &
                    table.occurrenceId.equals(occurrenceId),
              ))
              .get();
      final existingRemovedIds = existingTargetRows
          .where((row) => row.status == _removedEventContactStatus)
          .map((row) => row.contactId)
          .toSet();
      final existingEffective = await _readEffectiveEventContactLinks(
        profileId: profileId,
        eventId: eventId,
        occurrenceId: occurrenceId,
      );
      final existingIds = existingEffective.map((row) => row.contactId).toSet();
      final removedIds = existingIds.difference(normalizedSet);
      // Freeze every past occurrence that a removed series-level participant
      // was on BEFORE removing the link, so history can never be erased.
      if (removedIds.isNotEmpty) {
        await _freezeRemovedParticipants(
          profileId: profileId,
          eventId: eventId,
          removedIds: removedIds.toList(growable: false),
          occurrenceId: occurrenceId,
          originalDate: originalDate,
        );
      }
      if (explicitSeriesRemovals.isNotEmpty) {
        final exactRows =
            await (database.select(database.eventContactLinks)..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.eventId.equals(eventId) &
                      table.occurrenceId.equals(seriesOccurrenceId).not() &
                      table.contactId.isIn(explicitSeriesRemovals.toList()),
                ))
                .get();
        for (final row in exactRows) {
          if (row.status != _activeEventContactStatus ||
              row.originalDate == null) {
            continue;
          }
          await _freezeRemovedParticipants(
            profileId: profileId,
            eventId: eventId,
            removedIds: <String>[row.contactId],
            occurrenceId: row.occurrenceId,
            originalDate: PlannerDate.parse(row.originalDate!),
          );
        }
        await (database.delete(database.eventContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.equals(eventId) &
                  table.occurrenceId.equals(seriesOccurrenceId).not() &
                  table.contactId.isIn(explicitSeriesRemovals.toList()),
            ))
            .go();
      }
      await (database.delete(database.eventContactLinks)..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.eventId.equals(eventId) &
                table.occurrenceId.equals(occurrenceId),
          ))
          .go();
      final now = clock.nowUtc();
      final inheritedIds = occurrenceId == seriesOccurrenceId
          ? const <String>{}
          : (await (database.select(database.eventContactLinks)..where(
                      (table) =>
                          table.profileId.equals(profileId) &
                          table.eventId.equals(eventId) &
                          table.occurrenceId.equals(seriesOccurrenceId) &
                          table.status.equals(_activeEventContactStatus),
                    ))
                    .get())
                .map((row) => row.contactId)
                .toSet();
      final deltas = <(String, String)>[];
      if (occurrenceId == seriesOccurrenceId) {
        deltas.addAll(
          normalizedIds.map(
            (contactId) => (contactId, _activeEventContactStatus),
          ),
        );
        final removedSeriesIds = <String>{
          ...existingRemovedIds,
          ...explicitSeriesRemovals,
        }..removeAll(normalizedSet);
        deltas.addAll(
          removedSeriesIds.map(
            (contactId) => (contactId, _removedEventContactStatus),
          ),
        );
      } else {
        deltas.addAll(
          normalizedSet
              .difference(inheritedIds)
              .map((contactId) => (contactId, _activeEventContactStatus)),
        );
        final removedOccurrenceIds = <String>{
          ...existingRemovedIds,
          ...removedIds,
          ...inheritedIds.difference(normalizedSet),
        }..removeAll(normalizedSet);
        deltas.addAll(
          removedOccurrenceIds.map(
            (contactId) => (contactId, _removedEventContactStatus),
          ),
        );
      }
      await database.batch((batch) {
        for (final delta in deltas) {
          batch.insert(
            database.eventContactLinks,
            EventContactLinksCompanion.insert(
              id: identifiers.nextUuid(),
              profileId: profileId,
              eventId: eventId,
              occurrenceId: Value<String>(occurrenceId),
              originalDate: Value<String?>(
                occurrenceId == seriesOccurrenceId
                    ? null
                    : originalDate?.iso8601,
              ),
              contactId: delta.$1,
              status: Value<String>(delta.$2),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
        }
      });
    });
  }

  /// Section 10 purpose invalidation, shared by every Contact mutation that can
  /// remove a Contact from live link truth (archive, recently-deleted, merge).
  ///
  /// Delivery resolves a follow-up's Contact from CURRENT canonical truth every
  /// time (an archived/deleted Contact simply does not resolve).  Invalidating
  /// the durable purpose here keeps the stored policy row consistent with that
  /// law instead of leaving an unresolvable `contactFollowUp` behind, and it
  /// deliberately does NOT retarget the purpose at a merged survivor: a
  /// follow-up names a specific human, so a merge retires the intent rather
  /// than silently pointing it at somebody else (section 13).  Timing is never
  /// touched — only the purpose/contact columns.
  ///
  /// Runs on [executor] so the invalidation commits inside the caller's own
  /// transaction.  Pure data work: no platform call, no gateway, no history.
  Future<void> _invalidateContactFollowUpPurposes(
    DatabaseConnectionUser executor, {
    required String profileId,
    required Iterable<String> contactIds,
  }) async {
    final ids = contactIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    await (executor.update(database.reminderPolicies)..where(
          (table) =>
              table.profileId.equals(profileId) &
              table.purpose.equals(ReminderPurpose.contactFollowUp.name) &
              table.contactId.isIn(ids),
        ))
        .write(
          ReminderPoliciesCompanion(
            purpose: Value<String>(ReminderPurpose.standard.name),
            contactId: const Value<String?>(null),
            updatedAtUtc: Value<DateTime>(clock.nowUtc()),
          ),
        );
  }

  Future<List<EventContactLinkRow>> _readEffectiveEventContactLinks({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  }) async {
    final seriesLinks =
        await (database.select(database.eventContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.equals(eventId) &
                  table.occurrenceId.equals(seriesOccurrenceId) &
                  table.status.equals(_activeEventContactStatus),
            ))
            .get();
    if (occurrenceId == seriesOccurrenceId) {
      return seriesLinks;
    }
    final exactLinks =
        await (database.select(database.eventContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.equals(eventId) &
                  table.occurrenceId.equals(occurrenceId),
            ))
            .get();
    final effective = <String, EventContactLinkRow>{
      for (final link in seriesLinks) link.contactId: link,
    };
    for (final link in exactLinks) {
      if (link.status == _activeEventContactStatus) {
        effective[link.contactId] = link;
      } else if (link.status == _removedEventContactStatus) {
        effective.remove(link.contactId);
      }
    }
    return effective.values.toList(growable: false);
  }

  @override
  Future<void> copyPeopleOnDuplicate({
    required String profileId,
    required String sourceEventId,
    required String sourceOccurrenceId,
    required String duplicateEventId,
  }) async {
    final effective = await _readEffectiveEventContactLinks(
      profileId: profileId,
      eventId: sourceEventId,
      occurrenceId: sourceOccurrenceId,
    );
    if (effective.isEmpty) return;
    final now = clock.nowUtc();
    await database.batch((batch) {
      for (final link in effective) {
        batch.insert(
          database.eventContactLinks,
          EventContactLinksCompanion.insert(
            id: identifiers.nextUuid(),
            profileId: profileId,
            eventId: duplicateEventId,
            occurrenceId: const Value<String>(seriesOccurrenceId),
            originalDate: const Value<String?>(null),
            contactId: link.contactId,
            status: const Value<String>(_activeEventContactStatus),
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }

  Future<void> _freezeRemovedParticipants({
    required String profileId,
    required String eventId,
    required List<String> removedIds,
    required String occurrenceId,
    required PlannerDate? originalDate,
  }) async {
    final event =
        await (database.select(database.calendarEvents)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(eventId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (event == null) {
      return;
    }
    final today = PlannerDate.fromDateTime(clock.nowUtc().toLocal());
    final dates = occurrenceId == seriesOccurrenceId
        ? _seriesDates(event, today, nextLimit: 0, pastLimit: 500)
        : <PlannerDate>[?originalDate];
    final contacts = await (database.select(
      database.contacts,
    )..where((table) => table.id.isIn(removedIds))).get();
    final contactsById = {for (final row in contacts) row.id: row};
    final memberships =
        await (database.select(database.contactGroupMemberships).join([
              innerJoin(
                database.contactGroups,
                database.contactGroups.id.equalsExp(
                  database.contactGroupMemberships.groupId,
                ),
              ),
            ])..where(
              database.contactGroupMemberships.contactId.isIn(removedIds) &
                  database.contactGroupMemberships.isPrimary.equals(true),
            ))
            .get();
    final colorByContact = <String, int?>{
      for (final row in memberships)
        row.readTable(database.contactGroupMemberships).contactId: row
            .readTable(database.contactGroups)
            .colorValue,
    };
    final now = clock.nowUtc();
    await database.batch((batch) {
      for (final date in dates) {
        if (date.compareTo(today) >= 0) {
          continue;
        }
        final occurrenceIdForDate = CalendarEventOccurrenceIdentity.forDate(
          eventId: eventId,
          originalDate: date,
        );
        for (final contactId in removedIds) {
          final contact = contactsById[contactId];
          batch.insert(
            database.eventOccurrenceParticipants,
            EventOccurrenceParticipantsCompanion.insert(
              id: identifiers.nextUuid(),
              profileId: profileId,
              eventId: eventId,
              occurrenceId: occurrenceIdForDate,
              originalDate: date.iso8601,
              contactId: contactId,
              displayNameSnapshot: contact?.displayName ?? 'Contact',
              groupColorValueSnapshot: Value<int?>(colorByContact[contactId]),
              createdAtUtc: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
        }
      }
    });
  }

  /// Narrow live-link read shared with P19 (contract section 15/53).
  ///
  /// Returns the SAME effective link truth the People section renders — series
  /// `active` rows overlaid by the exact occurrence's active/removed rows — and
  /// deliberately NOT the historical fallback `readEventPeople` keeps for past
  /// occurrences.  Delivery must never invent participation that the current
  /// link truth does not hold, so this read exposes exactly one answer and does
  /// not write anything.
  @override
  Future<Set<String>> readEffectiveEventContactIds({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  }) async {
    final links = await _readEffectiveEventContactLinks(
      profileId: profileId,
      eventId: eventId,
      occurrenceId: occurrenceId,
    );
    return <String>{for (final link in links) link.contactId};
  }

  @override
  Future<List<ContactSummary>> readEventPeople({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required PlannerDate today,
  }) async {
    final links = await _readEffectiveEventContactLinks(
      profileId: profileId,
      eventId: eventId,
      occurrenceId: occurrenceId,
    );
    if (links.isEmpty) {
      // Historical participation is owned by occurrence-level snapshots:
      // a series edit that removed people must not empty a past occurrence.
      if (occurrenceId == seriesOccurrenceId) {
        return const <ContactSummary>[];
      }
      final snapshotRows =
          await (database.select(database.eventOccurrenceParticipants)..where(
                (table) =>
                    table.eventId.equals(eventId) &
                    table.occurrenceId.equals(occurrenceId),
              ))
              .get();
      if (snapshotRows.isEmpty) {
        return const <ContactSummary>[];
      }
      final removedRows =
          await (database.select(database.eventContactLinks)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.eventId.equals(eventId) &
                    (table.occurrenceId.equals(occurrenceId) |
                        table.occurrenceId.equals(seriesOccurrenceId)) &
                    table.status.equals(_removedEventContactStatus),
              ))
              .get();
      final exactRemovedContactIds = removedRows
          .where((row) => row.occurrenceId == occurrenceId)
          .map((row) => row.contactId)
          .toSet();
      final seriesRemovedContactIds = removedRows
          .where((row) => row.occurrenceId == seriesOccurrenceId)
          .map((row) => row.contactId)
          .toSet();
      final snapshotIds = snapshotRows
          .where((row) {
            if (exactRemovedContactIds.contains(row.contactId)) {
              return false;
            }
            final historical =
                PlannerDate.parse(row.originalDate).compareTo(today) < 0;
            return historical ||
                !seriesRemovedContactIds.contains(row.contactId);
          })
          .map((row) => row.contactId)
          .toSet()
          .toList();
      if (snapshotIds.isEmpty) {
        return const <ContactSummary>[];
      }
      final snapshotContactRows = await (database.select(
        database.contacts,
      )..where((table) => table.id.isIn(snapshotIds))).get();
      if (snapshotContactRows.isEmpty) {
        return const <ContactSummary>[];
      }
      return _summariesForContactRows(
        profileId: profileId,
        rows: snapshotContactRows,
        today: today,
      );
    }
    final ids = links.map((link) => link.contactId).toList(growable: false);
    final rows = await (database.select(
      database.contacts,
    )..where((table) => table.id.isIn(ids))).get();
    if (rows.isEmpty) {
      return const <ContactSummary>[];
    }
    return _summariesForContactRows(
      profileId: profileId,
      rows: rows,
      today: today,
    );
  }

  @override
  Future<List<EventParticipantPresentation>> readEventParticipantPresentation({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required bool historical,
  }) async {
    if (historical) {
      final exactRows =
          await (database.select(database.eventContactLinks)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.eventId.equals(eventId) &
                    table.occurrenceId.equals(occurrenceId),
              ))
              .get();
      final exactActiveContactIds = exactRows
          .where((row) => row.status == _activeEventContactStatus)
          .map((row) => row.contactId)
          .toSet();
      final exactRemovedContactIds = exactRows
          .where((row) => row.status == _removedEventContactStatus)
          .map((row) => row.contactId)
          .where((contactId) => !exactActiveContactIds.contains(contactId))
          .toSet();
      final snapshots =
          await (database.select(database.eventOccurrenceParticipants)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.eventId.equals(eventId) &
                      table.occurrenceId.equals(occurrenceId),
                )
                ..orderBy(<OrderingTerm Function(EventOccurrenceParticipants)>[
                  (table) => OrderingTerm.asc(table.displayNameSnapshot),
                  (table) => OrderingTerm.asc(table.contactId),
                ]))
              .get();
      if (snapshots.isNotEmpty) {
        final visibleSnapshots = <String, EventOccurrenceParticipantRow>{};
        for (final snapshot in snapshots) {
          if (exactRemovedContactIds.contains(snapshot.contactId)) {
            continue;
          }
          visibleSnapshots.putIfAbsent(snapshot.contactId, () => snapshot);
        }
        return List<EventParticipantPresentation>.unmodifiable(
          <EventParticipantPresentation>[
            for (final snapshot in visibleSnapshots.values)
              EventParticipantPresentation(
                contactId: snapshot.contactId,
                displayName: snapshot.displayNameSnapshot,
                isSnapshot: true,
              ),
          ],
        );
      }
      // A historical occurrence with no frozen participants still has no
      // immutable relationship to protect. Fall through to the canonical
      // Event-contact links so Add People projects truthfully after save.
    }
    final links = await _readEffectiveEventContactLinks(
      profileId: profileId,
      eventId: eventId,
      occurrenceId: occurrenceId,
    );
    if (links.isEmpty) return const <EventParticipantPresentation>[];
    final rows =
        await (database.select(database.contacts)..where(
              (table) =>
                  table.id.isIn(links.map((link) => link.contactId).toList()),
            ))
            .get();
    final names = <String, String>{
      for (final row in rows) row.id: row.displayName,
    };
    return List<EventParticipantPresentation>.unmodifiable(
      <EventParticipantPresentation>[
        for (final link in links)
          if (names[link.contactId] case final displayName?)
            EventParticipantPresentation(
              contactId: link.contactId,
              displayName: displayName,
              isSnapshot: false,
            ),
      ],
    );
  }

  @override
  Future<void> setTaskContacts({
    required String profileId,
    required String taskId,
    required List<String> contactIds,
  }) async {
    final normalizedIds = contactIds.toSet().toList(growable: false);
    await database.transaction(() async {
      await (database.delete(
        database.taskContactLinks,
      )..where((table) => table.taskId.equals(taskId))).go();
      final now = clock.nowUtc();
      await database.batch((batch) {
        for (final contactId in normalizedIds) {
          batch.insert(
            database.taskContactLinks,
            TaskContactLinksCompanion.insert(
              id: identifiers.nextUuid(),
              profileId: profileId,
              taskId: taskId,
              contactId: contactId,
              createdAtUtc: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
        }
      });
    });
  }

  @override
  Future<List<PlannerTask>> readContactUpcomingTasks({
    required String profileId,
    required String contactId,
  }) async {
    final links = await (database.select(
      database.taskContactLinks,
    )..where((table) => table.contactId.equals(contactId))).get();
    if (links.isEmpty) {
      return const <PlannerTask>[];
    }
    final taskIds = links.map((link) => link.taskId).toSet();
    final rows =
        await (database.select(database.plannerTasks)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.isIn(taskIds) &
                    table.status.equals(PlannerTaskStatus.incomplete.name),
              )
              ..orderBy([(table) => OrderingTerm.asc(table.dueDate)]))
            .get();
    return rows
        .map(
          (row) => PlannerTask(
            id: row.id,
            profileId: row.profileId,
            title: row.title,
            notes: row.notes,
            dueDate: row.dueDate == null
                ? null
                : PlannerDate.parse(row.dueDate!),
            dueMinute: row.dueMinute,
            recurrence:
                PlannerTaskRecurrence.values
                    .asNameMap()[row.recurrenceFrequency] ??
                PlannerTaskRecurrence.none,
            status:
                PlannerTaskStatus.values.asNameMap()[row.status] ??
                PlannerTaskStatus.incomplete,
            requiresReport: row.requiresReport,
            people: const <String>[],
            createdAtUtc: row.createdAtUtc,
            updatedAtUtc: row.updatedAtUtc,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<ContactSummary>> readTaskContacts({
    required String profileId,
    required String taskId,
  }) async {
    final links = await (database.select(
      database.taskContactLinks,
    )..where((table) => table.taskId.equals(taskId))).get();
    if (links.isEmpty) {
      return const <ContactSummary>[];
    }
    final ids = links.map((link) => link.contactId).toList(growable: false);
    final rows = await (database.select(
      database.contacts,
    )..where((table) => table.id.isIn(ids))).get();
    return _summariesForContactRows(
      profileId: profileId,
      rows: rows,
      today: PlannerDate.fromDateTime(clock.nowUtc().toLocal()),
    );
  }

  // -- Timeline -------------------------------------------------------------

  @override
  Future<ContactTimeline> readTimeline({
    required String profileId,
    required String contactId,
    required PlannerDate today,
  }) async {
    final nowUtc = clock.nowUtc();
    final detail = await readContactDetail(
      profileId: profileId,
      contactId: contactId,
    );
    final loadedLinks =
        await (database.select(database.eventContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.contactId.equals(contactId),
            ))
            .get();
    final links = loadedLinks
        .where((link) => link.status == _activeEventContactStatus)
        .toList(growable: false);
    final activeOccurrenceKeys = <String>{
      for (final link in loadedLinks)
        if (link.status == _activeEventContactStatus &&
            link.occurrenceId != seriesOccurrenceId)
          '${link.eventId}:${link.occurrenceId}',
    };
    final removedOccurrenceKeys = <String>{
      for (final link in loadedLinks)
        if (link.status == _removedEventContactStatus &&
            link.occurrenceId != seriesOccurrenceId &&
            !activeOccurrenceKeys.contains(
              '${link.eventId}:${link.occurrenceId}',
            ))
          '${link.eventId}:${link.occurrenceId}',
    };
    final removedSeriesEventIds = <String>{
      for (final link in loadedLinks)
        if (link.status == _removedEventContactStatus &&
            link.occurrenceId == seriesOccurrenceId)
          link.eventId,
    };
    // Immutable occurrence-level participant snapshots are the canonical
    // historical record: a series People edit that removed this Contact must
    // never erase their past participation.
    final loadedSnapshots = await (database.select(
      database.eventOccurrenceParticipants,
    )..where((table) => table.contactId.equals(contactId))).get();
    // Some upgraded owner databases predate the unique participant index and
    // can therefore contain equivalent immutable snapshots.  The Timeline is
    // a read model: canonicalize that inherited shape in memory without
    // mutating the factual stored rows.
    final snapshotsByParticipant =
        <(String, String, String), EventOccurrenceParticipantRow>{};
    for (final snapshot in loadedSnapshots) {
      snapshotsByParticipant.putIfAbsent((
        snapshot.eventId,
        snapshot.occurrenceId,
        snapshot.contactId,
      ), () => snapshot);
    }
    final snapshots = snapshotsByParticipant.values.toList(growable: false);
    final eventIds = <String>{
      for (final link in links) link.eventId,
      for (final snapshot in snapshots) snapshot.eventId,
    };
    final events = eventIds.isEmpty
        ? const <CalendarEventRow>[]
        : await (database.select(database.calendarEvents)..where(
                (table) =>
                    table.profileId.equals(profileId) & table.id.isIn(eventIds),
              ))
              .get();
    final eventsById = {for (final event in events) event.id: event};
    final exceptions = eventIds.isEmpty
        ? const <CalendarEventExceptionRow>[]
        : await (database.select(database.calendarEventExceptions)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.eventId.isIn(eventIds),
              ))
              .get();
    final exceptionsByKey = <String, CalendarEventExceptionRow>{
      for (final row in exceptions) '${row.eventId}:${row.occurrenceId}': row,
    };
    // Planner's submitted, effective outcome report is the canonical source
    // for an occurrence outcome.  Contact Timeline consumes that same source
    // rather than inferring an outcome because time elapsed.
    final reports = eventIds.isEmpty
        ? const <OutcomeReportRow>[]
        : await (database.select(database.outcomeReports)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.eventId.isIn(eventIds) &
                    table.status.equals('submitted') &
                    table.effectiveSlotKey.isNotNull() &
                    table.occurrenceId.isNotNull() &
                    table.outcome.isNotNull(),
              ))
              .get();
    final reportStatusByOccurrenceId = <String, CalendarEventStatus>{
      for (final report in reports)
        report.occurrenceId!: _statusFromRow(report.outcome!),
    };

    final upcoming = <ContactTimelineEntry>[];
    final futureTasks = <ContactTimelineEntry>[];
    final history = <ContactTimelineEntry>[];
    final cancelledEvents = <ContactTimelineEntry>[];
    final freezeTargets = <(String, PlannerDate)>{};
    final projectedEventKeys = <String>{};

    for (final link in links) {
      final event = eventsById[link.eventId];
      if (event == null) {
        continue;
      }
      final dates = link.occurrenceId == seriesOccurrenceId
          ? _seriesDates(event, today, nextLimit: 30, pastLimit: 500)
          : <PlannerDate>[
              if (link.originalDate != null)
                PlannerDate.parse(link.originalDate!),
            ];
      for (final date in dates) {
        final occurrenceIdForDate = CalendarEventOccurrenceIdentity.forDate(
          eventId: event.id,
          originalDate: date,
        );
        final projectionKey = '${event.id}:$occurrenceIdForDate';
        if (removedOccurrenceKeys.contains(projectionKey)) {
          continue;
        }
        if (!projectedEventKeys.add(projectionKey)) {
          continue;
        }
        final exception = exceptionsByKey['${event.id}:$occurrenceIdForDate'];
        final effectiveDate = exception == null
            ? date
            : PlannerDate.parse(exception.effectiveDate);
        final startMinute = exception?.startMinute ?? event.startMinute ?? 0;
        final masterStatus = _statusFromRow(event.status);
        final occurrenceStoredStatus = exception == null
            ? masterStatus
            : _statusFromRow(exception.status);
        final structurallyCancelled =
            masterStatus == CalendarEventStatus.cancelled ||
            occurrenceStoredStatus == CalendarEventStatus.cancelled;
        final submittedStatus = reportStatusByOccurrenceId[occurrenceIdForDate];
        final status =
            submittedStatus ??
            (structurallyCancelled
                ? CalendarEventStatus.cancelled
                : occurrenceStoredStatus);
        final isUpcoming = _isUpcomingOccurrence(
          date: effectiveDate,
          timing: exception?.timing ?? event.timing,
          endMinute: exception?.endMinute ?? event.endMinute,
          timeZoneId: exception?.timeZoneId ?? event.timeZoneId,
          today: today,
          nowUtc: nowUtc,
        );
        final entry = ContactTimelineEntry(
          kind: ContactTimelineKind.eventOccurrence,
          date: effectiveDate,
          chronology: _timelineChronology(effectiveDate, startMinute),
          title: _eventDisplayTitle(event, exception),
          subtitle: isUpcoming ? _occurrenceTimeLabel(event, exception) : null,
          status: status,
          statusLabel: _timelineStatusLabel(
            status,
            isPast: !isUpcoming,
            requiresReport: exception?.requiresReport ?? event.requiresReport,
          ),
          eventId: event.id,
          originalDate: date,
          occurrenceId: occurrenceIdForDate,
          activityTypeId: exception?.activityTypeId ?? event.activityTypeId,
          activityTypeStableKey:
              exception?.activityTypeStableKeySnapshot ??
              event.activityTypeStableKeySnapshot,
          activityTypeColorValue:
              exception?.activityTypeColorValueSnapshot ??
              event.activityTypeColorValueSnapshot,
          effectiveStartMinute:
              (exception?.timing ?? event.timing) ==
                  CalendarEventTiming.allDay.name
              ? null
              : startMinute,
          isUpcoming: isUpcoming,
          isStructurallyCancelled: structurallyCancelled,
          hasSubmittedOutcome: submittedStatus != null,
        );
        if (!isUpcoming && submittedStatus != null) {
          history.add(entry);
          freezeTargets.add((event.id, date));
        } else if (structurallyCancelled) {
          cancelledEvents.add(entry);
          if (!isUpcoming) {
            freezeTargets.add((event.id, date));
          }
        } else if (isUpcoming) {
          upcoming.add(entry);
        } else {
          history.add(entry);
          freezeTargets.add((event.id, date));
        }
      }
    }

    // Freeze historical participation so later series edits cannot erase it.
    // POLISH-07: the freeze writes run inside ONE transaction so drift emits
    // a single coalesced table update instead of one per occurrence.  This
    // read is watched by a provider that re-runs on eventOccurrenceParticipants
    // updates; per-write emissions made every mid-read write re-trigger the
    // read (a ~5Hz loading<->data flicker cascade until every snapshot
    // existed).  A transaction collapses that to exactly one refresh cycle,
    // and the idempotent existence check below means the follow-up read is a
    // pure no-op read.
    final missingFreezeTargets = <(String, PlannerDate)>[
      for (final target in freezeTargets)
        if (!snapshotsByParticipant.containsKey((
          target.$1,
          CalendarEventOccurrenceIdentity.forDate(
            eventId: target.$1,
            originalDate: target.$2,
          ),
          contactId,
        )))
          target,
    ];
    if (missingFreezeTargets.isNotEmpty) {
      final primaryColor = await _primaryGroupColor(profileId, contactId);
      await database.transaction(() async {
        for (final target in missingFreezeTargets) {
          await _freezeSingleParticipant(
            profileId: profileId,
            eventId: target.$1,
            date: target.$2,
            contact: detail.contact,
            primaryColor: primaryColor,
          );
        }
      });
    }

    // A participant snapshot preserves factual participation, not a fixed
    // historical bucket. It follows the same current effective scheduling law
    // as a live link and dedupes across both Timeline sections.
    for (final snapshot in snapshots) {
      final event = eventsById[snapshot.eventId];
      if (event == null) {
        continue;
      }
      final projectionKey = '${snapshot.eventId}:${snapshot.occurrenceId}';
      if (!projectedEventKeys.add(projectionKey)) {
        continue;
      }
      final date = PlannerDate.parse(snapshot.originalDate);
      final exception = exceptionsByKey['${event.id}:${snapshot.occurrenceId}'];
      final effectiveDate = exception == null
          ? date
          : PlannerDate.parse(exception.effectiveDate);
      final startMinute = exception?.startMinute ?? event.startMinute ?? 0;
      final masterStatus = _statusFromRow(event.status);
      final occurrenceStoredStatus = exception == null
          ? masterStatus
          : _statusFromRow(exception.status);
      final structurallyCancelled =
          masterStatus == CalendarEventStatus.cancelled ||
          occurrenceStoredStatus == CalendarEventStatus.cancelled;
      final submittedStatus = reportStatusByOccurrenceId[snapshot.occurrenceId];
      final status =
          submittedStatus ??
          (structurallyCancelled
              ? CalendarEventStatus.cancelled
              : occurrenceStoredStatus);
      final isUpcoming = _isUpcomingOccurrence(
        date: effectiveDate,
        timing: exception?.timing ?? event.timing,
        endMinute: exception?.endMinute ?? event.endMinute,
        timeZoneId: exception?.timeZoneId ?? event.timeZoneId,
        today: today,
        nowUtc: nowUtc,
      );
      if (removedOccurrenceKeys.contains(projectionKey) ||
          (isUpcoming && removedSeriesEventIds.contains(snapshot.eventId))) {
        continue;
      }
      final entry = ContactTimelineEntry(
        kind: ContactTimelineKind.eventOccurrence,
        date: effectiveDate,
        chronology: _timelineChronology(effectiveDate, startMinute),
        title: _eventDisplayTitle(event, exception),
        subtitle: null,
        status: status,
        statusLabel: _timelineStatusLabel(
          status,
          isPast: !isUpcoming,
          requiresReport: exception?.requiresReport ?? event.requiresReport,
        ),
        eventId: event.id,
        originalDate: date,
        occurrenceId: snapshot.occurrenceId,
        activityTypeId: exception?.activityTypeId ?? event.activityTypeId,
        activityTypeStableKey:
            exception?.activityTypeStableKeySnapshot ??
            event.activityTypeStableKeySnapshot,
        activityTypeColorValue:
            exception?.activityTypeColorValueSnapshot ??
            event.activityTypeColorValueSnapshot,
        effectiveStartMinute:
            (exception?.timing ?? event.timing) ==
                CalendarEventTiming.allDay.name
            ? null
            : startMinute,
        isUpcoming: isUpcoming,
        isStructurallyCancelled: structurallyCancelled,
        hasSubmittedOutcome: submittedStatus != null,
      );
      if (!isUpcoming && submittedStatus != null) {
        history.add(entry);
      } else if (structurallyCancelled) {
        cancelledEvents.add(entry);
      } else {
        (isUpcoming ? upcoming : history).add(entry);
      }
    }

    // Tasks use only the canonical task_contact_links relation. The Timeline
    // deliberately projects dated, incomplete Tasks on/after the Planner day;
    // overdue, undated, completed, skipped and cancelled Tasks are excluded.
    // Recurrence is metadata on the one live Task, never a generated
    // occurrence stream, so a qualifying recurring Task appears once.
    final taskLinks =
        await (database.select(database.taskContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.contactId.equals(contactId),
            ))
            .get();
    final taskIds = taskLinks.map((link) => link.taskId).toSet();
    if (taskIds.isNotEmpty) {
      final taskRows =
          await (database.select(database.plannerTasks)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.isIn(taskIds) &
                    table.status.equals(PlannerTaskStatus.incomplete.name) &
                    table.dueDate.isNotNull(),
              ))
              .get();
      for (final task in taskRows) {
        final dueDate = PlannerDate.parse(task.dueDate!);
        if (dueDate.compareTo(today) < 0) {
          continue;
        }
        futureTasks.add(
          ContactTimelineEntry(
            kind: ContactTimelineKind.plannerTask,
            date: dueDate,
            chronology: _timelineChronology(dueDate, task.dueMinute ?? 0),
            title: task.title,
            subtitle: _taskTimelineDueLabel(dueDate, task.dueMinute),
            statusLabel: 'Incomplete',
            taskId: task.id,
            activityTypeStableKey: task.linkedActivityTypeStableKey,
            isUpcoming: true,
          ),
        );
      }
    }

    final createdLocal = detail.contact.createdAtUtc.toLocal();
    history.add(
      ContactTimelineEntry(
        kind: ContactTimelineKind.recordCreated,
        date: PlannerDate.fromDateTime(createdLocal),
        chronology: createdLocal,
        title: 'Record Created',
        subtitle: 'Contact was added',
      ),
    );

    upcoming.sort(_compareTimelineChronology);
    futureTasks.sort(_compareTimelineChronology);
    history.sort((a, b) => _compareTimelineChronology(b, a));
    cancelledEvents.sort((a, b) => _compareTimelineChronology(b, a));
    return ContactTimeline(
      upcoming: upcoming,
      futureTasks: futureTasks,
      history: history,
      cancelledEvents: cancelledEvents,
    );
  }

  @override
  Future<List<CommonEventPattern>> readCommonEventPatterns({
    required String profileId,
    required String contactId,
  }) async {
    final nowUtc = clock.nowUtc();
    final today = PlannerDate.fromDateTime(nowUtc.toLocal());
    final participations = await (database.select(
      database.eventOccurrenceParticipants,
    )..where((table) => table.contactId.equals(contactId))).get();
    if (participations.isEmpty) {
      return const <CommonEventPattern>[];
    }
    final eventIds = participations.map((row) => row.eventId).toSet();
    final events =
        await (database.select(database.calendarEvents)..where(
              (table) =>
                  table.profileId.equals(profileId) & table.id.isIn(eventIds),
            ))
            .get();
    final eventsById = {for (final event in events) event.id: event};
    final exceptions =
        await (database.select(database.calendarEventExceptions)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.isIn(eventIds),
            ))
            .get();
    final exceptionsByKey = <String, CalendarEventExceptionRow>{
      for (final row in exceptions) '${row.eventId}:${row.occurrenceId}': row,
    };
    final reports =
        await (database.select(database.outcomeReports)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.isIn(eventIds) &
                  table.status.equals('submitted') &
                  table.effectiveSlotKey.isNotNull() &
                  table.occurrenceId.isNotNull() &
                  table.outcome.isNotNull(),
            ))
            .get();
    final reportStatusByOccurrenceId = <String, CalendarEventStatus>{
      for (final report in reports)
        report.occurrenceId!: _statusFromRow(report.outcome!),
    };
    final counts = <String, int>{};
    for (final participation in participations) {
      final event = eventsById[participation.eventId];
      if (event == null) {
        continue;
      }
      final exception =
          exceptionsByKey['${participation.eventId}:${participation.occurrenceId}'];
      final storedStatus = exception == null
          ? _statusFromRow(event.status)
          : _statusFromRow(exception.status);
      final status =
          reportStatusByOccurrenceId[participation.occurrenceId] ??
          storedStatus;
      if (status != CalendarEventStatus.completedHappened) {
        continue;
      }
      final date = PlannerDate.parse(participation.originalDate);
      final effectiveDate = exception == null
          ? date
          : PlannerDate.parse(exception.effectiveDate);
      if (_isUpcomingOccurrence(
        date: effectiveDate,
        timing: exception?.timing ?? event.timing,
        endMinute: exception?.endMinute ?? event.endMinute,
        timeZoneId: exception?.timeZoneId ?? event.timeZoneId,
        today: today,
        nowUtc: nowUtc,
      )) {
        continue;
      }
      final startMinute = exception?.startMinute ?? event.startMinute;
      final key =
          '${participation.eventId}:${effectiveDate.weekday}:$startMinute';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final patterns = <CommonEventPattern>[];
    for (final entry in counts.entries) {
      final count = entry.value;
      if (count < 3) {
        continue;
      }
      final parts = entry.key.split(':');
      final eventId = parts[0];
      final weekday = int.parse(parts[1]);
      final startMinute = parts[2] == 'null' ? null : int.tryParse(parts[2]);
      final event = eventsById[eventId];
      if (event == null) {
        continue;
      }
      patterns.add(
        CommonEventPattern(
          eventId: eventId,
          title: _eventDisplayTitle(event, null),
          weekdayLabel: _weekdayShort(weekday),
          startMinuteLabel: startMinute == null
              ? 'All day'
              : _formatMinute(startMinute),
          count: count,
        ),
      );
    }
    patterns.sort((a, b) => b.count.compareTo(a.count));
    return patterns;
  }

  // -- Merge / duplicates ---------------------------------------------------

  @override
  Future<List<List<Contact>>> readDuplicateCandidates(String profileId) async {
    final contacts =
        await (database.select(database.contacts)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.lifecycleState.equals(
                    ContactLifecycleState.active.name,
                  ),
            ))
            .get();
    if (contacts.length < 2) {
      return const <List<Contact>>[];
    }
    final methods =
        await (database.select(database.contactMethods)..where(
              (table) =>
                  table.contactId.isIn(contacts.map((row) => row.id).toList()),
            ))
            .get();
    final contactsById = {for (final row in contacts) row.id: row};
    final byNormalized = <String, Set<String>>{};
    for (final method in methods) {
      if (method.type != 'phone' && method.type != 'email') {
        continue;
      }
      final normalized = method.normalizedValue.trim().toLowerCase();
      if (normalized.isEmpty) {
        continue;
      }
      byNormalized
          .putIfAbsent(normalized, () => <String>{})
          .add(method.contactId);
    }
    String normalizedName(String value) => value
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9]+"), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');

    final names = <String, String>{
      for (final contact in contacts)
        contact.id: normalizedName(contact.displayName),
    };
    for (final entry in names.entries) {
      if (entry.value.isNotEmpty) {
        byNormalized
            .putIfAbsent('name:${entry.value}', () => <String>{})
            .add(entry.key);
      }
    }
    for (var i = 0; i < contacts.length; i++) {
      final left = names[contacts[i].id]!
          .split(' ')
          .where((token) => token.isNotEmpty)
          .toSet();
      for (var j = i + 1; j < contacts.length; j++) {
        final right = names[contacts[j].id]!
            .split(' ')
            .where((token) => token.isNotEmpty)
            .toSet();
        final shorter = left.length <= right.length ? left : right;
        final longer = left.length <= right.length ? right : left;
        if (shorter.length >= 2 && longer.containsAll(shorter)) {
          byNormalized['name-contained:${contacts[i].id}|${contacts[j].id}'] =
              <String>{contacts[i].id, contacts[j].id};
        }
      }
    }
    final groups = <List<Contact>>[];
    final seen = <String>{};
    for (final ids in byNormalized.values) {
      if (ids.length < 2) {
        continue;
      }
      final sorted = ids.toList()..sort();
      final key = sorted.join('|');
      if (!seen.add(key)) {
        continue;
      }
      final members = <Contact>[
        for (final id in sorted)
          if (contactsById[id] != null) _contactFromRow(contactsById[id]!),
      ];
      if (members.length >= 2) {
        groups.add(members);
      }
    }
    groups.sort((a, b) => a.length.compareTo(b.length));
    return groups;
  }

  @override
  Future<ContactMergePlan> readMergePlan({
    required String profileId,
    required String survivorId,
    required List<String> absorbedIds,
  }) async {
    final survivor = await readContactDetail(
      profileId: profileId,
      contactId: survivorId,
    );
    final absorbed = <Contact>[];
    var absorbedLinks = 0;
    var absorbedNotes = 0;
    for (final id in absorbedIds) {
      final detail = await readContactDetail(
        profileId: profileId,
        contactId: id,
      );
      absorbed.add(detail.contact);
      absorbedLinks +=
          await (database.select(database.eventContactLinks)
                ..where((table) => table.contactId.equals(id)))
              .get()
              .then((rows) => rows.length);
      absorbedNotes += detail.notes.length;
    }
    final survivorLinks = (await (database.select(
      database.eventContactLinks,
    )..where((table) => table.contactId.equals(survivorId))).get()).length;
    return ContactMergePlan(
      survivor: survivor.contact,
      absorbed: absorbed,
      survivorLinkCount: survivorLinks,
      absorbedLinkCount: absorbedLinks,
      absorbedNoteCount: absorbedNotes,
    );
  }

  @override
  Future<Contact> mergeContacts({
    required String profileId,
    required String survivorId,
    required List<String> absorbedIds,
    required ContactMergeChoices choices,
  }) async {
    if (absorbedIds.contains(survivorId)) {
      throw const ContactMergeException(
        'Survivor cannot be an absorbed Contact.',
      );
    }
    final now = clock.nowUtc();
    return database.transaction(() async {
      final survivorRow =
          await (database.select(database.contacts)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.id.equals(survivorId),
                )
                ..limit(1))
              .getSingleOrNull();
      if (survivorRow == null) {
        throw const ContactMergeException('Survivor Contact not found.');
      }
      final survivor = _contactFromRow(survivorRow);
      final survivorMethods = await (database.select(
        database.contactMethods,
      )..where((table) => table.contactId.equals(survivorId))).get();
      final survivorMethodKeys = survivorMethods
          .map((m) => '${m.type}:${m.normalizedValue.toLowerCase()}')
          .toSet();
      final survivorMemberships = await (database.select(
        database.contactGroupMemberships,
      )..where((table) => table.contactId.equals(survivorId))).get();
      final survivorGroupIds = survivorMemberships
          .map((row) => row.groupId)
          .toSet();
      final survivorTags = await (database.select(
        database.contactTagMemberships,
      )..where((table) => table.contactId.equals(survivorId))).get();
      final survivorTagIds = survivorTags.map((row) => row.tagId).toSet();
      final survivorEventLinks = await (database.select(
        database.eventContactLinks,
      )..where((table) => table.contactId.equals(survivorId))).get();
      final survivorEventLinkKeys = survivorEventLinks
          .map((row) => '${row.eventId}:${row.occurrenceId}')
          .toSet();
      final survivorParticipantKeys =
          (await (database.select(
                database.eventOccurrenceParticipants,
              )..where((table) => table.contactId.equals(survivorId))).get())
              .map((row) => '${row.eventId}:${row.occurrenceId}')
              .toSet();
      final survivorTaskLinks = await (database.select(
        database.taskContactLinks,
      )..where((table) => table.contactId.equals(survivorId))).get();
      final survivorTaskLinkKeys = survivorTaskLinks
          .map((row) => row.taskId)
          .toSet();

      for (final absorbedId in absorbedIds) {
        final absorbedRow =
            await (database.select(database.contacts)
                  ..where(
                    (table) =>
                        table.profileId.equals(profileId) &
                        table.id.equals(absorbedId),
                  )
                  ..limit(1))
                .getSingleOrNull();
        if (absorbedRow == null) {
          continue;
        }
        // Methods: keep survivor's; add absorbed ones that do not collide.
        final absorbedMethods = await (database.select(
          database.contactMethods,
        )..where((table) => table.contactId.equals(absorbedId))).get();
        for (final method in absorbedMethods) {
          final key = '${method.type}:${method.normalizedValue.toLowerCase()}';
          if (survivorMethodKeys.contains(key)) {
            await (database.delete(
              database.contactMethods,
            )..where((table) => table.id.equals(method.id))).go();
            continue;
          }
          survivorMethodKeys.add(key);
          await (database.update(
            database.contactMethods,
          )..where((table) => table.id.equals(method.id))).write(
            ContactMethodsCompanion(
              contactId: Value<String>(survivorId),
              isPrimary: const Value<bool>(false),
            ),
          );
        }
        // Groups: add missing memberships.
        final absorbedMemberships = await (database.select(
          database.contactGroupMemberships,
        )..where((table) => table.contactId.equals(absorbedId))).get();
        for (final membership in absorbedMemberships) {
          if (survivorGroupIds.add(membership.groupId)) {
            await database
                .into(database.contactGroupMemberships)
                .insert(
                  ContactGroupMembershipsCompanion.insert(
                    contactId: survivorId,
                    groupId: membership.groupId,
                    isPrimary: const Value<bool>(false),
                  ),
                );
          }
        }
        await (database.delete(
          database.contactGroupMemberships,
        )..where((table) => table.contactId.equals(absorbedId))).go();
        // Tags: add missing.
        final absorbedTags = await (database.select(
          database.contactTagMemberships,
        )..where((table) => table.contactId.equals(absorbedId))).get();
        for (final membership in absorbedTags) {
          if (survivorTagIds.add(membership.tagId)) {
            await database
                .into(database.contactTagMemberships)
                .insert(
                  ContactTagMembershipsCompanion.insert(
                    contactId: survivorId,
                    tagId: membership.tagId,
                  ),
                );
          }
        }
        await (database.delete(
          database.contactTagMemberships,
        )..where((table) => table.contactId.equals(absorbedId))).go();
        // Notes move to the survivor (same IDs, new owner).
        await (database.update(database.contactNotes)
              ..where((table) => table.contactId.equals(absorbedId)))
            .write(ContactNotesCompanion(contactId: Value<String>(survivorId)));
        // Availability moves to the survivor.
        await (database.update(
          database.contactAvailabilities,
        )..where((table) => table.contactId.equals(absorbedId))).write(
          ContactAvailabilitiesCompanion(contactId: Value<String>(survivorId)),
        );
        // Event links: dedupe then re-own.
        final absorbedLinks = await (database.select(
          database.eventContactLinks,
        )..where((table) => table.contactId.equals(absorbedId))).get();
        for (final link in absorbedLinks) {
          final key = '${link.eventId}:${link.occurrenceId}';
          if (!survivorEventLinkKeys.add(key)) {
            await (database.delete(
              database.eventContactLinks,
            )..where((table) => table.id.equals(link.id))).go();
            continue;
          }
          await (database.update(
            database.eventContactLinks,
          )..where((table) => table.id.equals(link.id))).write(
            EventContactLinksCompanion(contactId: Value<String>(survivorId)),
          );
        }
        // Participant snapshots: dedupe then re-own.
        final absorbedParticipants = await (database.select(
          database.eventOccurrenceParticipants,
        )..where((table) => table.contactId.equals(absorbedId))).get();
        for (final participant in absorbedParticipants) {
          final key = '${participant.eventId}:${participant.occurrenceId}';
          if (!survivorParticipantKeys.add(key)) {
            await (database.delete(
              database.eventOccurrenceParticipants,
            )..where((table) => table.id.equals(participant.id))).go();
            continue;
          }
          await (database.update(
            database.eventOccurrenceParticipants,
          )..where((table) => table.id.equals(participant.id))).write(
            EventOccurrenceParticipantsCompanion(
              contactId: Value<String>(survivorId),
            ),
          );
        }
        // Task links: dedupe then re-own.
        final absorbedTaskLinks = await (database.select(
          database.taskContactLinks,
        )..where((table) => table.contactId.equals(absorbedId))).get();
        for (final link in absorbedTaskLinks) {
          if (!survivorTaskLinkKeys.add(link.taskId)) {
            await (database.delete(
              database.taskContactLinks,
            )..where((table) => table.id.equals(link.id))).go();
            continue;
          }
          await (database.update(
            database.taskContactLinks,
          )..where((table) => table.id.equals(link.id))).write(
            TaskContactLinksCompanion(contactId: Value<String>(survivorId)),
          );
        }
        // Absorb the row into a traceable tombstone.
        await (database.update(
          database.contacts,
        )..where((table) => table.id.equals(absorbedId))).write(
          ContactsCompanion(
            lifecycleState: Value<String>(ContactLifecycleState.merged.name),
            mergedIntoContactId: Value<String?>(survivorId),
            updatedAtUtc: Value<DateTime>(now),
          ),
        );
      }

      // Apply field-level choices to the survivor.  The absorbed rows are
      // loaded up front so per-field value choices can resolve by ID.
      final absorbedRowsCache = <String, Contact>{};
      for (final id in absorbedIds) {
        final detail = await readContactDetail(
          profileId: profileId,
          contactId: id,
        );
        absorbedRowsCache[id] = detail.contact;
      }

      String? sourceFor(String field) {
        return choices.valueFor(field, fallbackContactId: survivorId);
      }

      Contact? resolveChosen(String? contactId) {
        if (contactId == null) {
          return null;
        }
        if (contactId == survivorId) {
          return survivor;
        }
        return absorbedRowsCache[contactId];
      }

      final displaySource = resolveChosen(sourceFor('displayName'));
      final addressSource = resolveChosen(sourceFor('addressText'));
      final methodSource = resolveChosen(sourceFor('preferredContactMethod'));
      final mergedDisplay = displaySource?.displayName ?? survivor.displayName;
      final mergedAddress = addressSource?.addressText ?? survivor.addressText;
      final mergedMethod =
          methodSource?.preferredContactMethod ??
          survivor.preferredContactMethod;

      await (database.update(
        database.contacts,
      )..where((table) => table.id.equals(survivorId))).write(
        ContactsCompanion(
          firstName: Value<String?>(_splitNames(mergedDisplay).$1),
          lastName: Value<String?>(_splitNames(mergedDisplay).$2),
          displayName: Value<String>(mergedDisplay),
          addressText: Value<String?>(mergedAddress),
          preferredContactMethod: Value<String>(
            ContactPreferredMethodCodec.encode(mergedMethod),
          ),
          isFavorite: Value<bool>(
            survivor.isFavorite ||
                absorbedRowsCache.values.any((contact) => contact.isFavorite),
          ),
          updatedAtUtc: Value<DateTime>(now),
        ),
      );
      final detail = await readContactDetail(
        profileId: profileId,
        contactId: survivorId,
      );
      // Section 10/27: a merge retires every absorbed Contact, so any reminder
      // that named one of them must be re-resolved against current truth.  The
      // absorbed purposes are invalidated (never retargeted to the survivor —
      // section 13 forbids silently redirecting a follow-up at a different
      // human) and the repair intent commits with the merge.
      await _invalidateContactFollowUpPurposes(
        database,
        profileId: profileId,
        contactIds: absorbedIds,
      );
      await reminderRepair?.mark(database, profileId: profileId);
      return detail.contact;
    });
  }

  @override
  Future<ContactImportResult> importDeviceContacts({
    required String profileId,
    required List<DeviceContactDraft> drafts,
  }) async {
    if (drafts.isEmpty) {
      return const ContactImportResult(
        createdCount: 0,
        skippedCount: 0,
        duplicateContactIds: <String>[],
      );
    }
    final existingContacts =
        await (database.select(database.contacts)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.lifecycleState.equals(
                    ContactLifecycleState.active.name,
                  ),
            ))
            .get();
    final existingIds = existingContacts
        .map((row) => row.id)
        .toList(growable: false);
    final existingMethods = existingIds.isEmpty
        ? const <ContactMethodRow>[]
        : await (database.select(
            database.contactMethods,
          )..where((table) => table.contactId.isIn(existingIds))).get();
    final existingNormalized = <String>{
      for (final method in existingMethods)
        if (method.normalizedValue.trim().isNotEmpty)
          '${method.type}:${method.normalizedValue.trim().toLowerCase()}',
    };
    final duplicateContactIds = <String>[];
    var created = 0;
    var skipped = 0;
    for (final draft in drafts) {
      final displayName = draft.displayName.trim();
      if (displayName.isEmpty) {
        skipped++;
        continue;
      }
      // POST-M7 CLOSURE: one device contact can legitimately list the SAME
      // number or email under two labels (a SIM row merging with a Google row).
      // The write path rejects a repeated (type, normalizedValue) inside one
      // contact, and that rejection used to escape this loop and abandon every
      // remaining selected draft.  Consolidate here with the exact key the
      // validator uses, so the draft still matches intent: one method per
      // distinct value, first occurrence wins.
      final phones = draft.resolvedPhones
          .where((phone) => phone.value.trim().isNotEmpty)
          .toList(growable: false);
      final emails = draft.emails
          .map((value) => value.trim().toLowerCase())
          .where((value) => value.isNotEmpty)
          .toList();
      final seenMethodKeys = <String>{};
      final consolidatedPhones = <DeviceContactPhone>[];
      for (final phone in phones) {
        final normalized = normalizePhone(phone.value);
        if (normalized.isEmpty) {
          continue;
        }
        if (seenMethodKeys.add('phone\u0000$normalized')) {
          consolidatedPhones.add(phone);
        }
      }
      final consolidatedEmails = <String>[];
      for (final email in emails) {
        if (seenMethodKeys.add('email\u0000$email')) {
          consolidatedEmails.add(email);
        }
      }
      final normalizedPhone = consolidatedPhones.isEmpty
          ? null
          : normalizePhone(consolidatedPhones.first.value);
      final normalizedEmail = consolidatedEmails.isEmpty
          ? null
          : consolidatedEmails.first;
      final phoneKey = normalizedPhone == null || normalizedPhone.isEmpty
          ? null
          : 'phone:$normalizedPhone';
      final emailKey = normalizedEmail == null || normalizedEmail.isEmpty
          ? null
          : 'email:$normalizedEmail';
      final matchedExisting = <String>[];
      if (phoneKey != null && existingNormalized.contains(phoneKey)) {
        matchedExisting.add(phoneKey);
      }
      if (emailKey != null && existingNormalized.contains(emailKey)) {
        matchedExisting.add(emailKey);
      }
      if (matchedExisting.isNotEmpty) {
        // A normalized phone/email match is advisory — we never merge and
        // never silently rewrite history.  The record is simply skipped and
        // reported so the user can decide what to do with it.
        duplicateContactIds.add(displayName);
        existingNormalized.addAll([?phoneKey, ?emailKey]);
        skipped++;
        continue;
      }
      final contactDraft = ContactDraft(
        id: identifiers.nextUuid(),
        firstName: draft.firstName ?? '',
        lastName: draft.lastName ?? '',
        displayName: displayName,
        preferredContactMethod: ContactPreferredMethod.message,
        isFavorite: false,
        source: ContactSource.deviceImport,
        methods: <ContactMethodDraft>[
          for (final phone in consolidatedPhones)
            ContactMethodDraft(
              type: ContactMethodType.phone,
              value: phone.value,
              label: _importPhoneLabel(phone.sourceLabel),
              receivesTexts: _importReceivesTexts(phone.sourceLabel),
              hasWhatsApp: null,
            ),
          for (final email in consolidatedEmails)
            ContactMethodDraft(type: ContactMethodType.email, value: email),
        ],
      );
      try {
        await createContact(profileId: profileId, draft: contactDraft);
        created++;
      } on ContactValidationException {
        // POST-M7 CLOSURE: contain a draft-level rejection so one unexpected
        // record can never abandon the rest of the selected batch.  A systemic
        // failure (anything other than a validation rejection) is deliberately
        // NOT swallowed here — it must surface truthfully to the user.
        skipped++;
      }
    }
    return ContactImportResult(
      createdCount: created,
      skippedCount: skipped,
      duplicateContactIds: duplicateContactIds,
    );
  }

  static String _importPhoneLabel(String? sourceLabel) {
    final label = sourceLabel?.trim().toLowerCase();
    return switch (label) {
      'mobile' || 'workmobile' || 'mms' => 'Mobile',
      'home' => 'Home',
      'work' || 'companymain' || 'main' => 'Work',
      _ => 'Other',
    };
  }

  static bool? _importReceivesTexts(String? sourceLabel) {
    final label = sourceLabel?.trim().toLowerCase();
    return switch (label) {
      'mobile' || 'workmobile' || 'mms' => true,
      'home' ||
      'homefax' ||
      'workfax' ||
      'otherfax' ||
      'pager' ||
      'workpager' ||
      'isdn' ||
      'telex' ||
      'ttytdd' => false,
      _ => null,
    };
  }

  // -- Shared helpers -------------------------------------------------------

  Future<List<ContactSummary>> _summariesForContactRows({
    required String profileId,
    required List<ContactRow> rows,
    required PlannerDate today,
  }) async {
    final ids = rows.map((row) => row.id).toList(growable: false);
    final eventContext = await _eventContextForContacts(ids, today);
    final memberships =
        await (database.select(database.contactGroupMemberships).join([
          innerJoin(
            database.contactGroups,
            database.contactGroups.id.equalsExp(
              database.contactGroupMemberships.groupId,
            ),
          ),
        ])..where(database.contactGroupMemberships.contactId.isIn(ids))).get();
    final primaryGroupByContact = <String, ContactGroupRow>{};
    final secondaryByContact = <String, List<String>>{};
    for (final row in memberships) {
      final membership = row.readTable(database.contactGroupMemberships);
      final group = row.readTable(database.contactGroups);
      if (group.isArchived) {
        continue;
      }
      if (membership.isPrimary) {
        primaryGroupByContact[membership.contactId] = group;
      } else {
        secondaryByContact
            .putIfAbsent(membership.contactId, () => <String>[])
            .add(group.name);
      }
    }
    return rows
        .map((row) {
          final primary = primaryGroupByContact[row.id];
          return ContactSummary(
            contact: _contactFromRow(row),
            primaryGroup: primary == null ? null : _groupFromRow(primary),
            groupNames: List<String>.unmodifiable(
              secondaryByContact[row.id] ?? const <String>[],
            ),
            context: eventContext[row.id] ?? const ContactListContext(),
          );
        })
        .toList(growable: false);
  }

  /// Bounded, batched next/last occurrence computation for a set of
  /// Contacts.  Uses the exact same recurrence semantics as the Planner
  /// (`occurrenceIndexOn` / `occurrenceAt`), so Timeline and list rows can
  /// never disagree about a date.
  Future<Map<String, ContactListContext>> _eventContextForContacts(
    List<String> contactIds,
    PlannerDate today,
  ) async {
    if (contactIds.isEmpty) {
      return const <String, ContactListContext>{};
    }
    final links =
        await (database.select(database.eventContactLinks)..where(
              (table) =>
                  table.contactId.isIn(contactIds) &
                  table.status.equals('active'),
            ))
            .get();
    final snapshots = await (database.select(
      database.eventOccurrenceParticipants,
    )..where((table) => table.contactId.isIn(contactIds))).get();
    if (links.isEmpty && snapshots.isEmpty) {
      return const <String, ContactListContext>{};
    }
    final eventIds = <String>{
      ...links.map((link) => link.eventId),
      ...snapshots.map((snapshot) => snapshot.eventId),
    };
    final events = await (database.select(
      database.calendarEvents,
    )..where((table) => table.id.isIn(eventIds))).get();
    final eventsById = {for (final event in events) event.id: event};
    final exceptions = await (database.select(
      database.calendarEventExceptions,
    )..where((table) => table.eventId.isIn(eventIds))).get();
    final exceptionsByKey = <String, CalendarEventExceptionRow>{
      for (final row in exceptions) '${row.eventId}:${row.occurrenceId}': row,
    };
    final byContact = <String, List<EventContactLinkRow>>{};
    for (final link in links) {
      byContact
          .putIfAbsent(link.contactId, () => <EventContactLinkRow>[])
          .add(link);
    }
    for (final snapshot in snapshots) {
      byContact.putIfAbsent(snapshot.contactId, () => <EventContactLinkRow>[]);
    }
    final result = <String, ContactListContext>{};
    for (final entry in byContact.entries) {
      PlannerDate? nextDate;
      String? nextTitle;
      PlannerDate? lastDate;
      PlannerDate? lastHappenedDate;
      PlannerDate? leastRecentDate;
      PlannerDate? leastRecentHappenedDate;

      void considerHistoricalFact(
        CalendarEventRow event,
        PlannerDate date,
        String occurrenceId,
      ) {
        if (date.compareTo(today) >= 0) return;
        final exception = exceptionsByKey['${event.id}:$occurrenceId'];
        final effectiveStatus = _statusFromRow(
          exception?.status ?? event.status,
        );
        if (effectiveStatus == CalendarEventStatus.cancelled) return;
        if (leastRecentDate == null || date.compareTo(leastRecentDate!) < 0) {
          leastRecentDate = date;
        }
        final happened =
            effectiveStatus == CalendarEventStatus.completedHappened ||
            effectiveStatus == CalendarEventStatus.partiallyCompleted;
        if (!happened) return;
        if (lastHappenedDate == null || date.compareTo(lastHappenedDate!) > 0) {
          lastHappenedDate = date;
        }
        if (leastRecentHappenedDate == null ||
            date.compareTo(leastRecentHappenedDate!) < 0) {
          leastRecentHappenedDate = date;
        }
      }

      for (final link in entry.value) {
        final event = eventsById[link.eventId];
        if (event == null) {
          continue;
        }
        final dates = link.occurrenceId == seriesOccurrenceId
            ? _seriesDates(event, today, nextLimit: 20, pastLimit: 60)
            : <PlannerDate>[
                if (link.originalDate != null)
                  PlannerDate.parse(link.originalDate!),
              ];
        for (final date in dates) {
          final occurrenceIdForDate = CalendarEventOccurrenceIdentity.forDate(
            eventId: event.id,
            originalDate: date,
          );
          final exception = exceptionsByKey['${event.id}:$occurrenceIdForDate'];
          if (exception?.status == CalendarEventStatus.cancelled.name) {
            continue;
          }
          if (date.compareTo(today) >= 0) {
            if (nextDate == null || date.compareTo(nextDate) < 0) {
              nextDate = date;
              nextTitle = _eventDisplayTitle(event, exception);
            }
          } else if (lastDate == null || date.compareTo(lastDate) > 0) {
            lastDate = date;
          }
        }
        final historicalDates = link.occurrenceId == seriesOccurrenceId
            ? _seriesDates(event, today, nextLimit: 0, pastLimit: 2000)
            : dates;
        for (final date in historicalDates) {
          considerHistoricalFact(
            event,
            date,
            CalendarEventOccurrenceIdentity.forDate(
              eventId: event.id,
              originalDate: date,
            ),
          );
        }
      }
      for (final snapshot in snapshots.where(
        (snapshot) => snapshot.contactId == entry.key,
      )) {
        final event = eventsById[snapshot.eventId];
        if (event == null) continue;
        considerHistoricalFact(
          event,
          PlannerDate.parse(snapshot.originalDate),
          snapshot.occurrenceId,
        );
      }
      result[entry.key] = ContactListContext(
        nextEventTitle: nextTitle,
        nextEventDate: nextDate,
        lastEventDate: lastDate,
        lastHappenedEventDate: lastHappenedDate,
        leastRecentEventDate: leastRecentDate,
        leastRecentHappenedEventDate: leastRecentHappenedDate,
      );
    }
    return result;
  }

  Future<void> _freezeSingleParticipant({
    required String profileId,
    required String eventId,
    required PlannerDate date,
    required Contact contact,
    required int? primaryColor,
  }) async {
    final now = clock.nowUtc();
    final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: date,
    );
    // POLISH-07: the freeze is idempotent.  readTimeline() runs inside a
    // provider that watches eventOccurrenceParticipants updates; a blind
    // insertOrIgnore with a fresh UUID wrote a NEW row on every read, so the
    // watch re-emitted and re-ran the read — a self-sustaining ~5Hz
    // loading<->data flicker with unbounded row growth.  The existence check
    // makes the first read after a snapshot a no-op write, so the loop
    // quiesces after exactly one refresh cycle.
    final existing =
        await (database.select(database.eventOccurrenceParticipants)
              ..where(
                (table) =>
                    table.eventId.equals(eventId) &
                    table.occurrenceId.equals(occurrenceId) &
                    table.contactId.equals(contact.id),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) {
      return;
    }
    await database
        .into(database.eventOccurrenceParticipants)
        .insert(
          EventOccurrenceParticipantsCompanion.insert(
            id: identifiers.nextUuid(),
            profileId: profileId,
            eventId: eventId,
            occurrenceId: occurrenceId,
            originalDate: date.iso8601,
            contactId: contact.id,
            displayNameSnapshot: contact.displayName,
            groupColorValueSnapshot: Value<int?>(primaryColor),
            createdAtUtc: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<int?> _primaryGroupColor(String profileId, String contactId) async {
    final row =
        await (database.select(database.contactGroupMemberships).join([
                innerJoin(
                  database.contactGroups,
                  database.contactGroups.id.equalsExp(
                    database.contactGroupMemberships.groupId,
                  ),
                ),
              ])
              ..where(
                database.contactGroupMemberships.contactId.equals(contactId) &
                    database.contactGroupMemberships.isPrimary.equals(true),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.readTable(database.contactGroups).colorValue;
  }

  Future<void> _replaceMethods(
    String profileId, {
    required String contactId,
    required List<ContactMethodDraft> methods,
  }) async {
    final primaryTypes = <ContactMethodType>{};
    for (final method in methods) {
      if (method.isPrimary && !primaryTypes.add(method.type)) {
        throw const ContactValidationException(
          'Choose at most one preferred Phone, Email, and Social Profile.',
        );
      }
    }
    final existing = await (database.select(
      database.contactMethods,
    )..where((table) => table.contactId.equals(contactId))).get();
    final existingById = <String, ContactMethodRow>{
      for (final row in existing) row.id: row,
    };
    final existingIds = existingById.keys.toSet();
    final retainedIds = <String>{};
    final methodKeys = <String>{};
    final normalizedValues = <ContactMethodDraft, String>{};

    for (final method in methods) {
      final normalized = switch (method.type) {
        ContactMethodType.phone => normalizePhone(method.value),
        ContactMethodType.email => method.value.toLowerCase().trim(),
        ContactMethodType.social => method.value.trim(),
      };
      if (normalized.isEmpty) {
        continue;
      }
      final methodId = method.id;
      if (methodId != null) {
        if (!existingIds.contains(methodId)) {
          throw const ContactValidationException('Contact method not found.');
        }
        if (!retainedIds.add(methodId)) {
          throw const ContactValidationException(
            'A contact method was submitted twice.',
          );
        }
      }
      if (!methodKeys.add('${method.type.name}\u0000$normalized')) {
        throw const ContactValidationException(
          'Duplicate Phone, Email, or Social Profile values are not allowed.',
        );
      }
      normalizedValues[method] = normalized;
    }

    final idsToDelete = existingIds.difference(retainedIds);
    if (idsToDelete.isNotEmpty) {
      await (database.delete(
        database.contactMethods,
      )..where((table) => table.id.isIn(idsToDelete.toList()))).go();
    }

    // Keep every retained existing ID while making value swaps safe under the
    // contact/type/normalized-value uniqueness constraint.  The temporary
    // values live only within the enclosing Contact transaction.
    final occupied = <String>{
      for (final row in existing) '${row.type}\u0000${row.normalizedValue}',
      for (final entry in normalizedValues.entries)
        '${entry.key.type.name}\u0000${entry.value}',
    };
    for (final method in methods) {
      final methodId = method.id;
      if (methodId == null || !normalizedValues.containsKey(method)) {
        continue;
      }
      final row = existingById[methodId]!;
      var temporary = '__next_transfer_c4_pending_$methodId';
      var suffix = 1;
      while (occupied.contains('${row.type}\u0000$temporary')) {
        temporary = '__next_transfer_c4_pending_${methodId}_$suffix';
        suffix++;
      }
      occupied.add('${row.type}\u0000$temporary');
      await (database.update(
        database.contactMethods,
      )..where((table) => table.id.equals(methodId))).write(
        ContactMethodsCompanion(normalizedValue: Value<String>(temporary)),
      );
    }

    for (final method in methods) {
      final normalized = normalizedValues[method];
      if (normalized == null) {
        continue;
      }
      final label = method.label;
      final savedLabel = label == null || label.trim().isEmpty ? null : label;
      final methodId = method.id;
      if (methodId == null) {
        await database
            .into(database.contactMethods)
            .insert(
              ContactMethodsCompanion.insert(
                id: identifiers.nextUuid(),
                contactId: contactId,
                type: method.type.name,
                label: Value<String?>(savedLabel),
                rawValue: method.value.trim(),
                normalizedValue: normalized,
                isPrimary: Value<bool>(method.isPrimary),
                receivesTexts: Value<bool?>(
                  method.type == ContactMethodType.phone
                      ? method.receivesTexts
                      : null,
                ),
                hasWhatsApp: Value<bool?>(
                  method.type == ContactMethodType.phone
                      ? method.hasWhatsApp
                      : null,
                ),
              ),
            );
      } else {
        await (database.update(
          database.contactMethods,
        )..where((table) => table.id.equals(methodId))).write(
          ContactMethodsCompanion(
            type: Value<String>(method.type.name),
            label: Value<String?>(savedLabel),
            rawValue: Value<String>(method.value.trim()),
            normalizedValue: Value<String>(normalized),
            isPrimary: Value<bool>(method.isPrimary),
            receivesTexts: Value<bool?>(
              method.type == ContactMethodType.phone
                  ? method.receivesTexts
                  : null,
            ),
            hasWhatsApp: Value<bool?>(
              method.type == ContactMethodType.phone
                  ? method.hasWhatsApp
                  : null,
            ),
          ),
        );
      }
    }
  }

  // -- Occurrence math ------------------------------------------------------

  CalendarRecurrenceRule _ruleFromRow(CalendarEventRow row) {
    return calendarRecurrenceRuleFromStorage(
      frequencyName: row.recurrenceFrequency,
      endModeName: row.recurrenceEndMode,
      endDateIso: row.recurrenceEndDate,
      occurrenceCount: row.recurrenceCount,
      patternJson: row.recurrencePatternJson,
    );
  }

  static int _approximateIndex(
    CalendarRecurrenceRule rule,
    PlannerDate start,
    PlannerDate target,
  ) {
    if (target.compareTo(start) <= 0) {
      return 0;
    }
    return rule.occurrenceIndexAtOrBefore(startDate: start, targetDate: target);
  }

  /// Enumerates occurrence dates for [event], bounded for list/timeline use.
  /// Only dates that satisfy `occurrenceIndexOn` are included, so monthly
  /// clamped dates behave exactly like the Planner.
  List<PlannerDate> _seriesDates(
    CalendarEventRow event,
    PlannerDate today, {
    required int nextLimit,
    required int pastLimit,
  }) {
    final rule = _ruleFromRow(event);
    final start = PlannerDate.parse(event.startDate);
    if (!rule.isRecurring) {
      return <PlannerDate>[start];
    }
    final approx = _approximateIndex(rule, start, today);
    final result = <PlannerDate>[];
    final pastBudget = pastLimit * 4 + 10;
    var index = approx - 1;
    var pastWalked = 0;
    while (index >= 0 && pastWalked < pastBudget) {
      final date = rule.occurrenceAt(startDate: start, index: index);
      if (rule.occurrenceIndexOn(startDate: start, targetDate: date) == index) {
        result.add(date);
        pastWalked++;
        if (pastWalked >= pastLimit) {
          break;
        }
      }
      index--;
      if (pastWalked == 0 && index < approx - 100) {
        // The approximation is off (e.g. clamped month); bail defensively.
        break;
      }
    }
    final upcomingBudget = nextLimit * 4 + 10;
    index = approx;
    var upcomingWalked = 0;
    while (upcomingWalked < upcomingBudget) {
      final date = rule.occurrenceAt(startDate: start, index: index);
      final verified = rule.occurrenceIndexOn(
        startDate: start,
        targetDate: date,
      );
      if (verified == index) {
        result.add(date);
        upcomingWalked++;
        if (result.where((d) => d.compareTo(today) >= 0).length >= nextLimit) {
          break;
        }
      }
      index++;
      if (upcomingWalked == 0 && index > approx + 100) {
        break;
      }
    }
    return result;
  }

  // -- Row mapping ----------------------------------------------------------

  static bool _hasRecordedAddress(ContactRow row) {
    final text = row.addressText?.trim() ?? '';
    return text.isNotEmpty;
  }

  /// Phone category filter.  Keys come from [ContactPhoneFilterKeys].
  /// Selections OR together within the category; absence (No Phone) matches
  /// contacts with zero phone methods.
  static bool _matchesPhoneFilter(
    List<String> selection,
    List<ContactMethodRow> methods,
  ) {
    final phones = methods
        .where((m) => m.type == ContactMethodType.phone.name)
        .toList(growable: false);
    if (selection.contains(ContactPhoneFilterKeys.noPhone) && phones.isEmpty) {
      return true;
    }
    final typed = selection
        .where((k) => k != ContactPhoneFilterKeys.noPhone)
        .toSet();
    if (typed.isEmpty) {
      return false;
    }
    if (typed.contains(ContactPhoneFilterKeys.other)) {
      return phones.any((m) {
        final label = normalizedMethodLabel(m.label);
        return label == null || !ContactPhoneFilterKeys.typed.contains(label);
      });
    }
    return phones.any((m) {
      final label = normalizedMethodLabel(m.label);
      return label != null && typed.contains(label);
    });
  }

  /// Email category filter.  Keys come from [ContactEmailFilterKeys].
  /// "Personal" accepts both "personal" and device-style "home" labels.
  static bool _matchesEmailFilter(
    List<String> selection,
    List<ContactMethodRow> methods,
  ) {
    final emails = methods
        .where((m) => m.type == ContactMethodType.email.name)
        .toList(growable: false);
    if (selection.contains(ContactEmailFilterKeys.noEmail) && emails.isEmpty) {
      return true;
    }
    final typed = selection
        .where((k) => k != ContactEmailFilterKeys.noEmail)
        .toSet();
    if (typed.isEmpty) {
      return false;
    }
    if (typed.contains(ContactEmailFilterKeys.other)) {
      return emails.any((m) {
        final label = normalizedMethodLabel(m.label);
        return label == null ||
            !{'personal', 'home', 'work', 'family'}.contains(label);
      });
    }
    return emails.any((m) {
      final label = normalizedMethodLabel(m.label);
      if (label == null) {
        return false;
      }
      if (typed.contains(ContactEmailFilterKeys.personal) &&
          ContactEmailFilterKeys.personalLabels.contains(label)) {
        return true;
      }
      if (typed.contains(ContactEmailFilterKeys.work) &&
          label == ContactEmailFilterKeys.work) {
        return true;
      }
      if (typed.contains(ContactEmailFilterKeys.family) &&
          label == ContactEmailFilterKeys.family) {
        return true;
      }
      return false;
    });
  }

  /// Address category filter.  Keys come from [ContactAddressFilterKeys].
  /// A map pin alone does not count as recorded; only stored addressText does.
  static bool _matchesAddressFilter(List<String> selection, ContactRow row) {
    final recorded = _hasRecordedAddress(row);
    var match = false;
    if (selection.contains(ContactAddressFilterKeys.notRecorded) && !recorded) {
      match = true;
    }
    if (selection.contains(ContactAddressFilterKeys.recorded) && recorded) {
      match = true;
    }
    return match;
  }

  /// Social Profile category filter.  Keys come from [ContactSocialFilterKeys].
  static bool _matchesSocialFilter(
    List<String> selection,
    List<ContactMethodRow> methods,
  ) {
    final socials = methods
        .where((m) => m.type == ContactMethodType.social.name)
        .toList(growable: false);
    if (selection.contains(ContactSocialFilterKeys.noSocial) &&
        socials.isEmpty) {
      return true;
    }
    final typed = selection
        .where((k) => k != ContactSocialFilterKeys.noSocial)
        .toSet();
    if (typed.isEmpty) {
      return false;
    }
    if (typed.contains(ContactSocialFilterKeys.other)) {
      return socials.any((m) {
        final label = normalizedMethodLabel(m.label);
        return label == null ||
            !ContactSocialFilterKeys.canonical.contains(label);
      });
    }
    return socials.any((m) {
      final label = normalizedMethodLabel(m.label);
      return label != null && typed.contains(label);
    });
  }

  Contact _contactFromRow(ContactRow row) {
    return Contact(
      id: row.id,
      profileId: row.profileId,
      firstName: row.firstName,
      lastName: row.lastName,
      displayName: row.displayName,
      preferredContactMethod: ContactPreferredMethodCodec.decode(
        row.preferredContactMethod,
      ),
      isFavorite: row.isFavorite,
      lifecycleState: ContactLifecycleStateCodec.decode(row.lifecycleState),
      source: ContactSourceCodec.decode(row.source),
      addressText: row.addressText,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
      lastViewedAtUtc: row.lastViewedAtUtc,
      archivedAtUtc: row.archivedAtUtc,
      deletedAtUtc: row.deletedAtUtc,
      mergedIntoContactId: row.mergedIntoContactId,
    );
  }

  ContactMethod _methodFromRow(ContactMethodRow row) {
    return ContactMethod(
      id: row.id,
      contactId: row.contactId,
      type:
          ContactMethodType.values.asNameMap()[row.type] ??
          ContactMethodType.phone,
      label: row.label,
      rawValue: row.rawValue,
      normalizedValue: row.normalizedValue,
      isPrimary: row.isPrimary,
      receivesTexts: row.receivesTexts,
      hasWhatsApp: row.hasWhatsApp,
    );
  }

  ContactGroup _groupFromRow(ContactGroupRow row) {
    return ContactGroup(
      id: row.id,
      profileId: row.profileId,
      name: row.name,
      colorValue: row.colorValue,
      isArchived: row.isArchived,
      sortOrder: row.sortOrder,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
    );
  }

  ContactTag _tagFromRow(ContactTagRow row) {
    return ContactTag(id: row.id, profileId: row.profileId, name: row.name);
  }

  ContactNote _noteFromRow(ContactNoteRow row) {
    return ContactNote(
      id: row.id,
      contactId: row.contactId,
      noteText: row.noteText,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
    );
  }

  ContactAvailability _availabilityFromRow(ContactAvailabilityRow row) {
    return ContactAvailability(
      weekday: row.weekday,
      startMinute: row.startMinute,
      endMinute: row.endMinute,
    );
  }

  SavedContactFilter _filterFromRow(SavedContactFilterRow row) {
    final document = SavedContactFilterDocument.decode(row.criteriaJson);
    return SavedContactFilter(
      id: row.id,
      profileId: row.profileId,
      name: row.name,
      isSystem: row.isSystem,
      criteria: document.criteria,
      sortBy:
          ContactSortBy.values.asNameMap()[row.sortBy] ?? ContactSortBy.name,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
      description: document.description,
      displayedFields: document.displayedFields,
    );
  }

  CalendarEventStatus _statusFromRow(String value) {
    return CalendarEventStatus.values.asNameMap()[value] ??
        CalendarEventStatus.scheduled;
  }

  /// Keeps Timeline ordering on the canonical Planner calendar date and
  /// occurrence start. All-day Events have no start minute and therefore sort
  /// at the start of their own Planner day, matching Planner's day model.
  static DateTime _timelineChronology(PlannerDate date, int startMinute) {
    return DateTime(
      date.year,
      date.month,
      date.day,
      startMinute ~/ 60,
      startMinute % 60,
    );
  }

  /// Occurrences at the same factual minute retain a deterministic canonical
  /// identity order instead of falling back to database/insertion order.
  static int _compareTimelineChronology(
    ContactTimelineEntry left,
    ContactTimelineEntry right,
  ) {
    final chronology = left.chronology.compareTo(right.chronology);
    if (chronology != 0) {
      return chronology;
    }
    final identity = (left.eventId ?? left.taskId ?? '').compareTo(
      right.eventId ?? right.taskId ?? '',
    );
    if (identity != 0) {
      return identity;
    }
    return (left.occurrenceId ?? '').compareTo(right.occurrenceId ?? '');
  }

  static String _eventDisplayTitle(
    CalendarEventRow event,
    CalendarEventExceptionRow? exception,
  ) {
    final storedTitle = (exception?.title ?? event.title).trim();
    if (storedTitle.isNotEmpty) {
      return storedTitle;
    }
    final label =
        (exception?.activityTypeLabelSnapshot ??
                event.activityTypeLabelSnapshot)
            ?.trim();
    return label == null || label.isEmpty ? 'Calendar Event' : label;
  }

  static String _occurrenceTimeLabel(
    CalendarEventRow event,
    CalendarEventExceptionRow? exception,
  ) {
    final timing = exception?.timing ?? event.timing;
    if (timing == 'allDay') {
      return 'All day';
    }
    final start = exception?.startMinute ?? event.startMinute;
    final end = exception?.endMinute ?? event.endMinute;
    if (start == null) {
      return '';
    }
    return end == null
        ? _formatMinute(start)
        : '${_formatMinute(start)} – ${_formatMinute(end)}';
  }

  static String _taskTimelineDueLabel(PlannerDate date, int? dueMinute) {
    const monthNames = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final dateLabel = '${monthNames[date.month - 1]} ${date.day}, ${date.year}';
    return dueMinute == null
        ? 'Due $dateLabel'
        : 'Due $dateLabel · ${_formatMinute(dueMinute)}';
  }

  static String? _timelineStatusLabel(
    CalendarEventStatus status, {
    required bool isPast,
    required bool requiresReport,
  }) {
    if (!isPast) {
      // Timeline Future deliberately keeps the factual scheduled lifecycle
      // label beneath its time. Profile Upcoming consumes the same entries but
      // never renders [statusLabel], so this remains Timeline-only.
      return 'Scheduled';
    }
    if (!requiresReport) {
      // A normal passed Event is clean History: title only.  Do not create an
      // outcome or retain the original scheduled status merely because it is
      // now in History.
      return null;
    }
    // Report-required History uses Planner's canonical vocabulary.  Its
    // scheduled state means an actual required report is still unreported.
    return calendarEventStatusLabel(status);
  }

  /// The Timeline's single future predicate mirrors Planner's Event time law:
  /// all-day Events remain current through their Planner day; timed Events
  /// remain current through (but not after) their effective wall-clock end in
  /// their persisted IANA zone.  A malformed legacy timed row falls back to
  /// the prior date-only law rather than hiding a persisted Event.
  static bool _isUpcomingOccurrence({
    required PlannerDate date,
    required String timing,
    required int? endMinute,
    required String? timeZoneId,
    required PlannerDate today,
    required DateTime nowUtc,
  }) {
    if (timing == CalendarEventTiming.allDay.name) {
      return date.compareTo(today) >= 0;
    }
    if (endMinute == null ||
        timeZoneId == null ||
        timeZoneId.isEmpty ||
        !_timelineTimeZones.isValid(timeZoneId)) {
      return date.compareTo(today) >= 0;
    }
    try {
      final endUtc = _timelineTimeZones.wallTimeToUtc(
        date: date,
        minuteOfDay: endMinute,
        timeZoneId: timeZoneId,
      );
      // At the exact end boundary the occurrence has ended.  An in-progress
      // occurrence remains in Future/Profile Upcoming until that point.
      return endUtc.isAfter(nowUtc);
    } on ArgumentError {
      return date.compareTo(today) >= 0;
    }
  }

  static String _formatMinute(int minute) {
    final hour24 = minute ~/ 60;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final minuteText = (minute % 60).toString().padLeft(2, '0');
    final period = hour24 < 12 ? 'AM' : 'PM';
    return '$hour12:$minuteText $period';
  }

  static String _weekdayShort(int weekday) {
    const labels = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return labels[weekday - 1];
  }

  static (String, String) _splitNames(String displayName) {
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) {
      return ('', '');
    }
    if (parts.length == 1) {
      return (parts.first, '');
    }
    return (parts.first, parts.sublist(1).join(' '));
  }
}
