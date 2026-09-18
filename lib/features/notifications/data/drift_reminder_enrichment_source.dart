import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/notifications/application/reminder_enrichment_resolver.dart';

/// Astra §15/P19: narrow Drift read port for enrichment validation.
/// Mirrors DriftContactRepository._readEffectiveEventContactLinks
/// (drift_contact_repository.dart:2501) ACTIVE series + exact active/removed
/// occurrence overlay semantics WITHOUT its historical fallback; Task links
/// are filtered explicitly by profile + taskId.  Never calls readTimeline,
/// readContactDetail or readEventPeople.
final class DriftReminderEnrichmentSource implements ReminderEnrichmentSource {
  DriftReminderEnrichmentSource({required this.database});

  final AppDatabase database;

  static const String _series = 'series';
  static const String _activeStatus = 'active';
  static const String _removedStatus = 'removed';
  static const String _activeLifecycle = 'active';

  @override
  Future<EnrichmentContactIdentity?> readActiveContact({
    required String profileId,
    required String contactId,
  }) async {
    final row = await (database.select(database.contacts)
          ..where(
            (table) =>
                table.id.equals(contactId) &
                table.profileId.equals(profileId) &
                table.lifecycleState.equals(_activeLifecycle),
          )
          ..limit(1))
        .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return EnrichmentContactIdentity(
      contactId: row.id,
      displayName: row.displayName,
      updatedAtUtc: row.updatedAtUtc,
    );
  }

  @override
  Future<bool> hasLiveEventLink({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required String contactId,
  }) async {
    // Source existence is part of both-endpoint validation (§7/§15).
    final event = await (database.select(database.calendarEvents)
          ..where(
            (table) =>
                table.id.equals(eventId) &
                table.profileId.equals(profileId),
          )
          ..limit(1))
        .getSingleOrNull();
    if (event == null) {
      return false;
    }
    final effective = await _readEffectiveEventContactLinks(
      profileId: profileId,
      eventId: eventId,
      occurrenceId: occurrenceId,
    );
    return effective.contains(contactId);
  }

  @override
  Future<bool> hasLiveTaskLink({
    required String profileId,
    required String taskId,
    required String contactId,
  }) async {
    final task = await (database.select(database.plannerTasks)
          ..where(
            (table) =>
                table.id.equals(taskId) & table.profileId.equals(profileId),
          )
          ..limit(1))
        .getSingleOrNull();
    if (task == null) {
      return false;
    }
    final link = await (database.select(database.taskContactLinks)
          ..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.taskId.equals(taskId) &
                table.contactId.equals(contactId),
          )
          ..limit(1))
        .getSingleOrNull();
    return link != null;
  }

  @override
  Future<String?> readEventLocationText({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  }) async {
    // Occurrence location resolves override-first: a CalendarEventExceptions
    // row for this exact occurrence carries the override locationText;
    // otherwise the base CalendarEvents.locationText is current truth.
    final exception = await (database.select(database.calendarEventExceptions)
          ..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.eventId.equals(eventId) &
                table.occurrenceId.equals(occurrenceId),
          )
          ..limit(1))
        .getSingleOrNull();
    if (exception != null) {
      final override = exception.locationText?.trim();
      if (override != null && override.isNotEmpty) {
        return override;
      }
    }
    final event = await (database.select(database.calendarEvents)
          ..where(
            (table) =>
                table.id.equals(eventId) & table.profileId.equals(profileId),
          )
          ..limit(1))
        .getSingleOrNull();
    if (event == null) {
      return null;
    }
    final text = event.locationText?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// Series links plus exact active/removed occurrence overlay — same
  /// effective semantics as DriftContactRepository._readEffectiveEventContact
  /// Links, without any historical participation fallback.
  Future<Set<String>> _readEffectiveEventContactLinks({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  }) async {
    final seriesLinks = await (database.select(database.eventContactLinks)
          ..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.eventId.equals(eventId) &
                table.occurrenceId.equals(_series) &
                table.status.equals(_activeStatus),
          ))
        .get();
    final effective = <String>{
      for (final link in seriesLinks) link.contactId,
    };
    if (occurrenceId == _series) {
      return effective;
    }
    final exactLinks = await (database.select(database.eventContactLinks)
          ..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.eventId.equals(eventId) &
                table.occurrenceId.equals(occurrenceId),
          ))
        .get();
    for (final link in exactLinks) {
      if (link.status == _activeStatus) {
        effective.add(link.contactId);
      } else if (link.status == _removedStatus) {
        effective.remove(link.contactId);
      }
    }
    return effective;
  }
}
