import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

/// OWNER REVIEW #4 — first-ever notification setup.
///
/// A brand-new user who grants the Android notification permission for the
/// first time gets the owner-approved defaults. An EXISTING user who later
/// revokes and re-grants the permission keeps every deliberate choice they
/// made, because the two cases are distinguished by durable state rather than
/// by a mutable "seen it" flag.
///
/// The sentinel is SEMANTIC, not a raw row check. OWNER REVIEW #4's first
/// implementation asked only whether a `notification_preferences` row existed,
/// which is unsafe: the Detailed content store INSERTS that same row to hold its
/// five columns (leaving every delivery field at its compiled default), and a
/// master toggle on an already-granted permission writes a row over untouched
/// defaults too. Both would have marked a never-configured profile as
/// configured, permanently suppressing the owner-approved defaults.
///
/// [NotificationFoundationRepository.readSetupState] therefore classifies the
/// row's own delivery fields. See [NotificationSetupState] for the exact law.
/// No new column, no flag table and no schema change are involved (schema 47).
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
///
/// OWNER REVIEW #4 STRAIGHTFIX — it reads PERSISTED truth and writes exactly one
/// field.
///
/// `savePlannerSettings` writes the whole settings object, so seeding from a
/// controller that was still showing its loading placeholder would have written
/// the compiled defaults over a real user's Planner settings (week start, visible
/// hours, presentation) on a profile that merely happened to have never touched
/// notifications. Reading the persisted settings first means the only field this
/// seam can ever change is the one it was asked to change.
final eventDefaultReminderSeederProvider =
    Provider<Future<void> Function(int minutes)>((ref) {
      return (int minutes) async {
        final startup = ref.read(startupControllerProvider);
        if (startup is! StartupReady) return;
        final profileId = startup.profile.id;
        // Writes through the repository, NOT through
        // `EventTypeController.saveSettings`. That controller AWAITS a reminder
        // reconcile whenever the reminder changes, and the enable path holds the
        // reconcile gate across this entire operation — so an awaited reconcile
        // here would wait for a release that can only happen after this returns.
        // The deadlock is real, not theoretical: with a real Planner graph the
        // enable never reached its own master write at all, which is the most
        // likely reason a brand-new profile's System notifications could never
        // be turned on. The enable path reconciles once for itself, after it
        // releases the gate.
        final repository = ref.read(eventTypeRepositoryProvider);
        final current = await repository.readPlannerSettings(
          profileId: profileId,
        );
        if (current.defaultReminderMinutes != null) return;
        await repository.savePlannerSettings(
          profileId: profileId,
          settings: current.copyWith(defaultReminderMinutes: minutes),
        );
        // Make the new value visible to any open Planner surface without
        // triggering a reconcile or a second read set here.
        ref.invalidate(eventTypeControllerProvider);
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

  /// The profile's semantic notification-setup state.
  Future<NotificationSetupState> readSetupState({required String profileId}) {
    return _ref
        .read(notificationFoundationRepositoryProvider)
        .readSetupState(profileId: profileId);
  }

  /// Seeds the owner-approved defaults when, and only when, this profile is
  /// still [NotificationSetupState.neverConfigured].
  ///
  /// A `configured` OR `partiallyInitialized` profile is preserved exactly: the
  /// owner's law is that an established or restored configuration — including a
  /// deliberately unset default reminder — is never overwritten, and that the
  /// ambiguous Review #4 partial row is reported rather than guessed at.
  ///
  /// Returns true when it seeded, false when an existing configuration was
  /// preserved. Failure is reported by rethrowing; the caller decides, and the
  /// enable path deliberately treats a seeding failure as non-fatal because the
  /// user's explicit action is to enable notifications.
  Future<bool> seedIfNeverConfigured({required String profileId}) async {
    final repository = _ref.read(notificationFoundationRepositoryProvider);
    final setupState = await repository.readSetupState(profileId: profileId);
    if (setupState != NotificationSetupState.neverConfigured) {
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
