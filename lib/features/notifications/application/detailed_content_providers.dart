import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

/// VS16 M7 corrective — the Detailed notification content preferences.
///
/// Persistence is reached through the ALREADY-OVERRIDDEN
/// `notificationFoundationRepositoryProvider`, which both the app root and the
/// headless worker supply. No new provider has to be added to either container,
/// so this feature cannot break the worker isolate.

/// The profile whose notification preferences are being read or edited.
///
/// The runtime override is consulted first: the worker isolate sets it and must
/// never reach the UI startup graph.
final detailedContentProfileIdProvider = Provider<String?>((ref) {
  final runtime = ref.watch(reminderRuntimeProfileIdProvider);
  if (runtime != null) return runtime;
  final startup = ref.watch(startupControllerProvider);
  return startup is StartupReady ? startup.profile.id : null;
});

/// The current profile's saved Detailed content options.
///
/// Fail-closed TOWARD CONTENT: any read problem resolves to the all-TRUE
/// default, so a preferences failure can never blank a notification.
/// Privacy Lock is deliberately NOT consulted here — it forces Generic at
/// render time and must never erase the owner's saved Detailed choices.
final detailedContentPreferencesProvider =
    FutureProvider<DetailedContentPreferences>((ref) async {
      final profileId = ref.watch(detailedContentProfileIdProvider);
      if (profileId == null) return DetailedContentPreferences.defaults;
      try {
        return await ref
            .read(notificationFoundationRepositoryProvider)
            .readDetailedContent(profileId: profileId);
      } on Object {
        return DetailedContentPreferences.defaults;
      }
    });

/// Writes the five options.
final detailedContentControllerProvider = Provider<DetailedContentController>(
  DetailedContentController.new,
);

final class DetailedContentController {
  const DetailedContentController(this._ref);

  final Ref _ref;

  /// Persists the profile's options, preserving unrelated document keys.
  Future<void> save(DetailedContentPreferences next) async {
    final profileId = _ref.read(detailedContentProfileIdProvider);
    if (profileId == null) return;
    await _ref
        .read(notificationFoundationRepositoryProvider)
        .saveDetailedContent(profileId: profileId, preferences: next);
    _ref.invalidate(detailedContentPreferencesProvider);
  }

  /// Toggles the DETAILED CONTENT MASTER, preserving all five fields.
  ///
  /// The master is separate storage precisely so this write cannot touch the
  /// owner's field choices: turning detail off and back on must return exactly
  /// the configuration that was there before.
  ///
  /// Persistence only.  The Settings screen uses [setEnabledAndRefresh] so that
  /// already-scheduled reminder copy is re-rendered as well; keeping the pure
  /// write separate means a caller that only wants durability (and the tests
  /// that assert the storage law) never triggers a platform reconciliation.
  Future<void> setEnabled({
    required DetailedContentPreferences current,
    required bool enabled,
  }) => save(current.copyWith(enabled: enabled));

  /// Toggles ONE field, preserving the other four.  Persistence only; see
  /// [setFieldAndRefresh].
  Future<void> setField({
    required DetailedContentPreferences current,
    bool? showTitle,
    bool? showDescription,
    bool? showTime,
    bool? showContacts,
    bool? showLocation,
  }) => save(
    current.copyWith(
      showTitle: showTitle,
      showDescription: showDescription,
      showTime: showTime,
      showContacts: showContacts,
      showLocation: showLocation,
    ),
  );

  /// The owner-facing toggle: persists the change AND refreshes the copy of
  /// reminders that are already scheduled.
  ///
  /// Owner pass 2026-09-19 (defect N1-G).  The ordinary transport PRE-RENDERS
  /// the notification body when it schedules the alarm, so without this pass a
  /// changed Show toggle would only take effect the next time that reminder
  /// happened to be reconciled for some unrelated reason.  The refresh is the
  /// SAME canonical Event-and-Task content refresh the privacy preview toggle
  /// already uses — there is deliberately no second reconciliation path.
  Future<void> setEnabledAndRefresh({
    required DetailedContentPreferences current,
    required bool enabled,
  }) async {
    await setEnabled(current: current, enabled: enabled);
    await _refreshScheduledContent();
  }

  /// The owner-facing field toggle: persists the change AND refreshes the copy
  /// of reminders that are already scheduled.
  Future<void> setFieldAndRefresh({
    required DetailedContentPreferences current,
    bool? showTitle,
    bool? showDescription,
    bool? showTime,
    bool? showContacts,
    bool? showLocation,
  }) async {
    await setField(
      current: current,
      showTitle: showTitle,
      showDescription: showDescription,
      showTime: showTime,
      showContacts: showContacts,
      showLocation: showLocation,
    );
    await _refreshScheduledContent();
  }

  /// Re-renders already-scheduled reminder copy.
  ///
  /// The preference is already durable before this runs, so a platform failure
  /// must not surface as a failed toggle: the next canonical reconciliation is
  /// idempotent and will converge.  The failure is swallowed for exactly the
  /// same reason the privacy write swallows it.
  Future<void> _refreshScheduledContent() async {
    try {
      await _ref.read(notificationPrivacyRefreshProvider)();
    } on Object {
      // Durable preference kept; scheduling converges on the next pass.
    }
  }
}

/// Builds the canonical preview using the SAME renderer the notification path
/// uses, so the Settings preview can never drift from the delivered copy.
///
/// M2 OWNER CORRECTION (Issue 1): the preview follows ONLY the saved content
/// options.  Privacy Lock no longer forces Generic; it does not participate
/// in notification content selection at all.
RenderedReminder buildDetailedPreview({
  required bool isEvent,
  required DetailedContentPreferences options,
  String? sourceTitle,
  DateTime? startDisplay,
  DateTime? endDisplay,
  int? dueMinute,
  String? notes,
  String? followUpName,
  String? locationText,
}) {
  final resolved = options.toOptions();
  if (isEvent) {
    return ReminderNotificationRenderer.eventDetailed(
      eventTitle: sourceTitle,
      startDisplay: startDisplay,
      endDisplay: endDisplay,
      notes: notes,
      followUpName: followUpName,
      locationText: locationText,
      options: resolved,
    );
  }
  return ReminderNotificationRenderer.taskDetailed(
    taskTitle: sourceTitle,
    dueMinute: dueMinute,
    notes: notes,
    followUpName: followUpName,
    options: resolved,
  );
}
