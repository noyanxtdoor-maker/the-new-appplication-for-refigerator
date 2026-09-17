/// Immediate, non-scheduled notification delivery.
///
/// [NotificationGateway] owns canonical reminder *scheduling*: it speaks in
/// scheduled requests and stable reminder keys, and every call is about a
/// reminder that must survive a reboot. Backup & Restore needs the opposite
/// shape — one short-lived card, shown now and rewritten in place while a
/// user-initiated operation runs — so it gets its own contract instead of a
/// looser reminder gateway. Keeping them apart means reminder code cannot post
/// an unscheduled "progress" card, and an operation cannot accidentally create,
/// reschedule or cancel a reminder alarm.
library;

abstract interface class TransientNotificationGateway {
  /// Shows the notification identified by [platformId], replacing any card
  /// already published under that id. That in-place replacement is what keeps
  /// one operation to exactly one card.
  Future<void> showTransient({
    required int platformId,
    required String title,
    String? body,
  });

  /// Takes the card down, if it is showing. Used when an operation was
  /// abandoned before it did anything, so there is nothing truthful to report.
  Future<void> dismissTransient(int platformId);
}

/// Channel identity for transient operation feedback.
///
/// Deliberately not a `NotificationChannelKind`: those are the reminder
/// channels, and their labels, descriptions and importance are reminder
/// semantics. A dedicated channel lets the user silence operation feedback
/// without muting reminders (and the reverse), and it cannot alter the
/// importance or wording of any channel that already exists on a device.
const transientNotificationsChannelId = 'next_transfer_operations';
const transientNotificationsChannelLabel = 'Backup & Restore';
const transientNotificationsChannelDescription =
    'Backup and restore progress and results.';
