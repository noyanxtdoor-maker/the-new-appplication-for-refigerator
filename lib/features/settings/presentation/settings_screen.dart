import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/shell/window_size_class.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';

/// Canonical centralized Settings home (Pack 3, Phase 4).
///
/// Only sections and rows that are real and supported are shown.  Omitted
/// here (with reasons documented in the Pack 3 report):
///   - Appearance: dark-only architecture (hard-coded AppTheme tokens on
///     every screen) cannot safely support a complete Light/System theme or
///     a Rose/Blue accent switch within Pack 3 (locked policy 10).
///   - Accessibility / Country and Language: no functional preferences
///     exist to expose (locked policy 8).
///   - Contacts: the Contacts slice is not an implemented feature yet.
///   - Account and Sync: guest-first; no fake sync status is shown.
///
/// Settings is the only top-level drawer destination for Privacy and Data,
/// Permissions, and the planner/calendar preferences: they are never
/// duplicated as separate drawer rows.
final class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const List<String> _dayNames = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final startOfWeek = ref.watch(startOfWeekProvider);
    final startOfWeekLabel = _dayNames[startOfWeek - DateTime.monday];
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Settings')),
      body: SafeArea(
        // PRE-BETA RESPONSIVE (owner law, 2026-09-16): ordinary settings
        // content stops stretching across a wide window.  At phone widths this
        // wrapper is layout-neutral, so the accepted phone appearance is
        // unchanged.
        child: MaxContentWidth(
          child: ListView(
            padding: InternalScreen.pagePadding,
            children: <Widget>[
              const _SettingsSectionLabel('PRIVACY AND DEVICE'),
              Card(
                margin: EdgeInsets.zero,
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: AppTheme.outlineOf(context)),
                ),
                child: Column(
                  children: <Widget>[
                    ListTile(
                      key: const Key('settings-appearance'),
                      leading: const Icon(Icons.contrast_outlined),
                      title: const Text('Appearance'),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => context.push(RoutePaths.appearance),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('settings-privacy-data'),
                      leading: const Icon(Icons.shield_outlined),
                      title: const Text('Privacy and Data'),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => context.push(RoutePaths.privacyCenter),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('settings-permissions'),
                      leading: const Icon(Icons.lock_outline),
                      title: const Text('Permissions'),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => context.push(RoutePaths.permissions),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('settings-notifications'),
                      leading: const Icon(Icons.notifications_outlined),
                      title: const Text('Notifications'),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () =>
                          context.push(RoutePaths.notificationsSettings),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const _SettingsSectionLabel('MAPS'),
              Card(
                margin: EdgeInsets.zero,
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: AppTheme.outlineOf(context)),
                ),
                child: Column(
                  children: <Widget>[
                    ListTile(
                      key: const Key('settings-maps'),
                      leading: const Icon(Icons.map_outlined),
                      title: const Text('Maps'),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => context.push(RoutePaths.mapsSettings),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const _SettingsSectionLabel('PLANNER AND CALENDAR'),
              Card(
                margin: EdgeInsets.zero,
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: AppTheme.outlineOf(context)),
                ),
                child: Column(
                  children: <Widget>[
                    ListTile(
                      key: const Key('settings-planner-calendar'),
                      leading: const Icon(Icons.calendar_month_outlined),
                      title: const Text('Planner and Calendar'),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => context.push(RoutePaths.plannerSettings),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('settings-colors'),
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('Colors'),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => context.push(RoutePaths.colors),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const _SettingsSectionLabel('PLANNING'),
              Card(
                margin: EdgeInsets.zero,
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: AppTheme.outlineOf(context)),
                ),
                child: Column(
                  children: <Widget>[
                    ListTile(
                      key: const Key('settings-start-of-week'),
                      leading: const Icon(Icons.calendar_view_week_outlined),
                      title: const Text('Start of week'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(startOfWeekLabel),
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right, size: 20),
                        ],
                      ),
                      onTap: () => context.push(RoutePaths.startOfWeek),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSectionLabel extends StatelessWidget {
  const _SettingsSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
        child: Text(
          label,
          key: Key(
            'settings-section-${label.toLowerCase().replaceAll(' ', '-')}',
          ),
          style: TextStyle(
            fontFamily: 'Roboto',
            fontSize: 12.5,
            height: 16 / 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: AppTheme.secondaryTextOf(context),
          ),
        ),
      ),
    );
  }
}
