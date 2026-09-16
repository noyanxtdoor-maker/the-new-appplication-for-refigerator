import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A bottom-navigation destination icon backed by an owner-supplied SVG.
///
/// POST-M7 CLOSURE (owner law, 2026-09-16).  Two rules make this safe:
///
/// 1. The artwork is tinted from the navigation's OWN [IconTheme].  Flutter's
///    `NavigationDestination` wraps its icon child in `IconTheme.merge` with the
///    theme-resolved selected/unselected [IconThemeData], so reading
///    `IconTheme.of(context)` leaves the accepted selected/unselected colours
///    exactly where `NavigationBarThemeData` puts them.  No colour is declared
///    here, and the source art is never painted with its literal black.
/// 2. Nothing about this widget can reach the asset bytes: [opticalScale] is a
///    render-side size correction only, so the owner's SVG is used verbatim.
final class NavDestinationIcon extends StatelessWidget {
  const NavDestinationIcon({
    required this.asset,
    this.opticalScale = 1,
    super.key,
  });

  /// The owner's Home artwork: a 24-grid, stroke-2 line icon.
  static const String houseAsset = 'assets/icons/navigation/house-01.svg';

  /// The owner's Planner artwork: a 24-grid, stroke-2 line icon.
  static const String calendarAsset =
      'assets/icons/navigation/calendar-day.svg';

  /// The owner's Maps artwork: a SOLID fill glyph on a 16-grid.
  static const String mapPinAsset = 'assets/icons/navigation/map-pin.svg';

  /// Renderer-only optical correction for `map-pin.svg`.
  ///
  /// `house-01.svg` and `calendar-day.svg` inset ~2–3 units inside their 24-unit
  /// grid, so their ink covers roughly 18/24 of the render box, while the pin's
  /// path spans the FULL 0–16 of its own (16-unit) grid — 100% of the box in the
  /// vertical axis.  Painted at the same requested size the pin therefore reads
  /// both taller and heavier than its siblings.  Scaling the paint area to ~0.78
  /// brings its ink height to ~18.7 dp inside a 24 dp box, matching the stroke
  /// icons, while keeping the pin's naturally narrow width.  This never edits
  /// the SVG.  Final optical acceptance belongs to the owner.
  static const double mapPinOpticalScale = 0.78;

  /// Asset path of the owner-supplied SVG, used verbatim.
  final String asset;

  /// Renderer-only optical scale (default 1 = untouched).
  final double opticalScale;

  @override
  Widget build(BuildContext context) {
    final IconThemeData iconTheme = IconTheme.of(context);
    final double size = iconTheme.size ?? 24;
    final Color? tint = iconTheme.color;
    final double paintSize = size * opticalScale;
    return SizedBox.square(
      dimension: size,
      // Center keeps the outer box at [size] while letting the SVG paint at its
      // optically corrected size inside it.
      child: Center(
        child: SvgPicture.asset(
          asset,
          width: paintSize,
          height: paintSize,
          fit: BoxFit.contain,
          // The NavigationDestination label owns semantics; the artwork must not
          // add a second node.
          excludeFromSemantics: true,
          colorFilter: tint == null
              ? null
              : ColorFilter.mode(tint, BlendMode.srcIn),
        ),
      ),
    );
  }
}
