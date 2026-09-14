import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/maps/application/current_location_service.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_interaction_trace.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

/// Defaults to a no-op repository so widget tests and forms that never
/// configure Maps keep working.  Production (`main.dart`) overrides this
/// with the real Drift-backed repository; the Maps screen itself always runs
/// inside the full app where that override exists.
final mapCoordinateRepositoryProvider = Provider<MapCoordinateRepository>((
  ref,
) {
  return const NoopMapCoordinateRepository();
});

final currentLocationServiceProvider = Provider<CurrentLocationService>((ref) {
  return GeolocatorCurrentLocationService(
    privacyRepository: ref.read(privacyRepositoryProvider),
  );
});

/// Starts alongside Maps and stays cached across ordinary tab recreation.
/// It never requests permission; explicit Locate remains the only prompt path.
final mapPassiveLocationProvider = FutureProvider<MapCoordinate?>((ref) async {
  final service = ref.read(currentLocationServiceProvider);
  if (service is CachedCurrentLocationService) {
    final cached = (service as CachedCurrentLocationService).cachedCoordinate;
    if (cached != null) return cached;
  }
  if (service is! PassiveCurrentLocationService) return null;
  return (await (service as PassiveCurrentLocationService)
          .locateIfAlreadyGranted())
      .coordinate;
});

enum MapFocusOwnerKind { contact, eventOccurrence, savedPlace }

/// Typed, in-memory focus request for the one permanent Maps destination.
/// The nonce makes repeated requests for the same record observable.
final class MapFocusRequest {
  const MapFocusRequest({
    required this.ownerKind,
    required this.recordId,
    required this.coordinate,
    required this.nonce,
    this.occurrenceId,
    this.originalDate,
    this.renderedDate,
  });

  final MapFocusOwnerKind ownerKind;
  final String recordId;
  final MapCoordinate coordinate;
  final int nonce;
  final String? occurrenceId;
  final PlannerDate? originalDate;
  final PlannerDate? renderedDate;

  String get markerKey => switch (ownerKind) {
    MapFocusOwnerKind.contact => MapCoordinate.ownerKey(
      MapCoordinateOwner.contact.kind,
      recordId,
    ),
    MapFocusOwnerKind.eventOccurrence =>
      '${MapCoordinate.ownerKey(MapCoordinateOwner.event.kind, recordId)}:'
          '$occurrenceId',
    MapFocusOwnerKind.savedPlace => MapCoordinate.ownerKey(
      MapCoordinateOwner.savedPlace.kind,
      recordId,
    ),
  };
}

final class MapFocusState {
  const MapFocusState({this.command, this.visibilityLease});

  /// A one-shot navigation command. It is cleared immediately after the
  /// camera accepts it and can never become a later default camera owner.
  final MapFocusRequest? command;

  /// A separate, non-camera lease that can keep an explicitly requested
  /// record visible when it falls outside the current Maps filter.
  final MapFocusRequest? visibilityLease;

  MapFocusRequest? get pending => command;
}

/// Ephemeral direct-marker selection for the Maps preview sheet.
///
/// This is intentionally distinct from [MapFocusRequest]: a selection owns
/// marker emphasis and preview content only, while a focus request is a
/// nonce-bearing, one-shot camera command from another workflow.
enum MapMarkerGrouping { exactCoordinate, zoomCluster }

/// Render context is ephemeral; record coordinates remain canonical.
final class MapMarkerGroupContext {
  const MapMarkerGroupContext({
    required this.members,
    required this.position,
    this.nativeMarkerIds = const [],
    this.nativeGroupKey,
    this.bitmap,
    this.width = 34,
    this.height = 34,
    this.excludedOwnerKey,
  });
  final List<MapMarker> members;
  final MapCoordinate position;
  final List<String> nativeMarkerIds;
  final String? nativeGroupKey;
  final Uint8List? bitmap;
  final double width, height;
  final String? excludedOwnerKey;
}

final class MapSelectedMarker {
  const MapSelectedMarker(this.marker, {this.origin})
    : members = const [],
      grouping = null;

  MapSelectedMarker.group(List<MapMarker> records, this.grouping, {this.origin})
    : members = List.unmodifiable(records),
      marker = records.first;

