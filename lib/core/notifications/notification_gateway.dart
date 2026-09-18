import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';

enum NotificationChannelKind { reminders, planning }

extension NotificationChannelDefinition on NotificationChannelKind {
  String get id => switch (this) {
    NotificationChannelKind.reminders => 'next_transfer_reminders',
    NotificationChannelKind.planning => 'next_transfer_planning',
  };

  String get label => switch (this) {
    NotificationChannelKind.reminders => 'Reminders',
    NotificationChannelKind.planning => 'Planning',
  };

  String get description => switch (this) {
    NotificationChannelKind.reminders =>
      'User-selected Event and Task reminders.',
    NotificationChannelKind.planning =>
      'Planning reminders introduced in later milestones.',
  };
}

final class LocalNotificationRequest {
  const LocalNotificationRequest({
    required this.platformId,
    required this.stableKey,
    required this.channel,
    required this.scheduledAtUtc,
    required this.title,
    required this.body,
    required this.responseIntent,
    this.onlyAlertOnce = false,
  });

  final int platformId;
  final String stableKey;
  final NotificationChannelKind channel;
  final DateTime scheduledAtUtc;
  final String title;
  final String body;
  final NotificationResponseIntent responseIntent;

  /// True for the M7 worker re-show path: re-posting the same platform ID
  /// must update the existing open notification without re-alerting.
  final bool onlyAlertOnce;
}

/// The M7 enriched-delivery WorkManager input.  It carries exactly three
/// technical values and no private content: the durable logical key, the
/// target epoch millis and the technical source revision.  The unique work
/// name is the existing `nt.reminder.<platformId>` tag prefix plus the target
/// and the first 16 hex characters of SHA256(sourceRevision).
final class CanonicalReminderWorkSpec {
  const CanonicalReminderWorkSpec({
    required this.platformId,
    required this.stableKey,
    required this.scheduledAtUtc,
    required this.sourceRevision,
  });

  static const String taskName = 'nt.reminder.delivery';
  static const Set<String> inputKeys = <String>{
    'stable_key',
    'scheduled_utc_ms',
    'source_revision',
  };

  final int platformId;
  final String stableKey;
  final DateTime scheduledAtUtc;
  final String sourceRevision;

  String get revisionDigest16 =>
      sha256.convert(utf8.encode(sourceRevision)).toString().substring(0, 16);

  String get uniqueName =>
      'nt.reminder.$platformId.'
      '${scheduledAtUtc.millisecondsSinceEpoch}.$revisionDigest16';

  BackgroundWorkSpec toBackgroundWorkSpec() => BackgroundWorkSpec(
    uniqueName: uniqueName,
    taskName: taskName,
    inputData: <String, Object?>{
      'stable_key': stableKey,
      'scheduled_utc_ms': scheduledAtUtc.millisecondsSinceEpoch,
      'source_revision': sourceRevision,
    },
    // Bounded retry: the dispatcher records the durable attempt count and
    // attempt 5 terminates; the plugin's WorkManager retry observes the
    // exponential 30s/60s/120s/240s minimum backoff.
    backoffPolicy: BackgroundBackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(seconds: 30),
    existingPolicy: BackgroundExistingWorkPolicy.keep,
  );
}

final class PendingLocalNotification {
  const PendingLocalNotification({required this.platformId, this.payload});

  final int platformId;
  final String? payload;
}

abstract interface class NotificationGateway {
  Stream<NotificationResponseIntent> get responses;

  Future<void> initialize();

  Future<void> schedule(LocalNotificationRequest request);

  Future<void> cancel(int platformId);

  Future<List<PendingLocalNotification>> pending();

  NotificationResponseIntent? takeInitialResponse();
}
