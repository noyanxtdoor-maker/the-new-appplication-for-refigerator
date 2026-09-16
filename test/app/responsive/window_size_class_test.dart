import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/shell/window_size_class.dart';

import '../../support/view_size.dart';

/// PRE-BETA RESPONSIVE (2026-09-16) — the ONE window classification.
///
/// These are the breakpoint laws the rest of the app is allowed to depend on.
/// They are asserted directly from `Size`, with no widget tree, so a boundary
/// error cannot hide behind a layout.
void main() {
  group('width classification boundaries', () {
    test('compact is everything below 600', () {
      for (final double width in <double>[0, 320, 393, 599]) {
        expect(
          AppWindowSizeClass.fromSize(Size(width, 800)).width,
          AppWindowWidthClass.compact,
          reason: 'width $width must be compact',
        );
      }
    });

    test('medium starts exactly at 600 and stops below 840', () {
      for (final double width in <double>[600, 700, 839]) {
        expect(
          AppWindowSizeClass.fromSize(Size(width, 800)).width,
          AppWindowWidthClass.medium,
          reason: 'width $width must be medium',
        );
      }
    });

    test('expanded starts exactly at 840 and stops below 1200', () {
      for (final double width in <double>[840, 1024, 1199]) {
        expect(
          AppWindowSizeClass.fromSize(Size(width, 800)).width,
          AppWindowWidthClass.expanded,
          reason: 'width $width must be expanded',
        );
      }
    });

    test('large starts exactly at 1200 and stops below 1600', () {
      for (final double width in <double>[1200, 1400, 1599]) {
        expect(
          AppWindowSizeClass.fromSize(Size(width, 800)).width,
          AppWindowWidthClass.large,
          reason: 'width $width must be large',
        );
      }
    });

    test('extra large starts exactly at 1600', () {
      expect(
        AppWindowSizeClass.fromSize(const Size(1600, 900)).width,
        AppWindowWidthClass.extraLarge,
      );
      expect(
        AppWindowSizeClass.fromSize(const Size(2560, 1440)).width,
        AppWindowWidthClass.extraLarge,
      );
    });
  });

  group('height classification boundaries', () {
    test('compact is everything below 480', () {
      for (final double height in <double>[0, 320, 393, 479]) {
        expect(
          AppWindowSizeClass.fromSize(Size(800, height)).height,
          AppWindowHeightClass.compact,
          reason: 'height $height must be compact',
        );
      }
    });

    test('medium starts exactly at 480 and stops below 900', () {
      for (final double height in <double>[480, 600, 874, 899]) {
        expect(
          AppWindowSizeClass.fromSize(Size(800, height)).height,
          AppWindowHeightClass.medium,
          reason: 'height $height must be medium',
        );
      }
    });

    test('expanded starts exactly at 900', () {
      for (final double height in <double>[900, 1280]) {
        expect(
          AppWindowSizeClass.fromSize(Size(800, height)).height,
          AppWindowHeightClass.expanded,
          reason: 'height $height must be expanded',
        );
      }
    });
  });

  group('the navigation rail law is width-only', () {
    test('compact width always uses the bar', () {
      for (final Size size in <Size>[
        TestWindowSizes.phonePortrait,
        TestWindowSizes.compactWidthBoundary,
        TestWindowSizes.compactSplit,
        // Height is irrelevant to the presentation decision.
        const Size(393, 393),
      ]) {
        expect(
          AppWindowSizeClass.fromSize(size).usesNavigationRail,
          isFalse,
          reason: '$size is compact width',
        );
      }
    });

    test('medium width and above use the rail, even at compact height', () {
      for (final Size size in <Size>[
        TestWindowSizes.phoneLandscape,
        TestWindowSizes.mediumWidthBoundary,
        TestWindowSizes.expandedWidthBoundary,
        TestWindowSizes.tabletLandscape,
        TestWindowSizes.largeTablet,
        TestWindowSizes.extraLargeWidthBoundary,
      ]) {
        expect(
          AppWindowSizeClass.fromSize(size).usesNavigationRail,
          isTrue,
          reason: '$size is at least medium width',
        );
      }
    });

    test('a landscape phone is wide with COMPACT height', () {
      // 393x874 rotated is 874x393: width lands in the expanded band and height
      // is compact. The classification is a function of the numbers, not of the
      // fact that the hardware is a phone.
      final AppWindowSizeClass landscape = AppWindowSizeClass.fromSize(
        TestWindowSizes.phoneLandscape,
      );
      expect(landscape.width, AppWindowWidthClass.expanded);
      expect(landscape.height, AppWindowHeightClass.compact);
      expect(landscape.isHeightCompact, isTrue);
      expect(landscape.usesNavigationRail, isTrue);
    });

    test('the documented medium+compact combination is classified', () {
      // Android documents landscape phones as typically MEDIUM width with
      // COMPACT height; that combination is exactly what this case covers.
      final AppWindowSizeClass landscape = AppWindowSizeClass.fromSize(
        const Size(800, 400),
      );
      expect(landscape.width, AppWindowWidthClass.medium);
      expect(landscape.height, AppWindowHeightClass.compact);
      expect(landscape.usesNavigationRail, isTrue);
    });
  });

  group('MaxContentWidth', () {
    Future<double> pumpAndMeasure(
      WidgetTester tester, {
      required Size window,
    }) async {
      await pumpAtLogicalSize(
        tester,
        window,
        const MaterialApp(
          home: Scaffold(
            // The probe expands to whatever the wrapper allows, exactly like a
            // list body or a full-width field does.
            body: MaxContentWidth(child: SizedBox.expand(key: Key('probe'))),
          ),
        ),
      );
      return tester.getSize(find.byKey(const Key('probe'))).width;
    }

    testWidgets('is layout-neutral at and below the cap', (tester) async {
      // A phone keeps the full available width: the wrapper must not add
      // gutters to the accepted phone layout.
      expect(
        await pumpAndMeasure(tester, window: TestWindowSizes.phonePortrait),
        TestWindowSizes.phonePortrait.width,
      );
      expect(await pumpAndMeasure(tester, window: const Size(720, 800)), 720);
    });

    testWidgets('caps ordinary content on a wide window', (tester) async {
      expect(
        await pumpAndMeasure(tester, window: TestWindowSizes.largeTablet),
        kAppMaxContentWidth,
      );
      expect(
        await pumpAndMeasure(
          tester,
          window: TestWindowSizes.extraLargeWidthBoundary,
        ),
        kAppMaxContentWidth,
      );
    });

    testWidgets('centres the capped content', (tester) async {
      await pumpAndMeasure(tester, window: TestWindowSizes.largeTablet);
      final Rect box = tester.getRect(find.byKey(const Key('probe')));
      expect(box.center.dx, TestWindowSizes.largeTablet.width / 2);
    });
  });
}
