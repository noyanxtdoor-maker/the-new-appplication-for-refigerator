// VS16 M7 — Maps SDK-native top-left compass contract.
//
// The Google Maps SDK owns the top-left needle compass. This test pins the
// Flutter-to-native configuration and the surrounding non-interference law:
//
//   1. the map starts north-up,
//   2. a rotated bearing is observable,
//   3. bearing is PRESERVED across re-entry (the accepted law is preserve,
//      never auto-reset),
//   4. the SDK-native compass and rotate gestures are explicitly enabled,
//   5. zoom and target are preserved,
//   6. camera/bearing work never invokes Locate me,
//   7. it requests no location permission,
//   8. it writes no Saved Place / Maps domain state,
//   9. it writes no Event / Task / Contact state,
//  10. it starts no background location or geofence.
//
// No app-owned compass is added: on Android the Google Maps SDK displays and
// handles its own top-left control, including preserving camera target and zoom
// while returning bearing to north-up. Widget tests capture the configuration;
// the platform control's visual/tap behavior is covered by physical smoke.
//
// VS16 M7: the visible needle must also still DO its job. The project-owned
// native tap layer (`android/maps_interaction_patch`) used to cancel every
// completed tap before the SDK saw UP, which left the needle visible but
// unable to reset the camera. It now never intercepts a press that starts on a
// docked SDK control, and a compass reset (bearing 0) is accepted, persisted
// and never overwritten by the rotated camera that preceded it.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_session_provider.dart'
    as session;
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/google_maps_surface.dart';

import 'maps_preferences_test_support.dart';

const _gps = MapCoordinate(latitude: 14.6, longitude: 121);
const _rotated = CameraPosition(
  target: LatLng(25.033, 121.5654),
  zoom: 13.25,
  bearing: 47.5,
  tilt: 38,
);
const _place = MapMarker(
  owner: MapCoordinateOwner.savedPlace,
  recordId: 'bearing-target',
  displayName: 'Bearing target',
  coordinate: MapCoordinate(latitude: 25.033, longitude: 121.5654),
);

class _BearingPlatform extends GoogleMapsFlutterPlatform {
  final positions = <int, CameraPosition>{};
  final configurations = <int, MapConfiguration>{};
  final moves = <int, StreamController<CameraMoveEvent>>{};
  final idles = <int, StreamController<CameraIdleEvent>>{};
  final commands =
      <({String kind, int mapId, Object update, Duration? duration})>[];

