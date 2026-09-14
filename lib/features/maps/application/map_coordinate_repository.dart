import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/domain/saved_place.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';

/// Which owner table a saved map pin belongs to.  Markers use the stable
/// typed ownership key `contact:<id>` / `event:<id>` / `place:<id>`.
enum MapCoordinateOwner { contact, event, savedPlace }

extension MapCoordinateOwnerKey on MapCoordinateOwner {
  String get kind => switch (this) {
    MapCoordinateOwner.contact => 'contact',
    MapCoordinateOwner.event => 'event',
    MapCoordinateOwner.savedPlace => 'place',
  };

  String ownerKey(String recordId) => MapCoordinate.ownerKey(kind, recordId);
}

/// A located record shown as a map marker.  Coordinates are ONLY explicit
/// user map-picks; they are never derived from address/location text and
/// never silently geocoded.
final class MapMarker {
  const MapMarker({
    required this.owner,
    required this.recordId,
    required this.coordinate,
    required this.displayName,
    this.isFavorite = false,
    this.colorValue = 0xFF9CA0A6,
    this.occurrenceId,
    this.eventOriginalDate,
    this.eventRenderedDate,
    this.eventState,
    this.outsideCurrentFilter = false,
    this.placeMarkerMode,
    this.placeStandardCategory,
    this.placeEmoji,
  });

  final MapCoordinateOwner owner;
  final String recordId;
  final MapCoordinate coordinate;
  final String displayName;
  final bool isFavorite;
  final int colorValue;
  final String? occurrenceId;
  final PlannerDate? eventOriginalDate;
  final PlannerDate? eventRenderedDate;
  final PlannerEventState? eventState;
  final bool outsideCurrentFilter;

  /// Saved Place marker identity populated only for [MapCoordinateOwner.savedPlace].
  final SavedPlaceMarkerMode? placeMarkerMode;
  final SavedPlaceStandardCategory? placeStandardCategory;
  final String? placeEmoji;

  /// M1 compatibility alias. M2 routes Events by canonical original date.
  PlannerDate? get eventStartDate => eventOriginalDate;

  String get ownerKey {
    final occurrence = occurrenceId;
    if (owner == MapCoordinateOwner.event && occurrence != null) {
      return '${owner.ownerKey(recordId)}:$occurrence';
    }
    return owner.ownerKey(recordId);
  }

  MapMarker copyWith({
    String? displayName,
    bool? isFavorite,
    int? colorValue,
    String? occurrenceId,
    PlannerDate? eventOriginalDate,
    PlannerDate? eventRenderedDate,
    PlannerEventState? eventState,
    bool? outsideCurrentFilter,
    SavedPlaceMarkerMode? placeMarkerMode,
    SavedPlaceStandardCategory? placeStandardCategory,
    String? placeEmoji,
  }) {
    return MapMarker(
      owner: owner,
      recordId: recordId,
      coordinate: coordinate,
      displayName: displayName ?? this.displayName,
      isFavorite: isFavorite ?? this.isFavorite,
      colorValue: colorValue ?? this.colorValue,
      occurrenceId: occurrenceId ?? this.occurrenceId,
      eventOriginalDate: eventOriginalDate ?? this.eventOriginalDate,
      eventRenderedDate: eventRenderedDate ?? this.eventRenderedDate,
      eventState: eventState ?? this.eventState,
      outsideCurrentFilter: outsideCurrentFilter ?? this.outsideCurrentFilter,
      placeMarkerMode: placeMarkerMode ?? this.placeMarkerMode,
      placeStandardCategory:
          placeStandardCategory ?? this.placeStandardCategory,
      placeEmoji: placeEmoji ?? this.placeEmoji,
    );
  }
}

/// Maps V1 persistence.  A separate, additive repository (not the large
/// Contact/Event repositories) so existing test doubles are untouched.
abstract interface class MapCoordinateRepository {
  /// Coalesced table change stream over the two coordinate-bearing tables,
  /// used by the Maps screen to refresh markers without polling.
  Stream<int> watchChanges(String profileId);

  /// Persists an explicit user map-pick for the record.  Requires a
  /// valid coordinate pair; the pair invariant (both present or both
  /// absent) is enforced here, never partially writable.
  Future<void> setCoordinate({
    required String profileId,
    required MapCoordinateOwner owner,
    required String recordId,
    required MapCoordinate coordinate,
  });

  /// Removes ONLY the coordinate pair + source.  Free text address /
  /// location text is never touched.
  Future<void> clearCoordinate({
    required String profileId,
    required MapCoordinateOwner owner,
    required String recordId,
  });

  Future<MapCoordinate?> readCoordinate({
    required String profileId,
    required MapCoordinateOwner owner,
    required String recordId,
  });

  /// Every located Contact, Event, and Saved Place marker in the profile.
  Future<List<MapMarker>> readMarkers(String profileId);
}

/// Optional narrow Maps seam used by M4.  Implementations that can identify
/// the owning table expose source-specific change streams and reads, allowing
/// a Contact/Event/Saved Place write to avoid refreshing the other layers.
/// Legacy test doubles retain [MapCoordinateRepository] compatibility and
/// safely use the broad fallback in the provider graph.
abstract interface class MapCoordinateOwnerRepository {
  Stream<int> watchOwnerChanges(String profileId, MapCoordinateOwner owner);

  Future<List<MapMarker>> readOwnerMarkers(
    String profileId,
    MapCoordinateOwner owner,
  );
}
