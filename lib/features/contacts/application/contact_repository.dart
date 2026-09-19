import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

abstract interface class ContactRepository {
  /// Emits a monotonic counter on every underlying-table change.
  ///
  /// The value is deliberately non-`void`: Riverpod 3 treats consecutive
  /// identical [AsyncData] states as equal and skips notifying listeners, so
  /// a `Stream<void>` would swallow every change after the first and live
  /// refresh would stop after the first emission.
  Stream<int> watchChanges(String profileId);

  /// Emits only when Event state that can affect a Contact Timeline changes.
  ///
  /// This is intentionally separate from [watchChanges] so Event writes do
  /// not broadly reload the Contacts list or Contact Profile.
  Stream<int> watchTimelineEventChanges(String profileId);

  // -- Contacts -------------------------------------------------------------
  Future<Contact> createContact({
    required String profileId,
    required ContactDraft draft,
  });

  Future<Contact> updateContact({
    required String profileId,
    required String contactId,
    required ContactDraft draft,
  });

  /// Narrow C5 section save. It changes only the identity and method facts
  /// owned by Contact Information, never hidden Tags, Groups, availability,
  /// notes, address, map coordinate, or favorite state.
  Future<Contact> updateContactIdentityAndMethods({
    required String profileId,
    required String contactId,
    required String firstName,
    required String lastName,
    required String displayName,
    required ContactPreferredMethod preferredContactMethod,
    required List<ContactMethodDraft> methods,
  });

  /// Narrow C5 section save for the text address. Coordinates remain owned by
  /// MapCoordinateRepository and are deliberately not inferred or rewritten.
  Future<Contact> updateContactAddress({
    required String profileId,
    required String contactId,
    String? addressText,
  });

  Future<ContactDetail> readContactDetail({
    required String profileId,
    required String contactId,
  });

  /// Records the successful opening of a Contact detail route without
  /// changing the Contact's edit/update timestamp.
  Future<void> markContactViewed({
    required String profileId,
    required String contactId,
  });

  Future<Contact> setFavorite({
    required String profileId,
    required String contactId,
    required bool favorite,
  });

  Future<void> archiveContact({
    required String profileId,
    required String contactId,
  });

  Future<Contact> restoreContact({
    required String profileId,
    required String contactId,
  });

  /// Recoverable deletion only.  The Contact row and every linked historical
  /// owner stay intact; this release deliberately has no hard-purge API.
  Future<void> moveContactsToRecentlyDeleted({
    required String profileId,
    required Iterable<String> contactIds,
  });

  Future<Contact> restoreRecentlyDeletedContact({
    required String profileId,
    required String contactId,
  });

  Future<List<ContactSummary>> readLifecycleContacts({
    required String profileId,
    required ContactLifecycleState lifecycleState,
    required PlannerDate today,
  });

  /// All active Contacts plus the one bounded method projection needed to
  /// pre-filter a purpose-specific external Text or Email action.
  Future<List<ContactRecipientCandidate>> readRecipientCandidates({
    required String profileId,
  });

  /// Active list rows for the current view.  Group/tag labels are joined in
  /// a bounded query set and event context is batched for the returned rows,
  /// so hundreds of Contacts render without N+1 reads.
  Future<List<ContactSummary>> readContacts({
    required String profileId,
    required ContactFilterCriteria criteria,
    required ContactSortBy sortBy,
    required PlannerDate today,
    ContactStandardView? standardView,
    String? query,
  });

  /// Returns only Status buckets with one or more eligible Contacts.
  Future<List<ContactStatusBucket>> readAvailableStatusBuckets({
    required String profileId,
  });

  Future<List<ContactSummary>> searchContacts({
    required String profileId,
    required String query,
    required PlannerDate today,
  });

  /// Summaries for an explicit Contact ID list (e.g. an Event People draft
  /// held outside the repository).  Archived and merged rows resolve too so a
  /// saved selection never silently disappears from view.
  Future<Map<String, ContactSummary>> readContactsByIds({
    required String profileId,
    required List<String> contactIds,
    required PlannerDate today,
  });

  // -- Groups ---------------------------------------------------------------
  Future<List<ContactGroup>> readGroups(
    String profileId, {
    bool includeArchived = false,
  });

  Future<ContactGroup> createGroup({
    required String profileId,
    required String name,
    required int colorValue,
  });

  Future<ContactGroup> updateGroup({
    required String profileId,
    required String groupId,
    required String name,
    required int colorValue,
  });

  /// The explicit, user-initiated canonical defaults action behind both
  /// "Use default groups" and "Restore default groups".
  ///
  /// Additive by default: creates any missing canonical built-in Group and
  /// leaves every other row — custom names, custom colours, the legacy `Other`
  /// row, and all Contact memberships — exactly as they are. When
  /// [restoreCanonicalValues] is true the canonical rows' name, order and
  /// colour are re-applied to their canonical ids (and only to those ids).
  ///
  /// Never throws on a same-name collision: the clash is reported in
  /// [ContactGroupDefaultsOutcome.collidingNames] so the UI can explain it.
  Future<ContactGroupDefaultsOutcome> applyDefaultGroups(
    String profileId, {
    bool restoreCanonicalValues = false,
  });

