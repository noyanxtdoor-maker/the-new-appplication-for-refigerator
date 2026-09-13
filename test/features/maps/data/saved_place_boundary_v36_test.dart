import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/data/drift_map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/data/drift_saved_place_repository.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/domain/saved_place.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../../../support/test_dependencies.dart';

void main() {
  test(
    'v35 to v36 adds boundary columns without losing place or profile data',
    () async {
      final raw = sqlite3.sqlite3.openInMemory();
      try {
        // Build a REAL v35 database: schema v35 with one saved place carrying
        // the accepted marker-identity state.
        final version35 = AppDatabase.forTesting(
          NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
          schemaVersionOverride: 35,
        );
        final repo35 = buildTestRepository(database: version35);
        final profile = await repo35.completeOnboarding();
        await version35
            .into(version35.savedPlaces)
            .insert(
              SavedPlacesCompanion.insert(
                id: 'place-v35',
                profileId: profile.id,
                label: 'Farm 35',
                latitude: 14.6,
                longitude: 121.0,
                markerMode: const Value<String>('standard'),
                standardCategory: const Value<String?>('food'),
                markerColor: const Value<String>('#0E71B8'),
                createdAtUtc: DateTime.utc(2026, 9, 1),
                updatedAtUtc: DateTime.utc(2026, 9, 1),
              ),
            );
        await version35.close();

        // Reopen at the CURRENT schema version (v47): the v36 step must add
        // the two nullable boundary columns while preserving every persisted
        // value, then all later additive migrations through v47 are applied
        // without touching Saved Place data.
        final version37 = AppDatabase.forTesting(
          NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
        );
        expect(
          (await version37.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          47,
        );
        final columns = await version37
            .customSelect("PRAGMA table_info(saved_places)")
            .get();
        final names = columns.map((row) => row.read<String>('name')).toSet();
        expect(
          names,
          containsAll(<String>['boundary_color', 'boundary_vertices']),
        );
        final place = await (version37.select(
          version37.savedPlaces,
        )..where((table) => table.id.equals('place-v35'))).getSingle();
        expect(place.label, 'Farm 35');
        expect(place.markerColor, '#0E71B8');
        expect(place.standardCategory, 'food');
        expect(
          place.boundaryColor,
          isNull,
          reason: 'fresh migration default is NO boundary',
        );
        expect(place.boundaryVertices, isNull);
        expect(
          (await version37.select(version37.localProfiles).get()).single.id,
          profile.id,
        );
        await version37.close();
      } finally {
        raw.close();
      }
    },
  );

  test('Saved Place boundary persists, edits, clears, and stays color-'
      'independent of the marker', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    final repository = DriftSavedPlaceRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 3, 2)),
      identifiers: SequenceIdentifierSource(const <String>['place-1']),
    );
    const a = MapCoordinate(latitude: 14.6, longitude: 121.0);
    const b = MapCoordinate(latitude: 14.61, longitude: 121.01);
    const c = MapCoordinate(latitude: 14.59, longitude: 121.02);

    // CREATE with a boundary: blue marker + YELLOW boundary are independent.
    final created = await repository.create(
      profileId: profile.id,
      draft: const SavedPlaceDraft(
        label: 'Farm A',
        coordinate: a,
        markerColorHex: '#175A8F',
        boundary: SavedPlaceBoundary(
          colorHex: '#FFD600',
          vertices: <MapCoordinate>[a, b, c],
        ),
      ),
    );
    final stored = (await repository.readById(
      profileId: profile.id,
      id: created.id,
    ))!;
    expect(stored.markerColorHex, '#175A8F');
    expect(stored.boundary!.colorHex, '#FFD600');
    expect(stored.boundary!.vertices, <MapCoordinate>[a, b, c]);
    final row = await (database.select(
      database.savedPlaces,
    )..where((table) => table.id.equals(created.id))).getSingle();
    expect(row.boundaryVertices, isNotNull);

    // UPDATE the boundary only; the marker color never moves.
    final updated = await repository.update(
      profileId: profile.id,
      id: created.id,
      draft: SavedPlaceDraft(
        label: 'Farm A',
        coordinate: a,
        markerColorHex: '#175A8F',
        boundary: SavedPlaceBoundary(
          colorHex: '#7B1FA2',
          vertices: const <MapCoordinate>[c, b, a],
        ),
      ),
    );
    expect(updated.boundary!.colorHex, '#7B1FA2');
    expect(updated.markerColorHex, '#175A8F');

    // CLEAR the boundary: the place itself survives untouched.
    final cleared = await repository.update(
      profileId: profile.id,
      id: created.id,
      draft: SavedPlaceDraft(label: 'Farm A', coordinate: a),
    );
    expect(cleared.boundary, isNull);
    expect(
      (await repository.readById(profileId: profile.id, id: created.id))!.label,
      'Farm A',
    );
    final clearedRow = await (database.select(
      database.savedPlaces,
    )..where((table) => table.id.equals(created.id))).getSingle();
    expect(clearedRow.boundaryColor, isNull);
    expect(clearedRow.boundaryVertices, isNull);

    // DELETE the place: the boundary dies with the row (Option A law).
    await repository.delete(profileId: profile.id, id: created.id);
    expect(
      await repository.readById(profileId: profile.id, id: created.id),
      isNull,
    );
  });

  test('malformed stored boundary JSON is treated as absent', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    final repository = DriftSavedPlaceRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 3, 2)),
      identifiers: SequenceIdentifierSource(const <String>['place-1']),
    );
    final place = await repository.create(
      profileId: profile.id,
      draft: const SavedPlaceDraft(
        label: 'Broken',
        coordinate: MapCoordinate(latitude: 14.6, longitude: 121.0),
      ),
    );
    await (database.update(
      database.savedPlaces,
    )..where((table) => table.id.equals(place.id))).write(
      SavedPlacesCompanion(
        boundaryColor: const Value<String?>('#FFD600'),
        boundaryVertices: const Value<String?>('{"not":"a vertex list"}'),
      ),
    );
    final read = (await repository.readById(
      profileId: profile.id,
      id: place.id,
    ))!;
    expect(read.boundary, isNull, reason: 'malformed geometry must be absent');
  });

  test(
    'boundary columns do not disturb the canonical marker projection',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final repository = DriftSavedPlaceRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 3, 2)),
        identifiers: SequenceIdentifierSource(const <String>['place-1']),
      );
      await repository.create(
        profileId: profile.id,
        draft: const SavedPlaceDraft(
          label: 'Farm B',
          coordinate: MapCoordinate(latitude: 10.0, longitude: 122.0),
          markerColorHex: '#0E71B8',
          boundary: SavedPlaceBoundary(
            colorHex: '#FFD600',
            vertices: <MapCoordinate>[
              MapCoordinate(latitude: 10.0, longitude: 122.0),
              MapCoordinate(latitude: 10.01, longitude: 122.01),
              MapCoordinate(latitude: 9.99, longitude: 122.02),
            ],
          ),
        ),
      );
      final markers = await DriftMapCoordinateRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 3, 2)),
      ).readMarkers(profile.id);
      final placeMarkers = markers
          .where((marker) => marker.owner == MapCoordinateOwner.savedPlace)
          .toList(growable: false);
      expect(placeMarkers, hasLength(1));
      expect(placeMarkers.single.displayName, 'Farm B');
      expect(placeMarkers.single.colorValue, markerColorHexToArgb('#0E71B8'));
      expect(
        placeMarkers.single.coordinate,
        const MapCoordinate(latitude: 10.0, longitude: 122.0),
      );
    },
  );
}
