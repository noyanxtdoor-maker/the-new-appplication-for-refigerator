import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';

/// PLANNING ATTENTION (owner law, 2026-09-20).
///
/// The Home hamburger carries a small red dot — never a number — whenever
/// either PLANNING destination has something in it:
///
///   hamburgerAttention = incompleteTaskCount > 0 || unreportedCount > 0
///
/// It is derived from the two canonical counts the drawer badges already use,
/// so the icon and the badges can never disagree.  Messages unread state
/// deliberately does NOT feed it: the Home bell keeps its own independent dot.
///
/// The value is an [AsyncValue] on purpose.  The Task count re-reads after a
/// mutation, and a listener must be able to keep its last known answer while
/// that read is in flight instead of flashing the dot off and on.
final planningAttentionRequiredProvider = Provider<AsyncValue<bool>>((ref) {
  final incompleteTasks = ref.watch(incompleteTaskCountProvider);
  if (!incompleteTasks.hasValue) {
    return const AsyncValue<bool>.loading();
  }
  final unreported = ref.watch(unreportedCountProvider);
  return AsyncValue<bool>.data(
    (incompleteTasks.value ?? 0) > 0 || unreported > 0,
  );
});
