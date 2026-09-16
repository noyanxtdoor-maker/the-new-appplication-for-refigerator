import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/shell/nav_destination_icon.dart';

/// POST-M7 CLOSURE (2026-09-16) — bottom-navigation SVG icon contract.
///
/// The nav keeps its Material icon for Contacts and gains the owner's three SVGs
/// for Home, Planner and Maps.  These tests pin the part that matters: the tint
/// is resolved from the navigation IconTheme (never a literal colour), the outer
/// geometry stays exact, the map pin carries its renderer-only optical
/// correction, and the owner's asset bytes are never redrawn or recoloured.
void main() {
  const selectedColor = Color(0xFF277CB5);
  const unselectedColor = Color(0xFF9CA0A6);

  Future<SvgPicture> pumpIcon(
    WidgetTester tester, {
    required String asset,
    required Color tint,
    double size = 24,
    double opticalScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        // Center keeps the constraints loose so the icon's own box wins.
        home: Center(
          child: IconTheme(
            data: IconThemeData(color: tint, size: size),
            child: NavDestinationIcon(asset: asset, opticalScale: opticalScale),
          ),
        ),
      ),
    );
    return tester.widget<SvgPicture>(find.byType(SvgPicture));
  }

  testWidgets('the artwork is tinted from the IconTheme, never hardcoded', (
    tester,
  ) async {
    final selected = await pumpIcon(
      tester,
      asset: NavDestinationIcon.houseAsset,
      tint: selectedColor,
    );
    expect(
      selected.colorFilter,
      ColorFilter.mode(selectedColor, BlendMode.srcIn),
    );
    expect(
      selected.excludeFromSemantics,
      isTrue,
      reason: 'label owns semantics',
    );

    final unselected = await pumpIcon(
      tester,
      asset: NavDestinationIcon.calendarAsset,
      tint: unselectedColor,
    );
    expect(
      unselected.colorFilter,
      ColorFilter.mode(unselectedColor, BlendMode.srcIn),
    );
    expect(
      unselected.colorFilter,
      isNot(ColorFilter.mode(const Color(0xFF000000), BlendMode.srcIn)),
      reason: 'the source art is never painted with its literal black',
    );
  });

  testWidgets('the outer geometry is exactly the requested icon size', (
    tester,
  ) async {
    await pumpIcon(
      tester,
      asset: NavDestinationIcon.houseAsset,
      tint: selectedColor,
      size: 24,
    );
    expect(tester.getSize(find.byType(NavDestinationIcon)), const Size(24, 24));

    await pumpIcon(
      tester,
      asset: NavDestinationIcon.houseAsset,
      tint: selectedColor,
      size: 32,
    );
    expect(tester.getSize(find.byType(NavDestinationIcon)), const Size(32, 32));
  });

  testWidgets('the solid pin glyph carries its optical correction', (
    tester,
  ) async {
    const scale = NavDestinationIcon.mapPinOpticalScale;
    expect(scale, lessThan(1));

    await pumpIcon(
      tester,
      asset: NavDestinationIcon.mapPinAsset,
      tint: selectedColor,
      size: 24,
      opticalScale: scale,
    );

    // The box stays 24 so the bar layout cannot shift, while the paint area is
    // optically reduced.
    expect(tester.getSize(find.byType(NavDestinationIcon)), const Size(24, 24));
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.width, closeTo(24 * scale, 0.001));
    expect(svg.height, closeTo(24 * scale, 0.001));
  });

  group('the owner assets are used verbatim', () {
    String read(String path) => File(path).readAsStringSync();

    test('each asset keeps its original grid and ink colour', () {
      final house = read(NavDestinationIcon.houseAsset);
      expect(house, contains('viewBox="0 0 24 24"'));
      expect(house, contains('stroke="#000000"'));
      expect(house, contains('stroke-width="2"'));

      final calendar = read(NavDestinationIcon.calendarAsset);
      expect(calendar, contains('viewBox="0 0 24 24"'));
      expect(calendar, contains('stroke="#000000"'));

      final pin = read(NavDestinationIcon.mapPinAsset);
      expect(pin, contains('viewBox="0 0 16 16"'));
      expect(pin, contains('fill="#000000"'));
    });
  });

  group('destination wiring is unchanged except the artwork', () {
    final shell = File('lib/app/shell/main_shell.dart').readAsStringSync();

    test('keys, labels and order are untouched', () {
      final home = shell.indexOf("Key('nav-home')");
      final planner = shell.indexOf("Key('nav-planner')");
      final contacts = shell.indexOf("Key('nav-contacts')");
      final maps = shell.indexOf("Key('nav-maps')");
      expect(home, greaterThan(-1));
      expect(planner, greaterThan(home));
      expect(contacts, greaterThan(planner));
      expect(maps, greaterThan(contacts));

      for (final label in <String>[
        "'Home'",
        "'Planner'",
        "'Contacts'",
        "'Maps'",
      ]) {
        expect(shell, contains('label: $label'));
      }
    });

    test('Home, Planner and Maps use the owner SVGs', () {
      expect(shell, contains('NavDestinationIcon.houseAsset'));
      expect(shell, contains('NavDestinationIcon.calendarAsset'));
      expect(shell, contains('NavDestinationIcon.mapPinAsset'));
      // The Material pairs for those three destinations are gone.
      expect(shell, isNot(contains('Icons.home_outlined')));
      expect(shell, isNot(contains('Icons.calendar_month_outlined')));
      expect(shell, isNot(contains('Icons.map_outlined')));
    });

    test('Contacts keeps its Material icon pair', () {
      expect(shell, contains('icon: Icon(Icons.people_outline)'));
      expect(shell, contains('selectedIcon: Icon(Icons.people)'));
    });
  });
}
