import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/planning_reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/application/reconcile_reminders.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';

typedef NotificationPrivacyRefresh = Future<void> Function();

/// One canonical Event-and-Task content refresh. Privacy settings invoke this
/// only after their durable write succeeds.
///
/// The pass also owns the durable repair-marker lifecycle (contract sections
/// 28/30): it claims the current dirty generation, runs every source pass, then
/// completes that generation only if it is still the one it reconciled.  A
/// mutation that landed mid-pass therefore produces exactly one trailing pass
/// instead of being stamped completed by an older result.
final reconcileRemindersProvider = Provider<ReconcileReminders>((ref) {
  final marker = ref.read(reminderRecoveryRequestProvider);
  final coordinator = ref.read(reminderRecoveryCoordinatorProvider);
  final sweeper = ref.read(reminderOrphanSweeperProvider);

  return ReconcileReminders(
    reconcileEvents: () => ref
        .read(calendarEventControllerProvider.notifier)
        .reconcileEventHorizon(refreshContent: true),
    reconcileTasks: () => ref
        .read(plannerControllerProvider.notifier)
        .reconcileTaskReminderHorizon(refreshContent: true),
    reconcilePlanning: () async {
      // Runtime-or-ready profile resolution: the headless worker supplies the
      // profile through the runtime override, the foreground through a real
      // StartupReady.  No fake StartupReady is constructed and no profile is
      // created here (contract sections 26/35).
      final profileId = resolveReminderRecoveryProfileId(ref);
      if (profileId == null) return;
      final permission = await ref
          .read(permissionGatewayProvider)
          .status(OptionalPermission.notifications);
      await PlanningReminderReconciler(
        weeklyPlans: ref.read(weeklyPlanningRepositoryProvider),
        events: ref.read(calendarEventRepositoryProvider),
        repository: ref.read(notificationFoundationRepositoryProvider),
        reminders: ref.read(reminderReconcilerProvider),
        permission: permission,
        privacy: await ref.read(privacyRepositoryProvider).readSettings(),
      ).reconcile(profileId: profileId);
    },
    // Unbounded-in-time orphan cleanup and both-transport registration repair
    // run inside the SAME coalesced pass, so neither can race a sibling pass or
    // a foreground mutation.
    reconcileOrphans: () async {
      final profileId = resolveReminderRecoveryProfileId(ref);
      if (profileId == null) return;
      await sweeper.sweep(profileId: profileId);
      await ref.read(reminderRegistrationRepairProvider).repair(
        profileId: profileId,
      );
    },
    claimRepair: marker == null
        ? null
        : () async {
            final profileId = resolveReminderRecoveryProfileId(ref);
            if (profileId == null) return null;
            return marker.claimRunning(marker.database, profileId: profileId);
          },
    completeRepair: marker == null
        ? null
        : (capturedToken) async {
            final profileId = resolveReminderRecoveryProfileId(ref);
            if (profileId == null) return true;
            final consumed = await marker.completeIfUnchanged(
              marker.database,
              profileId: profileId,
              capturedToken: capturedToken,
            );
            if (consumed) {
              // The bounded 42-day horizon refill is re-armed ONLY by a
              // successful recovery, so a failing pass cannot spawn a chain.
              try {
                await coordinator.armRefill();
              } on Object {
                // Refill is opportunistic maintenance; the repair itself is
                // already durable and must not be reported as failed.
              }
            }
            return consumed;
          },
    failRepair: marker == null
        ? null
        : (capturedToken, failureCategory) async {
            final profileId = resolveReminderRecoveryProfileId(ref);
            if (profileId == null) return;
            await marker.recordRepairFailure(
              marker.database,
              profileId: profileId,
              capturedToken: capturedToken,
              failureCategory: failureCategory,
            );
          },
  );
});

final notificationPrivacyRefreshProvider = Provider<NotificationPrivacyRefresh>(
  (ref) =>
      () => ref.read(reconcileRemindersProvider)(),
);
