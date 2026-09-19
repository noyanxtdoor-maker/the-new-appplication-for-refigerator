import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/shell/planning_navigation.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart'
    show incompleteTaskCountProvider;

import 'package:rmplanner/features/unreported/application/unreported_providers.dart';

/// How a drawer destination is opened (Pack 3, Phase 3).
///
/// Only real, currently implemented destinations exist in the catalog;
/// unsupported destinations are omitted entirely (no placeholders, no
/// "coming soon" rows, no fake badges).
enum GlobalDrawerNavigation {
  /// Root tabs (Planner / More / Home): `go` reveals the existing root and
  /// never pushes a duplicate route.
  selectRoot,

  /// Shell-child pages under `/planner` or `/more`: `go` navigates inside
  /// the existing shell (one shell instance, no second bottom nav), and the
  /// Pack 2 root Back policy provides the direct-entry fallback.
  openInShell,

  /// Root-level child pages pushed above the shell (Activity History,
  /// Messages, About): `push` so Back returns to the screen that was
  /// beneath the drawer instead of dead-ending on the platform exit.
  push,
}

/// Which canonical count, if any, a drawer row shows as a RED NUMBER.
///
/// One enum keeps the two planning badges on the same visual component while
/// staying honest about what each number means.
enum GlobalDrawerBadge {
  none,

  /// The canonical INCOMPLETE Task count (completed Tasks never contribute).
  incompleteTasks,

  /// The canonical awaiting-report Event backlog size.
  unreported,
}

/// A single canonical drawer destination.
@immutable
final class GlobalDrawerEntry {
  const GlobalDrawerEntry._({
    required this.id,
    required this.label,
    required this.icon,
    required this.group,
    required this.routePath,
    this.navigation = GlobalDrawerNavigation.selectRoot,
    this.badge = GlobalDrawerBadge.none,
  });

  final String id;
  final String label;
  final IconData icon;
  final GlobalDrawerGroup group;
  final String routePath;
  final GlobalDrawerNavigation navigation;
  final GlobalDrawerBadge badge;
}

enum GlobalDrawerGroup { planning, personal, account, support }

