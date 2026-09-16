/// PRE-BETA RESPONSIVE (2026-09-16) — shared logical window harness.
///
/// Flutter's test binding starts at `physicalSize = 2400x1800` with
/// `devicePixelRatio = 3.0`, i.e. a LOGICAL 800x600 window (measured on this
/// checkout, not assumed). That is a *medium width* window, so any test that
/// does not state a size is silently exercising a wide layout. Every
/// responsive test must therefore declare its logical size explicitly through
/// these helpers, which also make the reset impossible to forget.
///
/// Contracts:
/// * `tester.view.physicalSize` is in PHYSICAL pixels.
///   logical = physicalSize / devicePixelRatio.
/// * `addTearDown(tester.view.reset)` is registered internally, so a test can
///   never leak a view size into the next one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The canonical logical window sizes used by the responsive matrix.
abstract final class TestWindowSizes {
  // --- Phone ---------------------------------------------------------------

  /// Audited phone baseline (compact width, medium height).
  static const Size phonePortrait = Size(393, 874);

  /// Landscape phone: medium width, COMPACT height. The riskiest case.
  static const Size phoneLandscape = Size(874, 393);

  static const Size narrowPhone = Size(360, 800);

  // --- Width boundaries ----------------------------------------------------

  static const Size compactWidthBoundary = Size(599, 800);
  static const Size mediumWidthBoundary = Size(600, 800);
  static const Size mediumUpperBoundary = Size(839, 800);
  static const Size expandedWidthBoundary = Size(840, 800);
  static const Size largeWidthBoundary = Size(1200, 800);
  static const Size extraLargeWidthBoundary = Size(1600, 900);

  // --- Height boundaries ---------------------------------------------------

  static const Size compactHeightBoundary = Size(800, 479);
  static const Size mediumHeightBoundary = Size(800, 480);
  static const Size mediumHeightUpperBoundary = Size(800, 899);
  static const Size expandedHeightBoundary = Size(800, 900);

  // --- Windows -------------------------------------------------------------

  static const Size compactSplit = Size(540, 800);
  static const Size defaultTestSurface = Size(800, 600);
  static const Size smallTabletPortrait = Size(700, 1100);
  static const Size tabletPortrait = Size(800, 1280);
  static const Size tabletLandscape = Size(1024, 640);
  static const Size largeTablet = Size(1200, 800);
}

/// Sets the logical window size and registers the view reset automatically.
void setLogicalViewSize(
  WidgetTester tester,
  Size logical, {
  double devicePixelRatio = 1,
}) {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = logical * devicePixelRatio;
  addTearDown(tester.view.reset);
}

/// Sets the logical window size, then pumps [widget].
Future<void> pumpAtLogicalSize(
  WidgetTester tester,
  Size logical,
  Widget widget, {
  double devicePixelRatio = 1,
}) async {
  setLogicalViewSize(tester, logical, devicePixelRatio: devicePixelRatio);
  await tester.pumpWidget(widget);
}

/// Simulates the system-bar / cutout insets the platform reports.
void setViewInsets(
  WidgetTester tester, {
  FakeViewPadding padding = const FakeViewPadding(),
  FakeViewPadding viewPadding = const FakeViewPadding(),
  FakeViewPadding viewInsets = const FakeViewPadding(),
}) {
  tester.view.padding = padding;
  tester.view.viewPadding = viewPadding;
  tester.view.viewInsets = viewInsets;
}

/// The active primary navigation surface, whichever presentation is mounted.
///
/// The shell presents the SAME destination model as a bottom bar on a compact
/// window and as a side rail on a wider one, so a test that only cares about
/// navigation behaviour should not hardcode either widget.
Finder navigationFinder() {
  return find.byWidgetPredicate(
    (widget) =>
        widget.key == const Key('main-bottom-navigation') ||
        widget.key == const Key('main-navigation-rail'),
    description: 'active primary navigation (bar or rail)',
  );
}

/// Finds a destination by its visible label inside the active navigation.
Finder navigationLabelFinder(String label) {
  return find.descendant(of: navigationFinder(), matching: find.text(label));
}