  final MapMarker marker;
  final List<MapMarker> members;
  final MapMarkerGrouping? grouping;
  final MapMarkerGroupContext? origin;
  String? get excludedOwnerKey =>
      isGroup ? origin?.excludedOwnerKey : markerKey;
  bool get isGroup => members.length > 1;

  String get markerKey => marker.ownerKey;
}

final mapSelectedMarkerProvider =
    NotifierProvider<MapSelectedMarkerController, MapSelectedMarker?>(
      MapSelectedMarkerController.new,
    );

final class MapSelectedMarkerController extends Notifier<MapSelectedMarker?> {
  @override
  MapSelectedMarker? build() => null;

  void select(MapMarker marker) {
    if (state?.isGroup == false && identical(state?.marker, marker)) return;
    final previous = state?.origin;
    final origin =
        previous != null &&
            previous.members.any((m) => m.ownerKey == marker.ownerKey)
        ? previous
        : null;
    MapInteractionTrace.commit(marker.ownerKey);
    state = MapSelectedMarker(marker, origin: origin);
  }

  void selectGroup(
    Iterable<MapMarker> records,
    MapMarkerGrouping grouping, {
    MapMarkerGroupContext? origin,
  }) {
    final unique = {for (final marker in records) marker.ownerKey: marker};
    if (unique.length > 1) {
      final previous = state;
      final parent = previous?.origin;
      final exclusion = previous?.excludedOwnerKey;
      final preservesRemainder =
          parent != null &&
          exclusion != null &&
          !unique.containsKey(exclusion) &&
          unique.keys.every(
            (id) => parent.members.any((m) => m.ownerKey == id),
          );
      final context =
          origin ??
          MapMarkerGroupContext(
            members: unique.values.toList(),
            position: unique.values.first.coordinate,
          );
      origin = MapMarkerGroupContext(
        members: preservesRemainder ? parent.members : context.members,
        position: context.position,
        nativeMarkerIds: preservesRemainder
            ? parent.nativeMarkerIds
            : context.nativeMarkerIds,
        nativeGroupKey: context.nativeGroupKey,
        bitmap: context.bitmap,
        width: context.width,
        height: context.height,
        excludedOwnerKey: preservesRemainder ? exclusion : null,
      );
    }
    if (unique.isEmpty) {
      clear();
    } else if (unique.length == 1) {
      select(unique.values.single);
    } else {
      MapInteractionTrace.commit(unique.keys.join('|'));
      state = MapSelectedMarker.group(
        unique.values.toList(),
        grouping,
        origin: origin,
      );
    }
  }

  /// Reconcile an open group against canonical data/layer changes. Never keep
  /// deleted or hidden members, or silently add unrelated new records.
  void retainVisibleGroupMembers(Iterable<MapMarker> visible) {
    final current = state;
    if (current == null || !current.isGroup) return;
    final byKey = {for (final marker in visible) marker.ownerKey: marker};
    final remaining = [
      for (final member in current.members) ?byKey[member.ownerKey],
    ];
    if (remaining.length == current.members.length &&
        Iterable<int>.generate(
          remaining.length,
        ).every((i) => identical(remaining[i], current.members[i]))) {
      return;
    }
    selectGroup(remaining, current.grouping!, origin: current.origin);
  }

  void clear() {
    if (state == null) return;
    MapInteractionTrace.commit('clear');
    state = null;
  }
}

final mapTransientFocusProvider =
    NotifierProvider<MapTransientFocusController, MapFocusState>(
      MapTransientFocusController.new,
    );

final class MapTransientFocusController extends Notifier<MapFocusState> {
  int _nonce = 0;

  @override
  MapFocusState build() => const MapFocusState();

  void focusContact({
    required String contactId,
    required MapCoordinate coordinate,
  }) {
    final request = MapFocusRequest(
      ownerKind: MapFocusOwnerKind.contact,
      recordId: contactId,
      coordinate: coordinate,
      nonce: ++_nonce,
    );
    state = MapFocusState(command: request, visibilityLease: request);
  }

