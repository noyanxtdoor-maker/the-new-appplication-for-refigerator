import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/shell/global_drawer_controller.dart';
import 'package:rmplanner/app/shell/nav_destination_icon.dart';
import 'package:rmplanner/app/shell/window_size_class.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/planner/presentation/planner_notification_invitation.dart';
import 'package:rmplanner/features/shell/global_app_drawer.dart';

/// ONE canonical destination model for the shell.
///
/// PRE-BETA RESPONSIVE (owner law, 2026-09-16): the shell presents the SAME
/// four destinations in the bottom bar on a compact window and in the side rail
/// on a wider one.  Both presentations are generated from this single list, so
/// there is exactly one label/icon/key/route definition and the two
/// presentations can never drift apart.
final class _ShellDestination {
  const _ShellDestination({
    required this.key,
    required this.label,
    required this.routePath,
    required this.icon,
    this.selectedIcon,
  });

  final Key key;
  final String label;
  final String routePath;
  final Widget icon;
  final Widget? selectedIcon;
}

/// Home / Planner / Contacts / Maps, in the accepted order.
///
/// Artwork law is unchanged: Home, Planner and Maps keep the owner-supplied
/// SVGs (with the pin's renderer-only optical correction), Contacts keeps its
/// Material icon pair.
const List<_ShellDestination> _shellDestinations = <_ShellDestination>[
  _ShellDestination(
    key: Key('nav-home'),
    label: 'Home',
    routePath: RoutePaths.home,
    icon: NavDestinationIcon(asset: NavDestinationIcon.houseAsset),
  ),
  _ShellDestination(
    key: Key('nav-planner'),
    label: 'Planner',
    routePath: RoutePaths.planner,
    icon: NavDestinationIcon(asset: NavDestinationIcon.calendarAsset),
  ),
  _ShellDestination(
    key: Key('nav-contacts'),
    label: 'Contacts',
    routePath: RoutePaths.contacts,
    icon: Icon(Icons.people_outline),
    selectedIcon: Icon(Icons.people),
  ),
  _ShellDestination(
    key: Key('nav-maps'),
    label: 'Maps',
    routePath: RoutePaths.maps,
    icon: NavDestinationIcon(
      asset: NavDestinationIcon.mapPinAsset,
      // Solid 16-grid glyph: optically corrected so its ink height matches the
      // 24-grid stroke icons.
      opticalScale: NavDestinationIcon.mapPinOpticalScale,
    ),
  ),
];

/// Key of the compact-width bottom navigation presentation.
const Key kMainBottomNavigationKey = Key('main-bottom-navigation');

/// Key of the wide-window side navigation presentation.
const Key kMainNavigationRailKey = Key('main-navigation-rail');

/// OWNER RULING (2026-09-18) — enter the Planner through the notification
/// education gate.
///
/// `markVisit` records one DELIBERATE Planner entry. Visibility is then derived
/// from live permission state plus how many times the user has answered within
/// the current visit, which is what lets a user who tap-denied by accident get
/// another chance on a later entry while never being nagged twice inside one
/// session. There is deliberately no permanent "already shown" flag.
///
/// The Android dialog is only ever raised by the explicit `Enable notifications`
/// action, and it routes through the same serialized controller the Notifications
/// settings screen uses. Opening the Planner never fires a permission request,
/// and a dismissal is never treated as consent.
final class MainShell extends StatefulWidget {
  const MainShell({required this.child, super.key});

  final Widget child;

  @override
  State<MainShell> createState() => _MainShellState();
}

