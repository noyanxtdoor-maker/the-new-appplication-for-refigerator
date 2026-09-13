import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

/// Unbounded-in-time, profile-scoped reminder orphan cleanup (section 34).
///
/// Two sweeps, both strictly ownership-proven:
///
/// * FORWARD — walks the active-work listing in batches and retires rows whose
///   canonical source can no longer be reached: rows that were never registered
///   and carry no target, and rows whose target expired beyond the grace window
///   with no live platform owner behind them.
/// * REVERSE — inspects the actual pending platform notifications, strictly
///   decodes the v1 ID-only payload, and withdraws an item whose durable row is
///   missing, terminal or owned by the OTHER transport.
///
/// It never deletes history, never touches the launcher-badge platform ID,
/// never cancels a foreign or undecodable payload, and never reasons about
/// another profile's work.
final class ReminderOrphanSweeper {
  const ReminderOrphanSweeper({
    required this.repository,
    required this.clock,
    required this.reminders,
    this.readPlatformPending,
    this.platformPendingIds,
    this.cancelPlatform,
    this.reservedPlatformId,
  });

  final NotificationFoundationRepository repository;
  final AppClock clock;
  final ReminderReconciler reminders;

  /// Reads the platform's currently pending local notifications, when the
  /// installed adapter can.  Absent/unreadable means "no decision", never
  /// "nothing is pending".
  final Future<List<PendingLocalNotification>> Function()? readPlatformPending;

  /// The platform IDs the OS still holds.  NULL means the platform truth could
  /// not be read — which is not the same as "none", so nothing is withdrawn.
  final Future<Set<int>?> Function()? platformPendingIds;

  /// Withdraws one specific platform notification ID.
  final Future<void> Function(int platformId)? cancelPlatform;

  /// The launcher-badge platform ID.  It is never cancelled or relocated here.
  final int? reservedPlatformId;

  static const int batchSize = 200;

  /// How long past its target a registered row may stay non-terminal before it
  /// is treated as an orphan rather than a still-valid pending reminder.
  static const Duration expiredGrace = Duration(hours: 24);

  Future<void> sweep({required String profileId}) async {
    await _sweepActiveRows(profileId: profileId);
    await _sweepPlatformPending(profileId: profileId);
  }

  /// The reminder family a durable row belongs to.
  ///
  /// The planning families share `ownerKind = planning`, so the stable-key
  /// family prefix is the only field that separates them.  A row that matches
  /// no known family is not swept: an unknown owner is diagnostic information,
  /// not permission to cancel.
  static ReminderSourceKind? sourceKindOf(BackgroundWorkRequest row) {
    switch (row.ownerKind) {
      case BackgroundWorkOwnerKind.occurrence:
        return ReminderSourceKind.calendarEvent;
      case BackgroundWorkOwnerKind.task:
        return ReminderSourceKind.task;
      case BackgroundWorkOwnerKind.planning:
        if (ReminderSourceKind.weeklyReview.ownsStableKey(row.stableKey)) {
          return ReminderSourceKind.weeklyReview;
        }
        if (ReminderSourceKind.awaitingReport.ownsStableKey(row.stableKey)) {
          return ReminderSourceKind.awaitingReport;
        }
        return null;
      case BackgroundWorkOwnerKind.profile:
      case BackgroundWorkOwnerKind.event:
      case BackgroundWorkOwnerKind.device:
        return null;
    }
  }

  static bool _isActive(BackgroundWorkState state) => switch (state) {
    BackgroundWorkState.completed ||
    BackgroundWorkState.queued ||
    BackgroundWorkState.waitingForConstraints ||
    BackgroundWorkState.delayedBySystem ||
    BackgroundWorkState.retryScheduled ||
    BackgroundWorkState.scheduled => true,
    _ => false,
  };