/// Canonical drawer information architecture (Pack 3, Phase 2), filtered to
/// destinations that are actually implemented in the current build.
///
/// Destination deduplication: every feature has exactly one canonical route.
/// Planning, Plan History and Settings use the Pack 3 approved labels; the
/// obsolete "Weekly Planning" / "Weekly Plan History" labels are gone from the
/// drawer.
///
/// PRE-BETA (owner law, 2026-09-16): the `Life Goals` row was removed from the
/// drawer at the owner's request.  ONLY the drawer row is gone.  The route
/// (`RoutePaths.progress`, `/progress`, and its metric child routes), the
/// Life Goals list/detail/edit screens, the Goal records, the Goal feature,
/// Goal Planning, Plan History, Activity History and every Home Goal surface
/// are untouched; the row was the app's only navigation entry point to
/// `/progress`, so the list screen is intentionally unreachable from the UI
/// for now while remaining fully resolvable by route.
abstract final class GlobalDrawerCatalog {
  static const List<GlobalDrawerEntry> entries = <GlobalDrawerEntry>[
    // A. PLANNING -----------------------------------------------------
    //
    // Owner law (2026-09-19): the planning area becomes exactly two rows —
    // Tasks and Unreported.  The Planner, Goal Planning, Plan History and
    // Activity History rows are removed from the DRAWER ONLY: their screens,
    // routes, data and deep links are untouched (the Planner stays reachable
    // through the permanent bottom navigation, and the removed planning
    // surfaces remain fully resolvable by route).
    GlobalDrawerEntry._(
      id: 'drawer-tasks',
      label: 'Tasks',
      icon: Icons.task_alt_outlined,
      group: GlobalDrawerGroup.planning,
      routePath: RoutePaths.tasks,
      navigation: GlobalDrawerNavigation.openInShell,
      badge: GlobalDrawerBadge.incompleteTasks,
    ),
    GlobalDrawerEntry._(
      id: 'drawer-unreported',
      label: 'Unreported',
      icon: Icons.assignment_late_outlined,
      group: GlobalDrawerGroup.planning,
      routePath: RoutePaths.unreported,
      navigation: GlobalDrawerNavigation.openInShell,
      badge: GlobalDrawerBadge.unreported,
    ),
    // B. Personal Tools -----------------------------------------------
    // Quick Notes and Personal Journal are omitted (no complete real
    // module exists; Pack 3 locked policy 2/3).
    GlobalDrawerEntry._(
      id: 'drawer-messages',
      label: 'Messages',
      icon: Icons.chat_bubble_outline,
      group: GlobalDrawerGroup.personal,
      routePath: RoutePaths.messages,
      navigation: GlobalDrawerNavigation.push,
    ),
    // C. Programs and Resources ---------------------------------------
    // Entirely omitted: no approved canonical resource URLs exist in the
    // repository (Pack 3 locked policy 9).
    // D. Account and App ----------------------------------------------
    // Sync is still omitted (no canonical sync backend exists and no fake
    // sync status is shown; Pack 3 locked policy 8). Backup is no longer
    // omitted: VS-18 gives it a real canonical screen, so it gets a real
    // drawer row that opens that screen directly.
    GlobalDrawerEntry._(
      id: 'drawer-backup-restore',
      label: 'Backup & Restore',
      icon: Icons.cloud_download_outlined,
      group: GlobalDrawerGroup.account,
      routePath: RoutePaths.backupRecovery,
      navigation: GlobalDrawerNavigation.push,
    ),
    GlobalDrawerEntry._(
      id: 'drawer-account-settings',
      label: 'Settings',
      icon: Icons.settings_outlined,
      group: GlobalDrawerGroup.account,
      routePath: RoutePaths.settings,
      navigation: GlobalDrawerNavigation.openInShell,
    ),
    // E. Support -------------------------------------------------------
    // Report a Problem / Suggest a Feature are omitted (no approved real
    // support transport; Pack 3 locked policy 4).  Release Notes are
    // omitted (no real release-note source; locked policy 5).
    GlobalDrawerEntry._(
      id: 'drawer-about',
      label: 'About',
      icon: Icons.info_outline,
      group: GlobalDrawerGroup.support,
      routePath: RoutePaths.about,
      navigation: GlobalDrawerNavigation.push,
    ),
  ];

  /// The drawer groups in the order they appear.
  static const List<GlobalDrawerGroup> groupOrder = <GlobalDrawerGroup>[
    GlobalDrawerGroup.planning,
    GlobalDrawerGroup.personal,
    GlobalDrawerGroup.account,
    GlobalDrawerGroup.support,
  ];

  static String labelFor(GlobalDrawerGroup group) {
    return switch (group) {
      // Owner law (2026-09-19): the planning area heading is PLANNING.
      GlobalDrawerGroup.planning => 'PLANNING',
      GlobalDrawerGroup.personal => 'Personal Tools',
      GlobalDrawerGroup.account => 'Account and App',
      GlobalDrawerGroup.support => 'Support',
    };
  }
}

/// The canonical PMG-inspired global navigation drawer (Pack 3, Phase 1).
///
/// The drawer is a secondary navigation surface layered onto the existing
/// shell: one shell, the bottom navigation untouched, a compact Next
/// Transfer header, icon-and-label rows with no chevrons and no ordinary
/// subtitles, and a restrained selected state that is never color-only.
/// It opens over the current root, dims the background with the platform
/// scrim, closes on tap-outside and Android Back, stays transient (never
/// restored open after restart), and scrolls when contents overflow.
class GlobalAppDrawer extends ConsumerStatefulWidget {
  const GlobalAppDrawer({super.key});

  @override
  ConsumerState<GlobalAppDrawer> createState() => _GlobalAppDrawerState();
}

