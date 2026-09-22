import 'dart:ui' show Color;

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

/// OWNER DECISION (2026-09-22, final notification-identity restoration) — the
/// notification's identity IS the app icon.
///
/// WHY THIS REPLACED THE MONOCHROME MARK.  The owner's correction was explicit:
/// stop redrawing the small icon and restore the actual app-icon presentation, so
/// the identity on the left of the card reads as Next Transfer. The audit that
/// preceded this change is on the record too, because it explains what "restore"
/// can and cannot mean here: every shipped Next Transfer build — nine artifacts
/// from 2026-09-08 to 2026-09-22, debug/profile/AAB, reading both AOT snapshots and
/// debug kernel blobs — passed `@drawable/ic_nt_notification`, a custom monochrome
/// white vector. The app icon was NEVER the notification icon, so no historical
/// setting can be restored. What IS true is the mechanism: Android derives the
/// notification card's identity from the notification's small icon (drawn through
/// the icon's ALPHA channel), so that input is the only lever, and a white mark can
/// never read as the app icon however it is drawn.
///
/// `@mipmap/ic_launcher` is the canonical app-icon resource — the adaptive launcher
/// icon the home screen shows — and is the plugin's own documented value for this
/// purpose, used against the official monochrome guidance deliberately, on the
/// owner's direct device evidence, as the owner-review ticket directs:
/// "It is possible to use launcher icon/mipmap ... can be passed
/// `AndroidInitializationSettings` constructor. However, the official Android
/// guidance is that you should use drawable resources." (flutter_local_notifications
/// 22.3.0 README). It resolves through the same
/// `getIdentifier(name, "drawable", package)` lookup the plugin uses for every
/// icon, because the name is TYPE-PREFIXED.
///
/// TRADE-OFF ON THE RECORD: this artwork is opaque, so the STATUS BAR draws its
/// silhouette — a filled shape rather than a thin glyph. The shade, which is the
/// surface the owner judges, draws the brand artwork itself.
///
/// REVERT: [ntNotificationIconResource] below is the Android-compliant monochrome
/// mark. It stays maintained, stays kept by `res/raw/keep.xml`, and stays guarded
/// by tests, so reverting is this constant plus the initialization value beside it.
const String ntNotificationAppIconResource = '@mipmap/ic_launcher';

/// The Android-compliant monochrome notification small icon, kept as the
/// documented fallback (owner decision, 2026-09-22 — see
/// [ntNotificationAppIconResource]).
///
/// WHY ANY ICON MUST BE NAMED EXPLICITLY.  The plugin resolves an icon by NAME at
/// runtime, so every `AndroidNotificationDetails` this app builds names its icon
/// instead of relying on the default registered by `initialize()`.
///
/// That reliance was the HOTFIX defect (2026-09-19): if `initialize()`
/// does not persist a default icon (which is what happened in release builds, where
/// the drawable was stripped as unreferenced), then the plugin's
/// `setSmallIcon` fallback unboxes a null `iconResourceId` and **crashes the whole
/// process** when a scheduled reminder alarm fires. Naming the icon per send keeps
/// every notification path on the resolved-resource branch, so a missing default can
/// never take the process down again. `res/raw/keep.xml` keeps every resource this
/// app resolves by name.
const String ntNotificationIconResource = 'ic_nt_notification';

/// The ONE derivation of the notification tint (post-P2 owner decision,
/// 2026-09-22).
///
/// The audit proved the reported green notification glyph was a COLOUR
/// problem, not a debug artefact: nothing supplied a notification colour and no
/// `colorAccent`/`colorPrimary` is declared in any Android theme, so Android
/// tinted the monochrome small icon with the platform/AppCompat fallback —
/// `@color/material_deep_teal_500` (#ff008577) in light mode, which the shipped
/// profile APK still resolves. That is the green the owner saw.
///
/// The approved brand field is the same #FF002161 the launch window and the
/// adaptive launcher icon background already use (`nt_brand_blue`). Setting it
/// explicitly means the tint no longer depends on which theme the process
/// happens to resolve, or on the OEM presenter's defaults.
///
/// `colorized: false` keeps the icon itself untinted artwork and lets Android
/// apply the colour the canonical way for the small icon.
const Color ntNotificationTint = Color(0xFF002161);

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
        // OWNER DECISION (2026-09-22, final restoration): the notification
        // identity is the app icon itself — see [ntNotificationAppIconResource]
        // for the audit trail and the trade-off. The value registered here and the
        // per-send `icon:` must stay the SAME resource, or a scheduled reminder
        // would carry a different identity from the cards around it.
        android: AndroidInitializationSettings(ntNotificationAppIconResource),
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
          // NEVER depend on the startup-registered default icon: name the
          // identity explicitly on every path (see
          // [ntNotificationAppIconResource]).
          icon: ntNotificationAppIconResource,
          // NO large icon (owner decision, 2026-09-22): the owner judged the
          // full-colour logo on the right of the card unwanted, so the card
          // carries the notification identity and the text only — and that
          // identity is now the app icon itself, named above.
          // Owner decision (2026-09-22): an explicit brand tint instead of the
          // platform accent fallback that produced the green glyph.
          color: ntNotificationTint,
          colorized: false,
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
          // NEVER depend on the startup-registered default icon: name the
          // identity explicitly on every path (see
          // [ntNotificationAppIconResource]).
          icon: ntNotificationAppIconResource,
          // No large icon here either (owner decision, 2026-09-22): one
          // identity across every surface, and it is the small icon's — now the
          // canonical app icon resource named above.
          // Same explicit brand tint as the reminder path (owner decision
          // 2026-09-22): one notification identity across the whole app.
          color: ntNotificationTint,
          colorized: false,
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
