import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/contacts/application/contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

final contactRepositoryProvider = Provider<ContactRepository>((ref) {
  throw StateError('ContactRepository must be overridden at the app root');
});

final contactProfileIdProvider = Provider<String>((ref) {
  final startup = ref.read(startupControllerProvider);
  if (startup is! StartupReady) {
    throw StateError('Contacts require a ready Local Profile');
  }
  return startup.profile.id;
});

final contactChangesProvider = StreamProvider.family<int, String>((
  ref,
  profileId,
) {
  return ref.read(contactRepositoryProvider).watchChanges(profileId);
});

// ---------------------------------------------------------------------------
// Main Contacts list controller
// ---------------------------------------------------------------------------

enum ContactsLoadStatus { loading, ready, failure }

final class ContactsState {
  const ContactsState({
    required this.status,
    required this.criteria,
    required this.viewCriteria,
    required this.sortBy,
    required this.contacts,
    this.standardView,
    this.appliedFilter,
    this.displayedFieldsOverride,
    this.message,
  });

  final ContactsLoadStatus status;
  final ContactFilterCriteria criteria;
  final ContactFilterCriteria viewCriteria;
  final ContactSortBy sortBy;
  final List<ContactSummary> contacts;
  final ContactStandardView? standardView;
  final SavedContactFilter? appliedFilter;

  /// Transient Contacts-home presentation choice. It is deliberately not
  /// persisted and never changes filter/base-view truth.
  final List<ContactDisplayedField>? displayedFieldsOverride;
  final String? message;

