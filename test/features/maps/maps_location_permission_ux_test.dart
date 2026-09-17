// CLOSED-BETA MAPS HOTFIX — Location permission UX contract.
//
// FORENSIC CONTEXT: the Play-installed build's blank base map was proven to be
// a Google Maps API-key AUTHORIZATION failure (the delivered APK is signed by
// the Play App Signing certificate, whose SHA-1 was not authorized on the key).
// Location permission has never had anything to do with base-tile rendering.
//
// These tests therefore pin TWO independent laws:
//
//  1. The base map, pan/zoom, map type and Drop Pin are available with Location
//     denied, and a base-map failure is never mislabelled as a permission
//     problem.
//  2. The first-entry Location education, the Locate-me runtime request, the
//     permanently-denied Settings route and the resume-from-Settings refresh.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/maps/application/current_location_service.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/application/maps_location_education_provider.dart';
import 'package:rmplanner/features/maps/data/drift_map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

import '../../support/test_dependencies.dart';

final class _FakeLocationService
    implements CurrentLocationService, PassiveCurrentLocationService {
  /// A passive read is only honest when the permission is already granted, so
  /// it defaults to denied and is never the source of a blue dot in these
  /// tests unless a test explicitly asks for one.
  _FakeLocationService(this.result, {CurrentLocationResult? passiveResult})
    : passiveResult = passiveResult ?? const CurrentLocationResult.denied();

  CurrentLocationResult result;
  CurrentLocationResult passiveResult;
  int locateCalls = 0;
  int passiveCalls = 0;

  @override
  Future<CurrentLocationResult> locate() async {
    locateCalls += 1;
    return result;
  }

  @override
  Future<CurrentLocationResult> locateIfAlreadyGranted() async {
    passiveCalls += 1;
    return passiveResult;
  }
}

