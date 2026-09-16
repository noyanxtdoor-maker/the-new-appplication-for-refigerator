import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/application/saved_place_providers.dart';
import 'package:rmplanner/features/maps/application/saved_place_repository.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/domain/saved_place.dart';
import 'package:rmplanner/features/maps/presentation/google_maps_surface.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';

import 'support/fab_theme_probe.dart';

const _coordinate = MapCoordinate(latitude: 14.6001, longitude: 121.0002);
const _marker = MapMarker(
  owner: MapCoordinateOwner.savedPlace,
  recordId: 'place-1',
  coordinate: _coordinate,
  displayName: 'Original Place',
  colorValue: 0xFF175A8F,
  placeMarkerMode: SavedPlaceMarkerMode.standard,
  placeStandardCategory: SavedPlaceStandardCategory.information,
);

final class _Coordinates implements MapCoordinateRepository {
  @override
  Stream<int> watchChanges(String profileId) => const Stream<int>.empty();

  @override
  Future<void> clearCoordinate({
    required String profileId,
    required MapCoordinateOwner owner,
    required String recordId,
  }) async {}

  @override
  Future<MapCoordinate?> readCoordinate({
    required String profileId,
    required MapCoordinateOwner owner,
    required String recordId,
  }) async => _coordinate;

  @override
  Future<List<MapMarker>> readMarkers(String profileId) async => [_marker];

  @override
  Future<void> setCoordinate({
    required String profileId,
    required MapCoordinateOwner owner,
    required String recordId,
    required MapCoordinate coordinate,
  }) async {}
}

final class _Places implements SavedPlaceRepository {
  SavedPlace place = SavedPlace(
    id: 'place-1',
    profileId: 'profile-1',
    label: 'Original Place',
    coordinate: _coordinate,
    markerMode: SavedPlaceMarkerMode.standard,
    standardCategory: SavedPlaceStandardCategory.information,
    customEmoji: null,
    markerColorHex: '#175A8F',
    createdAtUtc: DateTime.utc(2026, 9, 2, 1),
    updatedAtUtc: DateTime.utc(2026, 9, 2, 1),
  );
  final created = <SavedPlaceDraft>[];
  final updated = <({String id, SavedPlaceDraft draft})>[];
  final deleted = <String>[];

  @override
  Stream<List<SavedPlace>> watch(String profileId) => Stream.value([place]);

  @override
  Future<List<SavedPlace>> list(String profileId) async => [place];

  @override
  Future<SavedPlace?> readById({
    required String profileId,
    required String id,
  }) async => id == place.id && profileId == place.profileId ? place : null;

  @override
  Future<SavedPlace> create({
    required String profileId,
    required SavedPlaceDraft draft,
  }) async {
    created.add(draft);
    return place;
  }

  @override
  Future<SavedPlace> update({
    required String profileId,
    required String id,
    required SavedPlaceDraft draft,
  }) async {
    updated.add((id: id, draft: draft));
    place = SavedPlace(
      id: place.id,
      profileId: place.profileId,
      label: draft.label,
      coordinate: draft.coordinate,
      markerMode: draft.markerMode,
      standardCategory: draft.standardCategory,
      customEmoji: draft.customEmoji,
      markerColorHex: draft.markerColorHex,
      createdAtUtc: place.createdAtUtc,
      updatedAtUtc: DateTime.utc(2026, 9, 2, 2),
    );
    return place;
  }

  @override
  Future<void> delete({required String profileId, required String id}) async {
    deleted.add(id);
  }
}