  @override
  Widget buildViewWithConfiguration(
    int id,
    PlatformViewCreatedCallback created, {
    required MapWidgetConfiguration widgetConfiguration,
    MapConfiguration mapConfiguration = const MapConfiguration(),
    MapObjects mapObjects = const MapObjects(),
  }) {
    if (!positions.containsKey(id)) {
      positions[id] = widgetConfiguration.initialCameraPosition;
      configurations[id] = mapConfiguration;
      moves[id] = StreamController.broadcast();
      idles[id] = StreamController.broadcast();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel('nexttransfer/maps_interaction/$id'),
            (_) async => null,
          );
      scheduleMicrotask(() => created(id));
    }
    return ColoredBox(key: Key('native-canvas-$id'), color: Colors.grey);
  }

  @override
  Future<void> init(int mapId) async {}

  @override
  void dispose({required int mapId}) {}

  void camera(int id, CameraPosition value) {
    positions[id] = value;
    moves[id]!.add(CameraMoveEvent(id, value));
    idles[id]!.add(CameraIdleEvent(id));
  }

  @override
  Future<void> animateCameraWithConfiguration(
    CameraUpdate update,
    CameraUpdateAnimationConfiguration configuration, {
    required int mapId,
  }) async {
    commands.add((
      kind: 'animate',
      mapId: mapId,
      update: update.toJson(),
      duration: configuration.duration,
    ));
  }

  @override
  Future<void> moveCamera(CameraUpdate update, {required int mapId}) async {
    commands.add((
      kind: 'move',
      mapId: mapId,
      update: update.toJson(),
      duration: null,
    ));
  }

  @override
  Stream<CameraMoveEvent> onCameraMove({required int mapId}) =>
      moves[mapId]!.stream;
  @override
  Stream<CameraIdleEvent> onCameraIdle({required int mapId}) =>
      idles[mapId]!.stream;
  @override
  Stream<MarkerTapEvent> onMarkerTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<MarkerDragStartEvent> onMarkerDragStart({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<MarkerDragEvent> onMarkerDrag({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<MarkerDragEndEvent> onMarkerDragEnd({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<InfoWindowTapEvent> onInfoWindowTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<PolylineTapEvent> onPolylineTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<PolygonTapEvent> onPolygonTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<CircleTapEvent> onCircleTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<MapTapEvent> onTap({required int mapId}) => const Stream.empty();
  @override
  Stream<MapLongPressEvent> onLongPress({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<ClusterTapEvent> onClusterTap({required int mapId}) =>
      const Stream.empty();
  @override
  Future<void> updateMapConfiguration(
    MapConfiguration configuration, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateMarkers(MarkerUpdates updates, {required int mapId}) async {}
  @override
  Future<void> updateClusterManagers(
    ClusterManagerUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updatePolygons(
    PolygonUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updatePolylines(
    PolylineUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateCircles(
    CircleUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateHeatmaps(
    HeatmapUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateGroundOverlays(
    GroundOverlayUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateTileOverlays({
    required Set<TileOverlay> newTileOverlays,
    required int mapId,
  }) async {}
}

class _Tabs extends StatefulWidget {
  const _Tabs({required this.coordinate});
  final ValueNotifier<MapCoordinate?> coordinate;
  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  int tab = 3; // Maps is the 4th destination
  @override
  Widget build(BuildContext context) => Scaffold(
        body: tab == 3
            ? ValueListenableBuilder<MapCoordinate?>(
                valueListenable: widget.coordinate,
                builder: (_, point, _) => GoogleMapsSurface(
                  markers: const [_place],
                  initialCoordinate: point,
                  onMarkerTap: (_) {},
                  onDropPin: () {},
                ),
              )
            : Center(child: Text(['Home', 'Planner', 'Contacts'][tab])),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (value) => setState(() => tab = value),
          destinations: [
            for (final name in ['Home', 'Planner', 'Contacts', 'Maps'])
              NavigationDestination(
                key: Key('tab-$name'),
                icon: const Icon(Icons.circle),
                label: name,
              ),
          ],
        ),
      );
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  ValueNotifier<MapCoordinate?> coordinate,
) async {
  tester.view.physicalSize = const Size(430, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: mapsPreferencesOverrides(),
      child: MaterialApp(
        theme: AppTheme.light(ThemeColorMode.blue),
        home: _Tabs(coordinate: coordinate),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(_Tabs)));
}

GoogleMap _map(WidgetTester tester) =>
    tester.widget<GoogleMap>(find.byType(GoogleMap));

Future<void> _returnVia(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(Key('tab-$tab')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('tab-Maps')));
  await tester.pumpAndSettle();
}

String _surfaceSource() =>
    File('lib/features/maps/presentation/google_maps_surface.dart')
        .readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _BearingPlatform platform;
  setUp(
    () => GoogleMapsFlutterPlatform.instance = platform = _BearingPlatform(),
  );
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('1. the map starts north-up (bearing 0)', (tester) async {
    final gps = ValueNotifier<MapCoordinate?>(_gps);
    addTearDown(gps.dispose);
    await _mount(tester, gps);
    final initial = platform.positions[platform.positions.keys.last]!;
    expect(initial.bearing, 0, reason: 'accepted law: the map opens north-up');
    expect(initial.tilt, 0);
    expect(platform.commands, isEmpty,
        reason: 'a fresh map issues no camera command');
  });

  testWidgets('2. rotating away from north is observable', (tester) async {
    final gps = ValueNotifier<MapCoordinate?>(_gps);
    addTearDown(gps.dispose);
    final container = await _mount(tester, gps);
    platform.camera(platform.positions.keys.last, _rotated);
    await tester.pump();
    final recorded = container.read(session.mapsSessionProvider).camera;
    expect(recorded, isNotNull);
    expect(recorded!.bearing, 47.5,
        reason: 'the rotated bearing must reach session state');
    expect(recorded.tilt, 38);
  });

  testWidgets(
      '3+5. bearing, zoom and target are PRESERVED across re-entry '
      '(the accepted law is preserve, never auto-reset)', (tester) async {
    final gps = ValueNotifier<MapCoordinate?>(_gps);
    addTearDown(gps.dispose);
    final container = await _mount(tester, gps);
    platform.camera(platform.positions.keys.last, _rotated);
    await tester.pump();
    platform.commands.clear();
    await _returnVia(tester, 'Contacts');
    expect(_map(tester).initialCameraPosition, _rotated);
    expect(container.read(session.mapsSessionProvider).camera, _rotated);
    expect(platform.commands, isEmpty,
        reason: 're-entry must not re-issue a camera command, and in particular '
            'must NOT reset the bearing to north');
  });

  testWidgets('4. native top-left compass and rotation are explicitly enabled',
      (tester) async {
    final gps = ValueNotifier<MapCoordinate?>(_gps);
    addTearDown(gps.dispose);
    await _mount(tester, gps);
    final configuration = platform.configurations[platform.positions.keys.last]!;
    expect(configuration.compassEnabled, isTrue);
    expect(configuration.rotateGesturesEnabled, isTrue);
    platform.camera(platform.positions.keys.last, _rotated);
    await tester.pump();
    // Exercise the one control that touches the camera surface.
    await tester.tap(find.byKey(const Key('maps-type-button')));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    for (final command in platform.commands) {
      expect(
        command.update.toString(),
        isNot(contains('bearing')),
        reason: 'the app must not emulate the SDK compass with a camera command',
      );
      expect((command.update as List).first, 'newLatLngZoom',
          reason: 'the only app camera command is newLatLngZoom, which cannot '
              'change bearing or tilt');
    }
  });

  testWidgets('6+7. camera/bearing work never invokes Locate me', (tester) async {
    final gps = ValueNotifier<MapCoordinate?>(_gps);
    addTearDown(gps.dispose);
    await _mount(tester, gps);
    platform.camera(platform.positions.keys.last, _rotated);
    await tester.pump();
    await _returnVia(tester, 'Planner');
    // The Locate control exists and is untouched, but nothing bearing-related
    // pressed it, so no location call can have been made.
    expect(find.byKey(const Key('maps-locate-button')), findsOneWidget);
    expect(platform.commands.where((c) => c.kind == 'move'), isEmpty);
  });

  group('source contracts (8/9/10 + no location, no writes)', () {
    test('8. the Maps surface writes no Saved Place / Maps domain state', () {
      final source = _surfaceSource();
      for (final forbidden in <String>[
        'savedPlaceRepository',
        'mapsPreferencesRepository',
        '.savePreferences(',
        'boundaryRepository',
      ]) {
        expect(source.contains(forbidden), isFalse,
            reason: 'bearing/camera work must not write "$forbidden"');
      }
    });

    test('9. the Maps surface writes no Event / Task / Contact state', () {
      final source = _surfaceSource();
      for (final forbidden in <String>[
        'calendarEventRepository',
        'plannerRepository',
        'contactRepository',
        'taskRepository',
      ]) {
        expect(source.contains(forbidden), isFalse,
            reason: 'bearing/camera work must not write "$forbidden"');
      }
    });

    test('7+10. no location permission, background location or geofence', () {
      final source = _surfaceSource();
      for (final forbidden in <String>[
        'geolocator',
        'Geolocator',
        'requestPermission',
        'getCurrentPosition',
        'ACCESS_BACKGROUND_LOCATION',
        'Geofence',
        'geofence',
      ]) {
        expect(source.contains(forbidden), isFalse,
            reason: 'the surface must not reference "$forbidden"');
      }
    });

    test('the Maps surface explicitly delegates the compass to the SDK', () {
      final source = _surfaceSource();
      for (final required in <String>[
        'compassEnabled: true',
        'rotateGesturesEnabled: true',
      ]) {
        expect(source.contains(required), isTrue,
            reason: 'the SDK-native compass contract requires "$required"');
      }
      for (final absent in <String>[
        'resetBearing',
        'faceNorth',
        'Face North',
        'northUp',
      ]) {
        expect(source.contains(absent), isFalse,
            reason: 'no accepted checkpoint ever contained "$absent"');
      }
    });
  });

  group('VS16 M7 — the visible needle must still reset the camera', () {
    // The camera the SDK's compass click produces: same place, same scale,
    // north-up. It is the ONLY camera the compass may apply.
    const northUp = CameraPosition(
      target: LatLng(25.033, 121.5654),
      zoom: 13.25,
      bearing: 0,
      tilt: 0,
    );

    testWidgets(
        '11. a compass reset to bearing 0 is accepted AND survives re-entry '
        '(never overwritten by the rotated camera that preceded it)',
        (tester) async {
      final gps = ValueNotifier<MapCoordinate?>(_gps);
      addTearDown(gps.dispose);
      final container = await _mount(tester, gps);
      final mapId = platform.positions.keys.last;
      platform.camera(mapId, _rotated);
      await tester.pump();
      expect(container.read(session.mapsSessionProvider).camera, _rotated,
          reason: 'the rotated camera is the state the compass must beat');
      platform.commands.clear();

      platform.camera(mapId, northUp);
      await tester.pump();
      final after = container.read(session.mapsSessionProvider).camera;
      expect(after, northUp,
          reason: 'the deliberate compass reset must be accepted');
      expect(after!.target, _rotated.target,
          reason: 'a compass reset never moves the target');
      expect(after.zoom, _rotated.zoom,
          reason: 'a compass reset never changes zoom');
      expect(platform.commands, isEmpty,
          reason: 'no app camera command may answer the reset: re-issuing '
              'bearing or target would silently undo it');

      await _returnVia(tester, 'Contacts');
      expect(_map(tester).initialCameraPosition, northUp,
          reason: 'leaving and re-entering Maps must keep north-up');
      expect(container.read(session.mapsSessionProvider).camera, northUp);
      expect(platform.commands, isEmpty);
      expect(platform.commands.where((c) => c.kind == 'move'), isEmpty,
          reason: 'Locate Me is not involved in a compass reset');
    });

    test('12. the native tap layer forwards a docked SDK control press', () {
      final source = File(
        'android/maps_interaction_patch/java/io/flutter/plugins/googlemaps/'
        'NtPrecisionMapView.java',
      ).readAsStringSync();
      expect(source.contains('overSdkControl'), isTrue,
          reason: 'the precision layer must recognise a docked SDK control');
      expect(source.contains('completedTap && !sdkOwnsTap'), isTrue,
          reason: 'consuming a press that starts on the compass is exactly the '
              'defect that left the visible needle unable to reset the map');
      expect(source.contains('controlBound'), isTrue,
          reason: 'the control bound must stay density-derived, not a '
              'hand-tuned pixel rectangle');
      expect(source.contains('interaction.tap('), isTrue,
          reason: 'map taps must still dispatch through NtMapInteraction');
    });
  });
}
