// EDGE-TO-EDGE (Android 15+ / targetSdk 35+): the app is displayed edge-to-edge
// and cannot opt out. A modal bottom sheet extends to the very bottom of the
// screen in BOTH `useSafeArea` modes (the framework only wraps it in
// `SafeArea(bottom: false)`), so a sheet must exclude the system navigation
// area in its OWN content or its last row can sit under the system bar.
//
// The Map Type sheet was the one proven gap in the audit. These tests mount the
// real screen with a synthetic bottom inset and prove the sheet's scrollable
// viewport stops above it, and that nothing is lost when there is no inset.
//
// Fail-first note: before the fix the sheet content was not inset at all, so
// `viewport.bottom` equalled the full screen height and the first assertion
// failed.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';

import 'maps_preferences_test_support.dart';

/// Screen size used by both cases: a tall phone, so the sheet is comfortably
/// visible above the simulated system bar.
const Size _screen = Size(431, 912);

/// The synthetic system-bar inset. 48 dp is the gesture-navigation bar height
/// Android reports on this class of device and is the value the accepted
/// responsive harness already uses.
const double _bottomInset = 48;

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

Future<void> _mount(
  WidgetTester tester, {
  required double bottomInset,
}) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(bottom: bottomInset);
  tester.view.viewPadding = FakeViewPadding(bottom: bottomInset);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        contactProfileIdProvider.overrideWithValue('test-profile'),
        mapProfileIdProvider.overrideWithValue('test-profile'),
        mapProjectedMarkersProvider.overrideWith((ref) async => <MapMarker>[]),
        mapPassiveLocationProvider.overrideWith((ref) async => null),
        ...mapsPreferencesOverrides(),
      ],
      child: const MaterialApp(home: MapsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<Rect> _openMapTypeSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('maps-type-button')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const Key('maps-type-dropdown')),
    findsOneWidget,
    reason: 'the Map Type sheet opened',
  );
  final viewport = find
      .descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable),
      )
      .first;
  return tester.getRect(viewport);
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
    'the Map Type sheet keeps its content above the system navigation area',
    (tester) async {
      await _mount(tester, bottomInset: _bottomInset);
      final viewport = await _openMapTypeSheet(tester);

      expect(
        viewport.bottom,
        lessThanOrEqualTo(_screen.height - _bottomInset),
        reason: 'sheet content must not extend into the system bar inset',
      );
      // The sheet itself still reaches the screen bottom: only its *content*
      // is inset, so the sheet keeps its full-bleed material surface.
      expect(
        viewport.bottom,
        greaterThan(_screen.height - _bottomInset - 1),
        reason: 'content fills the available space exactly',
      );
    },
  );

  testWidgets(
    'with no system inset the sheet is unchanged (no shrinking regression)',
    (tester) async {
      await _mount(tester, bottomInset: 0);
      final viewport = await _openMapTypeSheet(tester);

      expect(
        viewport.bottom,
        closeTo(_screen.height, 0.5),
        reason: 'no inset means no reserved space',
      );
    },
  );

  testWidgets(
    'the sheet still offers every control with a system inset present',
    (tester) async {
      await _mount(tester, bottomInset: _bottomInset);
      await _openMapTypeSheet(tester);

      for (final key in <Key>[
        const Key('maps-type-dropdown'),
        const Key('maps-layer-people'),
        const Key('maps-layer-events'),
        const Key('maps-layer-places'),
        const Key('maps-group-nearby'),
      ]) {
        expect(
          find.byKey(key),
          findsOneWidget,
          reason: 'inset handling must not remove a control',
        );
      }
    },
  );
}