Future<void> _mountMaps(WidgetTester tester, _Places places) async {
  tester.view.physicalSize = const Size(431, 912);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mapProfileIdProvider.overrideWithValue('profile-1'),
        savedPlaceProfileIdProvider.overrideWithValue('profile-1'),
        savedPlaceRepositoryProvider.overrideWithValue(places),
        mapCoordinateRepositoryProvider.overrideWithValue(_Coordinates()),
        mapProjectedMarkersProvider.overrideWith((ref) async => [_marker]),
        mapPassiveLocationProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        home: MapsScreen(
          mapBuilder: (_, _) => const ColoredBox(color: Colors.white),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

GoogleMapsSurface _surface(WidgetTester tester) =>
    tester.widget<GoogleMapsSurface>(find.byType(GoogleMapsSurface));

void main() {
  test('Saved Place artwork is an upright non-flat square marker', () {
    final source = File(
      'lib/features/maps/presentation/google_maps_surface.dart',
    ).readAsStringSync();
    expect(source, contains('final square = RRect.fromRectAndRadius'));
    expect(source, isNot(contains('final diamond = Path()')));
    expect(source, contains('flat: false'));
  });

  testWidgets('map controls are one white and blue family with a real pin', (
    tester,
  ) async {
    final lift = ValueNotifier<double>(0);
    addTearDown(lift.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          // Pass 4: the icon foreground follows the ACTIVE theme accent; this
          // lock pins the blue theme. Rose is locked in the Pass 4 suite.
          theme: AppTheme.light(ThemeColorMode.blue),
          home: Scaffold(
            body: GoogleMapsSurface(
              markers: const [_marker],
              initialCoordinate: null,
              onMarkerTap: (_) {},
              controlsLift: lift,
              mapBuilder: (_, _) => const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in const [
      'maps-drop-pin-button',
      'maps-type-button',
      'maps-locate-button',
    ]) {
      // M7 reconciliation (2026-09-16): the control passes NO colours; the
      // canonical FAB theme supplies the primary surface and the WHITE glyph.
      expect(
        resolvedFabBackground(tester, Key(key)),
        AppTheme.light(ThemeColorMode.blue).colorScheme.primary,
      );
      expect(resolvedFabIconColor(tester, Key(key)), Colors.white);
    }
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(const Key('maps-drop-pin-button')),
              matching: find.byType(Icon),
            ),
          )
          .icon,
      Icons.location_pin,
    );
  });

  testWidgets('placement lifts the whole stack and restores its exact rest', (
    tester,
  ) async {
    await _mountMaps(tester, _Places());
    final keys = const [
      'maps-drop-pin-button',
      'maps-type-button',
      'maps-locate-button',
    ];
    final resting = [
      for (final key in keys) tester.getRect(find.byKey(Key(key))),
    ];
    await tester.tap(find.byKey(const Key('maps-drop-pin-button')));
    await tester.pumpAndSettle();
    final cancel = tester.getRect(
      find.byKey(const Key('maps-centering-cancel')),
    );
    final confirm = tester.getRect(
      find.byKey(const Key('maps-centering-confirm')),
    );
    for (var index = 0; index < keys.length; index++) {
      final moved = tester.getRect(find.byKey(Key(keys[index])));
      expect(moved.top, lessThan(resting[index].top));
      expect(moved.overlaps(cancel), isFalse);
      expect(moved.overlaps(confirm), isFalse);
    }
    await tester.tap(find.byKey(const Key('maps-centering-cancel')));
    await tester.pumpAndSettle();
    for (var index = 0; index < keys.length; index++) {
      expect(tester.getRect(find.byKey(Key(keys[index]))), resting[index]);
    }
  });

  testWidgets('Edit Place prefills and updates the same ID without moving it', (
    tester,
  ) async {
    final places = _Places();
    await _mountMaps(tester, places);
    _surface(tester).onMarkerTap(_marker);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('maps-place-preview-edit-place')));
    await tester.pumpAndSettle();
    expect(find.text('Edit Place'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('saved-place-label')))
          .controller!
          .text,
      'Original Place',
    );
    await tester.enterText(
      find.byKey(const Key('saved-place-label')),
      'Updated Place',
    );
    await tester.tap(find.byKey(const Key('saved-place-category-food')));
    await tester.tap(find.byKey(const Key('saved-place-save')));
    await tester.pumpAndSettle();
    expect(places.created, isEmpty);
    expect(places.updated, hasLength(1));
    expect(places.updated.single.id, 'place-1');
    expect(places.updated.single.draft.coordinate, _coordinate);
    expect(places.updated.single.draft.label, 'Updated Place');
  });

  testWidgets('Delete Place confirms and deletes only the selected ID', (
    tester,
  ) async {
    final places = _Places();
    await _mountMaps(tester, places);
    _surface(tester).onMarkerTap(_marker);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('maps-place-preview-delete-place')));
    await tester.pumpAndSettle();
    expect(find.text('Delete Place?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-saved-place-cancel')));
    await tester.pumpAndSettle();
    expect(places.deleted, isEmpty);

    await tester.tap(find.byKey(const Key('maps-place-preview-delete-place')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-saved-place-confirm')));
    await tester.pumpAndSettle();
    expect(places.deleted, ['place-1']);
  });
}
