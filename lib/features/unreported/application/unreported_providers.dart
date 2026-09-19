import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';

/// The single canonical UNREPORTED backlog (owner law, 2026-09-19).
///
/// ONE provider is the source of truth for the hamburger red number, the
/// summary-notification count and the combined rows across the Life Goals +
/// Events + Contacts tabs, so those three can never disagree.
///
/// Freshness: the provider watches the Contact change stream (Contacts,
/// links, Tasks and outcome reports), the Event-timeline stream (Events and
/// occurrence exceptions) and the Goal change stream (rename/archive/delete),
/// which together cover every table a classified row reads.  A source that
/// cannot supply the awaiting-report backlog has an EMPTY hub — never an
/// "everything is unreported" fallback.
final unreportedEntriesProvider = FutureProvider<List<UnreportedEntry>>((
  ref,
) async {
  final startup = ref.read(startupControllerProvider);
  if (startup is! StartupReady) {
    return const <UnreportedEntry>[];
  }
  final profileId = startup.profile.id;
  ref.watch(contactChangesProvider(profileId));
  ref.watch(contactTimelineEventChangesProvider(profileId));
  ref.watch(goalChangesProvider(profileId));

  final repository = ref.read(calendarEventRepositoryProvider);
  if (repository is! CalendarEventAwaitingReportSource) {
    return const <UnreportedEntry>[];
  }
  final backlog = await (repository as CalendarEventAwaitingReportSource)
      .readAwaitingReportEvents(
        profileId: profileId,
        today: ref.read(plannerDateSourceProvider).today(),
        nowUtc: DateTime.now().toUtc(),
      );
  if (backlog.isEmpty) {
    return const <UnreportedEntry>[];
  }

  final contacts = ref.read(contactRepositoryProvider);
  final today = ref.read(plannerDateSourceProvider).today();
  final effectiveByOccurrence = <String, Set<String>>{};
  final allContactIds = <String>{};
  for (final event in backlog) {
    final eventId = event.item.eventId;
    if (eventId == null) {
      continue;
    }
    final ids = await contacts.readEffectiveEventContactIds(
      profileId: profileId,
      eventId: eventId,
      occurrenceId: event.item.id,
    );
    if (ids.isEmpty) {
      continue;
    }
    effectiveByOccurrence[event.item.id] = ids;
    allContactIds.addAll(ids);
  }
  final Map<String, ContactSummary> summaries;
  if (allContactIds.isEmpty) {
    summaries = const <String, ContactSummary>{};
  } else {
    summaries = await contacts.readContactsByIds(
      profileId: profileId,
      contactIds: allContactIds.toList(growable: false),
      today: today,
    );
  }

  final entries = <UnreportedEntry>[];
  for (final event in backlog) {
    final ids = effectiveByOccurrence[event.item.id] ?? const <String>{};
    // Only a LIVE Contact resolves to a row reference: an archived, merged,
    // deleted or otherwise inactive Contact keeps its canonical link (so the
    // Event is still contact-related) but never renders as a stale name.
    final references = <UnreportedContactRef>[
      for (final id in ids)
        if (_liveContact(summaries[id]?.contact) case final contact?)
          UnreportedContactRef(
            contactId: contact.id,
            displayName: contact.displayName,
            contact: summaries[id]!,
          ),
    ]..sort((left, right) {
      final byName = left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      );
      return byName != 0 ? byName : left.contactId.compareTo(right.contactId);
    });
    entries.add(
      UnreportedEntry(
        tab: UnreportedClassification.classify(
          goalId: event.goalId,
          activityTypeStableKey: event.activityTypeStableKey,
          hasEffectiveContacts: ids.isNotEmpty,
        ),
        event: event,
        goalId: event.goalId,
        contacts: List<UnreportedContactRef>.unmodifiable(references),
      ),
    );
  }
  return List<UnreportedEntry>.unmodifiable(entries);
});

/// The ONE number: hamburger indicator, summary notification and hub rows.
final unreportedCountProvider = Provider<int>((ref) {
  return ref.watch(unreportedEntriesProvider).value?.length ?? 0;
});

/// Entries for one tab, in canonical backlog order (oldest occurrence first).
final unreportedEntriesForTabProvider =
    Provider.family<List<UnreportedEntry>, UnreportedTab>((ref, tab) {
      final entries =
          ref.watch(unreportedEntriesProvider).value ??
          const <UnreportedEntry>[];
      return entries
          .where((entry) => entry.tab == tab)
          .toList(growable: false);
    });

Contact? _liveContact(Contact? contact) {
  if (contact == null) return null;
  if (contact.lifecycleState != ContactLifecycleState.active) return null;
  if (contact.mergedIntoContactId != null) return null;
  if (contact.archivedAtUtc != null) return null;
  if (contact.deletedAtUtc != null) return null;
  return contact.displayName.trim().isEmpty ? null : contact;
}
