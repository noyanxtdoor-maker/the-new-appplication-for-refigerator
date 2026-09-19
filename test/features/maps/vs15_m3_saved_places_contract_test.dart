import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('M3.0 preserves marker identity with a centered red pin', () {
    final source = File(
      'lib/features/maps/presentation/google_maps_surface.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('defaultMarkerWithHue')));
    expect(source, contains('_paintSelectedLocationPinGlyph'));
    expect(source, contains('selected: selected'));
    expect(source, contains('canvas.drawPath(star, outline)'));
    expect(source, isNot(contains('_paintSelectedLocationBadge')));
    expect(source, isNot(contains('CameraUpdate.scrollBy(0, 180)')));
  });

  test('M3 Saved Place seams are explicit and provisional', () {
    final database = File(
      'lib/core/database/app_database.dart',
    ).readAsStringSync();
    final providers = File(
      'lib/features/maps/application/map_providers.dart',
    ).readAsStringSync();
    final surface = File(
      'lib/features/maps/presentation/google_maps_surface.dart',
    ).readAsStringSync();
    final screen = File(
      'lib/features/maps/presentation/maps_screen.dart',
    ).readAsStringSync();
    final preview = File(
      'lib/features/maps/presentation/map_marker_preview_sheet.dart',
    ).readAsStringSync();
    final search = File(
      'lib/features/maps/presentation/maps_search_screen.dart',
    ).readAsStringSync();

    expect(database, contains('class SavedPlaces extends Table'));
    expect(database, contains('schemaVersion => _schemaVersionOverride ?? 48'));
    expect(database, contains('markerMode'));
    expect(database, contains('markerColor'));
    expect(providers, contains('MapFocusOwnerKind.savedPlace'));
    expect(providers, contains('mapSavedPlaceMarkersProvider'));
    expect(surface, contains("label: 'Places'"));
    expect(surface, contains("key: const Key('maps-drop-pin-button')"));
    expect(surface, isNot(contains("key: const Key('maps-drop-pin')")));
    expect(surface, contains('onLongPress:'));
    expect(screen, contains('SavedPlaceFormScreen('));
    expect(screen, contains('MaterialPageRoute<void>'));
    expect(screen, contains('_cancelPlacementMode()'));
    expect(screen, contains('_confirmDropPin'));
    expect(screen, contains('showMapLocationActionSheet'));
    expect(preview, contains('MapCoordinateOwner.savedPlace'));
    expect(search, contains('MapSearchSelection.savedPlace'));
  });

  test('Saved Place customization law is present in the form and domain', () {
    final form = File(
      'lib/features/maps/presentation/saved_place_form_sheet.dart',
    ).readAsStringSync();
    final domain = File(
      'lib/features/maps/domain/saved_place.dart',
    ).readAsStringSync();

    expect(domain, contains('enum SavedPlaceMarkerMode'));
    expect(domain, contains('enum SavedPlaceStandardCategory'));
    expect(domain, contains("SavedPlaceStandardCategory.information"));
    expect(domain, contains("SavedPlaceStandardCategory.avoid"));
    expect(domain, contains('normalizeMarkerColorHex'));
    expect(domain, contains('markerColorHexToArgb'));
    expect(form, contains('SegmentedButton<SavedPlaceMarkerMode>'));
    expect(form, contains("key: Key('saved-place-category-"));
    expect(form, contains("key: const Key('saved-place-emoji')"));
    expect(form, isNot(contains("key: const Key('saved-place-hex')")));
    expect(form, isNot(contains('polygon')));
    expect(form, isNot(contains('vertices')));
  });
}
