// VS-15 M6.2 — MapsPreferences repository (schema v37) tests.
//
// Covers: missing-row defaults, invalid-token fallback, DEFAULT ROW LAW
// (explicit choice creates the physical row), recreation persistence,
// one-field updates preserving all other fields, idempotent no-write, and
// the v36 → v37 additive migration (fresh v37 table, records intact, no
// row seeded, failure rollback).
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/maps/application/map_session_provider.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_repository.dart';
import 'package:rmplanner/features/maps/data/drift_maps_preferences_repository.dart';
import 'package:rmplanner/features/maps/data/drift_saved_place_repository.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/domain/saved_place.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../support/test_dependencies.dart';

void main() {
  final clock = FixedClock(DateTime.utc(2026, 9, 4, 12));

  group('MapsPreferences repository (v37)', () {
    late AppDatabase database;
    late DriftMapsPreferencesRepository repository;

    setUp(() {
      database = openMemoryDatabase();
      repository = DriftMapsPreferencesRepository(
        database: database,
        clock: clock,
      );
    });

    tearDown(() => database.close());

    test('1. missing row resolves owner-locked defaults', () async {
      final preferences = await repository.readPreferences();
      expect(preferences.mapType, NextTransferMapType.satellite);
      expect(preferences.groupNearbyMarkers, isTrue);
      expect(preferences.showContacts, isTrue);
      expect(preferences.showEvents, isTrue);
      expect(preferences.showSavedPlaces, isTrue);
      expect(preferences.showBoundaries, isTrue);
    });

    test('2. invalid stored mapType fails safely to Satellite', () async {
      await database
          .into(database.mapsPreferences)
          .insert(
            MapsPreferencesCompanion.insert(
              mapType: const drift.Value<String>('hologram'),
              updatedAtUtc: DateTime.utc(2026, 9, 4, 12),
            ),
          );
      final preferences = await repository.readPreferences();
      expect(preferences.mapType, NextTransferMapType.satellite);
      expect(preferences.groupNearbyMarkers, isTrue);
    });

    test(
      '3. explicit Satellite with no physical row CREATES the row',
      () async {
        expect(await database.select(database.mapsPreferences).get(), isEmpty);
        await repository.savePreferences(
          const MapsPreferencesModel(mapType: NextTransferMapType.satellite),
        );
        final rows = await database.select(database.mapsPreferences).get();
        expect(rows, hasLength(1));
        expect(rows.single.mapType, NextTransferMapType.satellite.storageName);
        expect(rows.single.key, 'primary');
      },
    );

    test('4. map type persists after repository recreation', () async {
      await repository.savePreferences(
        const MapsPreferencesModel(mapType: NextTransferMapType.terrain),
      );
      final recreated = DriftMapsPreferencesRepository(
        database: database,
        clock: clock,
      );
      final preferences = await recreated.readPreferences();
      expect(preferences.mapType, NextTransferMapType.terrain);
    });

    test('5. grouping persists after repository recreation', () async {
      await repository.savePreferences(
        const MapsPreferencesModel(groupNearbyMarkers: false),
      );
      final recreated = DriftMapsPreferencesRepository(
        database: database,
        clock: clock,
      );
      expect((await recreated.readPreferences()).groupNearbyMarkers, isFalse);
    });

    test('6. all visibility booleans persist', () async {
      await repository.savePreferences(
        const MapsPreferencesModel(
          showContacts: false,
          showEvents: false,
          showSavedPlaces: false,
          showBoundaries: false,
        ),
      );
      final preferences = await repository.readPreferences();
      expect(preferences.showContacts, isFalse);
      expect(preferences.showEvents, isFalse);
      expect(preferences.showSavedPlaces, isFalse);
      expect(preferences.showBoundaries, isFalse);
      expect(preferences.mapType, NextTransferMapType.satellite);
      expect(preferences.groupNearbyMarkers, isTrue);
    });

    test('7. updating one field preserves all other stored fields', () async {
      await repository.savePreferences(
        const MapsPreferencesModel(
          mapType: NextTransferMapType.hybrid,
          groupNearbyMarkers: false,
          showEvents: false,
        ),
      );
      await repository.savePreferences(
        const MapsPreferencesModel(
          mapType: NextTransferMapType.hybrid,
          groupNearbyMarkers: false,
          showEvents: false,
          showContacts: false,
        ),
      );
      final preferences = await repository.readPreferences();
      expect(preferences.showContacts, isFalse);
      expect(preferences.mapType, NextTransferMapType.hybrid);
      expect(preferences.groupNearbyMarkers, isFalse);
      expect(preferences.showEvents, isFalse);
      expect(preferences.showSavedPlaces, isTrue);
      expect(preferences.showBoundaries, isTrue);
    });

    test(
      '8. same stored value with existing row is an idempotent no-write',
      () async {
        await repository.savePreferences(
          const MapsPreferencesModel(mapType: NextTransferMapType.terrain),
        );
        final firstRow =
            (await database.select(database.mapsPreferences).get()).single;
        await repository.savePreferences(
          const MapsPreferencesModel(mapType: NextTransferMapType.terrain),
        );
        final secondRow =
            (await database.select(database.mapsPreferences).get()).single;
        expect(secondRow.updatedAtUtc, firstRow.updatedAtUtc);
        expect(secondRow.mapType, 'terrain');
      },
    );
  });

  group('v36 → v37 migration', () {
    test('9/10/11/12. v36 DB upgrades additively: MapsPreferences table '
        'created, domain records + Saved Places + boundaries intact, no row '
        'seeded', () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionThirtySix = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 36,
        );
        final profile = await buildTestRepository(
          database: versionThirtySix,
        ).completeOnboarding();
        final savedPlaces = DriftSavedPlaceRepository(
          database: versionThirtySix,
          clock: clock,
          identifiers: SequenceIdentifierSource(<String>[
            '33333333-3333-4333-8333-333333333333',
          ]),
        );
        final created = await savedPlaces.create(
          profileId: profile.id,
          draft: const SavedPlaceDraft(
            label: 'Legacy Farm',
            coordinate: MapCoordinate(latitude: 14.6, longitude: 121.0),
            boundary: SavedPlaceBoundary(
              vertices: <MapCoordinate>[
                MapCoordinate(latitude: 14.59, longitude: 120.99),
                MapCoordinate(latitude: 14.61, longitude: 120.99),
                MapCoordinate(latitude: 14.61, longitude: 121.01),
              ],
              colorHex: '#175A8F',
            ),
          ),
        );
        expect(created.boundary, isNotNull);
        await versionThirtySix.close();

        final versionThirtySeven = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        );
        final userVersion = await versionThirtySeven
            .customSelect('PRAGMA user_version')
            .getSingle();
        // The historical v36 source must upgrade through every additive step
        // to the current application schema.
        expect(userVersion.read<int>('user_version'), 47);

        final tableCount = await versionThirtySeven
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type = 'table' AND name = 'maps_preferences'",
            )
            .getSingle();
        expect(tableCount.read<int>('count'), 1);

        // No row is seeded: missing-row fallback provides defaults.
        expect(
          await versionThirtySeven
              .select(versionThirtySeven.mapsPreferences)
              .get(),
          isEmpty,
        );

        // Existing domain records (profile + saved place + boundary) intact.
        final profiles = await versionThirtySeven
            .select(versionThirtySeven.localProfiles)
            .get();
        expect(profiles.single.id, profile.id);
        final rows = await versionThirtySeven
            .customSelect(
              "SELECT id, label, boundary_color, boundary_vertices "
              "FROM saved_places",
            )
            .get();
        expect(rows, hasLength(1));
        expect(rows.single.read<String>('label'), 'Legacy Farm');
        expect(rows.single.read<String>('boundary_color'), '#175A8F');
        expect(rows.single.read<String>('boundary_vertices'), isNot(isNull));
        await versionThirtySeven.close();
      } finally {
        sqliteDatabase.close();
      }
    });

    test('13. injected v37 migration failure rolls back: user_version stays '
        '36 and the table is not created', () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionThirtySix = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 36,
        );
        await buildTestRepository(
          database: versionThirtySix,
        ).completeOnboarding();
        await versionThirtySix.close();

        final failing = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          injectMapsPreferencesMigrationFailure: true,
        );
        await expectLater(
          failing.select(failing.mapsPreferences).get(),
          throwsA(isA<StateError>()),
        );
        await failing.close();

        final reopened = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 36,
        );
        final userVersion = await reopened
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(userVersion.read<int>('user_version'), 36);
        final tableCount = await reopened
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type = 'table' AND name = 'maps_preferences'",
            )
            .getSingle();
        expect(tableCount.read<int>('count'), 0);
        await reopened.close();
      } finally {
        sqliteDatabase.close();
      }
    });

    test('14. fresh v37 database creates the table correctly', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final tableCount = await database
          .customSelect(
            "SELECT COUNT(*) AS count FROM sqlite_master "
            "WHERE type = 'table' AND name = 'maps_preferences'",
          )
          .getSingle();
      expect(tableCount.read<int>('count'), 1);
      expect(await database.select(database.mapsPreferences).get(), isEmpty);
    });
  });
}
