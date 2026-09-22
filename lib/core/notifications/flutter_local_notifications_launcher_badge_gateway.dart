import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_gateway.dart';
import 'package:rmplanner/core/notifications/launcher_badge_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';

final class FlutterLocalNotificationsLauncherBadgeGateway
    implements LauncherBadgeGateway {
  const FlutterLocalNotificationsLauncherBadgeGateway(this.plugin);

  static const int notificationId = 0x7ffffffe;
  static const String channelId = 'next_transfer_app_status';

  /// Stable response-intent source id for the summary destination.  It is an
  /// identity token only; the hub itself is canonical and profile-scoped.
  static const String unreportedSummarySourceId = 'unreported-hub';

  final FlutterLocalNotificationsPlugin plugin;

  @override
  Future<void> setCount({required String profileId, required int count}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (count <= 0) {
      await plugin.cancel(id: notificationId);
      return;
    }
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        'App status',
        description: 'Actionable Next Transfer item count.',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: true,
      ),
    );
    // Owner law (2026-09-19): tapping the summary notification opens the
    // canonical Unreported hub.  The payload is the ordinary canonical
    // response intent, so the tap travels the one existing routing seam
    // instead of a bespoke deep link.
    final payload = NotificationPayloadCodec.encode(
      NotificationResponseIntent(
        profileId: profileId,
        sourceKind: NotificationSourceKind.unreportedSummary,
        sourceId: unreportedSummarySourceId,
        action: NotificationResponseAction.open,
      ),
    );
    await plugin.show(
      id: notificationId,
      title: 'Next Transfer',
      body: '$count actionable ${count == 1 ? 'item' : 'items'}',
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          'App status',
          channelDescription: 'Actionable Next Transfer item count.',
          // NEVER depend on the startup-registered default icon: every path names
          // the SAME identity, which is the canonical app icon (see
          // [ntNotificationAppIconResource]).
          icon: ntNotificationAppIconResource,
          // NO large icon (owner decision, 2026-09-22): the identity comes from
          // the notification icon itself — the app icon resource named above —
          // not from a full-colour logo beside the text.
          // Owner decision (2026-09-22): the same explicit brand tint as the
          // reminder and transient paths, so no notification surface falls back
          // to the platform accent (the green-glyph defect).
          color: ntNotificationTint,
          colorized: false,
          importance: Importance.low,
          priority: Priority.low,
          playSound: false,
          enableVibration: false,
          onlyAlertOnce: true,
          ongoing: true,
          autoCancel: false,
          number: count,
          visibility: NotificationVisibility.secret,
        ),
      ),
    );
  }
}