  void focusEventOccurrence({
    required String eventId,
    required String occurrenceId,
    required PlannerDate originalDate,
    required PlannerDate renderedDate,
    required MapCoordinate coordinate,
  }) {
    final request = MapFocusRequest(
      ownerKind: MapFocusOwnerKind.eventOccurrence,
      recordId: eventId,
      occurrenceId: occurrenceId,
      originalDate: originalDate,
      renderedDate: renderedDate,
      coordinate: coordinate,
      nonce: ++_nonce,
    );
    state = MapFocusState(command: request, visibilityLease: request);
  }

  void focusSavedPlace({
    required String placeId,
    required MapCoordinate coordinate,
  }) {
    final request = MapFocusRequest(
      ownerKind: MapFocusOwnerKind.savedPlace,
      recordId: placeId,
      coordinate: coordinate,
      nonce: ++_nonce,
    );
    state = MapFocusState(command: request, visibilityLease: request);
  }

  void consume(int nonce) {
    if (state.command?.nonce == nonce) {
      state = MapFocusState(visibilityLease: state.visibilityLease);
    }
  }

  void clearVisibilityLease() {
    if (state.visibilityLease != null) {
      state = MapFocusState(command: state.command);
    }
  }

  void clear() => state = const MapFocusState();
}

/// Maps owns its Contact filter state while reusing canonical criteria.
final class MapsPeopleViewState {
  const MapsPeopleViewState({
    this.criteria = const ContactFilterCriteria(),
    this.sortBy = ContactSortBy.name,
    this.standardView = const ContactStandardView(
      filter: ContactStandardFilter.status,
    ),
    this.appliedFilter,
  });

  final ContactFilterCriteria criteria;
  final ContactSortBy sortBy;
  final ContactStandardView? standardView;
  final SavedContactFilter? appliedFilter;

  bool get hasFilter =>
      criteria.withoutRetiredTags().encode() !=
      const ContactFilterCriteria().encode();

  MapsPeopleViewState copyWith({
    ContactFilterCriteria? criteria,
    ContactSortBy? sortBy,
    ContactStandardView? standardView,
    SavedContactFilter? appliedFilter,
    bool clearStandardView = false,
    bool clearAppliedFilter = false,
  }) {
    return MapsPeopleViewState(
      criteria: criteria ?? this.criteria,
      sortBy: sortBy ?? this.sortBy,
      standardView: clearStandardView
          ? null
          : standardView ?? this.standardView,
      appliedFilter: clearAppliedFilter
          ? null
          : appliedFilter ?? this.appliedFilter,
    );
  }
}

final mapsPeopleViewProvider =
    NotifierProvider<MapsPeopleViewController, MapsPeopleViewState>(
      MapsPeopleViewController.new,
    );

final class MapsPeopleViewController extends Notifier<MapsPeopleViewState> {
  @override
  MapsPeopleViewState build() => const MapsPeopleViewState();

  void applyStandardView(ContactStandardView standardView) {
    state = MapsPeopleViewState(standardView: standardView);
  }

  void applyFilter({
    required ContactFilterCriteria criteria,
    required ContactSortBy sortBy,
    SavedContactFilter? appliedFilter,
  }) {
    state = state.copyWith(
      criteria: criteria.withoutRetiredTags(),
      sortBy: sortBy,
      appliedFilter: appliedFilter,
      clearAppliedFilter: appliedFilter == null,
      clearStandardView: true,
    );
  }
}

/// Repository that stores nothing.  Used only as the un-overridden default;
/// it lets Contact/Event forms open and save normally without a Maps layer.
final class NoopMapCoordinateRepository implements MapCoordinateRepository {
  const NoopMapCoordinateRepository();

  @override
  Stream<int> watchChanges(String profileId) => const Stream<int>.empty();

  @override
  Future<void> setCoordinate({
    required String profileId,
    required MapCoordinateOwner owner,
    required String recordId,
    required MapCoordinate coordinate,
  }) async {}

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
  Future<List<MapMarker>> readMarkers(String profileId) async =>
      const <MapMarker>[];
}

final mapProfileIdProvider = Provider<String>((ref) {
  final startup = ref.read(startupControllerProvider);
  if (startup is! StartupReady) {
    throw StateError('Maps require a ready Local Profile');
  }
  return startup.profile.id;
});