void main() {
  late AppDatabase database;

  setUp(() {
    database = openMemoryDatabase();
    addTearDown(database.close);
  });

  Future<Override> profileOverride() async {
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    return mapProfileIdProvider.overrideWithValue(profile.id);
  }

  Override coordinateOverride() {
    return mapCoordinateRepositoryProvider.overrideWithValue(
      DriftMapCoordinateRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 16, 12)),
      ),
    );
  }

  DriftPrivacyRepository privacyRepository() => DriftPrivacyRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 9, 16, 12)),
  );

  Future<void> pumpMaps(
    WidgetTester tester, {
    required _FakeLocationService service,
    required FakePermissionGateway gateway,
    MapBuilder? mapBuilder,
  }) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          await profileOverride(),
          coordinateOverride(),
          privacyRepositoryProvider.overrideWithValue(privacyRepository()),
          permissionGatewayProvider.overrideWithValue(gateway),
          currentLocationServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: MapsScreen(
            mapBuilder:
                mapBuilder ??
                (_, _) => const SizedBox.expand(
                  key: Key('maps-base-surface'),
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'the education is due once per session and is finished by an ask',
    () async {
      final repository = privacyRepository();
      final gateway = FakePermissionGateway();
      final container = ProviderContainer(
        overrides: <Override>[
          privacyRepositoryProvider.overrideWithValue(repository),
          permissionGatewayProvider.overrideWithValue(gateway),
        ],
      );
      addTearDown(container.dispose);

      // Never requested, never granted: the one first-entry education is due.
      expect(await container.read(mapsLocationEducationDueProvider.future), isTrue);

      // Dismissing it (Not now) must not re-nag on a later tab switch.
      container.read(mapsLocationEducationProvider.notifier).markPresented();
      expect(
        await container.read(mapsLocationEducationDueProvider.future),
        isFalse,
      );
    },
  );

  test('an already-asked permission is never asked about twice', () async {
    final repository = privacyRepository();
    await repository.recordPermissionRequested(
      OptionalPermission.foregroundLocation,
    );
    final container = ProviderContainer(
      overrides: <Override>[
        privacyRepositoryProvider.overrideWithValue(repository),
        permissionGatewayProvider.overrideWithValue(FakePermissionGateway()),
      ],
    );
    addTearDown(container.dispose);

    expect(
      await container.read(mapsLocationEducationDueProvider.future),
      isFalse,
    );
  });

  test('a granted permission is never educated and never re-requested', () async {
    final container = ProviderContainer(
      overrides: <Override>[
        privacyRepositoryProvider.overrideWithValue(privacyRepository()),
        permissionGatewayProvider.overrideWithValue(
          FakePermissionGateway(
            states: <OptionalPermission, OperatingSystemPermissionState>{
              OptionalPermission.foregroundLocation:
                  OperatingSystemPermissionState.granted,
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      await container.read(mapsLocationEducationDueProvider.future),
      isFalse,
    );
  });

  test('an unavailable permission dependency is never due', () async {
    // No app-root privacy/gateway override: Maps must never block on education.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      await container.read(mapsLocationEducationDueProvider.future),
      isFalse,
    );
  });

  testWidgets('first Maps entry educates without blocking the base map', (
    tester,
  ) async {
    final service = _FakeLocationService(const CurrentLocationResult.denied());
    await pumpMaps(
      tester,
      service: service,
      gateway: FakePermissionGateway(),
    );

    expect(find.byKey(const Key('maps-location-education')), findsOneWidget);
    expect(find.text('Allow location?'), findsOneWidget);
    expect(find.byKey(const Key('maps-location-education-allow')), findsOneWidget);
    expect(
      find.byKey(const Key('maps-location-education-not-now')),
      findsOneWidget,
    );

    // The map itself was built and never gated on Location.
    expect(find.byKey(const Key('maps-base-surface')), findsOneWidget);
    expect(find.byKey(const Key('maps-locate-button')), findsOneWidget);
    expect(find.byKey(const Key('maps-drop-pin-button')), findsOneWidget);
    expect(find.byKey(const Key('maps-type-button')), findsOneWidget);
    expect(find.byKey(const Key('maps-load-failure')), findsNothing);
    // Nothing was requested merely by opening Maps.
    expect(service.locateCalls, 0);
  });

  testWidgets('Allow location performs the runtime request exactly once', (
    tester,
  ) async {
    final service = _FakeLocationService(
      const CurrentLocationResult.located(
        MapCoordinate(latitude: 14.6, longitude: 120.9),
      ),
    );
    await pumpMaps(
      tester,
      service: service,
      gateway: FakePermissionGateway(),
    );

    await tester.tap(find.byKey(const Key('maps-location-education-allow')));
    await tester.pumpAndSettle();

    expect(service.locateCalls, 1);
    expect(find.byKey(const Key('maps-location-education')), findsNothing);
  });

  testWidgets('Not now leaves the map fully usable and asks Android nothing', (
    tester,
  ) async {
    final service = _FakeLocationService(const CurrentLocationResult.denied());
    await pumpMaps(
      tester,
      service: service,
      gateway: FakePermissionGateway(),
    );

    await tester.tap(find.byKey(const Key('maps-location-education-not-now')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maps-location-education')), findsNothing);
    expect(service.locateCalls, 0);
    // Non-location map functionality remains reachable.
    expect(find.byKey(const Key('maps-type-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('maps-type-button')));
    await tester.pumpAndSettle();
    expect(find.text('Map Type'), findsWidgets);
  });

  testWidgets('Locate me after Not now still requests and then locates', (
    tester,
  ) async {
    final service = _FakeLocationService(
      const CurrentLocationResult.located(
        MapCoordinate(latitude: 14.6, longitude: 120.9),
      ),
    );
    await pumpMaps(
      tester,
      service: service,
      gateway: FakePermissionGateway(),
    );

    await tester.tap(find.byKey(const Key('maps-location-education-not-now')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('maps-locate-button')));
    await tester.pumpAndSettle();

    // One tap cleared the prompt's session suppression and requested directly.
    expect(service.locateCalls, 1);
  });

  testWidgets('a permanently denied Locate offers the Android Settings route', (
    tester,
  ) async {
    final service = _FakeLocationService(
      const CurrentLocationResult.permanentlyDenied(),
    );
    final gateway = FakePermissionGateway();
    await pumpMaps(tester, service: service, gateway: gateway);

    await tester.tap(find.byKey(const Key('maps-location-education-not-now')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('maps-locate-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maps-location-settings-education')), findsOneWidget);
    expect(find.text('Location permission is turned off'), findsOneWidget);
    expect(find.byKey(const Key('maps-location-settings-open')), findsOneWidget);
    expect(
      find.byKey(const Key('maps-location-settings-not-now')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('maps-location-settings-open')));
    await tester.pumpAndSettle();

    expect(gateway.settingsOpened, isTrue);
  });

  testWidgets(
    'returning from Android Settings updates Maps without a restart or a '
    'second prompt',
    (tester) async {
      // The owner's reported defect: granting Location manually in Android
      // App Settings and returning produced no visible reaction.
      const located = CurrentLocationResult.located(
        MapCoordinate(latitude: 14.6, longitude: 120.9),
      );
      final service = _FakeLocationService(located);
      final gateway = FakePermissionGateway(
        states: <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.foregroundLocation:
              OperatingSystemPermissionState.denied,
        },
      );
      // Already asked once: no education, and no pending Locate intent.
      await privacyRepository().recordPermissionRequested(
        OptionalPermission.foregroundLocation,
      );

      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            await profileOverride(),
            coordinateOverride(),
            privacyRepositoryProvider.overrideWithValue(privacyRepository()),
            permissionGatewayProvider.overrideWithValue(gateway),
            currentLocationServiceProvider.overrideWithValue(service),
          ],
          // The real platform path: the GoogleMap widget is the observable.
          child: const MaterialApp(home: MapsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('maps-location-education')), findsNothing);
      expect(
        tester.widget<GoogleMap>(find.byType(GoogleMap)).myLocationEnabled,
        isFalse,
      );

      // The user grants Location in Android App Settings and comes back.
      gateway.states[OptionalPermission.foregroundLocation] =
          OperatingSystemPermissionState.granted;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(
        tester.widget<GoogleMap>(find.byType(GoogleMap)).myLocationEnabled,
        isTrue,
      );
      // No second permission prompt was manufactured by the refresh.
      expect(service.locateCalls, 0);

      // Drain the re-armed base-map watchdog so no timer outlives the test.
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'a base-map failure is never mislabelled as a Location problem',
    (tester) async {
      final service = _FakeLocationService(
        const CurrentLocationResult.located(
          MapCoordinate(latitude: 14.6, longitude: 120.9),
        ),
      );
      final gateway = FakePermissionGateway(
        states: <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.foregroundLocation:
              OperatingSystemPermissionState.granted,
        },
      );
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            await profileOverride(),
            coordinateOverride(),
            privacyRepositoryProvider.overrideWithValue(privacyRepository()),
            permissionGatewayProvider.overrideWithValue(gateway),
            currentLocationServiceProvider.overrideWithValue(service),
          ],
          child: const MaterialApp(home: MapsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('maps-load-failure')), findsOneWidget);
      // Location IS granted here, so nothing may blame the permission.
      expect(find.textContaining('permission'), findsNothing);
      expect(find.textContaining('Allow location'), findsNothing);
    },
  );
}

typedef MapBuilder =
    Widget Function(BuildContext context, List<MapMarker> markers);
