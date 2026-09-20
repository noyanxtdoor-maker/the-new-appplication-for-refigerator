import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/notifications/notification_response_controller.dart';
import 'package:rmplanner/core/notifications/transient_notification_gateway.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

/// OWNER HOTFIX (2026-09-19) — the ONE derivation of the notification small icon.
///
/// The plugin resolves this drawable by NAME at runtime, so every
/// `AndroidNotificationDetails` this app builds must name it explicitly instead of
/// relying on the default icon registered by `initialize()`.
///
/// Reliance on the registered default was the delivery defect: if `initialize()`
/// does not persist a default icon (which is what happened in release builds, where
/// the drawable was stripped as unreferenced), then the plugin's
/// `setSmallIcon` fallback unboxes a null `iconResourceId` and **crashes the whole
/// process** when a scheduled reminder alarm fires. Naming the icon per send keeps
/// every notification path on the resolved-drawable branch, so a missing default can
/// never take the process down again. `res/raw/keep.xml` keeps the drawable itself.
const String ntNotificationIconResource = 'ic_nt_notification';

final class FlutterLocalNotificationsGateway
    implements
        NotificationGateway,
        CanonicalReminderDeliveryGateway,
        TransientNotificationGateway {
  FlutterLocalNotificationsGateway({
    FlutterLocalNotificationsPlugin? plugin,
    this.runningDeliveryPlatformId,
    NotificationResponseController? responses,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _responseController = responses ?? NotificationResponseController();

  final FlutterLocalNotificationsPlugin _plugin;
  final int? runningDeliveryPlatformId;
  final NotificationResponseController _responseController;

  @override
  Stream<NotificationResponseIntent> get responses =>
      _responseController.responses;

  @override
  Future<void> initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        // M3/M4 owner-review correction: the dedicated monochrome hand +
        // planner small icon derived from the owner-approved logo SVG.
        // Android tints it; the full-color launcher icon must never be the
        // notification small icon.
        android: AndroidInitializationSettings('@drawable/ic_nt_notification'),
      ),
      onDidReceiveBackgroundNotificationResponse: nextTransferReminderAction,
      onDidReceiveNotificationResponse: (response) {
        _responseController.capture(
          payload: response.payload,
          actionId: response.actionId,
        );
      },
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    for (final channel in NotificationChannelKind.values) {
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          channel.id,
          channel.label,
          description: channel.description,
          importance: Importance.defaultImportance,
        ),
      );
    }
    // OWNER correction #3: transient operation feedback (Backup & Restore)
    // reaches the shade through this same plugin, on its own channel. Low
    // importance keeps progress and result cards silent — the user just
    // started the operation and is watching the screen — while still being
    // visible in the shade. The reminder channels above are untouched.
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        transientNotificationsChannelId,
        transientNotificationsChannelLabel,
        description: transientNotificationsChannelDescription,
        importance: Importance.low,
      ),
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final response = launch?.notificationResponse;
      _responseController.capture(
        payload: response?.payload,
        actionId: response?.actionId,
        initial: true,
      );
    }
  }

  static String deliveryTag(int id) => 'nt.reminder.$id';
  static String deliveryName(int id, DateTime at) =>
      '${deliveryTag(id)}.${at.millisecondsSinceEpoch}';

  @override
  Future<void> schedule(LocalNotificationRequest request) async {
    // WorkManager is deliberately retained for recovery/reconciliation, but it
    // is not a delivery clock: its one-off initialDelay is opportunistic and
    // measured as 30–45 seconds late on the authorized device.  Android's
    // inexact notification scheduler owns normal and Snooze delivery timing.
    await Workmanager().cancelByTag(deliveryTag(request.platformId));
    await _plugin.cancel(id: request.platformId);
    await _plugin.zonedSchedule(
      id: request.platformId,
      scheduledDate: tz.TZDateTime.from(request.scheduledAtUtc, tz.UTC),
      title: request.title,
      body: request.body,
      notificationDetails: _detailsFor(request),
      payload: NotificationPayloadCodec.encode(request.responseIntent),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Future<bool> hasPendingReminder(
    int platformId,
    DateTime scheduledAtUtc,
  ) async {
    // Delivery is now owned by the Android local-notification scheduler.  The
    // old WorkManager unique name no longer exists, so querying it here made
    // every unchanged reconciliation cancel and recreate a still-pending
    // platform alarm.  Platform IDs are allocation-stable for the durable
    // logical reminder; the reconciler has already matched the target and
    // render revision before calling this check.
    final pending = await _plugin.pendingNotificationRequests();
    return pending.any((request) => request.id == platformId);
  }

  @override
  Future<bool> hasDisplayedReminder(int platformId) async {
    final active = await _plugin.getActiveNotifications();
    return active.any((notification) => notification.id == platformId);
  }

  @override
  Future<void> showCanonicalReminder(LocalNotificationRequest request) =>
      _plugin.show(
        id: request.platformId,
        title: request.title,
        body: request.body,
        notificationDetails: _detailsFor(request),
        payload: NotificationPayloadCodec.encode(request.responseIntent),
      );

  // VS16 owner decision: reminders carry NO explicit action buttons. Snooze is
  // deferred from the current product and the notification body's own tap is
  // the canonical Open path (same payload/routing as the retired button).
  //
  // VS16 M7 corrective — BigText presentation.
  //
  // Both `schedule()` (the native ordinary transport) and
  // `showCanonicalReminder()` (the worker/enriched transport) route through
  // this one method, so applying the style here converges both transports on a
  // single presentation choke point.
  //
  // Without a style, Android renders the body in the collapsed one-line
  // layout and a multiline Detailed body (time range + follow-up + description
  // + location) collapses to a single visible line.  BigTextStyle makes the
  // full body readable when the user expands the notification.
  //
  // `contentTitle` is pinned to [LocalNotificationRequest.title] so the
  // expanded header shows exactly the same resolved title the collapsed header
  // shows — including the M7 source-title amendment.  This is presentation
  // only: channel identity, importance, permissions, platform IDs, transport
  // ownership and scheduling semantics are all untouched.
  NotificationDetails _detailsFor(LocalNotificationRequest request) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          request.channel.id,
          request.channel.label,
          channelDescription: request.channel.description,
          // HOTFIX: never depend on the startup-registered default icon (see
          // [ntNotificationIconResource]).
          icon: ntNotificationIconResource,
          styleInformation: BigTextStyleInformation(
            request.body,
            contentTitle: request.title,
          ),
        ),
      );

  // OWNER correction #3. This is NOT a reminder transport: no payload, no
  // action buttons, no schedule, no WorkManager tag, and never a place in the
  // reminder platform-id space. A card posted here cannot be picked up by
  // `pending()`, by `hasPendingReminder` or by `hasDisplayedReminder`, because
  // there is no pending *request* and the ids used are outside the range the
  // reminder allocator can produce.
  @override
  Future<void> showTransient({
    required int platformId,
    required String title,
    String? body,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _plugin.show(
      id: platformId,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          transientNotificationsChannelId,
          transientNotificationsChannelLabel,
          channelDescription: transientNotificationsChannelDescription,
          // HOTFIX: never depend on the startup-registered default icon (see
          // [ntNotificationIconResource]).
          icon: ntNotificationIconResource,
          importance: Importance.low,
          priority: Priority.low,
          // One card per operation: updating it must not re-alert, and a
          // finished operation's card is the user's to dismiss.
          onlyAlertOnce: true,
          autoCancel: true,
          ongoing: false,
        ),
      ),
    );
  }

  @override
  Future<void> dismissTransient(int platformId) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _plugin.cancel(id: platformId);
  }

  @override
  Future<void> cancel(int platformId) async {
    if (platformId != runningDeliveryPlatformId) {
      await Workmanager().cancelByTag(deliveryTag(platformId));
    }
    await _plugin.cancel(id: platformId);
  }

  @override
  Future<List<PendingLocalNotification>> pending() async {
    final requests = await _plugin.pendingNotificationRequests();
    return requests
        .map(
          (request) => PendingLocalNotification(
            platformId: request.id,
            payload: request.payload,
          ),
        )
        .toList(growable: false);
  }

  @override
  NotificationResponseIntent? takeInitialResponse() =>
      _responseController.takeInitial();
}