/// M4 P07 source-specific marker feed. Each owner uses its own table-change
/// stream and read whenever the repository supports it; older narrow test
/// doubles deliberately retain the previous broad read/filter fallback.
final mapOwnerMarkersProvider =
    StreamProvider.family<List<MapMarker>, MapCoordinateOwner>((ref, owner) {
      final profileId = ref.read(mapProfileIdProvider);
      final repository = ref.watch(mapCoordinateRepositoryProvider);
      final MapCoordinateOwnerRepository? ownerRepository =
          repository is MapCoordinateOwnerRepository
          ? repository as MapCoordinateOwnerRepository
          : null;
      final changes = ownerRepository?.watchOwnerChanges(profileId, owner) ??
          repository.watchChanges(profileId);
      return _coalescedMarkerReads(
        changes: changes,
        read: () async {
          if (ownerRepository case final ownerSource?) {
            return ownerSource.readOwnerMarkers(profileId, owner);
          }
          final markers = await repository.readMarkers(profileId);
          return markers
              .where((marker) => marker.owner == owner)
              .toList(growable: false);
        },
      );
    });

/// Compatibility union for existing consumers. M4 keeps composition cheap:
/// a source mutation changes its own feed, then this union only rejoins the
/// latest three source values without rereading their sibling owner tables.
final mapMarkersProvider = StreamProvider<List<MapMarker>>((ref) async* {
  final values = await Future.wait(<Future<List<MapMarker>>>[
    ref.watch(mapOwnerMarkersProvider(MapCoordinateOwner.contact).future),
    ref.watch(mapOwnerMarkersProvider(MapCoordinateOwner.event).future),
    ref.watch(mapOwnerMarkersProvider(MapCoordinateOwner.savedPlace).future),
  ]);
  yield <MapMarker>[...values[0], ...values[1], ...values[2]];
});

final mapChangesProvider = StreamProvider.family<int, String>((ref, profileId) {
  return ref.read(mapCoordinateRepositoryProvider).watchChanges(profileId);
});

Stream<List<MapMarker>> _coalescedMarkerReads({
  required Stream<int> changes,
  required Future<List<MapMarker>> Function() read,
}) {
  late final StreamController<List<MapMarker>> controller;
  StreamSubscription<int>? subscription;
  Future<void>? active;
  var dirty = false;

  Future<void> request() {
    if (active != null) {
      dirty = true;
      return active!;
    }
    late final Future<void> running;
    running = () async {
      do {
        dirty = false;
        try {
          controller.add(await read());
        } on Object catch (error, stackTrace) {
          controller.addError(error, stackTrace);
        }
      } while (dirty);
    }();
    active = running;
    return running.whenComplete(() {
      if (identical(active, running)) active = null;
    });
  }

  controller = StreamController<List<MapMarker>>(
    onListen: () {
      subscription = changes.listen(
        (_) => unawaited(request()),
        onError: controller.addError,
      );
      unawaited(request());
    },
    onCancel: () async {
      await subscription?.cancel();
    },
  );
  return controller.stream;
}

