import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

@immutable
final class EventScheduleConflictRangeKey {
  const EventScheduleConflictRangeKey({
    required this.profileId,
    required this.startDate,
    required this.endDate,
    required this.displayTimeZoneId,
  });

  final String profileId;
  final PlannerDate startDate;
  final PlannerDate endDate;
  final String displayTimeZoneId;

  @override
  bool operator ==(Object other) {
    return other is EventScheduleConflictRangeKey &&
        other.profileId == profileId &&
        other.startDate == startDate &&
        other.endDate == endDate &&
        other.displayTimeZoneId == displayTimeZoneId;
  }

  @override
  int get hashCode =>
      Object.hash(profileId, startDate, endDate, displayTimeZoneId);
}

/// One canonical bounded occurrence read per civil window. Time/title/note
/// edits reuse the family's latest list and run the pure O(n) scan locally.
final eventScheduleConflictCandidatesProvider = FutureProvider.autoDispose
    .family<List<PlannerCalendarItem>, EventScheduleConflictRangeKey>((
      ref,
      key,
    ) async {
      final startup = ref.watch(startupControllerProvider);
      if (startup is! StartupReady || startup.profile.id != key.profileId) {
        return const <PlannerCalendarItem>[];
      }
      // Outcome-report writes can make a scheduled row terminal without
      // changing the Event table; Event/exception changes use the narrower
      // timeline stream. Neither stream performs a Contact join.
      ref.watch(contactChangesProvider(key.profileId));
      ref.watch(contactTimelineEventChangesProvider(key.profileId));
      ref.watch(
        plannerControllerProvider.select(
          (state) => state.eventDeletionRevision,
        ),
      );
      final repository = ref.watch(calendarEventRepositoryProvider);
      if (repository is! CalendarEventRangeSource) {
        return const <PlannerCalendarItem>[];
      }
      final candidates = await (repository as CalendarEventRangeSource)
          .readRange(
            profileId: key.profileId,
            startDate: key.startDate,
            endDate: key.endDate,
          );
      final currentStartup = ref.read(startupControllerProvider);
      if (currentStartup is! StartupReady ||
          currentStartup.profile.id != key.profileId) {
        return const <PlannerCalendarItem>[];
      }
      final planner = ref.read(plannerControllerProvider.notifier);
      return candidates
          .where((candidate) => !planner.isPendingEventDeletion(candidate))
          .toList(growable: false);
    });
