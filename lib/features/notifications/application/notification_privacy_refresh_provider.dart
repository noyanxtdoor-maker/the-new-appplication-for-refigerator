import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/planning_reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/application/reconcile_reminders.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';

typedef NotificationPrivacyRefresh = Future<void> Function();

/// One canonical Event-and-Task content refresh. Privacy settings invoke this
/// only after their durable write succeeds.
final reconcileRemindersProvider = Provider<ReconcileReminders>((ref) {
  /// Runtime override OR actual StartupReady; never a fabricated startup.
  /// A container without an overridden startup/diagnostics foundation simply
  /// has no profile to repair and must not surface a provider error.
  String? resolveProfileId() {
    final runtimeProfile = ref.read(reminderRuntimeProfileIdProvider);
    if (runtimeProfile != null) return runtimeProfile;
    try {
      final startup = ref.read(startupControllerProvider);
      return startup is StartupReady ? startup.profile.id : null;
    } on Object {
      return null;
    }
  }

  /// True only when this container actually composes the notification
  /// foundation.  Reading StartupController in a test/reduced container would
  /// build providers whose async diagnostics read reports an uncaught zone
  /// error, so prerequisite availability is checked BEFORE startup.
  bool hasNotificationFoundation() {
    try {
      ref.read(notificationFoundationRepositoryProvider);
      return true;
    } on Object {
      return false;
    }
  }

  bool hasReading(Object? Function() read) {
    try {
      read();
      return true;
    } on Object {
      return false;
    }
  }

  return ReconcileReminders(
    // No profile (no StartupReady and no runtime override) means there is no
    // canonical source to reconcile; skip instead of surfacing a provider
    // read error from a container without the startup foundation.
    reconcileEvents: () => ref
        .read(calendarEventControllerProvider.notifier)
        .reconcileEventHorizon(refreshContent: true),
    reconcileTasks: () => ref
        .read(plannerControllerProvider.notifier)
        .reconcileTaskReminderHorizon(refreshContent: true),
    beginRepair: () async {
      if (!hasNotificationFoundation()) return false;
      final profileId = resolveProfileId();
      if (profileId == null) return false;
      return ref
          .read(notificationFoundationRepositoryProvider)
          .beginReminderRepair(profileId: profileId);
    },
    completeRepair: () async {
      if (!hasNotificationFoundation()) return;
      final profileId = resolveProfileId();
      if (profileId == null) return;
      await ref
          .read(notificationFoundationRepositoryProvider)
          .completeReminderRepair(profileId: profileId);
    },
    reconcilePlanning: () async {
      if (!hasNotificationFoundation() ||
          !hasReading(() => ref.read(weeklyPlanningRepositoryProvider))) {
        return;
      }
      final profileId = resolveProfileId();
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
  );
});

final notificationPrivacyRefreshProvider = Provider<NotificationPrivacyRefresh>(
  (ref) =>
      () => ref.read(reconcileRemindersProvider)(),
);