/// Truthful located-Contact projection. Canonical filtering and canonical
/// search are intersected before the coordinate requirement is applied.
final mapPeopleMarkersProvider = FutureProvider<List<MapMarker>>((ref) async {
  final profileId = ref.read(mapProfileIdProvider);
  final raw = await ref.watch(
    mapOwnerMarkersProvider(MapCoordinateOwner.contact).future,
  );
  final rawById = <String, MapMarker>{
    for (final marker in raw)
      if (marker.owner == MapCoordinateOwner.contact) marker.recordId: marker,
  };
  if (rawById.isEmpty) return const <MapMarker>[];

  final view = ref.watch(mapsPeopleViewProvider);
  final focus = ref.watch(
    mapTransientFocusProvider.select((value) => value.visibilityLease),
  );
  try {
    ref.watch(contactChangesProvider(profileId));
    final repository = ref.read(contactRepositoryProvider);
    final today = ref.read(plannerDateSourceProvider).today();
    final filtered = await repository.readContacts(
      profileId: profileId,
      criteria: view.criteria.withoutRetiredTags(),
      sortBy: view.sortBy,
      today: today,
      standardView: view.standardView,
    );
    final summaries = <String, ContactSummary>{
      for (final summary in filtered) summary.contact.id: summary,
    };
    String? outsideFocusId;
    if (focus?.ownerKind == MapFocusOwnerKind.contact &&
        rawById.containsKey(focus!.recordId) &&
        !summaries.containsKey(focus.recordId)) {
      final focused = await repository.readContactsByIds(
        profileId: profileId,
        contactIds: <String>[focus.recordId],
        today: today,
      );
      final summary = focused[focus.recordId];
      if (summary != null) {
        summaries[focus.recordId] = summary;
        outsideFocusId = focus.recordId;
      }
    }

    return <MapMarker>[
      for (final summary in summaries.values)
        if (rawById[summary.contact.id] case final rawMarker?)
          rawMarker.copyWith(
            displayName: summary.contact.displayName,
            isFavorite: summary.contact.isFavorite,
            colorValue: summary.colorValue.value,
            outsideCurrentFilter: summary.contact.id == outsideFocusId,
          ),
    ];
  } on Object catch (error) {
    if (!_isMissingRootOverride(error, 'ContactRepository')) rethrow;
    // Compatibility for isolated M1 surfaces without the app-root providers.
    return rawById.values.toList(growable: false);
  }
});

/// Dedicated off-map Search adapter. Typing never changes the Maps marker
/// provider graph; only the selected result returns as a one-shot focus.
Future<List<ContactSummary>> searchMapPeople(
  WidgetRef ref,
  String query,
) async {
  final profileId = ref.read(mapProfileIdProvider);
  final view = ref.read(mapsPeopleViewProvider);
  final repository = ref.read(contactRepositoryProvider);
  final today = ref.read(plannerDateSourceProvider).today();
  final results = await Future.wait(<Future<List<ContactSummary>>>[
    repository.readContacts(
      profileId: profileId,
      criteria: view.criteria.withoutRetiredTags(),
      sortBy: view.sortBy,
      today: today,
      standardView: view.standardView,
    ),
    repository.searchContacts(profileId: profileId, query: query, today: today),
  ]);
  final filteredIds = results[0].map((item) => item.contact.id).toSet();
  final locatedIds = (await ref.read(
        mapOwnerMarkersProvider(MapCoordinateOwner.contact).future,
      ))
      .map((marker) => marker.recordId)
      .toSet();
  return results[1]
      .where(
        (summary) =>
            filteredIds.contains(summary.contact.id) &&
            locatedIds.contains(summary.contact.id),
      )
      .toList(growable: false);
}

/// Map-local day invalidation; no Planner/repository clock redesign.
final mapLocalDayProvider =
    NotifierProvider<MapLocalDayController, PlannerDate>(
      MapLocalDayController.new,
    );

final class MapLocalDayController extends Notifier<PlannerDate> {
  Timer? _midnight;
  @override
  PlannerDate build() {
    ref.onDispose(() => _midnight?.cancel());
    _schedule();
    return ref.read(plannerDateSourceProvider).today();
  }

  void refresh() {
    final today = ref.read(plannerDateSourceProvider).today();
    if (state != today) state = today;
    _schedule();
  }

  void _schedule() {
    _midnight?.cancel();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now), refresh);
  }
}

