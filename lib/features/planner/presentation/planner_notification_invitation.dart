/// OWNER REVIEW #4 — the contextual notification invitation.
///
/// A beta user who never discovers Android's notification settings receives
/// nothing and has no way to find out why. This is the Planner's own restrained
/// invitation: it is contextual to the Planner, it never blocks Planner use, and
/// it never fires the Android permission dialog by itself.
///
/// The Android dialog is only ever raised by an explicit tap on the enable
/// action, which routes through the SAME serialized controller path the
/// Notifications settings screen already uses. There is deliberately no second
/// permission system.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

/// One Planner visit.
///
/// A visit is counted per entry into the Planner, so dismissing the invitation
/// hides it for that visit only. The owner's requirement is that a user who
/// tapped "Don't allow" by accident still gets another chance on a later visit;
/// a permanent "already shown" flag could never provide that, so visibility is
/// derived from live permission state plus how many times the user has answered
/// within the current visit.
final plannerNotificationVisitsProvider =
    NotifierProvider<PlannerNotificationVisits, int>(
      PlannerNotificationVisits.new,
    );

final class PlannerNotificationVisits extends Notifier<int> {
  @override
  int build() => 0;

  /// Records that the Planner was entered again.
  void markVisit() => state = state + 1;
}

/// How many times the user has answered the invitation so far.
final plannerNotificationAnswersProvider =
    NotifierProvider<PlannerNotificationAnswers, int>(
      PlannerNotificationAnswers.new,
    );

final class PlannerNotificationAnswers extends Notifier<int> {
  @override
  int build() => 0;

  /// "Not now" is an answer, not a permanent opt-out.
  void answer() => state = state + 1;
}

/// What, if anything, the Planner should show.
enum PlannerNotificationInvitationKind {
  /// Nothing: notifications already work, or the app cannot know yet.
  hidden,

  /// Android has not been asked (or the user said no once): invite.
  invitation,

  /// Android will no longer show its own dialog: offer App Settings instead.
  openSettings,
}

/// The single derivation of invitation visibility.
///
/// `granted` means Android will deliver, so the invitation never appears and a
/// successful grant can never leave a stale prompt behind. `permanentlyDenied`
/// and `restricted` are the states where another runtime request would be a dead
/// end, so those become the Open Settings variant. Everything else — not yet
/// requested, dismissed, or denied once — is the plain invitation.
final plannerNotificationInvitationProvider =
    Provider<PlannerNotificationInvitationKind>((ref) {
      final settings = ref.watch(notificationSettingsControllerProvider);
      if (settings.loading) {
        return PlannerNotificationInvitationKind.hidden;
      }
      final permission = settings.permission;
      if (permission == OperatingSystemPermissionState.granted) {
        return PlannerNotificationInvitationKind.hidden;
      }
      // An answer hides the invitation for the current visit only.
      final answered =
          ref.watch(plannerNotificationAnswersProvider) >=
          ref.watch(plannerNotificationVisitsProvider);
      if (answered) return PlannerNotificationInvitationKind.hidden;

      return switch (permission) {
        OperatingSystemPermissionState.permanentlyDenied ||
        OperatingSystemPermissionState.restricted =>
          PlannerNotificationInvitationKind.openSettings,
        // OWNER REVIEW #4: `unavailable` means Android did not answer — the
        // platform has no notification permission model, or the permission
        // gateway is not wired at all. There is then nothing truthful to invite
        // the user to, and offering a switch the app cannot act on would be a
        // lie. The Planner stays silent. Only a real refusal (denied, which also
        // covers never-asked) produces the invitation.
        OperatingSystemPermissionState.unavailable =>
          PlannerNotificationInvitationKind.hidden,
        _ => PlannerNotificationInvitationKind.invitation,
      };
    });

/// Whether this platform actually has the Android notification permission model
/// the education exists to explain.
///
/// The education asks the user to let Android deliver notifications, which only
/// means something where Android owns a `POST_NOTIFICATIONS` permission. On a
/// host without that model — a desktop test VM, a platform build — there is
/// nothing truthful to invite the user to, and offering a switch the app cannot
/// act on would be a lie. This is a capability, not a test switch: the shipped
/// app is Android and sees `true`.
final notificationEducationSupportedProvider = Provider<bool>(
  (ref) => !kIsWeb && Platform.isAndroid,
);

/// What the user chose in the education sheet.
///
/// A dismissed sheet (barrier tap, system back) returns `null` and is treated as
/// "not now" for that visit: the app must not nag twice in one Planner session,
/// and it must never treat a dismissal as consent.
enum PlannerNotificationEducationOutcome {
  /// The user asked the app to turn notifications on.
  enable,

