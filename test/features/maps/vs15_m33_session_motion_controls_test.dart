import 'dart:async';
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
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/application/map_session_provider.dart'
    as session;
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/google_maps_surface.dart';

import 'maps_preferences_test_support.dart';

import 'support/fab_theme_probe.dart';

const _gps = MapCoordinate(latitude: 14.6, longitude: 121);
const _taiwan = CameraPosition(
  target: LatLng(25.033, 121.5654),
  zoom: 13.25,
  bearing: 47.5,
  tilt: 38,
);
const _place = MapMarker(
  owner: MapCoordinateOwner.savedPlace,
  recordId: 'search-target',
  displayName: 'Search target',
  coordinate: MapCoordinate(latitude: 25.033, longitude: 121.5654),
);

class _CameraPlatform extends GoogleMapsFlutterPlatform {
  final positions = <int, CameraPosition>{};
  final moves = <int, StreamController<CameraMoveEvent>>{};
  final idles = <int, StreamController<CameraIdleEvent>>{};
  final commands =
      <({String kind, int mapId, Object update, Duration? duration})>[];
  final disposed = <int>{};
  Completer<void>? initGate, animationGate;
  bool emitAnimationEnd = true;
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
  Future<void> init(int mapId) async {
    await initGate?.future;
  }

  @override
  void dispose({required int mapId}) {
    disposed.add(mapId);
  }

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
    await animationGate?.future;
    if (emitAnimationEnd) {
      final args = update.toJson() as List;
      final point = args[1] as List;
      final old = positions[mapId]!;
      camera(
        mapId,
        CameraPosition(
          target: LatLng(point[0] as double, point[1] as double),
          zoom: (args[2] as num).toDouble(),
          bearing: old.bearing,
          tilt: old.tilt,
        ),
      );
    }
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
  Future<void> updateMarkers(
    MarkerUpdates updates, {
    required int mapId,
  }) async {}
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
  int tab = 3;
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
  ValueNotifier<MapCoordinate?> coordinate, {
  ThemeData? theme,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(430, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: mapsPreferencesOverrides(),
      child: MaterialApp(
        theme: theme ?? AppTheme.light(ThemeColorMode.blue),
        home: _Tabs(coordinate: coordinate),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(_Tabs)));
}

GoogleMap _map(WidgetTester tester) =>
    tester.widget<GoogleMap>(find.byType(GoogleMap));
Future<void> _choose(WidgetTester tester, String type) async {
  await tester.tap(find.byKey(const Key('maps-type-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('maps-type-dropdown')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('maps-type-$type')));
  await tester.pumpAndSettle();
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pumpAndSettle();
}

Future<void> _returnVia(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(Key('tab-$tab')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('tab-Maps')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CameraPlatform platform;
  setUp(
    () => GoogleMapsFlutterPlatform.instance = platform = _CameraPlatform(),
  );
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test('fresh session is Satellite with no durable/restored camera', () async {
    final oldSession = ProviderContainer();
    await oldSession
        .read(session.mapsSessionProvider.notifier)
        .selectMapType(session.NextTransferMapType.road);
    oldSession.read(session.mapsSessionProvider.notifier).recordCamera(_taiwan);
    oldSession.dispose();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // M6.2 owner law: the fresh-session default is SATELLITE and the camera
    // is session-only (never durable).
    expect(
      container.read(session.mapsSessionProvider).mapType,
      session.NextTransferMapType.satellite,
    );
    expect(container.read(session.mapsSessionProvider).camera, isNull);
  });
  for (final choice in [
    ('satellite', 'Contacts', MapType.hybrid),
    ('terrain', 'Planner', MapType.terrain),
    ('hybrid', 'Home', MapType.hybrid),
    ('road', 'Contacts', MapType.normal),
  ]) {
    testWidgets(
      '${choice.$1} survives actual map disposal through ${choice.$2}',
      (tester) async {
        final gps = ValueNotifier<MapCoordinate?>(_gps);
        addTearDown(gps.dispose);
        await _mount(tester, gps);
        await _choose(tester, choice.$1);
        final id = platform.positions.keys.last;
        expect(_map(tester).mapType, choice.$3);
        await _returnVia(tester, choice.$2);
        expect(platform.disposed, contains(id));
        expect(platform.positions.keys.last, isNot(id));
        expect(_map(tester).mapType, choice.$3);
      },
    );
  }
  testWidgets(
    'Taiwan target zoom bearing tilt survive re-entry and two hours without GPS recenter',
    (tester) async {
      final gps = ValueNotifier<MapCoordinate?>(_gps);
      addTearDown(gps.dispose);
      final container = await _mount(tester, gps);
      platform.camera(platform.positions.keys.last, _taiwan);
      await tester.pump();
      platform.commands.clear();
      await _returnVia(tester, 'Contacts');
      expect(_map(tester).initialCameraPosition, _taiwan);
      expect(container.read(session.mapsSessionProvider).camera, _taiwan);
      expect(platform.commands, isEmpty);
      await tester.pump(const Duration(hours: 2));
      await _returnVia(tester, 'Planner');
      expect(_map(tester).initialCameraPosition, _taiwan);
      expect(platform.commands, isEmpty);
    },
  );
  testWidgets(
    'Search focus issues one smooth animation, keeps identity and retains destination',
    (tester) async {
      final gps = ValueNotifier<MapCoordinate?>(null);
      addTearDown(gps.dispose);
      final container = await _mount(tester, gps);
      platform.commands.clear();
      container
          .read(mapTransientFocusProvider.notifier)
          .focusSavedPlace(
            placeId: _place.recordId,
            coordinate: _place.coordinate,
          );
      await tester.pumpAndSettle();
      expect(platform.commands, hasLength(1));
      expect(platform.commands.single.kind, 'animate');
      expect(
        platform.commands.single.duration,
        const Duration(milliseconds: 650),
      );
      expect(platform.commands.single.update, [
        'newLatLngZoom',
        [25.033, 121.5654],
        15.0,
      ]);
      expect(
        container.read(mapSelectedMarkerProvider)!.markerKey,
        _place.ownerKey,
      );
      expect(container.read(mapTransientFocusProvider).pending, isNull);
      final destination = container.read(session.mapsSessionProvider).camera!;
      expect(destination.target, _taiwan.target);
      expect(destination.zoom, 15);
      gps.value = _gps;
      await tester.pumpAndSettle();
      expect(platform.commands, hasLength(1));
      await _returnVia(tester, 'Contacts');
      expect(_map(tester).initialCameraPosition, destination);
      expect(platform.commands, hasLength(1));
    },
  );
  testWidgets(
    'Search queued during map creation beats passive location without a preliminary move',
    (tester) async {
      platform.initGate = Completer<void>();
      final gps = ValueNotifier<MapCoordinate?>(_gps);
      addTearDown(gps.dispose);
      final container = await _mount(tester, gps, settle: false);
      container
          .read(mapTransientFocusProvider.notifier)
          .focusSavedPlace(
            placeId: _place.recordId,
            coordinate: _place.coordinate,
          );
      platform.initGate!.complete();
      await tester.pumpAndSettle();
      expect(platform.commands, hasLength(1));
      expect(platform.commands.single.kind, 'animate');
      expect(
        platform.commands.single.duration,
        const Duration(milliseconds: 650),
      );
    },
  );
  testWidgets(
    'a late Search completion cannot override a newer user camera or replay after re-entry',
    (tester) async {
      final gps = ValueNotifier<MapCoordinate?>(null);
      addTearDown(gps.dispose);
      final container = await _mount(tester, gps);
      platform.emitAnimationEnd = false;
      platform.animationGate = Completer<void>();
      container
          .read(mapTransientFocusProvider.notifier)
          .focusSavedPlace(
            placeId: _place.recordId,
            coordinate: _place.coordinate,
          );
      await tester.pump();
      expect(container.read(mapTransientFocusProvider).pending, isNull);
      final gesture = await tester.startGesture(const Offset(30, 100));
      await gesture.moveBy(const Offset(30, 0));
      await gesture.up();
      const moved = CameraPosition(
        target: LatLng(24, 120),
        zoom: 9,
        bearing: 80,
        tilt: 20,
      );
      platform.camera(platform.positions.keys.last, moved);
      await tester.pump();
      platform.animationGate!.complete();
      await tester.pumpAndSettle();
      expect(container.read(mapSelectedMarkerProvider), isNull);
      await _returnVia(tester, 'Home');
      expect(_map(tester).initialCameraPosition, moved);
      expect(platform.commands, hasLength(1));
    },
  );
  for (final mode in ThemeColorMode.values) {
    for (final dark in [false, true]) {
      testWidgets(
        '$mode dark=$dark controls use strong surface white icons and unchanged size',
        (tester) async {
          final gps = ValueNotifier<MapCoordinate?>(null);
          addTearDown(gps.dispose);
          await _mount(
            tester,
            gps,
            theme: dark ? AppTheme.dark(mode) : AppTheme.light(mode),
          );
          final theme = dark ? AppTheme.dark(mode) : AppTheme.light(mode);
          // M7 reconciliation (2026-09-16): the accepted canonical law resolves
          // the control surface from the ACTIVE theme primary and paints the
          // glyph WHITE in Light and Dark. The retired VS15 assertion pinned the
          // LIGHT primary even in dark mode and read constructor properties the
          // control deliberately never sets.
          final background = theme.colorScheme.primary;
          expect(
            1.05 / (background.computeLuminance() + .05),
            greaterThanOrEqualTo(4.5),
          );
          for (final key in [
            'maps-drop-pin-button',
            'maps-type-button',
            'maps-locate-button',
          ]) {
            final finder = find.byKey(Key(key));
            final button = tester.widget<FloatingActionButton>(finder);
            expect(resolvedFabBackground(tester, Key(key)), background);
            expect(resolvedFabIconColor(tester, Key(key)), Colors.white);
            expect(tester.getSize(finder), const Size(56, 56));
            expect(button.onPressed, isNotNull);
          }
        },
      );
    }
  }
}
