import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/google_maps_surface.dart';
import 'package:rmplanner/features/maps/presentation/saved_place_form_sheet.dart';

import 'support/fab_theme_probe.dart';

const _coordinate = MapCoordinate(latitude: 14.6, longitude: 121);
const _marker = MapMarker(
  owner: MapCoordinateOwner.contact,
  recordId: 'contact-1',
  coordinate: _coordinate,
  displayName: 'Sample Example',
  colorValue: 0xFF407AC2,
);

const _nineLabels = <String>[
  'Information',
  'Avoid',
  'Food',
  'Repair',
  'Transit',
  'Wi-Fi',
  'Haircut',
  'Shopping',
  'Laundry',
];

String get _surfaceSource => File(
  'lib/features/maps/presentation/google_maps_surface.dart',
).readAsStringSync();

String get _editorSource => File(
  'lib/features/maps/presentation/saved_place_form_sheet.dart',
).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selected marker anchor law', () {
    test('identity anchor distance is identical selected and unselected', () {
      expect(
        _surfaceSource,
        contains(
          'final identityCenter = Offset(size / 2, canvasHeight - size / 2);',
        ),
        reason:
            'the identity must stay exactly 48 bitmap pixels above the '
            'bottom map anchor whether selected or not',
      );
      expect(
        _surfaceSource,
        isNot(contains('const Offset(size / 2, 42')),
        reason:
            'the Pass 3 selected-special-case position moved the base '
            'record to another geographic position and is owner-rejected',
      );
    });

    test('red pin is painted above the identity with its tip on the marker', () {
      expect(
        _surfaceSource,
        contains('static const double _selectedPinGlyphSize'),
      );
      expect(
        _surfaceSource,
        contains(
          'final identityTop = identityCenter.dy - _selectedIdentityRadius;',
        ),
      );
      final pinCall = RegExp(
        r'_paintSelectedLocationPinGlyph\(\s*canvas,\s*Offset\(\s*size / 2,\s*identityTop - _selectedPinGlyphSize / 2 \+ 32\),\s*\)',
      );
      expect(
        pinCall.hasMatch(_surfaceSource),
        isTrue,
        reason:
            'the pin tip must sit precisely on the original marker so the '
            'record stays visible immediately beneath the tip',
      );
      // M3.1 final alignment: moderately larger pin (96) with a deeper canvas
      // extension (80) so the composition reads lower and more centered.
      expect(
        _surfaceSource,
        contains('static const double _selectedPinGlyphSize = 96;'),
        reason: 'selected pin must be moderately larger per PMG reference',
      );
      expect(
        _surfaceSource,
        contains('static const double _selectedPinCanvasExtension = 80;'),
        reason:
            'canvas extension must hold the larger pin without moving '
            'the base record',
      );
      expect(_surfaceSource, isNot(contains('_paintSelectedLocationBadge')));
    });

    test('pin head detail is a darker red, never a blue/teal dot', () {
      final painter = _surfaceSource.substring(
        _surfaceSource.indexOf('_paintSelectedLocationPinGlyph'),
        _surfaceSource.indexOf('static void _paintMaterialIconGlyph'),
      );
      expect(painter, contains('Colors.red.shade700'));
      expect(painter, contains('Colors.red.shade900'));
      expect(painter, isNot(contains('Colors.blue')));
      expect(painter, isNot(contains('Colors.teal')));
      expect(painter, isNot(contains('blueLightPrimary')));
      expect(painter, isNot(contains('colorScheme')));
    });

    test('semantic pin color does not inherit the app theme', () {
      final controlZone = _surfaceSource.substring(
        _surfaceSource.indexOf('maps-drop-pin-button'),
      );
      // M7 reconciliation (2026-09-16): `controlSurface` was retired — the
      // control passes NO colours and inherits primary/onPrimary from the
      // canonical FAB theme. The guard that still matters is that no per-screen
      // colour override is reintroduced beside the drop-pin control.
      expect(controlZone, isNot(contains('backgroundColor:')));
      expect(controlZone, isNot(contains('foregroundColor:')));
      final pinPainter = _surfaceSource.substring(
        _surfaceSource.indexOf('_paintSelectedLocationPinGlyph'),
        _surfaceSource.indexOf('static void _paintMaterialIconGlyph'),
      );
      expect(pinPainter, isNot(contains('Theme.of(context)')));
      expect(pinPainter, contains('Colors.red.shade700'));
    });

    test(
      'selection keeps the base record LatLng and issues no camera command',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(mapSelectedMarkerProvider.notifier).select(_marker);
        expect(
          container.read(mapSelectedMarkerProvider)?.marker.coordinate,
          _marker.coordinate,
          reason: 'selection must not move the record to another LatLng',
        );
        final markersBody = _surfaceSource.substring(
          _surfaceSource.indexOf('Set<Marker> get _markers'),
          _surfaceSource.indexOf('ClusterManagerId _clusterIdFor'),
        );
        expect(markersBody, contains('position: LatLng('));
        expect(markersBody, isNot(contains('animateCamera')));
        expect(markersBody, isNot(contains('moveCamera')));
        expect(container.read(mapTransientFocusProvider).pending, isNull);
      },
    );
  });

  group('theme-dependent map controls', () {
    Future<void> pumpControls(WidgetTester tester, ThemeColorMode mode) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(mode),
            home: Scaffold(
              body: GoogleMapsSurface(
                markers: const [_marker],
                initialCoordinate: null,
                onMarkerTap: (_) {},
                mapBuilder: (_, _) => const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('blue theme uses strong blue surfaces with white icons', (
      tester,
    ) async {
      await pumpControls(tester, ThemeColorMode.blue);
      for (final key in const [
        'maps-drop-pin-button',
        'maps-type-button',
        'maps-locate-button',
      ]) {
        expect(
          resolvedFabBackground(tester, Key(key)),
          AppTheme.light(ThemeColorMode.blue).colorScheme.primary,
        );
        expect(resolvedFabIconColor(tester, Key(key)), Colors.white);
      }
    });

    testWidgets('rose theme uses strong rose surfaces with white icons', (
      tester,
    ) async {
      await pumpControls(tester, ThemeColorMode.rose);
      for (final key in const [
        'maps-drop-pin-button',
        'maps-type-button',
        'maps-locate-button',
      ]) {
        expect(
          resolvedFabBackground(tester, Key(key)),
          AppTheme.light(ThemeColorMode.rose).colorScheme.primary,
        );
        expect(resolvedFabIconColor(tester, Key(key)), Colors.white);
      }
    });

    testWidgets(
      'Drop Pin keeps a real map-location-pin glyph on the strong accent',
      (tester) async {
        await pumpControls(tester, ThemeColorMode.blue);
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('maps-drop-pin-button')),
            matching: find.byType(Icon),
          ),
        );
        expect(icon.icon, Icons.location_pin);
      },
    );

    test('control surface comes from the canonical strong theme family', () {
      final controlZone = _surfaceSource.substring(
        _surfaceSource.indexOf('maps-drop-pin-button'),
      );
      // M7 reconciliation (2026-09-16): the canonical strong family now reaches
      // the control through FloatingActionButtonThemeData (primary/onPrimary)
      // instead of a per-screen `controlSurface` plus a literal white. Lock BOTH
      // halves: no local colour override, and a WHITE glyph on the canonical
      // blue primary surface.
      expect(controlZone, isNot(contains('backgroundColor:')));
      expect(controlZone, isNot(contains('foregroundColor:')));
      final canonical = AppTheme.light(ThemeColorMode.blue);
      expect(
        canonical.floatingActionButtonTheme.backgroundColor,
        AppTheme.blueLightPrimary,
      );
      expect(canonical.floatingActionButtonTheme.foregroundColor, Colors.white);
    });
  });

  group('Add/Edit Place design system and density', () {
    test('editor reuses the canonical Next Transfer form design system', () {
      expect(_editorSource, contains('InternalAppBar('));
      expect(_editorSource, contains('InternalScreen.pagePadding'));
      expect(_editorSource, contains('InternalScreen.sectionHeading'));
      expect(_editorSource, contains('InternalScreen.sectionGap'));
      expect(
        _editorSource,
        isNot(contains('AppTheme.blueLightPrimary')),
        reason: 'editor chrome must follow the active theme accent',
      );
    });

    test('category grid is structural and cannot clip a label', () {
      expect(_editorSource, isNot(contains('GridView')));
      expect(_editorSource, isNot(contains('childAspectRatio')));
      expect(_editorSource, contains('IntrinsicHeight'));
      expect(
        _editorSource,
        isNot(contains('TextOverflow.ellipsis')),
        reason: 'ordinary category names must never be ellipsized',
      );
    });

    test('icon color row is a small swatch with a small pencil glyph', () {
      expect(_editorSource, contains('width: 32'));
      expect(_editorSource, contains('size: 18'));
      final colorRow = _editorSource.substring(
        _editorSource.indexOf('Widget _buildColorPicker'),
        _editorSource.indexOf('final class _EmojiGraphemeFormatter'),
      );
      expect(colorRow, contains('Icons.edit_outlined'));
      expect(colorRow, isNot(contains('width: 44')));
    });

    testWidgets('standard editor has zero overflow at the Infinix viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: SavedPlaceFormScreen(
              coordinate: _coordinate,
              onSave: (_) async {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final label in _nineLabels) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('larger text scale still renders all nine labels unclipped', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: SavedPlaceFormScreen(
              coordinate: _coordinate,
              onSave: (_) async {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final label in _nineLabels) {
        final rect = tester.getRect(find.text(label));
        expect(rect.height, greaterThan(0), reason: label);
        expect(rect.width, greaterThan(0), reason: label);
      }
    });

    testWidgets(
      'segmented control hugs its content instead of the page width',
      (tester) async {
        tester.view.physicalSize = const Size(431, 912);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: SavedPlaceFormScreen(
                coordinate: _coordinate,
                onSave: (_) async {},
                onCancel: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final modeWidth = tester
            .getSize(find.byKey(const Key('saved-place-mode')))
            .width;
        expect(
          modeWidth,
          lessThan(260),
          reason: 'content-hugging Standard/Custom',
        );
      },
    );
  });
}
