// M6 FINAL CORRECTION — Maps base-render independence, Location recovery and
// the bounded failure surface.
//
// The forensic audit proved the blank base map was a CREDENTIAL problem (the
// packaged APK carried the placeholder `DEFAULT_API_KEY`), not a permission
// gate.  These tests pin the product law that made that distinction matter:
// the base map widget must exist with Location denied, Location controls the
// user-location feature only, and a map surface that never comes up must fail
// truthfully with a Retry rather than leave a silent blank field.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/maps/application/current_location_service.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/data/drift_map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

import '../../support/test_dependencies.dart';

final class _FakeLocationService
    implements CurrentLocationService, PassiveCurrentLocationService {
  _FakeLocationService(this.result);

  final CurrentLocationResult result;
  int locateCalls = 0;

  @override
  Future<CurrentLocationResult> locate() async {
    locateCalls += 1;
    return result;
  }

  @override
  Future<CurrentLocationResult> locateIfAlreadyGranted() async => result;
}

final class _FakePermissionGateway implements PermissionGateway {
  bool settingsOpened = false;

  @override
  Future<OperatingSystemPermissionState> status(
    OptionalPermission permission,
  ) async => OperatingSystemPermissionState.permanentlyDenied;

  @override
  Future<OperatingSystemPermissionState> request(
    OptionalPermission permission,
  ) async => OperatingSystemPermissionState.permanentlyDenied;

  @override
  Future<bool> openSystemSettings() async {
    settingsOpened = true;
    return true;
  }
}

void main() {
  Future<Override> profileOverride() async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    return mapProfileIdProvider.overrideWithValue(profile.id);
  }

  Future<Override> coordinateOverride() async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    return mapCoordinateRepositoryProvider.overrideWithValue(
      DriftMapCoordinateRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 15, 12)),
      ),
    );
  }

  testWidgets('the base map renders even with Location denied', (tester) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _FakeLocationService(const CurrentLocationResult.denied());
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          await profileOverride(),
          await coordinateOverride(),
          currentLocationServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: MapsScreen(
            // The canvas seam stands in for the platform map, proving the map
            // surface is built unconditionally — no permission gate precedes it.
            mapBuilder: (_, markers) => SizedBox(
              key: const Key('maps-base-surface'),
              child: Text('markers=${markers.length}'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maps-base-surface')), findsOneWidget);
    // The Location controls are present and usable; they were never consulted
    // before the base map was allowed to exist.
    expect(find.byKey(const Key('maps-locate-button')), findsOneWidget);
    expect(find.byKey(const Key('maps-drop-pin-button')), findsOneWidget);
    expect(service.locateCalls, 0);
    expect(find.byKey(const Key('maps-load-failure')), findsNothing);
  });

  testWidgets('a blocked Locate offers Android Settings and opens it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _FakeLocationService(
      const CurrentLocationResult.permanentlyDenied(),
    );
    final gateway = _FakePermissionGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          await profileOverride(),
          await coordinateOverride(),
          currentLocationServiceProvider.overrideWithValue(service),
          permissionGatewayProvider.overrideWithValue(gateway),
        ],
        child: MaterialApp(
          home: MapsScreen(
            mapBuilder: (_, markers) =>
                const SizedBox.expand(key: Key('maps-base-surface')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('maps-locate-button')));
    await tester.pumpAndSettle();

    expect(service.locateCalls, 1);
    // CLOSED-BETA HOTFIX (owner law, 2026-09-16): the permanently denied
    // route is now the explicit app-owned education surface rather than the
    // previous transient snackbar with its bare 'Settings' action.
    expect(
      find.byKey(const Key('maps-location-settings-education')),
      findsOneWidget,
    );
    expect(find.text('Location permission is turned off'), findsOneWidget);

    await tester.tap(find.byKey(const Key('maps-location-settings-open')));
    await tester.pumpAndSettle();
    expect(gateway.settingsOpened, isTrue);
  });

  testWidgets('a map surface that never comes up fails truthfully, then '
      'Retry rebuilds it', (tester) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          await profileOverride(),
          await coordinateOverride(),
          currentLocationServiceProvider.overrideWithValue(
            _FakeLocationService(const CurrentLocationResult.denied()),
          ),
        ],
        // No mapBuilder: this exercises the REAL platform map path, whose
        // controller never reports creation in a widget test.
        child: const MaterialApp(home: MapsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Before the bounded window elapses the surface is simply the map.
    expect(find.byKey(const Key('maps-load-failure')), findsNothing);

    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maps-load-failure')), findsOneWidget);
    expect(find.text('The map could not load'), findsOneWidget);
    // The message must never blame Location permission for a base-map failure.
    expect(find.textContaining('permission'), findsNothing);

    await tester.tap(find.byKey(const Key('maps-load-retry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maps-load-failure')), findsNothing);

    // Drain the re-armed watchdog so no timer outlives the test.
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
  });
}
