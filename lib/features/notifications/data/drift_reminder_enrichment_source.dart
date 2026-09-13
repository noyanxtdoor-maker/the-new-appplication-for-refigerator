import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/notifications/application/reminder_enrichment_resolver.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

/// VS16-M7 P19 — narrow live-read implementation of [ReminderEnrichmentSource].
///
/// This mirrors `DriftContactRepository._readEffectiveEventContactLinks`
/// semantics (active series links overlaid by the exact occurrence's active /
/// removed rows) but deliberately WITHOUT the historical fallback: it never
/// consults `event_occurrence_participants`, `readTimeline` or
/// `readContactDetail`, so a renamed Contact always reads as its CURRENT name
/// and a removed/unlinked Contact never resolves.
///
/// Every query is profile-scoped.  A read never mutates anything.
final class DriftReminderEnrichmentSource implements ReminderEnrichmentSource {
  const DriftReminderEnrichmentSource({required this.database});

  final AppDatabase database;

  /// Matches `DriftContactRepository.seriesOccurrenceId`.
  static const String seriesOccurrenceId = 'series';
  static const String _activeStatus = 'active';
  static const String _removedStatus = 'removed';
  static const String _activeLifecycle = 'active';

  @override
  Future<String?> currentContactDisplayName({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required String contactId,
  }) async {
    final linked = switch (sourceKind) {
      ReminderSourceKind.calendarEvent => await _eventLinkIsLive(
        profileId: profileId,
        eventId: sourceId,
        occurrenceId: occurrenceId,
        contactId: contactId,
      ),
      ReminderSourceKind.task => await _taskLinkIsLive(
        profileId: profileId,
        taskId: sourceId,
        contactId: contactId,
      ),
      // Planning families never carry Contact follow-up enrichment.
      ReminderSourceKind.weeklyReview ||
      ReminderSourceKind.awaitingReport => false,
    };
    if (!linked) return null;

    final rows =
        await (database.select(database.contacts)..where(
              (table) =>
                  table.id.equals(contactId) &
                  table.profileId.equals(profileId) &
                  table.lifecycleState.equals(_activeLifecycle) &
                  table.mergedIntoContactId.isNull() &
                  table.archivedAtUtc.isNull() &
                  table.deletedAtUtc.isNull(),
            ))
            .get();
    if (rows.length != 1) return null;
    return rows.single.displayName;
  }

  /// Effective live Event link check: active series links overlaid by the exact
  /// occurrence's active (add) and removed (drop) rows.
  Future<bool> _eventLinkIsLive({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required String contactId,
  }) async {
    final seriesLinks =
        await (database.select(database.eventContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.equals(eventId) &
                  table.occurrenceId.equals(seriesOccurrenceId) &
                  table.status.equals(_activeStatus),
            ))
            .get();
    if (occurrenceId == seriesOccurrenceId) {
      return seriesLinks.any((link) => link.contactId == contactId);
    }

    final exactLinks =
        await (database.select(database.eventContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.equals(eventId) &
                  table.occurrenceId.equals(occurrenceId),
            ))
            .get();
    final effective = <String>{
      for (final link in seriesLinks) link.contactId,
    };
    for (final link in exactLinks) {
      if (link.status == _activeStatus) {
        effective.add(link.contactId);
      } else if (link.status == _removedStatus) {
        effective.remove(link.contactId);
      }
    }
    return effective.contains(contactId);
  }

  /// Task links are whole-source: profile + task + contact must all match.
  Future<bool> _taskLinkIsLive({
    required String profileId,
    required String taskId,
    required String contactId,
  }) async {
    final rows =
        await (database.select(database.taskContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.taskId.equals(taskId) &
                  table.contactId.equals(contactId),
            ))
            .get();
    return rows.isNotEmpty;
  }
}