  ContactsState copyWith({
    ContactsLoadStatus? status,
    ContactFilterCriteria? criteria,
    ContactFilterCriteria? viewCriteria,
    ContactSortBy? sortBy,
    List<ContactSummary>? contacts,
    SavedContactFilter? appliedFilter,
    List<ContactDisplayedField>? displayedFieldsOverride,
    String? message,
    bool clearMessage = false,
    bool clearAppliedFilter = false,
    ContactStandardView? standardView,
    bool clearStandardView = false,
    bool clearDisplayedFieldsOverride = false,
    bool replaceViewCriteria = false,
  }) {
    return ContactsState(
      status: status ?? this.status,
      criteria: criteria ?? this.criteria,
      viewCriteria: replaceViewCriteria
          ? viewCriteria ?? this.viewCriteria
          : this.viewCriteria,
      sortBy: sortBy ?? this.sortBy,
      contacts: contacts ?? this.contacts,
      standardView: clearStandardView
          ? null
          : standardView ?? this.standardView,
      appliedFilter: clearAppliedFilter
          ? null
          : appliedFilter ?? this.appliedFilter,
      displayedFieldsOverride: clearDisplayedFieldsOverride
          ? null
          : displayedFieldsOverride ?? this.displayedFieldsOverride,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}

final contactsControllerProvider =
    NotifierProvider<ContactsController, ContactsState>(ContactsController.new);

final class ContactsController extends Notifier<ContactsState> {
  int _generation = 0;
  Future<void>? _activeLoad;
  bool _reloadDirty = false;

  ContactRepository get _repository => ref.read(contactRepositoryProvider);

  String get _profileId {
    final startup = ref.read(startupControllerProvider);
    if (startup is! StartupReady) {
      throw StateError('Contacts require a ready Local Profile');
    }
    return startup.profile.id;
  }

  @override
  ContactsState build() {
    ref.onDispose(() => _generation++);
    final profileId = _profileId;
    ref.listen(contactChangesProvider(profileId), (_, _) {
      unawaited(refresh());
    });
    unawaited(Future<void>.microtask(_requestLoad));
    return const ContactsState(
      status: ContactsLoadStatus.loading,
      criteria: ContactFilterCriteria(),
      viewCriteria: ContactFilterCriteria(),
      sortBy: ContactSortBy.name,
      contacts: <ContactSummary>[],
      standardView: ContactStandardView(filter: ContactStandardFilter.status),
    );
  }

  Future<void> _load() async {
    final generation = ++_generation;
    state = state.copyWith(
      status: ContactsLoadStatus.loading,
      clearMessage: true,
    );
    try {
      final contacts = await _repository.readContacts(
        profileId: _profileId,
        criteria: state.criteria,
        sortBy: state.sortBy,
        today: ref.read(plannerDateSourceProvider).today(),
        standardView: state.standardView,
      );
      if (generation != _generation) {
        return;
      }
      state = state.copyWith(
        status: ContactsLoadStatus.ready,
        contacts: contacts,
        clearMessage: true,
      );
    } on Object {
      if (generation != _generation) {
        return;
      }
      state = state.copyWith(
        status: ContactsLoadStatus.failure,
        message: 'Contacts could not be opened. Retry without data loss.',
      );
    }
  }

  Future<void> refresh() => _requestLoad();

  /// M4 P03: collapse pulse bursts to one active read plus, when needed, one
  /// trailing read of the final criteria/source state. Generation checks in
  /// [_load] remain the durable state-publication guard.
  Future<void> _requestLoad() {
    if (_activeLoad != null) {
      _reloadDirty = true;
      return _activeLoad!;
    }
    late final Future<void> active;
    active = () async {
      do {
        _reloadDirty = false;
        await _load();
      } while (_reloadDirty);
    }();
    _activeLoad = active;
    return active.whenComplete(() {
      if (identical(_activeLoad, active)) _activeLoad = null;
    });
  }

  void applyFilter(
    ContactFilterCriteria criteria, {
    SavedContactFilter? appliedFilter,
    bool clearAppliedFilter = false,
    bool updateCurrentView = true,
  }) {
    state = state.copyWith(
      criteria: criteria,
      appliedFilter: appliedFilter,
      clearAppliedFilter: clearAppliedFilter,
      clearStandardView: true,
      clearDisplayedFieldsOverride: true,
      viewCriteria: criteria,
      replaceViewCriteria: updateCurrentView,
    );
    unawaited(_requestLoad());
  }

  void applyStandardView(ContactStandardView standardView) {
    state = state.copyWith(
      criteria: const ContactFilterCriteria(),
      viewCriteria: const ContactFilterCriteria(),
      replaceViewCriteria: true,
      standardView: standardView,
      clearAppliedFilter: true,
      clearDisplayedFieldsOverride: true,
    );
    unawaited(_requestLoad());
  }

  /// Applies a compact-rail data criterion without replacing the current
  /// Status/All/saved base view. The baseline is retained for funnel reset.
  void applyQuickFilter(ContactFilterCriteria criteria) {
    state = state.copyWith(criteria: criteria);
    unawaited(_requestLoad());
  }

  void setDisplayedFieldsOverride(List<ContactDisplayedField>? fields) {
    state = state.copyWith(displayedFieldsOverride: fields);
  }

  void setSort(ContactSortBy sortBy) {
    state = state.copyWith(sortBy: sortBy);
    unawaited(_requestLoad());
  }

  /// Removes temporary quick-filter changes while retaining the selected
  /// current view and its saved-filter identity.
  void clearAdHocFilters() {
    final baseline = state.viewCriteria;
    state = state.copyWith(
      criteria: baseline,
      clearDisplayedFieldsOverride: true,
    );
    unawaited(_requestLoad());
  }

  void clearMessage() {
    state = state.copyWith(clearMessage: true);
  }
}

// ---------------------------------------------------------------------------
// Read-only data providers
// ---------------------------------------------------------------------------

final contactGroupsProvider = FutureProvider<List<ContactGroup>>((ref) async {
  final profileId = ref.read(contactProfileIdProvider);
  ref.watch(contactChangesProvider(profileId));
  // Groups are user-owned records. Never seed or recreate an arbitrary
  // catalog while reading: a group the user permanently deletes must remain
  // deleted across Contacts and Settings. Legacy archived rows are included
  // so the manager can expose them for manual deletion; assignment surfaces
  // filter them out.
  return ref
      .read(contactRepositoryProvider)
      .readGroups(profileId, includeArchived: true);
});

final contactTimelineEventChangesProvider =
    StreamProvider.autoDispose.family<int, String>((ref, profileId) {
      return ref
          .read(contactRepositoryProvider)
          .watchTimelineEventChanges(profileId);
    });

/// The Group manager projects active primary membership only. Dormant legacy
/// memberships remain stored and are never promoted by this management UI.
final contactGroupMembersProvider =
    FutureProvider.family<List<ContactSummary>, String>((ref, groupId) async {
  final profileId = ref.read(contactProfileIdProvider);
  ref.watch(contactChangesProvider(profileId));
  final summaries = await ref.read(contactRepositoryProvider).readContacts(
    profileId: profileId,
    criteria: const ContactFilterCriteria(),
    sortBy: ContactSortBy.name,
    today: ref.read(plannerDateSourceProvider).today(),
  );
  return summaries
      .where((summary) => summary.primaryGroup?.id == groupId)
      .toList(growable: false);
});

final contactGroupMemberCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  final profileId = ref.read(contactProfileIdProvider);
  ref.watch(contactChangesProvider(profileId));
  final summaries = await ref.read(contactRepositoryProvider).readContacts(
    profileId: profileId,
    criteria: const ContactFilterCriteria(),
    sortBy: ContactSortBy.name,
    today: ref.read(plannerDateSourceProvider).today(),
  );
  final counts = <String, int>{};
  for (final summary in summaries) {
    final groupId = summary.primaryGroup?.id;
    if (groupId != null) {
      counts.update(groupId, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  return counts;
});

final contactTagsProvider = FutureProvider<List<ContactTag>>((ref) {
  final profileId = ref.read(contactProfileIdProvider);
  ref.watch(contactChangesProvider(profileId));
  return ref.read(contactRepositoryProvider).readTags(profileId);
});

final savedContactFiltersProvider = FutureProvider<List<SavedContactFilter>>((
  ref,
) {
  final profileId = ref.read(contactProfileIdProvider);
  ref.watch(contactChangesProvider(profileId));
  return ref.read(contactRepositoryProvider).readSavedFilters(profileId);
});

final contactStatusBucketsProvider = FutureProvider<List<ContactStatusBucket>>((
  ref,
) {
  final profileId = ref.read(contactProfileIdProvider);
  ref.watch(contactChangesProvider(profileId));
  return ref
      .read(contactRepositoryProvider)
      .readAvailableStatusBuckets(profileId: profileId);
});

final contactDetailProvider = FutureProvider.family<ContactDetail, String>((
  ref,
  contactId,
) {
  final profileId = ref.read(contactProfileIdProvider);
  ref.watch(contactChangesProvider(profileId));
  return ref
      .read(contactRepositoryProvider)
      .readContactDetail(profileId: profileId, contactId: contactId);
});

/// A route-scoped Timeline refresh pulse.  Contacts remain stream-driven for
/// persisted writes; this tiny visible-read invalidation handles the one fact
/// that changes without a write: a timed Event crossing its end boundary.
///
/// It deliberately has no background service or Event store.  Nothing watches
/// it except [contactTimelineProvider] while a Contact Detail Timeline exists.
final contactTimelineClockProvider = StreamProvider.autoDispose<DateTime>((
  ref,
) {
  late final StreamController<DateTime> controller;
  Timer? timer;
  controller = StreamController<DateTime>(
    onListen: () {
      controller.add(DateTime.now().toUtc());
      timer = Timer.periodic(const Duration(seconds: 15), (_) {
        controller.add(DateTime.now().toUtc());
      });
    },
    onCancel: () => timer?.cancel(),
  );
  ref.onDispose(() {
    timer?.cancel();
    unawaited(controller.close());
  });
  return controller.stream;
});

final contactTimelineProvider = FutureProvider.family<ContactTimeline, String>((
  ref,
  contactId,
) {
  final profileId = ref.read(contactProfileIdProvider);
  ref.watch(contactChangesProvider(profileId));
  ref.watch(contactTimelineEventChangesProvider(profileId));
  ref.watch(contactTimelineClockProvider);
  return ref
      .read(contactRepositoryProvider)
      .readTimeline(
        profileId: profileId,
        contactId: contactId,
        today: ref.read(plannerDateSourceProvider).today(),
      );
});

final commonEventPatternsProvider =
    FutureProvider.family<List<CommonEventPattern>, String>((ref, contactId) async {
      final timeline = await ref.watch(contactTimelineProvider(contactId).future);
      return commonEventPatternsFromTimeline(timeline);
    });

final eventPeopleProvider =
    FutureProvider.family<
      List<ContactSummary>,
      ({String eventId, String occurrenceId})
    >((ref, key) {
      final profileId = ref.read(contactProfileIdProvider);
      ref.watch(contactChangesProvider(profileId));
      return ref
          .read(contactRepositoryProvider)
          .readEventPeople(
            profileId: profileId,
            eventId: key.eventId,
            occurrenceId: key.occurrenceId,
            today: ref.read(plannerDateSourceProvider).today(),
          );
    });

final taskContactsProvider =
    FutureProvider.family<List<ContactSummary>, String>((ref, taskId) {
      final profileId = ref.read(contactProfileIdProvider);
      ref.watch(contactChangesProvider(profileId));
      return ref
          .read(contactRepositoryProvider)
          .readTaskContacts(profileId: profileId, taskId: taskId);
    });

final contactUpcomingTasksProvider =
    FutureProvider.family<List<PlannerTask>, String>((ref, contactId) {
      final profileId = ref.read(contactProfileIdProvider);
      ref.watch(contactChangesProvider(profileId));
      return ref
          .read(contactRepositoryProvider)
          .readContactUpcomingTasks(profileId: profileId, contactId: contactId);
    });

final duplicateCandidatesProvider = FutureProvider<List<List<Contact>>>((ref) {
  final profileId = ref.read(contactProfileIdProvider);
  ref.watch(contactChangesProvider(profileId));
  return ref.read(contactRepositoryProvider).readDuplicateCandidates(profileId);
});

/// Summaries for a stable comma-separated contact ID list.  Used by the
/// Event form People section to render the current draft selection without
/// holding repository futures inside widget state.
final contactSummariesByCsvProvider =
    FutureProvider.family<Map<String, ContactSummary>, String>((ref, csv) {
      final ids = csv
          .split(',')
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      if (ids.isEmpty) {
        return Future<Map<String, ContactSummary>>.value(
          const <String, ContactSummary>{},
        );
      }
      final profileId = ref.read(contactProfileIdProvider);
      ref.watch(contactChangesProvider(profileId));
      return ref
          .read(contactRepositoryProvider)
          .readContactsByIds(
            profileId: profileId,
            contactIds: ids,
            today: ref.read(plannerDateSourceProvider).today(),
          );
    });