  /// Permanently deletes a user-managed group and its Contact memberships.
  /// Contacts themselves are retained without that group.
  Future<void> hardDeleteGroup({
    required String profileId,
    required String groupId,
  });

  /// Replaces a Contact's group memberships and enforces a single primary
  /// group within the same transaction. Dormant legacy secondary memberships
  /// are preserved (never bulk-deleted) per the C2 one-group V1 law.
  Future<void> setContactGroups({
    required String profileId,
    required String contactId,
    required List<String> groupIds,
    String? primaryGroupId,
  });

  /// Removes only this exact Contact-to-Group membership.  It never deletes
  /// the Contact or any of its other (including dormant legacy) memberships.
  Future<void> removeContactFromGroup({
    required String profileId,
    required String contactId,
    required String groupId,
  });

  /// Idempotently ensures the four built-in default ContactGroup rows exist
  /// for [profileId] with deterministic UUIDv5 identity. Collision-safe: if a
  /// real row already uses one of the built-in names but NOT the expected
  /// built-in identity, no mutation is performed for that group and a
  /// [ContactValidationException] is thrown (the caller must STOP C2).
  Future<void> ensureBuiltInGroups(String profileId);

  /// Restores the four real built-in default group colors to their approved
  /// defaults. Custom (non-built-in) groups are never touched.
  Future<void> restoreBuiltInGroupColorDefaults(String profileId);

  // -- Tags -----------------------------------------------------------------
  Future<List<ContactTag>> readTags(String profileId);

  // -- Notes ----------------------------------------------------------------
  Future<ContactNote> addNote({
    required String profileId,
    required String contactId,
    required String text,
  });

  Future<ContactNote> updateNote({
    required String profileId,
    required String noteId,
    required String text,
  });

  Future<void> deleteNote({required String profileId, required String noteId});

  // -- Availability ---------------------------------------------------------
  Future<void> setAvailability({
    required String profileId,
    required String contactId,
    required List<ContactAvailability> windows,
  });

  // -- Saved filters --------------------------------------------------------
  Future<List<SavedContactFilter>> readSavedFilters(String profileId);

  Future<SavedContactFilter> saveSavedFilter({
    required String profileId,
    required SavedContactFilterDraft draft,
  });

  Future<SavedContactFilter> updateSavedFilter({
    required String profileId,
    required String filterId,
    required SavedContactFilterDraft draft,
  });

  Future<void> deleteSavedFilter({
    required String profileId,
    required String filterId,
  });

  // -- Planner links --------------------------------------------------------
  /// Replaces the people on [eventId] for [occurrenceId] (`series` or a
  /// specific occurrence identity).  Historical occurrences are frozen into
  /// participant snapshots BEFORE any series-level removal, so a future
  /// People edit can never rewrite history.
  Future<void> setEventPeople({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    PlannerDate? originalDate,
    required List<String> contactIds,
    List<String> explicitlyRemovedSeriesContactIds = const <String>[],
  });

  Future<List<ContactSummary>> readEventPeople({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required PlannerDate today,
  });

  Future<List<EventParticipantPresentation>> readEventParticipantPresentation({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required bool historical,
  });

  /// The EFFECTIVE live Contact ids for one Event occurrence: series `active`
  /// links overlaid by the exact occurrence's active/removed rows, and
  /// deliberately WITHOUT the historical fallback [readEventPeople] keeps.
  ///
  /// Exposed on the interface because reminder transport selection needs the
  /// same live-link truth the People section renders: a source with attached
  /// People has to be delivered by the live-read transport, otherwise the
  /// attached names could never appear in a notification.
  Future<Set<String>> readEffectiveEventContactIds({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  });

  Future<void> setTaskContacts({
    required String profileId,
    required String taskId,
    required List<String> contactIds,
  });

  Future<List<ContactSummary>> readTaskContacts({
    required String profileId,
    required String taskId,
  });

  /// Incomplete Tasks linked to a Contact, for the Profile Upcoming section.
  Future<List<PlannerTask>> readContactUpcomingTasks({
    required String profileId,
    required String contactId,
  });

  // -- Timeline -------------------------------------------------------------
  Future<ContactTimeline> readTimeline({
    required String profileId,
    required String contactId,
    required PlannerDate today,
  });

  Future<List<CommonEventPattern>> readCommonEventPatterns({
    required String profileId,
    required String contactId,
  });

  // -- Merge / duplicates ---------------------------------------------------
  Future<List<List<Contact>>> readDuplicateCandidates(String profileId);

  Future<ContactMergePlan> readMergePlan({
    required String profileId,
    required String survivorId,
    required List<String> absorbedIds,
  });

  Future<Contact> mergeContacts({
    required String profileId,
    required String survivorId,
    required List<String> absorbedIds,
    required ContactMergeChoices choices,
  });

  // -- Device import --------------------------------------------------------
  Future<ContactImportResult> importDeviceContacts({
    required String profileId,
    required List<DeviceContactDraft> drafts,
  });
}
