import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

/// One validated live Contact enrichment candidate.  Only identity, current
/// display name and the technical revision timestamp leave this port.
final class ReminderEnrichmentContact {
  const ReminderEnrichmentContact({
    required this.contactId,
    required this.displayName,
    required this.updatedAtUtc,
  });

  final String contactId;
  final String displayName;
  final DateTime updatedAtUtc;
}

/// Narrow read-only port used by enriched delivery to re-resolve the explicitly
/// selected follow-up Contact at posting time.
///
/// Implementations MUST NOT read Timeline, Contact Detail or the historical
/// participant-snapshot fallback; only current live links count.
abstract interface class ReminderEnrichmentSource {
  Future<ReminderEnrichmentContact?> readFollowUpContact({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required String contactId,
  });
}

/// Drift implementation mirroring the active-series-plus-occurrence overlay
/// semantics of `DriftContactRepository._readEffectiveEventContactLinks`, and
/// the existing Task contact link table, with explicit profile checks on both
/// endpoints.
final class DriftReminderEnrichmentSource implements ReminderEnrichmentSource {
  const DriftReminderEnrichmentSource({required this.database});

  static const String _seriesOccurrenceId = 'series';
  static const String _activeStatus = 'active';
  static const String _removedStatus = 'removed';

  final AppDatabase database;

  @override
  Future<ReminderEnrichmentContact?> readFollowUpContact({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required String contactId,
  }) async {
    if (profileId.trim().isEmpty ||
        sourceId.trim().isEmpty ||
        contactId.trim().isEmpty) {
      return null;
    }
    final linked = switch (sourceKind) {
      ReminderSourceKind.calendarEvent => await _hasEffectiveEventLink(
        profileId: profileId,
        eventId: sourceId,
        occurrenceId: occurrenceId,
        contactId: contactId,
      ),
      ReminderSourceKind.task => await _hasTaskLink(
        profileId: profileId,
        taskId: sourceId,
        contactId: contactId,
      ),
      ReminderSourceKind.weeklyReview ||
      ReminderSourceKind.awaitingReport => false,
    };
    if (!linked) return null;
    final contact =
        await (database.select(database.contacts)..where(
              (table) =>
                  table.id.equals(contactId) &
                  table.profileId.equals(profileId) &
                  table.lifecycleState.equals(
                    ContactLifecycleState.active.name,
                  ),
            ))
            .getSingleOrNull();
    if (contact == null) return null;
    return ReminderEnrichmentContact(
      contactId: contact.id,
      displayName: contact.displayName,
      updatedAtUtc: contact.updatedAtUtc,
    );
  }

  Future<bool> _hasEffectiveEventLink({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required String contactId,
  }) async {
    final seriesActive =
        await (database.select(database.eventContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.equals(eventId) &
                  table.occurrenceId.equals(_seriesOccurrenceId) &
                  table.contactId.equals(contactId) &
                  table.status.equals(_activeStatus),
            ))
            .getSingleOrNull();
    var effective = seriesActive != null;
    if (occurrenceId == _seriesOccurrenceId) return effective;
    final exact =
        await (database.select(database.eventContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.eventId.equals(eventId) &
                  table.occurrenceId.equals(occurrenceId) &
                  table.contactId.equals(contactId),
            ))
            .getSingleOrNull();
    if (exact != null) {
      switch (exact.status) {
        case _activeStatus:
          effective = true;
        case _removedStatus:
          effective = false;
      }
    }
    return effective;
  }

  Future<bool> _hasTaskLink({
    required String profileId,
    required String taskId,
    required String contactId,
  }) async {
    final link =
        await (database.select(database.taskContactLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.taskId.equals(taskId) &
                  table.contactId.equals(contactId),
            ))
            .getSingleOrNull();
    return link != null;
  }
}
