import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';

/// Optional **Starter Goal** templates.
///
/// A Starter Goal template is NOT a Goal record and NEVER a database row.  It
/// is a compiled, read-only presentation of one canonical Goal slot — the same
/// immutable identity law [CanonicalGoalSlot] already defines — offered to the
/// user only through an explicit select -> configure -> confirm flow.
///
/// Importing a template creates a real Goal exclusively through the canonical
/// `GoalRepository.createGoal` transaction.  Opening or browsing this catalog
/// writes nothing, and no Starter Goal is ever created implicitly.
final class StarterGoalTemplate {
  const StarterGoalTemplate({required this.slot, required this.description});

  /// The canonical slot that owns this template's identity (slot index,
  /// Event Type stable key, indicator key and role come from that law).
  final CanonicalGoalSlot slot;

  /// One-line, user-facing explanation of what the Goal is for.
  final String description;

  /// Stable template identity: the canonical Event Type stable key.
  String get id => slot.eventTypeStableKey;

  String get title => slot.defaultTitle;

  GoalRole get role => slot.role;

  int get slotIndex => slot.slotIndex;

  String get indicatorKey => slot.indicatorKey;

  /// Target fields the canonical Create Goal flow requires for this role.
  bool get needsDailyTarget => role == GoalRole.dailyWeekly;

  /// Every canonical role plans toward a weekly target.
  bool get needsWeeklyTarget => true;

  bool get needsMonthlyTarget => role == GoalRole.weeklyMonthly;
}

const Map<String, String> _starterDescriptions = <String, String>{
  SystemEventTypeKeys.jobApplication:
      'Track applications and follow-ups, day by day.',
  SystemEventTypeKeys.scriptureStudy: 'Set aside regular time to study.',
  SystemEventTypeKeys.exercise: 'Build a steady routine during the week.',
  SystemEventTypeKeys.budgetReview: 'Review your spending each week.',
  SystemEventTypeKeys.meaningfulConnection: 'Reach out and stay connected.',
  SystemEventTypeKeys.templeVisit: 'Plan visits and keep them in view.',
};

/// The six optional Starter Goals.
///
/// Derived from the immutable canonical slot law, so this catalog can never
/// drift from the identity, role and capacity rules that Goal creation and the
/// slot allocator enforce.
List<StarterGoalTemplate> get starterGoalTemplates => <StarterGoalTemplate>[
  for (final slot in CanonicalGoalSlot.all)
    StarterGoalTemplate(
      slot: slot,
      description: _starterDescriptions[slot.eventTypeStableKey]!,
    ),
];

/// Canonical-identity availability for one Starter template.
///
/// A template is unavailable when an ACTIVE Goal already holds its canonical
/// identity — the slot index, the assigned Event Type stable key, or the
/// indicator key.  This is the ONLY duplicate/occupancy law: display names are
/// never matched, and nothing is ever overwritten.
///
/// Archived and deleted Goals never block a template: the canonical slot
/// allocator treats those slots as free, so a replacement Goal is legitimate
/// and the archived identity keeps its own history.
bool starterTemplateIsAvailable(
  StarterGoalTemplate template,
  Iterable<Goal> activeGoals,
) {
  for (final goal in activeGoals) {
    if (goal.status != GoalStatus.active) {
      continue;
    }
    if (goal.activeSlotIndex == template.slotIndex) {
      return false;
    }
    if (goal.assignedEventTypeStableKey == template.slot.eventTypeStableKey) {
      return false;
    }
    if (goal.indicatorKey == template.indicatorKey) {
      return false;
    }
  }
  return true;
}

/// The templates that can still be imported for [activeGoals], in canonical
/// slot order.  Used by the Starter Goals screen so already-owned identities
/// are shown as unavailable instead of being silently re-created.
List<StarterGoalTemplate> availableStarterGoalTemplates(
  Iterable<Goal> activeGoals,
) {
  return <StarterGoalTemplate>[
    for (final template in starterGoalTemplates)
      if (starterTemplateIsAvailable(template, activeGoals)) template,
  ];
}
