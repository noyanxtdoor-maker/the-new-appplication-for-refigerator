// MAPS V1 — Maps screen widget contract tests.
//
// The real maplibre surface is a platform view and cannot mount in widget
// tests, so the screen exposes a `mapBuilder` seam: tests exercise the
// honest empty state, the marker data projection, the offline/error branch,
// and the Light/Dark shell without ever mounting the platform view.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/maps/application/current_location_service.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/data/drift_map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../support/test_dependencies.dart';

const _contactId = '11111111-1111-4111-8111-111111111111';
const _eventId = '22222222-2222-4222-8222-222222222222';

void main() {
  testWidgets(
    'VS15 M1: with no located records the map canvas and controls remain usable',
    (tester) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final startup = buildTestRepository(database: database);
      final profile = await startup.completeOnboarding();
      // Use a canvas seam to prove an empty marker set still mounts
      // the interactive map shell without creating a platform view in test.
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            mapProfileIdProvider.overrideWithValue(profile.id),
            mapCoordinateRepositoryProvider.overrideWithValue(
              DriftMapCoordinateRepository(
                database: database,
                clock: FixedClock(DateTime.utc(2026, 8, 16, 12)),
              ),
            ),
            currentLocationServiceProvider.overrideWithValue(
              const _FakeCurrentLocationService(CurrentLocationResult.denied()),
            ),
          ],
          child: MaterialApp(
            home: MapsScreen(
              mapBuilder: (_, markers) => SizedBox(
                key: const Key('maps-test-surface'),
                child: Text('markers=${markers.length}'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('maps-test-surface')), findsOneWidget);
      expect(find.text('markers=0'), findsOneWidget);
      expect(find.byKey(const Key('maps-type-button')), findsOneWidget);
      expect(find.byKey(const Key('maps-locate-button')), findsOneWidget);
      expect(find.textContaining('No saved map pins yet'), findsOneWidget);
      await tester.tap(find.byKey(const Key('maps-type-button')));
      await tester.pumpAndSettle();
      expect(find.text('Map Type'), findsWidgets);
      expect(find.text('Markers'), findsOneWidget);
      expect(find.text('Contacts'), findsOneWidget);
      expect(find.text("Today's Events"), findsOneWidget);
      await tester.tap(find.byKey(const Key('maps-type-dropdown')));
      await tester.pumpAndSettle();
      for (final label in <String>['Road', 'Satellite', 'Terrain', 'Hybrid']) {
        expect(find.text(label), findsWidgets);
      }
      await tester.tap(find.text('Road').last);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Map Type').first)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('maps-locate-button')));
      await tester.pumpAndSettle();
      expect(
        find.text('Location permission was denied. You can still use the map.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'MAPS V1: located Contact + Event markers reach the map builder with '
    'their typed ownership and the empty state does not appear',
    (tester) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;

      final contacts = DriftContactRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 16, 12)),
        identifiers: SequenceIdentifierSource(<String>[_contactId]),
      );
      await contacts.createContact(
        profileId: profileId,
        draft: const ContactDraft(
          id: _contactId,
          firstName: 'Ana',
          lastName: 'Reyes',
          displayName: 'Ana Reyes',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
          addressText: '123 Main St, Manila',
        ),
      );
      final events = DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 16, 12)),
        timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
      );
      await events.saveEvent(
        profileId: profileId,
        draft: CalendarEventDraft(
          id: _eventId,
          title: 'Temple Visit',
          timing: CalendarEventTiming.timed,
          startDate: const PlannerDate(year: 2026, month: 8, day: 16),
          startMinute: 9 * 60 + 30,
          endMinute: 10 * 60 + 30,
          timeZoneId: 'Asia/Manila',
          locationText: 'Chapel, 9:30 AM',
          requiresReport: false,
        ),
      );
      final maps = DriftMapCoordinateRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 16, 12)),
      );
      await maps.setCoordinate(
        profileId: profileId,
        owner: MapCoordinateOwner.contact,
        recordId: _contactId,
        coordinate: const MapCoordinate(latitude: 14.5995, longitude: 120.9842),
      );
      await maps.setCoordinate(
        profileId: profileId,
        owner: MapCoordinateOwner.event,
        recordId: _eventId,
        coordinate: const MapCoordinate(latitude: 10.3157, longitude: 123.8854),
      );

      List<MapMarker>? received;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            mapCoordinateRepositoryProvider.overrideWithValue(maps),
            mapProfileIdProvider.overrideWithValue(profileId),
          ],
          child: MaterialApp(
            home: MapsScreen(
              mapBuilder: (context, markers) {
                received = markers;
                return const SizedBox(key: Key('maps-test-surface'));
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(received, hasLength(2));
      final contactMarker = received!.singleWhere(
        (marker) => marker.owner == MapCoordinateOwner.contact,
      );
      final eventMarker = received!.singleWhere(
        (marker) => marker.owner == MapCoordinateOwner.event,
      );
      expect(contactMarker.displayName, 'Ana Reyes');
      expect(contactMarker.ownerKey, 'contact:$_contactId');
      expect(contactMarker.coordinate.latitude, 14.5995);
      expect(eventMarker.displayName, 'Temple Visit');
      expect(eventMarker.ownerKey, 'event:$_eventId');
      expect(eventMarker.eventStartDate?.iso8601, '2026-08-16');
      expect(find.byKey(const Key('maps-test-surface')), findsOneWidget);
      expect(find.text('No saved map pins yet'), findsNothing);
    },
  );

  testWidgets(
    'MAPS V1: an offline/style failure surfaces the explicit error state, '
    'never a crash or a blank map',
    (tester) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            mapProfileIdProvider.overrideWithValue(profileId),
            // M7 reconciliation (2026-09-16): MapsScreen watches
            // mapProjectedMarkersProvider — the M4 refactor replaced the
            // deprecated mapMarkersProvider union with it — so the failure must
            // be injected into the provider the screen actually reads.
            mapProjectedMarkersProvider.overrideWith(
              (ref) => Future<List<MapMarker>>.error(
                StateError('network unavailable'),
              ),
            ),
          ],
          child: const MaterialApp(home: MapsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Maps could not be loaded'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

final class _FakeCurrentLocationService implements CurrentLocationService {
  const _FakeCurrentLocationService(this.result);

  final CurrentLocationResult result;

  @override
  Future<CurrentLocationResult> locate() async => result;
}
