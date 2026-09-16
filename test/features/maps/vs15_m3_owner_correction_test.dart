import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';

void main() {
  final surface = File(
    'lib/features/maps/presentation/google_maps_surface.dart',
  ).readAsStringSync();
  final screen = File(
    'lib/features/maps/presentation/maps_screen.dart',
  ).readAsStringSync();
  final preview = File(
    'lib/features/maps/presentation/map_marker_preview_sheet.dart',
  ).readAsStringSync();
  final actionSheet = File(
    'lib/features/maps/presentation/location_action_sheet.dart',
  ).readAsStringSync();
  final contactForm = File(
    'lib/features/contacts/presentation/contact_form_screen.dart',
  ).readAsStringSync();
  final eventForm = File(
    'lib/features/planner/presentation/calendar_event_form_screen.dart',
  ).readAsStringSync();
  final eventCreation = File(
    'lib/features/planner/presentation/calendar_event_creation.dart',
  ).readAsStringSync();
  final gate = File(
    'lib/features/planner/presentation/calendar_event_create_gate_screen.dart',
  ).readAsStringSync();

  group('A/B — the map is the stable canvas', () {
    test('direct marker tap selects only and issues no camera command', () {
      expect(surface, isNot(contains('_centerSelectedMarker')));
      expect(surface, isNot(contains('CameraUpdate.scrollBy(0, 180)')));
      final onTap = RegExp(
        r'void _selectMarker\(MapMarker marker\) \{\s*'
        r'(//[^\n]*\n\s*)*'
        r'(if \(widget\.interactionPaused\) return;\s*)?'
        r'ref\.read\(mapSelectedMarkerProvider\.notifier\)\.select\(marker\);\s*'
        r'widget\.onMarkerTap\(marker\);\s*\}',
      );
      expect(onTap.hasMatch(surface), isTrue);
    });

    test('marker switch selects the new marker without a selection camera', () {
      // A->B switch only changes the selected provider state; the surface never
      // issues a focus/camera command from selection.
      expect(surface, isNot(contains('_animateTo(marker.coordinate')));
    });

    test('search focus distinction preserves the intentional one-shot camera', () {
      // The dedicated Search focus path still owns a deliberate camera intent.
      expect(surface, contains('_handleFocus(MapFocusRequest request)'));
      expect(
        surface,
        matches(
          RegExp(
            r'final animation = _animateTo\(\s*request\.coordinate,\s*zoom: 15,\s*duration: const Duration\(milliseconds: 650\),\s*\)',
          ),
        ),
      );
      expect(surface, contains('_cameraIntent += 1;'));
    });

    test(
      'preview motion is sheet-controlled, not an abrupt direct overlay',
      () {
        expect(screen, contains('animation: _previewAnim'));
        expect(screen, contains('_previewLift'));
        expect(screen, contains('controlsLift: _previewLift'));
        expect(screen, contains('_PreviewSheetHost'));
        expect(screen, contains('Transform.translate'));
        expect(screen, contains('easeOutCubic'));
        expect(preview, contains('DraggableScrollableSheet'));
      },
    );
  });

  group('E — inline Edit Pin Location stays on the same map', () {
    test('no second picker route is pushed from the Maps origin', () {
      expect(screen, isNot(contains('MapLocationPickerScreen')));
      expect(screen, isNot(contains('RoutePaths.mapPicker')));
      expect(preview, isNot(contains('RoutePaths.mapPicker')));
      expect(screen, contains('_InlineEditSession'));
      expect(screen, contains('maps-centering-confirm'));
      expect(screen, contains('maps-centering-cancel'));
    });

    test('cancel writes nothing; confirm persists the camera center once', () {
      // Cancel only clears the session — no setCoordinate is reachable from it.
      expect(
        RegExp(
          'void _cancelInlineEdit\\(\\)\\s*\\{[^}]*setState\\(\\(\\) => _inlineEdit = null',
        ).hasMatch(screen),
        isTrue,
      );
      expect(screen, contains('_confirmInlineEdit() async'));
      expect(screen, contains('.setCoordinate('));
      expect(screen, contains('_cameraCenter ?? session.marker.coordinate'));
      expect(screen, contains('owner: session.marker.owner'));
      expect(RegExp('setCoordinate\\([^)]*\\)').hasMatch(screen), isTrue);
    });
  });

  group('C/F/G — dedicated Drop Pin + shared chooser', () {
    test('dedicated Drop Pin control enters provisional placement mode', () {
      expect(surface, contains("key: const Key('maps-drop-pin-button')"));
      // M7 reconciliation (2026-09-16): `controlSurface` and a literal
      // `foregroundColor: Colors.white` were retired with the canonical theme
      // law — the control passes NO colours and inherits primary/onPrimary from
      // FloatingActionButtonThemeData. Lock the law that replaced them: no local
      // colour override, and a WHITE glyph on the canonical blue primary.
      expect(surface, isNot(contains('backgroundColor: controlSurface')));
      expect(surface, isNot(contains('foregroundColor: Colors.white')));
      final canonical = AppTheme.light(ThemeColorMode.blue);
      expect(
        canonical.floatingActionButtonTheme.backgroundColor,
        AppTheme.blueLightPrimary,
      );
      expect(canonical.floatingActionButtonTheme.foregroundColor, Colors.white);
      expect(surface, isNot(contains("key: const Key('maps-drop-pin')")));
      expect(screen, contains('_beginDropPin'));
      expect(screen, contains('_dropPinMode = true'));
    });

    test('Drop Pin X writes nothing; check opens the chooser without a row', () {
      expect(screen, contains('void _cancelDropPin()'));
      expect(
        RegExp(
          'void _cancelDropPin\\(\\)\\s*\\{[^}]*setState\\(\\(\\) => _dropPinMode = false',
        ).hasMatch(screen),
        isTrue,
      );
      expect(screen, contains('_confirmDropPin'));
      expect(screen, contains('showMapLocationActionSheet(context)'));
      expect(screen, contains('_confirmDropPin'));
    });

    test('long press opens the same chooser and never writes a row', () {
      expect(
        screen,
        contains('_beginPlacementCoordinate(MapCoordinate coordinate)'),
      );
      expect(screen, contains('_openLocationActionSheet(coordinate)'));
      expect(screen, isNot(contains('_openLocationActionSheet;')));
    });

    test('chooser never persists by appearing and uses singular nouns', () {
      expect(actionSheet, contains("key: const Key('location-action-place')"));
      expect(actionSheet, contains('Add Place'));
      expect(actionSheet, contains('Add Contact'));
      expect(actionSheet, contains('Add Event'));
      expect(actionSheet, isNot(contains('Add Information')));
      expect(actionSheet, isNot(contains('Add Marker')));
      expect(actionSheet, isNot(contains('Add Person')));
    });
  });

  group('H — Add Contact from map uses the canonical form', () {
    test(
      'canonical create form receives the coordinate without address text',
      () {
        expect(
          contactForm,
          contains(
            'const ContactFormScreen.create({super.key, this.initialCoordinate})',
          ),
        );
        expect(contactForm, contains('final MapCoordinate? initialCoordinate'));
        expect(contactForm, contains('_mapCoordinate = coordinate'));
        expect(screen, contains('RoutePaths.contactCreate'));
        expect(screen, contains('AddContactMapExtra(coordinate: coordinate)'));
        // No geocoding or fabricated address.
        expect(contactForm, isNot(contains('Geocoder')));
        expect(contactForm, isNot(contains('reverseGeocode')));
      },
    );
  });

  group('I — Add Event from map uses the canonical form', () {
    test(
      'create form receives the coordinate and current date/time defaults',
      () {
        expect(gate, contains('this.initialCoordinate'));
        expect(gate, contains('final MapCoordinate? initialCoordinate'));
        expect(eventCreation, contains('initialCoordinate: initialCoordinate'));
        expect(eventForm, contains('initialCoordinate'));
        expect(eventForm, contains('_mapCoordinate = coordinate'));
        expect(screen, contains('RoutePaths.calendarEventCreate'));
        expect(screen, contains('today.iso8601'));
        expect(screen, contains(r'startMinute=$startMinute'));
        // The canonical end/duration default is preserved (no new end rule).
        expect(eventForm, contains('_end = _timeFromMinute('));
        // No Event row is created before form Save.
        expect(screen, isNot(contains('calendarEventRepositoryProvider')));
      },
    );
  });
}
