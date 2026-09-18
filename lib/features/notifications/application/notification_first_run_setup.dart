import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';

/// OWNER REVIEW #4 — first-ever notification setup.
///
/// A brand-new user who grants the Android notification permission for the
/// first time gets the owner-approved defaults. An EXISTING user who later
/// revokes and re-grants the permission keeps every deliberate choice they
/// made, because the two cases are distinguished by durable state rather than
/// by a mutable "seen it" flag.
///
/// The sentinel is the ABSENCE of the profile's `notification_preferences` row:
/// [NotificationFoundationRepository.readPreferences] is documented to answer
/// with [NotificationPreferences.defaults] and never to create a row, so an
/// absent row means nothing has ever been configured on this profile. The row
/// is written by the first real save. No new column, no flag table and no
/// schema change are involved.
///
/// This was the single largest real cause of a beta user receiving nothing.
/// Before this change a new profile had `defaultTaskReminderMinutes == null`
/// and every delivery category `false`, and `ReminderReconciler` resolves a
/// null offset to no reminder at all — so a correctly permissioned, correctly
/// enabled install still produced zero notifications, because nothing had ever
/// been configured to notify about.
final notificationFirstRunSetupProvider = Provider<NotificationFirstRunSetup>(
  NotificationFirstRunSetup.new,
);

/// Seam for the Event-side default reminder.
///
/// The Event default is a Planner setting, not a notification preference, so it
/// is written through the canonical Event Type controller. It is exposed as one
/// injectable function so the first-run behaviour can be proven without standing
/// up the whole Planner graph, and so there is exactly one place that decides it.
final eventDefaultReminderSeederProvider =
    Provider<Future<void> Function(int minutes)>((ref) {
      return (int minutes) async {
        final eventTypes = ref.read(eventTypeControllerProvider);
        if (eventTypes.settings.defaultReminderMinutes != null) return;
        await ref
            .read(eventTypeControllerProvider.notifier)
            .saveSettings(
              eventTypes.settings.copyWith(defaultReminderMinutes: minutes),
            );
      };
    });

final class NotificationFirstRunSetup {
  const NotificationFirstRunSetup(this._ref);

  final Ref _ref;

  /// The owner-approved default Event and timed-Task lead time.
  ///
  /// This applies to TIMED items only. A date-only Task has no `dueMinute`, and
  /// the occurrence generators exclude it before any offset is considered, so
  /// this value can never invent a notification time for a date-only Task.
  static const int defaultReminderLeadMinutes = 10;

  /// The owner-approved new-user notification preference set.
  ///
  /// Quiet Hours is OFF and every delivery category is ON, including the Goal
  /// completion category. In-app Goal celebrations keep their existing product
  /// default: an in-app celebration is not a system notification category, so
  /// it is deliberately not part of this delivery switch set.
  static const NotificationPreferences ownerApprovedDefaults =
      NotificationPreferences(
        systemNotificationsEnabled: true,
        eventRemindersEnabled: true,
        taskRemindersEnabled: true,
        weeklyReviewRemindersEnabled: true,
        awaitingReportRemindersEnabled: true,
        goalCompletionNotificationsEnabled: true,
        inAppGoalCelebrationsEnabled: true,
        defaultTaskReminderMinutes: defaultReminderLeadMinutes,
        snoozeDurationMinutes: 10,
        quietHours: QuietHoursSettings.disabled(),
      );

  /// Seeds the owner-approved defaults when, and only when, this profile has
  /// never had notification preferences written.
  ///
  /// Returns true when it seeded, false when an existing configuration was
  /// preserved. Failure is reported by rethrowing; the caller decides, and the
  /// enable path deliberately treats a seeding failure as non-fatal because the
  /// user's explicit action is to enable notifications.
  Future<bool> seedIfNeverConfigured({required String profileId}) async {
    final repository = _ref.read(notificationFoundationRepositoryProvider);
    if (await repository.hasPreferences(profileId: profileId)) {
      return false;
    }
    await repository.savePreferences(
      profileId: profileId,
      preferences: ownerApprovedDefaults,
    );
    // The notification preferences are already durable at this point, so the
    // Event-side default must never be able to un-seed them: a Planner problem
    // would otherwise make the caller believe seeding failed, and the caller's
    // next master write would then rebuild from the all-false compiled defaults
    // and silently discard everything just seeded.
    try {
      await _ref.read(eventDefaultReminderSeederProvider)(
        defaultReminderLeadMinutes,
      );
    } on Object {
      // The notification categories remain seeded; the Event default retries on
      // the next first-run attempt because it is still unset.
    }
    return true;
  }
}