/// Canonical today-only Event occurrence projection. Production uses the
/// Calendar repository's recurrence/exception owner and never loads Tasks.
final mapEventMarkersProvider = FutureProvider<List<MapMarker>>((ref) async {
  final profileId = ref.read(mapProfileIdProvider);
  final raw = await ref.watch(
    mapOwnerMarkersProvider(MapCoordinateOwner.event).future,
  );
  final rawById = <String, MapMarker>{
    for (final marker in raw)
      if (marker.owner == MapCoordinateOwner.event) marker.recordId: marker,
  };
  if (rawById.isEmpty) return const <MapMarker>[];
  final today = ref.watch(mapLocalDayProvider);
  try {
    final calendar = ref.read(calendarEventRepositoryProvider);
    final items = calendar is CalendarEventRangeSource
        ? await (calendar as CalendarEventRangeSource).readRange(
            profileId: profileId,
            startDate: today,
            endDate: today,
          )
        : await calendar.readDay(profileId: profileId, date: today);
    final occurrences = <String, MapMarker>{};
    for (final item in items) {
      final eventId = item.eventId;
      final originalDate = item.originalDate;
      final coordinate = eventId == null ? null : rawById[eventId];
      if (coordinate == null ||
          originalDate == null ||
          item.state != PlannerEventState.scheduled) {
        continue;
      }
      occurrences[item.id] = coordinate.copyWith(
        displayName: item.displayTitle,
        colorValue: item.activityTypeColorValue ?? coordinate.colorValue,
        occurrenceId: item.id,
        eventOriginalDate: originalDate,
        eventRenderedDate: item.date,
        eventState: item.state,
      );
    }

    return occurrences.values.toList(growable: false);
  } on Object catch (error) {
    if (!_isMissingRootOverride(error, 'CalendarEventRepository')) rethrow;
    return rawById.values.toList(growable: false);
  }
});

/// Explicit navigation exception is separate from the Today's Events layer.
final mapFocusedEventMarkersProvider = FutureProvider<List<MapMarker>>((
  ref,
) async {
  final focus = ref.watch(
    mapTransientFocusProvider.select((s) => s.visibilityLease),
  );
  if (focus?.ownerKind != MapFocusOwnerKind.eventOccurrence) return const [];
  final today = ref.watch(mapLocalDayProvider);
  final profileId = ref.read(mapProfileIdProvider);
  final raw = await ref.watch(
    mapOwnerMarkersProvider(MapCoordinateOwner.event).future,
  );
  final rawById = {
    for (final marker in raw)
      if (marker.owner == MapCoordinateOwner.event) marker.recordId: marker,
  };
  final occurrences = <String, MapMarker>{};
  try {
    if (focus?.ownerKind == MapFocusOwnerKind.eventOccurrence &&
        focus!.occurrenceId != null &&
        focus.originalDate != null &&
        rawById.containsKey(focus.recordId)) {
      final occurrence = await ref
          .read(calendarEventRepositoryProvider)
          .readOccurrence(
            profileId: profileId,
            eventId: focus.recordId,
            originalDate: focus.originalDate!,
          );
      if (occurrence != null &&
          (occurrence.displayDate != today ||
              occurrence.status.name != PlannerEventState.scheduled.name)) {
        final rawMarker = rawById[focus.recordId]!;
        occurrences[occurrence.id] = rawMarker.copyWith(
          displayName: occurrence.displayTitle,
          colorValue: occurrence.activityTypeColorValue ?? rawMarker.colorValue,
          occurrenceId: occurrence.id,
          eventOriginalDate: occurrence.originalDate,
          eventRenderedDate: occurrence.displayDate,
          eventState: PlannerEventState.values.byName(occurrence.status.name),
          outsideCurrentFilter: true,
        );
      }
    }
    return occurrences.values.toList(growable: false);
  } on Object catch (error) {
    if (!_isMissingRootOverride(error, 'CalendarEventRepository')) rethrow;
    // Compatibility for isolated M1 surfaces without the app-root providers.
    return rawById.values.toList(growable: false);
  }
});

final mapSavedPlaceMarkersProvider = FutureProvider<List<MapMarker>>((
  ref,
) async {
  return ref.watch(mapOwnerMarkersProvider(MapCoordinateOwner.savedPlace).future);
});

bool _isMissingRootOverride(Object error, String repositoryName) => error
    .toString()
    .contains('$repositoryName must be overridden at the app root');

final mapProjectedMarkersProvider = FutureProvider<List<MapMarker>>((
  ref,
) async {
  final results = await Future.wait(<Future<List<MapMarker>>>[
    ref.watch(mapPeopleMarkersProvider.future),
    ref.watch(mapEventMarkersProvider.future),
    ref.watch(mapSavedPlaceMarkersProvider.future),
    ref.watch(mapFocusedEventMarkersProvider.future),
  ]);
  return <MapMarker>[
    ...results[0],
    ...results[1],
    ...results[2],
    ...results[3],
  ];
});