final class _MainShellState extends State<MainShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalDrawerController _controller = GlobalDrawerController();

  /// Applies the notification education, then enters the Planner.
  ///
  /// The order matters and is the whole point of doing this in the shell: the
  /// education is resolved and answered BEFORE `go(planner)`, so the Planner is
  /// never mounted behind a modal, never resized, and never has a pointer taken
  /// from it. Every path — enable, not now, dismissed, unavailable, already
  /// granted — ends by entering the Planner.
  Future<void> _enterPlanner(BuildContext context, String routePath) async {
    final container = ProviderScope.containerOf(context, listen: false);
    // No Android notification permission model means no education to give.
    if (!container.read(notificationEducationSupportedProvider)) {
      if (!context.mounted) return;
      context.go(routePath);
      return;
    }
    final answers = container.read(plannerNotificationAnswersProvider.notifier);
    // One deliberate Planner entry. Counting it here, at the boundary, is what
    // makes "later entry offers another chance" true without a permanent flag.
    container.read(plannerNotificationVisitsProvider.notifier).markVisit();
    // The settings controller is built lazily and publishes `loading` until its
    // first read finishes, and `loading` deliberately means "show nothing".
    // Evaluating before that load completed would silently skip the education
    // for exactly the user who needs it, so the decision is made on real
    // permission truth instead.
    //
    // OWNER REVIEW #4 STRAIGHTFIX: this awaits `refreshWhenIdle`, not `load`.
    // `load` used to return WITHOUT publishing whenever a master operation or a
    // preference write was in flight, so the gate could then decide on a known
    // stale snapshot and re-offer the education to a user whose setup was in
    // fact complete. `refreshWhenIdle` waits for that work and then publishes
    // fresh truth, which is what makes "hidden after a valid setup" hold for the
    // Settings path and for a grant made in Android App Settings.
    final settingsController = container.read(
      notificationSettingsControllerProvider.notifier,
    );
    await settingsController.refreshWhenIdle();
    if (!context.mounted) return;
    final kind = container.read(plannerNotificationInvitationProvider);
    var wantsEnable = false;
    if (kind != PlannerNotificationInvitationKind.hidden) {
      final outcome = await showModalBottomSheet<
        PlannerNotificationEducationOutcome
      >(
        context: context,
        isScrollControlled: true,
        builder: (_) => const PlannerNotificationEducationSheet(),
      );
      // A dismissed sheet is an answer for THIS visit only: never consent, and
      // never a second nag inside the same session.
      answers.answer();
      wantsEnable = outcome == PlannerNotificationEducationOutcome.enable;
    }
    if (!context.mounted) return;
    // OWNER RULING: after either action the user continues into the Planner.
    // Navigation is never awaited on the permission machinery — an Android
    // dialog, a slow settings round-trip or a slow seed must not be able to
    // strand the user on the previous screen, and the Planner is not mounted
    // behind a modal in any case.
    context.go(routePath);
    if (wantsEnable) {
      // The same serialized path the Notifications settings screen uses — one
      // path, so the Planner and Settings setups cannot diverge. It requests at
      // most once, seeds the first-run defaults on a successful enable whatever
      // produced the grant, and opens App Settings when Android will no longer
      // show its dialog.
      unawaited(settingsController.setSystemNotificationsEnabled(true));
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.attach(_scaffoldKey);
  }

  @override
  void dispose() {
    _controller.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final selectedIndex = location.startsWith(RoutePaths.planner)
        ? 1
        : location.startsWith(RoutePaths.contacts)
        ? 2
        : location.startsWith(RoutePaths.maps)
        ? 3
        : 0;
    final isGoalIconPicker = location.endsWith('/icon');
    // Pack 2 root Back policy (B1 + B7).  Child pages are popped by the
    // shell's own navigator before this PopScope is ever consulted, so a
    // pushed page always returns to its logical parent.  This PopScope only
    // sees a pop that reached the shell page itself, i.e. a root tab or a
    // child page that was entered directly and has no parent beneath it:
    //   Home            -> pop flows on; the platform exits the app;
    //   Planner         -> reveal the existing Home root;
    //   direct /planner -> Planner root;
    //   direct /more/*  -> Home root (NX-07/08: the More landing is gone;
    //                      its children stay reachable, Home is the fallback);
    //   anything else   -> Home root.
    // Root-level routes pushed above the shell (tasks, events, privacy, ...)
    // are popped by the root navigator before this route is consulted.
    // PRE-BETA RESPONSIVE: ONE window observation point for the whole shell.
    // The width class decides the navigation PRESENTATION only; the selected
    // destination still comes from the router, so the two presentations can
    // never hold independent selection state.
    final windowSizeClass = AppWindowSizeClass.of(context);
    final showNavigation = !isGoalIconPicker;
    final useRail = showNavigation && windowSizeClass.usesNavigationRail;
    final isHomeRoot = location == RoutePaths.home;
    // Root tab is exactly `/planner`; anything deeper under those prefixes is
    // a direct-entered child page that needs a root fallback.  `/more` is no
    // longer a root tab: a direct /more child falls back to Home.
    final isPlannerChild = location.startsWith('${RoutePaths.planner}/');
    final isContactsChild = location.startsWith('${RoutePaths.contacts}/');

    // ONE selection handler shared by the bar and the rail.  The route comes
    // from the single destination model, so the two presentations cannot route
    // to different places.
    void selectDestination(int index) {
      if (index < 0 || index >= _shellDestinations.length) {
        return;
      }
      final routePath = _shellDestinations[index].routePath;
      if (routePath == RoutePaths.planner) {
        // OWNER RULING (2026-09-18): notification education happens at the SHELL
        // / NAVIGATION boundary, BEFORE the Planner is activated.
        //
        // Three mounting points inside `PlannerScreen` were built and measured,
        // and each broke a different accepted contract (canvas hit tests, the
        // accepted toolbar/header taps, the body height the canvas geometry is
        // measured against). Showing it here instead means the Planner's layout
        // and hit-test contract are untouched by construction: at the moment
        // this runs, the Planner is not mounted, so it can neither be resized
        // nor participate in the decision.
        unawaited(_enterPlanner(context, routePath));
        return;
      }
      context.go(routePath);
    }

    return GlobalDrawerScope(
      controller: _controller,
      child: Scaffold(
        key: _scaffoldKey,
        drawer: const GlobalAppDrawer(),
        drawerEdgeDragWidth: 24,
        body: PopScope<void>(
          canPop: isHomeRoot,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) {
              return;
            }
            // Pack 3: an open drawer is popped before any route fallback, so
            // Android Back closes the drawer first from every root (never
            // double-Back, never exit-while-open, never discard edits behind
            // it).  On Home the open drawer pops through the normal path and
            // never reaches here; this branch covers non-Home roots where the
            // shell PopScope intercepts the pop before the inner navigator
            // would dismiss the drawer.
            final scaffold = _scaffoldKey.currentState;
            if (scaffold != null && scaffold.isDrawerOpen) {
              scaffold.closeDrawer();
              return;
            }
            // Only non-Home locations reach here with the drawer closed.
            // Reveal the existing logical root; `go` replaces the current
            // page, so no duplicate Home route or tab-history stack is ever
            // created.
            //   Planner root tab  -> Home;
            //   direct /planner   -> Planner root;
            //   direct /contacts  -> Contacts root;
            //   direct /more/*    -> Home (NX-07/08: no More landing);
            //   everything else   -> Home root.
            if (isPlannerChild) {
              context.go(RoutePaths.planner);
            } else if (isContactsChild) {
              context.go(RoutePaths.contacts);
            } else {
              context.go(RoutePaths.home);
            }
          },
          child: useRail
              // Wide window: the side rail and the routed child share the body,
              // so no bottom bar steals vertical space from the content.
              ? Row(
                  children: <Widget>[
                    NavigationRail(
                      key: kMainNavigationRailKey,
                      selectedIndex: selectedIndex,
                      // Labels stay visible in both presentations; the rail's own
                      // SafeArea (left/right inner side, top, bottom) keeps the
                      // system insets correct without an extra wrapper here.
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: selectDestination,
                      destinations: <NavigationRailDestination>[
                        for (final destination in _shellDestinations)
                          NavigationRailDestination(
                            // The destination key rides on the icon so the SAME
                            // key resolves in both presentations (exactly one
                            // presentation is mounted at a time).
                            icon: KeyedSubtree(
                              key: destination.key,
                              child: destination.icon,
                            ),
                            selectedIcon: destination.selectedIcon == null
                                ? null
                                : KeyedSubtree(
                                    key: destination.key,
                                    child: destination.selectedIcon!,
                                  ),
                            label: Text(destination.label),
                          ),
                      ],
                    ),
                    Expanded(child: widget.child),
                  ],
                )
              : widget.child,
        ),
        // Exactly one navigation presentation is mounted in steady state: the
        // rail above on a wide window, this bar on a compact one, and neither
        // on the full-screen Goal icon picker.
        // OWNER REVIEW #4 — the Planner notification invitation is NOT mounted
        // here.
        //
        // It was implemented and unit-tested, and two mounting points were
        // tried and measured. Inside the Planner it shifted the day canvas the
        // accepted geometry contracts assert, and as an overlay over the canvas
        // it swallowed real hit tests. Riding above this navigation bar it made
        // the body shorter, which broke the app-level Planner tests that tap the
        // timeline at an absolute canvas coordinate. Every mounting point that
        // is visible on the first Planner visit therefore collides with an
        // accepted contract, and the choice between them is the owner's, not a
        // detail to settle silently. The widget, its visibility rules and its
        // tests stay in place so the decision costs only a mount point.
        bottomNavigationBar: useRail || isGoalIconPicker
            ? null
            : NavigationBar(
                key: kMainBottomNavigationKey,
                selectedIndex: selectedIndex,
                onDestinationSelected: selectDestination,
                // POST-M7 CLOSURE (owner law, 2026-09-16): Home, Planner and
                // Maps use the owner-supplied SVG artwork, tinted from the
                // navigation IconTheme.  Contacts deliberately keeps its
                // Material pair.  Keys, labels, order and routing are untouched.
                // PRE-BETA RESPONSIVE: generated from the one shared model above.
                destinations: <NavigationDestination>[
                  for (final destination in _shellDestinations)
                    NavigationDestination(
                      key: destination.key,
                      icon: destination.icon,
                      selectedIcon: destination.selectedIcon,
                      label: destination.label,
                    ),
                ],
              ),
      ),
    );
  }
}
