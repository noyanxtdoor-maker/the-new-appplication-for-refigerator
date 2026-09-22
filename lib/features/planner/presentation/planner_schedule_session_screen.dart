import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/planner/application/planner_schedule_session_provider.dart';
import 'package:rmplanner/features/planner/domain/planner_schedule_session.dart';
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';

/// P3 (2026-09-22) — the temporary scheduling session the Event form opens.
///
/// OWNER LAW: this reuses the EXISTING Planner timeline; it is not a second
/// scheduler.  The provisional block is the very same draggable/resizable
/// timeline item the Planner already paints, and the session's move/resize
/// callbacks write into [plannerScheduleSessionProvider] rather than into any
/// repository — so a session cannot save an Event, submit a report, move a
/// recurrence, or create a row.
///
/// `Confirm` pops with the [PlannerScheduleResult]; the form that pushed this
/// route stays open beneath it and applies the result to its own draft. The
/// ordinary form Save remains the only persistence boundary.
final class PlannerScheduleSessionScreen extends ConsumerWidget {
  const PlannerScheduleSessionScreen({super.key});

  static const Key screenKey = Key('planner-schedule-session-screen');
  static const Key confirmKey = Key('planner-schedule-session-confirm');
  static const Key cancelKey = Key('planner-schedule-session-cancel');

  void _confirm(BuildContext context, WidgetRef ref) {
    final result = ref.read(plannerScheduleSessionProvider.notifier).confirm();
    Navigator.of(context).pop(result);
  }

  void _cancel(BuildContext context, WidgetRef ref) {
    ref.read(plannerScheduleSessionProvider.notifier).clear();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(plannerScheduleSessionProvider);
    return PopScope<void>(
      // Android/app back is a CANCEL: the session is discarded and the form's
      // draft is left exactly as it was before the session opened.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        _cancel(context, ref);
      },
      child: Scaffold(
        key: screenKey,
        appBar: AppBar(
          title: const Text('Adjust schedule'),
          leading: TextButton(
            key: cancelKey,
            onPressed: () => _cancel(context, ref),
            child: const Text('Cancel'),
          ),
          leadingWidth: 88,
          actions: <Widget>[
            TextButton(
              key: confirmKey,
              onPressed: session == null ? null : () => _confirm(context, ref),
              child: const Text('Confirm'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        // OWNER CORRECTION (2026-09-22): ONE Planner context, one projection
        // source. The session does NOT push a second, competing Planner: it
        // hosts the canonical screen in `schedulingMode`, which the screen
        // itself renders as an adjustment-only draft-edit mode (no FAB, no
        // tap-to-create, unrelated blocks inert, creation drafts withheld, and
        // no saved-event Undo card for the draft block).
        body: session == null
            ? const SizedBox.shrink()
            : const PlannerScreen(schedulingMode: true),
      ),
    );
  }
}

/// Opens the scheduling session and resolves with `null` when the user backs
/// out.  Every caller awaits this; nothing else owns the session lifetime.
Future<PlannerScheduleResult?> openPlannerScheduleSession(
  BuildContext context,
  WidgetRef ref,
  PlannerScheduleSession session,
) async {
  ref.read(plannerScheduleSessionProvider.notifier).begin(session);
  try {
    return await Navigator.of(context).push<PlannerScheduleResult>(
      MaterialPageRoute<PlannerScheduleResult>(
        builder: (context) => const PlannerScheduleSessionScreen(),
      ),
    );
  } finally {
    // A route torn down by anything other than Confirm must never leave a stale
    // session behind for the next Planner build to paint.
    ref.read(plannerScheduleSessionProvider.notifier).clear();
  }
}