  /// The user declined for now. Not a permanent opt-out.
  notNow,
}

/// OWNER RULING (2026-09-18): the notification education lives at the SHELL /
/// NAVIGATION boundary, never inside `PlannerScreen`.
///
/// Three mounting points inside the Planner were built and measured, and each
/// one broke a different accepted contract: a bottom overlay stole real canvas
/// hit tests, a top overlay stole the accepted toolbar/header taps, and a
/// navigation-bar strip changed the body height the canvas geometry is measured
/// against. The Planner's accepted geometry and hit-test contract is therefore
/// left byte-for-byte unchanged, and the education is shown here instead — by
/// the shell, BEFORE the Planner is activated, so it cannot participate in
/// Planner layout or hit testing at all.
final class PlannerNotificationEducationSheet extends ConsumerWidget {
  const PlannerNotificationEducationSheet({super.key});

  static const Key sheetKey = Key('planner-notification-education');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final openSettings =
        ref.watch(plannerNotificationInvitationProvider) ==
        PlannerNotificationInvitationKind.openSettings;
    return SafeArea(
      key: sheetKey,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              openSettings
                  ? 'Notifications are turned off for Next Transfer.'
                  : 'Turn on notifications?',
              style: AppTypography.sectionTitle,
            ),
            if (!openSettings) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                'Get reminders for your Events, Tasks, Goals, and follow-ups.',
                style: AppTypography.secondary,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                TextButton(
                  key: PlannerNotificationInvitation.notNowKey,
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(PlannerNotificationEducationOutcome.notNow),
                  child: const Text('Not now'),
                ),
                FilledButton(
                  key: openSettings
                      ? PlannerNotificationInvitation.openSettingsKey
                      : PlannerNotificationInvitation.enableKey,
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(PlannerNotificationEducationOutcome.enable),
                  child: Text(
                    openSettings ? 'Open Settings' : 'Enable notifications',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class PlannerNotificationInvitation extends ConsumerStatefulWidget {
  const PlannerNotificationInvitation({super.key});

  static const Key cardKey = Key('planner-notification-invitation');
  static const Key enableKey = Key('planner-notification-enable');
  static const Key notNowKey = Key('planner-notification-not-now');
  static const Key openSettingsKey = Key('planner-notification-open-settings');

  @override
  ConsumerState<PlannerNotificationInvitation> createState() =>
      _PlannerNotificationInvitationState();
}

final class _PlannerNotificationInvitationState
    extends ConsumerState<PlannerNotificationInvitation> {
  @override
  void initState() {
    super.initState();
    // Counted after the first frame: marking a visit during initState would
    // mutate a provider while the first build is still in progress.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(plannerNotificationVisitsProvider.notifier).markVisit();
    });
  }

  /// One explicit user action route. The controller serializes it, requests only
  /// when Android still can, and opens App Settings when it cannot.
  Future<void> _enable() async {
    await ref
        .read(notificationSettingsControllerProvider.notifier)
        .setSystemNotificationsEnabled(true);
  }

  @override
  Widget build(BuildContext context) {
    final kind = ref.watch(plannerNotificationInvitationProvider);
    if (kind == PlannerNotificationInvitationKind.hidden) {
      return const SizedBox.shrink();
    }
    final openSettings = kind == PlannerNotificationInvitationKind.openSettings;
    return Padding(
      key: PlannerNotificationInvitation.cardKey,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                openSettings
                    ? 'Notifications are turned off for Next Transfer.'
                    : 'Turn on notifications?',
                style: AppTypography.sectionTitle,
              ),
              if (!openSettings) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  'Get reminders for your Events, Tasks, Goals, and '
                  'follow-ups.',
                  style: AppTypography.secondary,
                ),
              ],
              const SizedBox(height: 4),
              // OWNER REVIEW #4: a Wrap, not a Row. The two actions are wider
              // than a narrow phone's Planner width, and a fixed Row overflowed
              // by 165px at 341px of available space — which is a real layout
              // regression, not a cosmetic one. Wrapping lets the actions stack
              // on a short window instead of painting an overflow band.
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                runSpacing: 4,
                children: <Widget>[
                  TextButton(
                    key: PlannerNotificationInvitation.notNowKey,
                    onPressed: () => ref
                        .read(plannerNotificationAnswersProvider.notifier)
                        .answer(),
                    child: const Text('Not now'),
                  ),
                  FilledButton(
                    key: openSettings
                        ? PlannerNotificationInvitation.openSettingsKey
                        : PlannerNotificationInvitation.enableKey,
                    onPressed: _enable,
                    child: Text(
                      openSettings ? 'Open Settings' : 'Enable notifications',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