class _GlobalAppDrawerState extends ConsumerState<GlobalAppDrawer> {
  /// Owner law (2026-09-19, extended 2026-09-20): the PLANNING rows carry RED
  /// NUMERIC indicators derived from the same canonical providers the hub and
  /// the Tasks timeline use.  `Unreported` is the awaiting-report backlog size;
  /// `Tasks` is the INCOMPLETE Task count (completed Tasks never contribute).
  /// A zero count renders no number at all, and there are deliberately no
  /// subtitles.
  ///
  /// The subscriptions are created AFTER the frame, never inside initState and
  /// never during build.
  ///
  /// Subscribing to the backlog walks a chain of auto-disposing change
  /// streams.  If that chain is already dirty when the drawer mounts, the
  /// flush happens inside the build phase and the provider scope schedules its
  /// refresh with `setState` mid-frame, which the framework rejects.  Deferring
  /// to a post-frame callback keeps the flush outside the build phase; the
  /// drawer opens with an animation, so the numbers are in place for every
  /// frame the user actually sees.
  int _unreportedCount = 0;
  int _incompleteTaskCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.listenManual<int>(unreportedCountProvider, (_, next) {
        if (next == _unreportedCount) return;
        setState(() => _unreportedCount = next);
      }, fireImmediately: true);
      ref.listenManual<AsyncValue<int>>(incompleteTaskCountProvider, (_, next) {
        // A pending re-read keeps the last known number instead of flashing a
        // zero (and hiding the badge) while the canonical read is in flight.
        // The dot and the badges never flash to an empty state mid-refresh.
        final count = next.value;
        if (count == null || count == _incompleteTaskCount) return;
        setState(() => _incompleteTaskCount = count);
      }, fireImmediately: true);
    });
  }

  /// The canonical count this row shows, and what it counts.
  ({int count, String noun}) _badgeFor(GlobalDrawerEntry entry) {
    return switch (entry.badge) {
      GlobalDrawerBadge.none => (count: 0, noun: ''),
      GlobalDrawerBadge.incompleteTasks => (
        count: _incompleteTaskCount,
        noun: _incompleteTaskCount == 1
            ? 'incomplete task'
            : 'incomplete tasks',
      ),
      GlobalDrawerBadge.unreported => (
        count: _unreportedCount,
        noun: 'unreported',
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final currentLocation = GoRouterState.of(context).matchedLocation;
    // 84-88% of phone width, capped at ~360 dp on wider screens.
    final width = math.min(MediaQuery.sizeOf(context).width * 0.86, 360.0);
    return Drawer(
      key: const Key('global-app-drawer'),
      width: width,
      // NX-04: theme-aware surface.  Dark keeps the exact #181A1E surface
      // token byte-identical; Light resolves the semantic Light surface so
      // the drawer is never dark in Light appearance.
      backgroundColor: AppTheme.surfaceOf(context),
      surfaceTintColor: AppTheme.surfaceOf(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _DrawerHeader(),
            Expanded(
              child: ListView(
                key: const Key('global-app-drawer-list'),
                padding: const EdgeInsets.only(bottom: 20),
                children: <Widget>[
                  for (final group
                      in GlobalDrawerCatalog.groupOrder) ...<Widget>[
                    _DrawerGroupHeader(
                      label: GlobalDrawerCatalog.labelFor(group),
                    ),
                    for (final entry in GlobalDrawerCatalog.entries.where(
                      (e) => e.group == group,
                    ))
                      _DrawerEntryTile(
                        entry: entry,
                        isCurrent: entry.routePath == currentLocation,
                        badgeCount: _badgeFor(entry).count,
                        badgeNoun: _badgeFor(entry).noun,
                      ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact Next Transfer brand header.  No profile block, no avatar, no
/// ordinary subtitle, no fake account status (Pack 3, Phase 1 header rules).
class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('global-app-drawer-header'),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      decoration: BoxDecoration(
        // NX-04: header fill is the same theme-aware surface in Light and
        // keeps the exact darker #0D0E10 band in Dark.
        color: Theme.of(context).brightness == Brightness.dark
            ? AppTheme.background
            : Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: AppTheme.outlineOf(context))),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.rose.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'NT',
              style: TextStyle(
                color: AppTheme.rose,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Next Transfer',
              key: const Key('global-app-drawer-brand'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Roboto',
                fontSize: 17,
                height: 22 / 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DrawerGroupHeader extends StatelessWidget {
  const _DrawerGroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
        child: Text(
          label,
          key: Key('drawer-group-${label.toLowerCase().replaceAll(' ', '-')}'),
          style: TextStyle(
            fontFamily: 'Roboto',
            fontSize: 12.5,
            height: 16 / 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            // NX-04: Dark keeps #9CA0A6; Light resolves onSurfaceVariant.
            color: AppTheme.secondaryTextOf(context),
          ),
        ),
      ),
    );
  }
}

/// The ONE red numeric drawer badge (owner law, 2026-09-20).
///
/// Tasks and Unreported use this exact component: a number, never a word, and
/// nothing at all when the count is zero.  The accessibility label is pluralised
/// honestly by the caller.
final class DrawerCountBadge extends StatelessWidget {
  const DrawerCountBadge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$count',
      child: Container(
        constraints: const BoxConstraints(minWidth: 20),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          borderRadius: BorderRadius.circular(10),
        ),
        child: ExcludeSemantics(
          child: Text(
            '$count',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: 12,
              height: 16 / 12,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onError,
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerEntryTile extends StatelessWidget {
  const _DrawerEntryTile({
    required this.entry,
    required this.isCurrent,
    this.badgeCount = 0,
    this.badgeNoun,
  });

  final GlobalDrawerEntry entry;
  final bool isCurrent;

  /// A RED NUMERIC indicator, shown only when it is greater than zero.
  ///
  /// It is deliberately a number and never a count of something else: the value
  /// is the canonical count for this row's [GlobalDrawerBadge] kind, and zero
  /// hides the indicator entirely rather than rendering a zero.
  final int badgeCount;

  /// What the number counts, for the accessibility label only.
  final String? badgeNoun;

  /// The planning shell-child destinations record where they were opened FROM
  /// so their explicit back arrow can return there (owner law, 2026-09-20).
  static bool _recordsOrigin(String routePath) =>
      routePath == RoutePaths.tasks || routePath == RoutePaths.unreported;

  void _open(BuildContext context) {
    final currentLocation = GoRouterState.of(context).matchedLocation;
    // Close the drawer first; the drawer route lives on the shell navigator.
    Navigator.of(context).pop();
    // Current-destination tap: close only, never add a route.
    if (entry.routePath == currentLocation) {
      return;
    }
    final router = GoRouter.of(context);
    switch (entry.navigation) {
      case GlobalDrawerNavigation.selectRoot:
      case GlobalDrawerNavigation.openInShell:
        if (_recordsOrigin(entry.routePath)) {
          openPlanningDestinationFrom(
            context,
            entry.routePath,
            currentLocation,
          );
          return;
        }
        router.go(entry.routePath);
      case GlobalDrawerNavigation.push:
        unawaited(router.push(entry.routePath));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Selected state follows the semantic Theme Color primary (Rose Dark
    // resolves to the exact canonical rose so dark goldens stay
    // byte-identical; Blue mode resolves to Blue).
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      selected: isCurrent,
      button: true,
      label: badgeCount > 0
          ? '${entry.label}, $badgeCount ${badgeNoun ?? ''}'.trimRight()
          : entry.label,
      child: InkWell(
        key: Key(entry.id),
        onTap: () => _open(context),
        child: Container(
          // A minimum row height keeps the 48+ dp touch target while the row
          // grows at increased text scale instead of clipping (Pack 3
          // accessibility requirement).
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: isCurrent
              ? BoxDecoration(color: accent.withValues(alpha: 0.10))
              : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              // Reserved indicator slot: a left accent bar that appears
              // only when selected, so the selection is never indicated by
              // color alone and the row never shifts when selection changes.
              SizedBox(
                width: 4,
                height: 22,
                child: isCurrent
                    ? DecoratedBox(
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Icon(
                entry.icon,
                size: 23,
                // NX-04: Dark keeps #D6D8DB; Light resolves onSurfaceVariant.
                color: isCurrent
                    ? accent
                    : Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFFD6D8DB)
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  entry.label,
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 15.5,
                    height: 20 / 15.5,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                    // NX-04: Dark keeps #ECEDEF; Light resolves onSurface.
                    color: isCurrent
                        ? accent
                        : Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFFECEDEF)
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              if (badgeCount > 0) ...<Widget>[
                const SizedBox(width: 12),
                DrawerCountBadge(
                  key: Key(
                    'drawer-${entry.id.replaceFirst('drawer-', '')}-badge',
                  ),
                  count: badgeCount,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
