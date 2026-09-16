/// PRE-BETA RESPONSIVE POLICY (2026-09-16).
///
/// This is the ONE canonical place where Next Transfer classifies the space it
/// has been given, and the one place that owns the ordinary-content width cap.
/// Feature files must not re-derive either: a widget that needs a different
/// layout reads the classification that the shell already computed, so a window
/// resize rebuilds one subtree instead of adding a size subscriber per screen.
///
/// Source of truth for the breakpoints (verified 2026-09-16):
///   * Android window size classes — compact `< 600`, medium `600–839`,
///     expanded `840–1199`, large `1200–1599`, extra-large `>= 1600` width;
///     compact `< 480`, medium `480–899`, expanded `>= 900` height.
///   * Flutter's Material guidance uses the same 600 boundary for the
///     navigation bar -> navigation rail switch.
///
/// The classification is a function of the AVAILABLE WINDOW only. It must never
/// consult the device type, the platform, or the orientation: a physical device
/// does not guarantee a size class (multi-window, foldables and desktop
/// windowing all change the available space while the app is running).
library;

import 'package:flutter/widgets.dart';

// --- Width breakpoints (logical pixels). -------------------------------------

/// Below this width the shell uses the bottom navigation bar.
const double kAppCompactWidthMax = 600;

/// Medium width spans `[kAppCompactWidthMax, kAppMediumWidthMax)`.
const double kAppMediumWidthMax = 840;

/// Expanded width spans `[kAppMediumWidthMax, kAppExpandedWidthMax)`.
const double kAppExpandedWidthMax = 1200;

/// Large width spans `[kAppExpandedWidthMax, kAppLargeWidthMax)`.
const double kAppLargeWidthMax = 1600;

// --- Height breakpoints (logical pixels). ------------------------------------

/// Below this height the window is height-compact (landscape phones).
const double kAppCompactHeightMax = 480;

/// Medium height spans `[kAppCompactHeightMax, kAppMediumHeightMax)`.
const double kAppMediumHeightMax = 900;

// --- Ordinary content width. -------------------------------------------------

/// The shared maximum width for ordinary (non-canvas) content.
///
/// Large windows must not stretch text fields, rows, cards or dialogs across
/// the full window. The value deliberately matches the existing in-tree
/// precedent for the Planner preview sheets (`kPlannerPreviewSheetMaxWidth`),
/// so the app keeps ONE max-width concept rather than two competing numbers.
///
/// It is a no-op at or below this width: a phone layout is byte-identical.
const double kAppMaxContentWidth = 720;

/// Width class of the available window.
enum AppWindowWidthClass { compact, medium, expanded, large, extraLarge }

/// Height class of the available window.
///
/// Height is classified separately and is consumed only for vertical-space
/// decisions (compact-height reachability). It never selects a device identity.
enum AppWindowHeightClass { compact, medium, expanded }

/// An immutable classification of the space available to the app.
@immutable
final class AppWindowSizeClass {
  const AppWindowSizeClass._({
    required this.size,
    required this.width,
    required this.height,
  });

  /// Classifies [size] (logical pixels) directly. Pure, so breakpoint
  /// boundaries are unit-testable without a widget tree.
  factory AppWindowSizeClass.fromSize(Size size) {
    final double w = size.width;
    final double h = size.height;
    return AppWindowSizeClass._(
      size: size,
      width: w < kAppCompactWidthMax
          ? AppWindowWidthClass.compact
          : w < kAppMediumWidthMax
          ? AppWindowWidthClass.medium
          : w < kAppExpandedWidthMax
          ? AppWindowWidthClass.expanded
          : w < kAppLargeWidthMax
          ? AppWindowWidthClass.large
          : AppWindowWidthClass.extraLarge,
      height: h < kAppCompactHeightMax
          ? AppWindowHeightClass.compact
          : h < kAppMediumHeightMax
          ? AppWindowHeightClass.medium
          : AppWindowHeightClass.expanded,
    );
  }

  /// The single window observation point used by the shell.
  static AppWindowSizeClass of(BuildContext context) {
    return AppWindowSizeClass.fromSize(MediaQuery.sizeOf(context));
  }

  final Size size;
  final AppWindowWidthClass width;
  final AppWindowHeightClass height;

  bool get isWidthCompact => width == AppWindowWidthClass.compact;
  bool get isHeightCompact => height == AppWindowHeightClass.compact;

  /// `true` when the window is wide enough for the side navigation rail.
  ///
  /// The rule is intentionally width-only: a landscape phone reports medium
  /// width with compact height, and the rail is the better choice there too
  /// because it preserves scarce vertical space. Compact-height handling is a
  /// separate concern owned by each surface, not by this predicate.
  bool get usesNavigationRail => !isWidthCompact;

  @override
  String toString() =>
      'AppWindowSizeClass(size: $size, width: ${width.name}, '
      'height: ${height.name})';
}

/// Centers ordinary content and caps its width on large windows.
///
/// At or below [kAppMaxContentWidth] this widget is layout-neutral: the child
/// receives exactly the constraints it already had, so phone layouts do not
/// change. Use it for forms, settings rows, list bodies and dialogs — never for
/// canvases that genuinely use the full width (the Planner timeline, the Maps
/// surface, the front door).
final class MaxContentWidth extends StatelessWidget {
  const MaxContentWidth({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kAppMaxContentWidth),
        child: child,
      ),
    );
  }
}
