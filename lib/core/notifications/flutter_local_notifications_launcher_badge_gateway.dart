import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_gateway.dart';
import 'package:rmplanner/core/notifications/launcher_badge_gateway.dart';

final class FlutterLocalNotificationsLauncherBadgeGateway
    implements LauncherBadgeGateway {
  const FlutterLocalNotificationsLauncherBadgeGateway(this.plugin);

  static const int notificationId = 0x7ffffffe;
  static const String channelId = 'next_transfer_app_status';

  final FlutterLocalNotificationsPlugin plugin;

  @override
  Future<void> setCount(int count) async {
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
    await plugin.show(
      id: notificationId,
      title: 'Next Transfer',
      body: '$count actionable ${count == 1 ? 'item' : 'items'}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          'App status',
          channelDescription: 'Actionable Next Transfer item count.',
          // HOTFIX: never depend on the startup-registered default icon.
          icon: ntNotificationIconResource,
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
