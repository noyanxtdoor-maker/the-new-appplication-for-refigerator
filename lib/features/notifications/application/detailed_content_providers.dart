import 'package:flutter_riverpod/flutter_riverpod.dart';
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
final detailedContentControllerProvider =
    Provider<DetailedContentController>(DetailedContentController.new);

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

  /// Toggles ONE field, preserving the other four.
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