  Future<void> _sweepActiveRows({required String profileId}) async {
    final now = clock.nowUtc();
    // A row may only be retired when the platform truth is READABLE.  An
    // unreadable platform proves nothing, so the sweep leaves every row alone
    // and reports no outcome (section 34).
    final pendingIds = await platformPendingIds?.call();
    String? after;
    while (true) {
      final batch = await repository.readActiveReminderWork(
        profileId: profileId,
        limit: batchSize,
        afterStableKey: after,
      );
      if (batch.isEmpty) return;
      for (final row in batch) {
        after = row.stableKey;
        final occurrenceId = row.occurrenceId;
        final kind = sourceKindOf(row);
        if (occurrenceId == null || kind == null) continue;
        final target = row.scheduledForUtc;
        if (target == null) {
          // Registered nowhere and carries no target: this row can never
          // deliver, so it is a genuine orphan rather than a pending reminder.
          await reminders.cancel(
            sourceKind: kind,
            profileId: profileId,
            occurrenceId: occurrenceId,
            exactStableKey: row.stableKey,
          );
          continue;
        }
        if (!target.add(expiredGrace).isBefore(now)) continue;
        // Past its target.  A still-live platform notification keeps the row
        // actionable; an unreadable platform changes nothing at all.
        final platformId = row.platformNotificationId;
        if (row.state == BackgroundWorkState.scheduled && platformId != null) {
          if (pendingIds == null) continue;
          if (pendingIds.contains(platformId)) continue;
        }
        await reminders.cancel(
          sourceKind: kind,
          profileId: profileId,
          occurrenceId: occurrenceId,
          exactStableKey: row.stableKey,
        );
      }
      if (batch.length < batchSize) return;
    }
  }

  Future<void> _sweepPlatformPending({required String profileId}) async {
    final read = readPlatformPending;
    if (read == null) return;
    final List<PendingLocalNotification> pending;
    try {
      pending = await read();
    } on Object {
      // The platform truth could not be read.  Report nothing, change nothing.
      return;
    }
    for (final item in pending) {
      // Never the launcher badge.
      if (item.platformId == reservedPlatformId) continue;
      final payload = item.payload;
      // An unknown/foreign platform ID without an owned v1 payload is not ours.
      if (payload == null) continue;
      final intent = NotificationPayloadCodec.tryDecode(payload);
      // An undecodable payload is diagnostic unknown, not carte blanche cancel.
      if (intent == null) continue;
      // Another profile's work is never read, let alone cancelled.
      if (intent.profileId != profileId) continue;
      final occurrenceId = intent.occurrenceId;
      final kind = switch (intent.sourceKind) {
        NotificationSourceKind.calendarEvent => ReminderSourceKind.calendarEvent,
        NotificationSourceKind.task => ReminderSourceKind.task,
        NotificationSourceKind.weeklyReview => ReminderSourceKind.weeklyReview,
        NotificationSourceKind.awaitingReport =>
          ReminderSourceKind.awaitingReport,
        // Dormant kinds (Goal achievement, Contact follow-up) are never
        // activated or swept by this milestone.
        NotificationSourceKind.contactFollowUp ||
        NotificationSourceKind.goalAchievement => null,
      };
      if (kind == null || occurrenceId == null) continue;
      final key = ReminderReconciler.stableKey(
        sourceKind: kind,
        profileId: profileId,
        occurrenceId: occurrenceId,
      );
      final row = await repository.readWorkRequest(key);
      final owned =
          row != null &&
          _isActive(row.state) &&
          row.platformNotificationId == item.platformId;
      if (owned) {
        // A worker-owned row must not also hold a native pending item: that is
        // exactly the duplicate delivery owner section 6 forbids.
        if (ReminderReconciler.ownsWorkerTransport(row.sourceRevision)) {
          await cancelPlatform?.call(item.platformId);
        }
        continue;
      }
      // The durable row is missing, terminal or owned by a different platform
      // ID, so this pending item is a stale orphan.  Withdraw the exact item.
      await cancelPlatform?.call(item.platformId);
      if (row != null) {
        await reminders.cancel(
          sourceKind: kind,
          profileId: profileId,
          occurrenceId: occurrenceId,
          exactStableKey: row.stableKey,
        );
      }
    }
  }
}
