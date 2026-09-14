import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';

void main() {
  test('P07 coalesces an Event burst without rereading Contact or Saved Place',
      () async {
    final repository = _CountingCoordinates();
    final container = ProviderContainer(
      overrides: [
        mapProfileIdProvider.overrideWithValue('profile-m4'),
        mapCoordinateRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    final subscriptions = <ProviderSubscription<AsyncValue<List<MapMarker>>>>[
      for (final owner in MapCoordinateOwner.values)
        container.listen(mapOwnerMarkersProvider(owner), (_, _) {}),
    ];
    addTearDown(() {
      for (final subscription in subscriptions) {
        subscription.close();
      }
    });

    await Future.wait<void>(
      MapCoordinateOwner.values.map(
        (owner) => container.read(mapOwnerMarkersProvider(owner).future),
      ),
    );
    expect(repository.readCounts, <MapCoordinateOwner, int>{
      MapCoordinateOwner.contact: 1,
      MapCoordinateOwner.event: 1,
      MapCoordinateOwner.savedPlace: 1,
    });

    final firstEventRead = Completer<void>();
    final releaseEventRead = Completer<void>();
    repository.onEventRead = () async {
      if (!firstEventRead.isCompleted) {
        firstEventRead.complete();
        await releaseEventRead.future;
      }
    };
    repository.emit(MapCoordinateOwner.event);
    await firstEventRead.future;
    repository.emit(MapCoordinateOwner.event);
    repository.emit(MapCoordinateOwner.event);
    releaseEventRead.complete();

    await _until(() => repository.readCounts[MapCoordinateOwner.event] == 3);
    expect(repository.readCounts[MapCoordinateOwner.contact], 1);
    expect(repository.readCounts[MapCoordinateOwner.savedPlace], 1);
    expect(
      container
          .read(mapOwnerMarkersProvider(MapCoordinateOwner.event))
          .requireValue
          .single
          .displayName,
      'Event revision 3',
    );
  });
}

Future<void> _until(bool Function() complete) async {
  for (var attempt = 0; attempt != 100 && !complete(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(complete(), isTrue, reason: 'provider did not publish its coalesced read');
}

final class _CountingCoordinates
    implements MapCoordinateRepository, MapCoordinateOwnerRepository {
  final _changes = <MapCoordinateOwner, StreamController<int>>{
    for (final owner in MapCoordinateOwner.values)
      owner: StreamController<int>.broadcast(sync: true),
  };
  final readCounts = <MapCoordinateOwner, int>{
    for (final owner in MapCoordinateOwner.values) owner: 0,
  };
  Future<void> Function()? onEventRead;

  void emit(MapCoordinateOwner owner) => _changes[owner]!.add(1);

  @override
  Future<List<MapMarker>> readMarkers(String profileId) async => <MapMarker>[
    for (final owner in MapCoordinateOwner.values)
      ...await readOwnerMarkers(profileId, owner),
  ];

  @override
  Future<List<MapMarker>> readOwnerMarkers(
    String profileId,
    MapCoordinateOwner owner,
  ) async {
    final revision = readCounts.update(owner, (count) => count + 1);
    if (owner == MapCoordinateOwner.event) await onEventRead?.call();
    return <MapMarker>[
      MapMarker(
        owner: owner,
        recordId: owner.kind,
        coordinate: const MapCoordinate(latitude: 14.6, longitude: 121),
        displayName: owner == MapCoordinateOwner.event
            ? 'Event revision $revision'
            : owner.kind,
      ),
    ];
  }

  @override
  Stream<int> watchChanges(String profileId) => const Stream<int>.empty();

  @override
  Stream<int> watchOwnerChanges(String profileId, MapCoordinateOwner owner) =>
      _changes[owner]!.stream;

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
  }) async => null;

  @override
  Future<void> setCoordinate({
    required String profileId,
    required MapCoordinateOwner owner,
    required String recordId,
    required MapCoordinate coordinate,
  }) async {}
}
