import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';

/// The three canonical UNREPORTED tabs (owner law, 2026-09-19).
///
/// The hub is ONE unreported-Event backlog split by canonical linkage:
///
/// * [lifeGoals] — `goalId != null` (manual Life Goal link) OR the
///   occurrence's Event Type is one of the six fixed Goal-linked types
///   (automatic linkage).  Title text is never consulted.
/// * [contacts] — the canonical contact relationship: the Contact Event Type
///   or at least one EFFECTIVE attached Contact link.
/// * [events] — everything remaining.
///
/// Precedence is frozen (Life Goals → Contacts → Events) so each unreported
/// occurrence appears in exactly one tab and the combined row count can never
/// double-count.  Tasks are never part of this backlog.
enum UnreportedTab { lifeGoals, events, contacts }

/// A Contact shown inside an Unreported row.
///
/// Only the live summary and its canonical identity reach this surface: no
/// phone number, email, note, group membership list, tag or availability is
/// carried, and the id is what lets the row hand off to the canonical Contact
/// Profile.  The summary exists so the shared Contact link primitive can keep
/// Next Transfer's existing identity/status presentation (colour + favorite)
/// instead of a neutral placeholder.
final class UnreportedContactRef {
  const UnreportedContactRef({
    required this.contactId,
    required this.displayName,
    required this.contact,
  });

  final String contactId;
  final String displayName;
  final ContactSummary contact;
}

/// One classified unreported occurrence.
final class UnreportedEntry {
  const UnreportedEntry({
    required this.tab,
    required this.event,
    required this.goalId,
    required this.contacts,
  });

  final UnreportedTab tab;
  final AwaitingReportEvent event;

  /// The Event's manual Life Goal link, when any (kept for the row's goal
  /// hand-off and for tests; classification already consumed it).
  final String? goalId;

  /// Effective attached Contacts, deterministically ordered by display name.
  final List<UnreportedContactRef> contacts;
}

/// The frozen exactly-once classification law.  Pure and dependency-free so
/// the hub, the hamburger indicator and the summary notification can never
/// disagree about what "unreported" means.
abstract final class UnreportedClassification {
  /// The six fixed Goal-linked Event Types — the code's own canonical
  /// definition of "an Event linked to a Goal" alongside a manual link.
  static const Set<String> automaticGoalTypeKeys =
      SystemEventTypeKeys.lockedWliTypeKeys;

  static UnreportedTab classify({
    required String? goalId,
    required String? activityTypeStableKey,
    required bool hasEffectiveContacts,
  }) {
    if (goalId != null) {
      return UnreportedTab.lifeGoals;
    }
    if (activityTypeStableKey != null &&
        automaticGoalTypeKeys.contains(activityTypeStableKey)) {
      return UnreportedTab.lifeGoals;
    }
    if (activityTypeStableKey == SystemEventTypeKeys.contact ||
        hasEffectiveContacts) {
      return UnreportedTab.contacts;
    }
    return UnreportedTab.events;
  }
}
