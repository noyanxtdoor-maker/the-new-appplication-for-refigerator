// OWNER BUG (closed beta): "Group nearby markers" was ON but nearby markers
// were not grouped, so the setting appeared to have no effect.
//
// Proven cause: the native rendering gate inherited the maps library's floor of
// FOUR items per cluster (DefaultClusterRenderer.mMinClusterSize), and the
// plugin's Dart ClusterManager exposes no way to lower it. The only grouping
// that could group fewer markers was Dart's exact-coordinate aggregation, which
// requires bit-identical coordinates. Two or three genuinely near records could
// therefore never group, at any zoom. See android/maps_interaction_patch:
// NtMapInteractionTest proves the corrected gate groups from two records, that
// the grouping radius applied to this app's own cluster managers is 65 screen
// pixels instead of the library's 100 (owner tuning, correction #4), and that
// zooming in still separates nearby records.
//
// These tests cover the Dart half of the same contract — what the surface must
// hand to the native transport for the setting to have any effect, and what it
// must withhold when the setting is OFF. Both nearby records here have
// GENUINELY DIFFERENT coordinates, which is the case the older suite (identical
// coordinates only) never exercised.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_provider.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_repository.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/domain/saved_place.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';

import 'maps_preferences_test_support.dart';

class _CanvasPlatform extends GoogleMapsFlutterPlatform {
  @override
  Widget buildViewWithConfiguration(
    int id,
    PlatformViewCreatedCallback created, {
    required MapWidgetConfiguration widgetConfiguration,
    MapConfiguration mapConfiguration = const MapConfiguration(),
    MapObjects mapObjects = const MapObjects(),
  }) => const ColoredBox(color: Colors.white);
}

GoogleMap _map(WidgetTester tester) =>
    tester.widget<GoogleMap>(find.byType(GoogleMap));

/// Two Saved Places roughly 60 m apart: near each other, but not at the same
/// coordinate, so the pre-fix code could never group them.
const _nearbyA = MapCoordinate(latitude: 14.6000, longitude: 121.0000);
const _nearbyB = MapCoordinate(latitude: 14.6004, longitude: 121.0004);

MapMarker _place(String id, MapCoordinate point) => MapMarker(
  owner: MapCoordinateOwner.savedPlace,
  recordId: id,
  displayName: id,
  coordinate: point,
  colorValue: 0xFF175A8F,
  placeMarkerMode: SavedPlaceMarkerMode.standard,
  placeStandardCategory: SavedPlaceStandardCategory.food,
);

final _records = <MapMarker>[_place('A', _nearbyA), _place('B', _nearbyB)];

Future<ProviderContainer> _mount(WidgetTester tester, {required bool group}) async {
  tester.view.physicalSize = const Size(431, 912);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        contactProfileIdProvider.overrideWithValue('test-profile'),
        mapProfileIdProvider.overrideWithValue('test-profile'),
        mapProjectedMarkersProvider.overrideWith((ref) async => _records),
        mapPassiveLocationProvider.overrideWith((ref) async => null),
        ...mapsPreferencesOverrides(
          seed: MapsPreferencesModel(groupNearbyMarkers: group),
        ),
      ],
      child: const MaterialApp(home: MapsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(MapsScreen)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() {
    GoogleMapsFlutterPlatform.instance = _CanvasPlatform();
  });

  testWidgets(
    'grouping OFF renders both nearby records individually and offers no '
    'cluster transport at all',
    (tester) async {
      await _mount(tester, group: false);

      expect(_map(tester).markers, hasLength(2));
      expect(
        _map(tester).markers.every((m) => m.clusterManagerId == null),
        isTrue,
        reason: 'no marker may be enrolled in clustering while the setting is '
            'OFF',
      );
      expect(
        _map(tester).clusterManagers,
        isEmpty,
        reason: 'with no manager on the map, nothing can group',
      );
    },
  );

  testWidgets(
    'grouping ON enrolls both nearby records in the native clustering '
    'transport',
    (tester) async {
      await _mount(tester, group: true);

      // Distinct coordinates stay distinct records in Dart: proximity grouping
      // is the native transport's job, which is exactly what the corrected
      // native gate now does from two records up.
      expect(_map(tester).markers, hasLength(2));
      expect(
        _map(tester).markers.every((m) => m.clusterManagerId != null),
        isTrue,
        reason: 'an unenrolled marker can never be grouped with its neighbour',
      );
      expect(_map(tester).clusterManagers, hasLength(3));
    },
  );

  testWidgets('the setting takes effect on the live map, both ways', (
    tester,
  ) async {
    final container = await _mount(tester, group: true);
    expect(_map(tester).clusterManagers, hasLength(3));

    await container
        .read(mapsPreferencesProvider.notifier)
        .setGroupNearbyMarkers(false);
    await tester.pumpAndSettle();
    expect(_map(tester).clusterManagers, isEmpty);
    expect(_map(tester).markers, hasLength(2));
    expect(_map(tester).markers.every((m) => m.clusterManagerId == null), isTrue);

    await container
        .read(mapsPreferencesProvider.notifier)
        .setGroupNearbyMarkers(true);
    await tester.pumpAndSettle();
    expect(_map(tester).clusterManagers, hasLength(3));
    expect(_map(tester).markers.every((m) => m.clusterManagerId != null), isTrue);
  });

  testWidgets(
    'grouping is presentation only: the records it groups are never rewritten',
    (tester) async {
      final before = List<MapMarker>.of(_records);
      final container = await _mount(tester, group: true);

      await container
          .read(mapsPreferencesProvider.notifier)
          .setGroupNearbyMarkers(false);
      await tester.pumpAndSettle();
      await container
          .read(mapsPreferencesProvider.notifier)
          .setGroupNearbyMarkers(true);
      await tester.pumpAndSettle();
      // Tapping a grouped member must not replace or move the record either.
      _map(tester).markers.first.onTap!();
      await tester.pumpAndSettle();

      expect(before, hasLength(2));
      for (var i = 0; i < before.length; i++) {
        expect(
          identical(before[i], _records[i]),
          isTrue,
          reason: 'the source record must survive grouping unchanged',
        );
        expect(
          _records[i].coordinate,
          before[i].coordinate,
          reason: 'grouping must never move a record',
        );
        expect(_records[i].recordId, before[i].recordId);
      }
    },
  );
}
