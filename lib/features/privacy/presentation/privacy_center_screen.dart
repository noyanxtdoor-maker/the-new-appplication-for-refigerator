import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/deletion_impact.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:rmplanner/features/privacy/presentation/privacy_policy_link.dart';

final class PrivacyCenterScreen extends ConsumerWidget {
  const PrivacyCenterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final privacy = ref.watch(privacyControllerProvider);
    final controller = ref.read(privacyControllerProvider.notifier);

    return Scaffold(
      appBar: InternalAppBar(title: const Text('Privacy and Data')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: <Widget>[
            Text(
              'Privacy controls',
              style: InternalScreen.sectionHeading.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),
            Card(
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('privacy-lock-switch'),
                    value: privacy.settings.lockEnabled,
                    onChanged: privacy.isBusy
                        ? null
                        : (enabled) async {
                            if (enabled) {
                              await controller.enableLock();
                            } else {
                              await controller.disableLock();
                            }
                          },
                    secondary: const Icon(Icons.lock_outline),
                    title: const Text('Privacy Lock'),
                  ),
                  if (privacy.isBusy)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: LinearProgressIndicator(),
                    ),
                  if (privacy.message != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          privacy.message!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: SwitchListTile(
                key: const Key('notification-preview-switch'),
                value:
                    privacy.settings.notificationPreviewMode ==
                    NotificationPreviewMode.showContent,
                onChanged: (showContent) async {
                  await controller.setNotificationPreviewMode(
                    showContent
                        ? NotificationPreviewMode.showContent
                        : NotificationPreviewMode.hidden,
                  );
                },
                secondary: const Icon(Icons.notifications_outlined),
                title: const Text('Show content in notification previews'),
              ),
            ),
            const SizedBox(height: 18),
            _SectionTitle(title: 'Data security'),
            const SizedBox(height: 8),
            const _BoundaryTile(
              icon: Icons.key_outlined,
              title: 'Authentication secrets',
              detail:
                  'Future account tokens use Android secure storage, not the '
                  'planner database or backups.',
            ),
            const SizedBox(height: 12),
            // Required factual privacy disclaimer. It remains explicit and is
            // not treated as preference-helper copy.
            const Text(
              'Next Transfer does not claim full-database encryption or '
              'end-to-end encryption. It states only protections implemented '
              'and verified.',
            ),
            const SizedBox(height: 18),
            _SectionTitle(title: 'Review and control'),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.admin_panel_settings_outlined),
                    title: const Text('Permissions'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(RoutePaths.permissions),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    key: const Key('diagnostic-preview-tile'),
                    leading: const Icon(Icons.bug_report_outlined),
                    title: const Text('Diagnostic export preview'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(RoutePaths.diagnosticPreview),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    key: const Key('backup-recovery-tile'),
                    leading: const Icon(Icons.backup_outlined),
                    title: const Text('Backup & Restore'),
                    subtitle: const Text(
                      'Back up your Next Transfer data, or restore it from a '
                      'backup file.',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(RoutePaths.backupRecovery),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    key: const Key('deletion-impact-tile'),
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('Review deletion impacts'),
                    trailing: const Icon(Icons.info_outline),
                    onTap: () => _showDeletionImpact(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _SectionTitle(title: 'Legal'),
            const SizedBox(height: 8),
            // Google Play's User Data policy expects our published Privacy
            // Policy to be reachable from inside the application, not only
            // from the store listing. The row opens the canonical page in the
            // user's own browser; nothing is loaded in-app and no permission
            // is involved.
            Card(
              child: ListTile(
                key: const Key('privacy-policy-link'),
                leading: const Icon(Icons.policy_outlined),
                title: const Text('Privacy Policy'),
                subtitle: const Text(
                  'Read how Next Transfer handles your data.',
                ),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => _openPrivacyPolicy(context, ref),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the published Privacy Policy externally.
  ///
  /// The URL is the canonical page from [privacyPolicyUrl]; nothing about the
  /// user or device is appended. A handoff that no installed app accepts is
  /// reported as ordinary feedback rather than an exception.
  Future<void> _openPrivacyPolicy(BuildContext context, WidgetRef ref) async {
    final opened = await ref.read(externalUriLauncherProvider)(
      Uri.parse(privacyPolicyUrl),
    );
    if (opened || !context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Unable to open the Privacy Policy.')),
      );
  }

  Future<void> _showDeletionImpact(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Deletion impacts'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'These are separate operations. Review the affected copy '
                  'before confirming any future destructive action.',
                ),
                const SizedBox(height: 16),
                for (final impact in DeletionImpactCatalog.values) ...[
                  Text(
                    impact.title,
                    style: Theme.of(dialogContext).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(impact.explanation),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
  }
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: InternalScreen.sectionHeading.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

final class _BoundaryTile extends StatelessWidget {
  const _BoundaryTile({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(detail),
      ),
    );
  }
}
