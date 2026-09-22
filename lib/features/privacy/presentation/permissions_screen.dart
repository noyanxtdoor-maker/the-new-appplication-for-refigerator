import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

/// What tapping a permission row may lawfully do.
///
/// The distinction is the whole point of this screen: Android only shows a
/// runtime dialog while a permission is still requestable. Once it is
/// permanently denied (or was granted and later revoked in system settings) a
/// second `request()` returns denied immediately and shows the user NOTHING, so
/// promising a prompt there would be a lie. Those rows must route to Android's
/// own app settings instead.
enum _PermissionAction {
  /// A runtime dialog is still possible.
  request,

  /// Android will not prompt again: only the system settings screen can change
  /// the answer.
  openSettings,

  /// Nothing to do: already granted, or the permission is not available in this
  /// build at all.
  none,
}

/// Owner decision (2026-09-22, post-P2 audit): the four rows describe optional
/// capabilities, and each row says exactly what it can do.
///
/// This screen previously rendered four status chips with NO row action at all —
/// the only interactive control was the footer button. Permission state was
/// therefore readable but never actionable in-app, even for permissions that are
/// still perfectly requestable.
final class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

final class _PermissionsScreenState extends ConsumerState<PermissionsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A permission answer can be changed OUTSIDE the app (the Android app-settings
  /// screen this page itself opens, or the system dialog). Re-reading the
  /// canonical summaries on resume is the only way the chips stay truthful
  /// instead of showing the answer from before the user left.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(permissionSummariesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summaries = ref.watch(permissionSummariesProvider);

    return Scaffold(
      appBar: InternalAppBar(title: const Text('Permissions')),
      body: SafeArea(
        child: summaries.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => _PermissionError(
            onRetry: () => ref.invalidate(permissionSummariesProvider),
          ),
          data: (items) => ListView(
            // The app's shared internal-screen padding, so this page cannot
            // drift from every other settings surface's rhythm.
            padding: InternalScreen.pagePadding,
            children: <Widget>[
              // One grouped card with dividers — the same pattern the Settings
              // home and Notifications screens already use. Four touching cards
              // with no gap was the reported "dense" layout.
              Card(
                child: Column(
                  children: <Widget>[
                    for (
                      var index = 0;
                      index < items.length;
                      index++
                    ) ...<Widget>[
                      if (index > 0) const Divider(height: 1),
                      _PermissionTile(
                        summary: items[index],
                        action: _actionFor(items[index]),
                        onTap: () => _act(items[index]),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: InternalScreen.sectionGap),
              OutlinedButton.icon(
                key: const Key('open-system-settings-button'),
                onPressed: _openSystemSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Open Android app settings'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _act(PermissionSummary summary) async {
    switch (_actionFor(summary)) {
      case _PermissionAction.request:
        await _request(summary.permission);
      case _PermissionAction.openSettings:
        await _openSystemSettings();
      case _PermissionAction.none:
        break;
    }
  }

  /// The state this row SHOWS. The Device calendar row is reported as
  /// Unavailable regardless of what the platform answers, because this build
  /// declares no calendar permission and ships no calendar integration: showing
  /// "Granted" or "Denied" there would describe a capability that does not
  /// exist. Owner decision (2026-09-22): keep the row as an honest placeholder.
  PermissionState _displayState(PermissionSummary summary) =>
      summary.permission == OptionalPermission.calendar
      ? PermissionState.unavailable
      : summary.state;

  _PermissionAction _actionFor(PermissionSummary summary) {
    if (summary.permission == OptionalPermission.calendar) {
      // Never request an undeclared permission: the call cannot prompt and
      // cannot succeed.
      return _PermissionAction.none;
    }
    return switch (_displayState(summary)) {
      PermissionState.notRequested ||
      PermissionState.denied => _PermissionAction.request,
      // `revoked` is exactly "was granted, is now denied in system settings" —
      // Android will not prompt again, so only the settings screen can help.
      PermissionState.revoked => _PermissionAction.openSettings,
      PermissionState.granted ||
      PermissionState.unavailable => _PermissionAction.none,
    };
  }

  /// Requests through the ONE canonical permission gateway.
  ///
  /// The audit trail is written around the call because the summary's own
  /// requested/ever-granted flags decide whether a denial reads as
  /// "Not requested" or "Denied". Requesting without recording would leave the
  /// chip claiming the app never asked — visibly wrong immediately after the
  /// user just answered a dialog.
  Future<void> _request(OptionalPermission permission) async {
    final repository = ref.read(privacyRepositoryProvider);
    OperatingSystemPermissionState result;
    try {
      await repository.recordPermissionRequested(permission);
      result = await ref.read(permissionGatewayProvider).request(permission);
      if (result == OperatingSystemPermissionState.granted) {
        await repository.recordPermissionGranted(permission);
      }
    } on Object {
      // A failed platform call must not invent a state; the refresh below
      // re-reads canonical OS truth either way.
      result = OperatingSystemPermissionState.unavailable;
    }
    if (!mounted) return;
    if (result == OperatingSystemPermissionState.permanentlyDenied) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Android will not ask again. Use "Open Android app settings" to '
            'change this permission.',
          ),
        ),
      );
    }
    ref.invalidate(permissionSummariesProvider);
  }

  Future<void> _openSystemSettings() async {
    final opened = await ref
        .read(permissionGatewayProvider)
        .openSystemSettings();
    if (!mounted) {
      return;
    }
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Android app settings could not be opened.'),
        ),
      );
    }
    ref.invalidate(permissionSummariesProvider);
  }
}

final class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.summary,
    required this.action,
    required this.onTap,
  });

  final PermissionSummary summary;
  final _PermissionAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isCalendar = summary.permission == OptionalPermission.calendar;
    final state = isCalendar ? PermissionState.unavailable : summary.state;
    final stateLabel = _stateLabel(state);
    // Only a row that can DO something is interactive. The Device calendar row
    // is informational (never tappable, never a claimed capability), and a
    // granted row must not offer a redundant request or a settings detour.
    final enabled = action != _PermissionAction.none;

    return ListTile(
      key: Key('permission-row-${summary.permission.name}'),
      enabled: enabled,
      leading: Icon(_icon(summary.permission)),
      title: Text(summary.title),
      subtitle: Text(
        isCalendar ? 'Not available in this build.' : summary.purpose,
      ),
      trailing: Semantics(
        label: '${summary.title} status $stateLabel',
        child: Chip(label: Text(stateLabel)),
      ),
      onTap: enabled ? onTap : null,
    );
  }

  static IconData _icon(OptionalPermission permission) {
    return switch (permission) {
      OptionalPermission.contacts => Icons.contacts_outlined,
      OptionalPermission.notifications => Icons.notifications_outlined,
      OptionalPermission.foregroundLocation => Icons.location_on_outlined,
      OptionalPermission.calendar => Icons.calendar_month_outlined,
    };
  }

  static String _stateLabel(PermissionState state) {
    return switch (state) {
      PermissionState.notRequested => 'Not requested',
      PermissionState.granted => 'Granted',
      PermissionState.denied => 'Denied',
      PermissionState.revoked => 'Revoked',
      PermissionState.unavailable => 'Unavailable',
    };
  }
}

final class _PermissionError extends StatelessWidget {
  const _PermissionError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'Permission status could not be read. No permission was requested.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
