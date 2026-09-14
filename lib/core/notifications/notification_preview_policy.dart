import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

enum EffectiveNotificationPreviewMode { generic, detailed }

/// M2 OWNER CORRECTION (Issue 1, 2026-09-14) — notification CONTENT law.
///
/// The saved notification content preference ALONE decides the preview:
///
///   explicit Generic/private choice (hidden)  -> Generic
///   detailed content enabled (showContent)    -> Detailed
///
/// Privacy Lock is no longer an input to notification content selection.
/// Privacy Lock remains authoritative ONLY for app-entry authentication,
/// startup access gates, pending notification OPEN handling, the five-minute
/// relock, and stale startup publication prevention — never for
/// system-notification content preview.
EffectiveNotificationPreviewMode resolveNotificationPreviewMode({
  required PrivacySettings settings,
}) {
  return settings.notificationPreviewMode == NotificationPreviewMode.showContent
      ? EffectiveNotificationPreviewMode.detailed
      : EffectiveNotificationPreviewMode.generic;
}
