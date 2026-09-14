import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/shell/global_drawer_controller.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/c3_contact_primitives.dart';
import 'package:rmplanner/features/contacts/presentation/filter_builder_screen.dart';
import 'package:rmplanner/features/contacts/presentation/saved_filters_screen.dart';
import 'package:rmplanner/features/maps/application/boundary_edit_session.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_interaction_trace.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_provider.dart';
import 'package:rmplanner/features/maps/application/saved_place_providers.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/domain/saved_place.dart';
import 'package:rmplanner/features/maps/presentation/boundary_mode_chrome.dart';
import 'package:rmplanner/features/maps/presentation/google_maps_surface.dart';
import 'package:rmplanner/features/maps/presentation/location_action_sheet.dart';
import 'package:rmplanner/features/maps/presentation/map_marker_preview_sheet.dart';
import 'package:rmplanner/features/maps/presentation/maps_search_screen.dart';
import 'package:rmplanner/features/maps/presentation/saved_place_form_sheet.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

/// Maps V1 — the fourth primary tab.
///
/// THE MAP IS THE STABLE CANVAS. Directly selecting an existing Contact,
/// Favorite, Event, or Saved Place never pans/recenters/zooms/offsets the
/// camera. Selection owns marker emphasis + preview + floating-control motion
/// only. The camera moves only for an explicit user map action or when the
/// user enters inline edit/drop-pin mode and moves the map themselves.
final class MapsScreen extends ConsumerStatefulWidget {
  const MapsScreen({this.mapBuilder, super.key});

  /// Test seam: builds the interactive map surface.  Defaults to the real
  /// Google Maps surface; widget tests override only the platform canvas.
  final Widget Function(BuildContext, List<MapMarker>)? mapBuilder;

  @override
  ConsumerState<MapsScreen> createState() => _MapsScreenState();
}

final class _InlineEditSession {
  const _InlineEditSession({required this.marker, required this.label});

  final MapMarker marker;
  final String label;
}

final class _MapsScreenState extends ConsumerState<MapsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _selectorExpanded = false;
  List<MapMarker> _lastMarkers = const <MapMarker>[];
  late final MapTransientFocusController _focusController;
  late final MapSelectedMarkerController _selectedMarkerController;
  late final ProviderContainer _providerContainer;
  late final ProviderSubscription<MapSelectedMarker?> _selectionSubscription;

  MapCoordinate? _cameraCenter;

  /// Inline, same-map edit-location session (Correction B).
  _InlineEditSession? _inlineEdit;

  /// VS-15 M6.1 Pass 2: same-map Define Boundary session. The Add/Edit Place
  /// form has yielded; THIS canonical map owns the boundary taps until the
  /// session resolves and the form is re-opened with its preserved draft.
  BoundaryEditSession? _boundary;
  bool _boundaryLocating = false;
  bool? _boundaryShowMyLocation;
  GoogleMapController? _surfaceMapController;

  /// Dedicated Drop Pin placement mode (Correction C), before the chooser.
  bool _dropPinMode = false;
  bool _savingLocation = false;
  bool _locationActionsOpen = false;
  MapSelectedMarker? _previewSelection;
  int _previewGeneration = 0;

  late final AnimationController _previewAnim;
  final ValueNotifier<double> _previewLift = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusController = ref.read(mapTransientFocusProvider.notifier);
    _selectedMarkerController = ref.read(mapSelectedMarkerProvider.notifier);
    _providerContainer = ProviderScope.containerOf(context, listen: false);
    _previewAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 200),
    )..addListener(_syncPreviewLift);
    _selectionSubscription = ref.listenManual(mapSelectedMarkerProvider, (
      _,
      selection,
    ) {
      if (!mounted) return;
      _previewGeneration += 1;
      if (selection != null) {
        setState(() => _previewSelection = selection);
        final gesture = MapInteractionTrace.token;
        MapInteractionTrace.record('T3', selection.markerKey, gesture: gesture);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_previewSelection, selection)) {
            MapInteractionTrace.record(
              'T4',
              selection.markerKey,
              gesture: gesture,
            );
          }
        });
        unawaited(_previewAnim.forward());
      } else {
        unawaited(_closePreview(_previewGeneration));
      }
    });
  }

  void _syncPreviewLift() {
    _previewLift.value =
        Curves.easeOutCubic.transform(_previewAnim.value) * 276.0;
  }

  Future<void> _closePreview(int generation) async {
    try {
      await _previewAnim.reverse().orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || generation != _previewGeneration) return;
    _previewLift.value = 0;
    setState(() => _previewSelection = null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(mapLocalDayProvider.notifier).refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // The boundary draft controller lives in the session provider and
    // survives tab recreation; only this screen's listener is detached.
    _boundary?.controller.removeListener(_onBoundaryChanged);
    final selection = _providerContainer.read(mapSelectedMarkerProvider);
    final focus = _providerContainer.read(mapTransientFocusProvider);
    _selectionSubscription.close();
    _previewAnim.dispose();
    _previewLift.dispose();
    // Child consumers unmount before ephemeral navigation state is cleared.
    // Identity guards protect a new Maps instance's newer selection/focus.
    scheduleMicrotask(() {
      try {
        if (identical(
          _providerContainer.read(mapTransientFocusProvider),
          focus,
        )) {
          _focusController.clear();
        }
        if (identical(
          _providerContainer.read(mapSelectedMarkerProvider),
          selection,
        )) {
          _selectedMarkerController.clear();
        }
      } on StateError {
        // The whole ProviderScope was disposed with this screen; it has no
        // surviving ephemeral state to clear.
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markersAsync = ref.watch(mapProjectedMarkersProvider);
    final passiveCoordinate = ref.watch(mapPassiveLocationProvider).value;
    if (markersAsync case AsyncData<List<MapMarker>>(:final value)) {
      _lastMarkers = value;
    }
    final markers = _lastMarkers;
    final selectedMarker = ref.watch(mapSelectedMarkerProvider);
    final topBarForeground = Theme.of(context).colorScheme.onSurface;
    ref.listen(boundaryEditSessionProvider, (previous, next) {
      if (!mounted) return;
      if (next != null && _boundary == null) {
        _beginBoundary(next);
      } else if (next == null && _boundary != null) {
        setState(() => _endBoundaryLocal());
      }
    });
    return PopScope<void>(
      canPop:
          !_dropPinMode &&
          _inlineEdit == null &&
          selectedMarker == null &&
          _boundary == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_dropPinMode || _inlineEdit != null) {
            _cancelPlacementMode();
          } else if (_boundary != null) {
            _cancelBoundary();
          } else {
            _dismissSelection();
          }
        }
      },
      child: Scaffold(
        appBar: _boundary != null
            ? _buildBoundaryAppBar()
            : _buildMapsAppBar(topBarForeground),
        body: _buildBody(
          markersAsync,
          markers,
          passiveCoordinate,
          selectedMarker,
        ),
      ),
    );
  }

  PreferredSizeWidget _buildMapsAppBar(Color topBarForeground) {
    final peopleView = ref.watch(mapsPeopleViewProvider);
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: AppTheme.surfaceOf(context),
      foregroundColor: topBarForeground,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      toolbarHeight: 72,
      leadingWidth: 64,
      leading: IconButton(
        key: const Key('maps-menu-button'),
        tooltip: 'Open navigation',
        onPressed: () => GlobalDrawerScope.of(context).open(),
        icon: const Icon(Icons.menu, size: 24),
      ),
      titleSpacing: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            'Maps',
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: 16,
              height: 22 / 16,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 2),
          ContactViewSelectorButton(
            key: const Key('maps-status-selector'),
            standardView: peopleView.standardView,
            appliedFilter: peopleView.appliedFilter,
            isFiltered: peopleView.hasFilter,
            expanded: _selectorExpanded,
            onTap: () => setState(() => _selectorExpanded = !_selectorExpanded),
          ),
        ],
      ),
      actions: <Widget>[
        IconButton(
          key: const Key('maps-filter-button'),
          tooltip: 'Filter',
          iconSize: 28,
          onPressed: () => unawaited(_openFilterBuilder()),
          icon: FilterPlusIcon(color: topBarForeground, size: 28),
        ),
        IconButton(
          key: const Key('maps-search-button'),
          tooltip: 'Search',
          iconSize: 27,
          onPressed: () => unawaited(_openSearch()),
          icon: Icon(Icons.search, color: topBarForeground),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// VS-15 M6.1 Pass 2: while the same-map Define Boundary session is active
  /// the canonical top bar yields to the owner-approved M6.1 editor bar
  /// (X + title) on the SAME screen — no second map, no second route.
  PreferredSizeWidget _buildBoundaryAppBar() {
    return InternalAppBar(
      key: const Key('boundary-editor-screen'),
      backgroundColor: AppTheme.surfaceOf(context),
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: false,
      title: const Text('Define Boundary'),
      leading: IconButton(
        key: const Key('boundary-editor-cancel'),
        tooltip: 'Cancel boundary drawing',
        onPressed: _cancelBoundary,
        color: Theme.of(context).colorScheme.primary,
        icon: const Icon(Icons.close),
      ),
    );
  }

  Widget _buildBody(
    AsyncValue<List<MapMarker>> markersAsync,
    List<MapMarker> markers,
    MapCoordinate? passiveCoordinate,
    MapSelectedMarker? selectedMarker,
  ) {
    final outsideFilter = markers.any(
      (marker) =>
          marker.owner == MapCoordinateOwner.contact &&
          marker.outsideCurrentFilter,
    );
    final focusedEvent = markers
        .where(
          (m) => m.owner == MapCoordinateOwner.event && m.outsideCurrentFilter,
        )
        .firstOrNull;
    return Column(
      children: <Widget>[
        if (focusedEvent != null)
          Container(
            key: const Key('maps-focused-event-disclosure'),
            width: double.infinity,
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Focused Event • ${focusedEvent.eventRenderedDate?.iso8601 ?? "outside today’s layer"}',
              textAlign: TextAlign.center,
            ),
          ),
        if (outsideFilter)
          Container(
            key: const Key('maps-outside-filter-disclosure'),
            width: double.infinity,
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: const Text(
              'Focused Contact is outside the current Maps filter.',
              textAlign: TextAlign.center,
            ),
          ),
        Expanded(
          child: _buildMapStack(
            markers,
            passiveCoordinate,
            selectedMarker,
            markersAsync,
          ),
        ),
      ],
    );
  }

  Widget _buildMapStack(
    List<MapMarker> markers,
    MapCoordinate? passiveCoordinate,
    MapSelectedMarker? selectedMarker,
    AsyncValue<List<MapMarker>> markersAsync,
  ) {
    final persistedPolygons = ref.watch(savedPlacePolygonsProvider);
    final showBoundaries = ref.watch(mapsPreferencesProvider).showBoundaries;
    final boundarySession = _boundary;
    // Boundaries visibility (M6.2) applies to normal Maps mode only. While
    // Define Boundary is active the editor exception keeps the working
    // draft, vertex handles, and the current place's faint reference
    // boundary visible regardless of the preference.
    final polygons = boundarySession == null
        ? (showBoundaries ? persistedPolygons : const <Polygon>{})
        : _boundaryOverlayPolygons(persistedPolygons, boundarySession);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GoogleMapsSurface(
          markers: boundarySession == null
              ? markers
              : _boundaryMarkers(markers, boundarySession),
          initialCoordinate: passiveCoordinate,
          onMarkerTap: _selectMarker,
          onMapLongPress: _beginPlacementCoordinate,
          onMapTap: _dismissSelection,
          onMapTapCoordinate: boundarySession == null
              ? null
              : _addBoundaryVertex,
          onDropPin: _beginDropPin,
          onCameraCenterChanged: (value) => _cameraCenter = value,
          placementTarget: _inlineEdit?.marker.coordinate,
          placementActive: _inlineEdit != null || _dropPinMode,
          controlsLift: _previewLift,
          mapBuilder: widget.mapBuilder,
          polygons: polygons,
          circles: boundarySession == null
              ? const <Circle>{}
              : boundaryVertexHandles(
                  vertices: boundarySession.controller.vertices,
                  colorHex: boundarySession.snapshot.boundaryColorHex,
                ),
          controlsEnabled: boundarySession == null,
          interactionPaused: boundarySession != null,
          myLocationOverride: boundarySession == null
              ? null
              : _boundaryShowMyLocation,
          onMapController: (controller) => _surfaceMapController = controller,
        ),
        if (boundarySession != null)
          Positioned.fill(
            child: BoundaryModeChrome(
              verticesCount: boundarySession.controller.vertices.length,
              canDone: boundarySession.controller.canDone,
              locating: _boundaryLocating,
              onUndo: () => boundarySession.controller.undo(),
              onClear: () => boundarySession.controller.clear(),
              onDone: _doneBoundary,
              onLocate: () => unawaited(_locateBoundary()),
            ),
          ),
        if (_inlineEdit != null)
          _PlacementChrome(
            helperText: _inlineEditHelper,
            onCancel: _cancelInlineEdit,
            onConfirm: _confirmInlineEdit,
          ),
        if (_dropPinMode)
          _PlacementChrome(
            helperText: 'Move map to place pin',
            onCancel: _cancelDropPin,
            onConfirm: _confirmDropPin,
          ),
        if (_previewSelection != null && _inlineEdit == null && !_dropPinMode)
          _PreviewSheetHost(
            animation: _previewAnim,
            child: IgnorePointer(
              ignoring: selectedMarker == null,
              child: MapMarkerPreviewSheet(
                selection: _previewSelection!,
                onDismiss: _dismissSelection,
                onEditLocation: () => _editLocation(_previewSelection!.marker),
                onEditPlace:
                    _previewSelection!.marker.owner ==
                        MapCoordinateOwner.savedPlace
                    ? () => unawaited(_openEditPlace(_previewSelection!.marker))
                    : null,
                onDeletePlace:
                    _previewSelection!.marker.owner ==
                        MapCoordinateOwner.savedPlace
                    ? () => unawaited(
                        _confirmDeletePlace(_previewSelection!.marker),
                      )
                    : null,
              ),
            ),
          ),
        if (_selectorExpanded)
          Material(
            color: AppTheme.surfaceOf(context),
            child: ContactViewSelectorPanel(onSelected: _applyViewSelection),
          ),
        if (markersAsync.isLoading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(
              key: Key('maps-marker-loading'),
              minHeight: 2,
            ),
          ),
        if (markersAsync.hasError)
          Align(
            alignment: Alignment.bottomCenter,
            child: _MarkerLoadError(onRetry: _retryMarkers),
          ),
      ],
    );
  }

  String get _inlineEditHelper => 'Move map to find location';

  void _applyViewSelection(SavedFilterSelection selection) {
    final controller = ref.read(mapsPeopleViewProvider.notifier);
    if (selection.standardView case final standardView?) {
      controller.applyStandardView(standardView);
    } else {
      controller.applyFilter(
        criteria: selection.criteria,
        sortBy: selection.appliedFilter?.sortBy ?? ContactSortBy.name,
        appliedFilter: selection.appliedFilter,
      );
    }
    setState(() => _selectorExpanded = false);
  }

  Future<void> _openFilterBuilder() async {
    final current = ref.read(mapsPeopleViewProvider);
    final result = await context.push<FilterBuilderResult>(
      RoutePaths.filterBuilder,
      extra: FilterBuilderArgs(
        initialCriteria: current.criteria,
        initialSortBy: current.sortBy,
      ),
    );
    if (!mounted || result == null) return;
    ref
        .read(mapsPeopleViewProvider.notifier)
        .applyFilter(
          criteria: result.criteria,
          sortBy: result.sortBy,
          appliedFilter: result.savedFilter,
        );
  }

  Future<void> _openSearch() async {
    final result = await context.push<MapSearchSelection>(RoutePaths.mapSearch);
    if (!mounted || result == null) return;
    final focus = ref.read(mapTransientFocusProvider.notifier);
    switch (result.ownerKind) {
      case MapFocusOwnerKind.contact:
        focus.focusContact(
          contactId: result.recordId,
          coordinate: result.coordinate,
        );
      case MapFocusOwnerKind.eventOccurrence:
        focus.focusEventOccurrence(
          eventId: result.recordId,
          occurrenceId: result.occurrenceId!,
          originalDate: result.originalDate!,
          renderedDate: result.renderedDate!,
          coordinate: result.coordinate,
        );
      case MapFocusOwnerKind.savedPlace:
        // VS-15 M7.2: the Search result snapshot may be stale — the Saved
        // Place can be moved or deleted after results were generated but
        // before the user taps the row. Re-resolve the CURRENT record by its
        // stable ID and focus its live coordinate; a deleted place focuses
        // nothing and the canonical Maps context stays untouched (no camera
        // animation, no selection, no preview).
        final place = await ref
            .read(savedPlaceRepositoryProvider)
            .readById(
              profileId: ref.read(savedPlaceProfileIdProvider),
              id: result.recordId,
            );
        if (!mounted || place == null) return;
        focus.focusSavedPlace(placeId: place.id, coordinate: place.coordinate);
    }
  }

  void _retryMarkers() {
    for (final owner in MapCoordinateOwner.values) {
      _invalidateMarkerOwner(owner);
    }
  }

  void _selectMarker(MapMarker marker) {
    // The map is the stable canvas: selecting a marker never moves the camera.
    // Same-map Define Boundary mode temporarily suppresses selection entirely.
    if (_boundary != null) return;
    if (_inlineEdit != null || _dropPinMode) {
      setState(() {
        _inlineEdit = null;
        _dropPinMode = false;
      });
    }
    _selectedMarkerController.select(marker);
  }

  void _dismissSelection() {
    _selectedMarkerController.clear();
  }

  Future<void> _editLocation(MapMarker marker) async {
    _cameraCenter = marker.coordinate;
    setState(() {
      _inlineEdit = _InlineEditSession(
        marker: marker,
        label: marker.displayName,
      );
      _dropPinMode = false;
    });
    _dismissSelection();
  }

  void _cancelInlineEdit() {
    if (_savingLocation) return;
    setState(() => _inlineEdit = null);
  }

  Future<void> _confirmInlineEdit() async {
    final session = _inlineEdit;
    if (session == null || _savingLocation) return;
    final coordinate = _cameraCenter ?? session.marker.coordinate;
    // M6.1 Pass 3: a Saved Place WITH a boundary may only move to a
    // coordinate inside/on its boundary. Read the CURRENT persisted place at
    // Confirm time (MapMarker carries presentation identity only) and
    // validate BEFORE any write. Outside: same containment dialog, zero
    // writes, inline edit stays active with the candidate camera unchanged.
    if (session.marker.owner == MapCoordinateOwner.savedPlace) {
      final place = await ref
          .read(savedPlaceRepositoryProvider)
          .readById(
            profileId: ref.read(savedPlaceProfileIdProvider),
            id: session.marker.recordId,
          );
      if (!mounted) return;
      final boundary = place?.boundary;
      if (boundary != null &&
          !savedPlaceBoundaryContainsCoordinate(boundary, coordinate)) {
        await _showBoundaryExclusionDialog();
        return;
      }
    }
    setState(() => _savingLocation = true);
    try {
      await ref
          .read(mapCoordinateRepositoryProvider)
          .setCoordinate(
            profileId: ref.read(mapProfileIdProvider),
            owner: session.marker.owner,
            recordId: session.marker.recordId,
            coordinate: coordinate,
          );
    } on Object {
      if (mounted) {
        setState(() => _savingLocation = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Location could not be saved. Your pin is unchanged.',
            ),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    _invalidateMarkerOwner(session.marker.owner);
    final updated = MapMarker(
      owner: session.marker.owner,
      recordId: session.marker.recordId,
      coordinate: coordinate,
      displayName: session.marker.displayName,
      isFavorite: session.marker.isFavorite,
      colorValue: session.marker.colorValue,
      occurrenceId: session.marker.occurrenceId,
      eventOriginalDate: session.marker.eventOriginalDate,
      eventRenderedDate: session.marker.eventRenderedDate,
      eventState: session.marker.eventState,
      outsideCurrentFilter: session.marker.outsideCurrentFilter,
      placeMarkerMode: session.marker.placeMarkerMode,
      placeStandardCategory: session.marker.placeStandardCategory,
      placeEmoji: session.marker.placeEmoji,
    );
    if (mounted) {
      setState(() {
        _inlineEdit = null;
        _savingLocation = false;
      });
      _selectedMarkerController.select(updated);
    }
  }

  void _beginDropPin() {
    if (_boundary != null || _inlineEdit != null) return;
    setState(() {
      _dropPinMode = true;
      _selectedMarkerController.clear();
    });
  }

  void _cancelDropPin() {
    setState(() => _dropPinMode = false);
  }

  /// Dedicated Drop Pin check: capture the camera center, exit placement, and
  /// open the shared Location Action Sheet (no domain write yet).
  void _confirmDropPin() {
    final coordinate =
        _cameraCenter ?? const MapCoordinate(latitude: 20, longitude: 0);
    setState(() => _dropPinMode = false);
    unawaited(_openLocationActionSheet(coordinate));
  }

  /// Long press opens the same shared Location Action Sheet at the exact
  /// coordinate. No Saved Place or other row is created by a long press alone.
  void _beginPlacementCoordinate(MapCoordinate coordinate) {
    if (_boundary != null || _inlineEdit != null || _dropPinMode) {
      return;
    }
    unawaited(_openLocationActionSheet(coordinate));
  }

  Future<void> _openLocationActionSheet(MapCoordinate coordinate) async {
    if (_locationActionsOpen) return;
    _locationActionsOpen = true;
    _dismissSelection();
    MapLocationAction? action;
    try {
      action = await showMapLocationActionSheet(context);
    } finally {
      _locationActionsOpen = false;
    }
    if (!mounted || action == null) return;
    switch (action) {
      case MapLocationAction.place:
        await _openAddPlace(coordinate);
      case MapLocationAction.contact:
        unawaited(_openAddContact(coordinate));
      case MapLocationAction.event:
        unawaited(_openAddEvent(coordinate));
    }
  }

  Future<void> _openAddPlace(MapCoordinate coordinate) async {
    await _pushPlaceForm(
      origin: BoundaryEditOriginAdd(coordinate: coordinate),
      snapshot: null,
    );
  }

  Future<void> _openEditPlace(MapMarker marker) async {
    final repository = ref.read(savedPlaceRepositoryProvider);
    final profileId = ref.read(savedPlaceProfileIdProvider);
    final place = await repository.readById(
      profileId: profileId,
      id: marker.recordId,
    );
    if (!mounted) return;
    if (place == null) {
      _dismissSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This Saved Place is no longer available.'),
        ),
      );
      return;
    }
    await _pushPlaceForm(
      origin: BoundaryEditOriginEdit(place: place),
      snapshot: null,
    );
  }

  /// Shared Add/Edit Place route. [snapshot] is non-null only when the form
  /// is being RE-opened after a same-map Define Boundary visit; it restores
  /// every unsaved value (label, mode, category, emoji, colors, boundary
  /// draft) exactly as they were at yield time.
  Future<void> _pushPlaceForm({
    required BoundaryEditOrigin origin,
    required SavedPlaceFormSnapshot? snapshot,
  }) async {
    switch (origin) {
      case BoundaryEditOriginAdd(:final coordinate):
        await Navigator.of(context, rootNavigator: true).push<void>(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: 'saved-place-create'),
            builder: (editorContext) => SavedPlaceFormScreen(
              coordinate: coordinate,
              initialSnapshot: snapshot,
              onSave: (draft) async {
                await _savePlace(draft);
                if (editorContext.mounted) Navigator.of(editorContext).pop();
              },
              onCancel: () => Navigator.of(editorContext).pop(),
            ),
          ),
        );
      case BoundaryEditOriginEdit(:final place):
        await Navigator.of(context, rootNavigator: true).push<void>(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: 'saved-place-edit'),
            builder: (editorContext) => SavedPlaceFormScreen(
              coordinate: place.coordinate,
              initialPlace: place,
              initialSnapshot: snapshot,
              onSave: (draft) async {
                final updated = await ref
                    .read(savedPlaceRepositoryProvider)
                    .update(
                      profileId: place.profileId,
                      id: place.id,
                      draft: SavedPlaceDraft(
                        label: draft.label,
                        coordinate: place.coordinate,
                        markerMode: draft.markerMode,
                        standardCategory: draft.standardCategory,
                        customEmoji: draft.customEmoji,
                        markerColorHex: draft.markerColorHex,
                        boundary: draft.boundary,
                      ),
                    );
                if (!mounted) return;
                _invalidateMarkerOwner(MapCoordinateOwner.savedPlace);
                _selectedMarkerController.select(
                  MapMarker(
                    owner: MapCoordinateOwner.savedPlace,
                    recordId: updated.id,
                    coordinate: updated.coordinate,
                    displayName: updated.label,
                    colorValue: updated.markerColorArgb,
                    placeMarkerMode: updated.markerMode,
                    placeStandardCategory: updated.standardCategory,
                    placeEmoji: updated.customEmoji,
                  ),
                );
                if (editorContext.mounted) Navigator.of(editorContext).pop();
              },
              onCancel: () => Navigator.of(editorContext).pop(),
            ),
          ),
        );
    }
  }

  Future<void> _confirmDeletePlace(MapMarker marker) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Place?'),
        content: Text(
          'Delete “${marker.displayName}”? This removes only this Saved Place.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('delete-saved-place-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('delete-saved-place-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(savedPlaceRepositoryProvider)
          .delete(
            profileId: ref.read(savedPlaceProfileIdProvider),
            id: marker.recordId,
          );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved Place could not be deleted.')),
        );
      }
      return;
    }
    if (!mounted) return;
    _dismissSelection();
    _invalidateMarkerOwner(MapCoordinateOwner.savedPlace);
  }

  Future<void> _openAddContact(MapCoordinate coordinate) async {
    await context.push<void>(
      RoutePaths.contactCreate,
      extra: AddContactMapExtra(coordinate: coordinate),
    );
    if (mounted) _invalidateMarkerOwner(MapCoordinateOwner.contact);
  }

  Future<void> _openAddEvent(MapCoordinate coordinate) async {
    final now = DateTime.now();
    final today = PlannerDate.fromDateTime(now);
    final startMinute = now.hour * 60 + now.minute;
    await context.push<void>(
      '${RoutePaths.calendarEventCreate}?lat=${coordinate.latitude}'
      '&lng=${coordinate.longitude}&date=${today.iso8601}'
      '&startMinute=$startMinute',
    );
    if (mounted) _invalidateMarkerOwner(MapCoordinateOwner.event);
  }

  Future<void> _savePlace(SavedPlaceDraft draft) async {
    await ref
        .read(savedPlaceRepositoryProvider)
        .create(profileId: ref.read(savedPlaceProfileIdProvider), draft: draft);
    if (!mounted) return;
    _invalidateMarkerOwner(MapCoordinateOwner.savedPlace);
  }

  /// Cancels whichever provisional placement mode is active (inline edit,
  /// or drop-pin). Never writes anything.
  void _cancelPlacementMode() {
    if (_dropPinMode) {
      setState(() => _dropPinMode = false);
    } else if (_inlineEdit != null) {
      _cancelInlineEdit();
    }
  }

  // ============================================================
  // VS-15 M6.1 PASS 2 — SAME-MAP DEFINE BOUNDARY SESSION
  // ============================================================

  /// The Add/Edit Place form yielded: enter Define Boundary mode on THIS
  /// canonical map. The camera, map type and every existing visual (contacts,
  /// events, places, clusters, persisted boundaries, the working place
  /// marker, the blue dot) keep rendering exactly as they were — the map is
  /// never recentered, retyped, or replaced. Marker/cluster selection and the
  /// long-press chooser are temporarily suppressed; a map tap becomes a
  /// boundary vertex.
  void _beginBoundary(BoundaryEditSession session) {
    _boundary = session;
    _boundaryLocating = false;
    _boundaryShowMyLocation = null;
    session.controller.addListener(_onBoundaryChanged);
    // The editing place must keep its normal canonical marker — never the
    // red selection pin. Clearing the selection removes emphasis + preview.
    _dismissSelection();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _boundary == session) {
        BoundaryEditTimingTrace.mapModeActive();
      }
    });
  }

  void _onBoundaryChanged() {
    if (mounted) setState(() {});
  }

  /// Exits boundary mode locally (session already cleared at the provider).
  void _endBoundaryLocal() {
    final session = _boundary;
    _boundary = null;
    _boundaryLocating = false;
    _boundaryShowMyLocation = null;
    session?.controller.removeListener(_onBoundaryChanged);
  }

  /// Map tap precedence: in boundary mode a map tap IS a vertex — never a
  /// marker selection, cluster selection, or preview.
  void _addBoundaryVertex(MapCoordinate coordinate) {
    final session = _boundary;
    if (session == null) return;
    BoundaryEditTimingTrace.tapReceived();
    final hadVertices = session.controller.vertices.isNotEmpty;
    session.controller.addVertex(coordinate);
    if (!hadVertices) BoundaryEditTimingTrace.firstVertexCommitted();
  }

  /// M6.1 Pass 3: the canonical blocking containment error, shared by Define
  /// Boundary Done and Edit Pin Location Confirm so the copy is identical.
  Future<void> _showBoundaryExclusionDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('boundary-exclusion-dialog'),
        title: const Text("Boundary doesn't include this place"),
        content: const Text(
          'The place icon must be inside the boundary. '
          'Adjust the outline and try again.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('boundary-exclusion-ok'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Done: validates the draft (>=3 valid vertices), returns it to the
  /// originating form, and re-opens THAT form with every unsaved value
  /// intact. Never persists — the main Add/Edit Place Save does that.
  ///
  /// M6.1 Pass 3: after geometry validation the completed draft must also
  /// CONTAIN the place coordinate (Add origin or the existing place's
  /// coordinate — never camera center, never the blue dot). An outside place
  /// shows the blocking dialog and the live session keeps every vertex,
  /// color, camera, and marker untouched.
  void _doneBoundary() {
    final session = _boundary;
    if (session == null) return;
    final draft = session.controller.complete();
    if (draft == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          key: Key('boundary-editor-done-error'),
          content: Text(
            'Add at least three distinct points that form an area.',
          ),
        ),
      );
      return;
    }
    final placeCoordinate = switch (session.origin) {
      BoundaryEditOriginAdd(:final coordinate) => coordinate,
      BoundaryEditOriginEdit(:final place) => place.coordinate,
    };
    if (!savedPlaceBoundaryContainsCoordinate(draft, placeCoordinate)) {
      unawaited(_showBoundaryExclusionDialog());
      return;
    }
    unawaited(_resolveBoundary(session, draft));
  }

  /// X (or system back): discards changes from THIS editor visit, preserves
  /// the prior form BoundaryDraft, and re-opens the form. No DB write.
  void _cancelBoundary() {
    final session = _boundary;
    if (session == null) return;
    unawaited(_resolveBoundary(session, null));
  }

  Future<void> _resolveBoundary(
    BoundaryEditSession session,
    SavedPlaceBoundary? draft,
  ) async {
    final resolved = ref
        .read(boundaryEditSessionProvider.notifier)
        .resolve(draft);
    if (!mounted) return;
    final snapshot = resolved?.snapshot.withBoundary(draft) ?? session.snapshot;
    await _pushPlaceForm(origin: session.origin, snapshot: snapshot);
  }

  /// Current Location during Define Boundary: works only when explicitly
  /// tapped, moves ONLY the same canonical map camera, never exits boundary
  /// mode, never clears vertices, and never selects/saves anything.
  Future<void> _locateBoundary() async {
    if (_boundaryLocating) return;
    setState(() => _boundaryLocating = true);
    final result = await ref.read(currentLocationServiceProvider).locate();
    if (!mounted) return;
    setState(() {
      _boundaryLocating = false;
      if (result.coordinate != null) _boundaryShowMyLocation = true;
    });
    final coordinate = result.coordinate;
    if (coordinate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Current location is unavailable.')),
      );
      return;
    }
    try {
      await _surfaceMapController?.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(coordinate.latitude, coordinate.longitude),
          16,
        ),
      );
    } on Object {
      // A recreating surface owns a stale controller; the session itself is
      // unaffected and the next locate attempt binds the fresh controller.
    }
  }

  /// During boundary mode every normal marker keeps its canonical visual.
  /// The working place marker must also stay visible even when its layer is
  /// toggled off or the place does not exist yet (Add flow): render it with
  /// its exact canonical identity, tap-suppressed like every other marker.
  List<MapMarker> _boundaryMarkers(
    List<MapMarker> markers,
    BoundaryEditSession session,
  ) {
    final snapshot = session.snapshot;
    final workingRecordId = switch (session.origin) {
      BoundaryEditOriginAdd() => 'boundary-working-place',
      BoundaryEditOriginEdit(:final place) => place.id,
    };
    final workingKey = MapCoordinateOwner.savedPlace.ownerKey(workingRecordId);
    // Edit mode: the persisted place marker IS the canonical working marker —
    // keep it untouched whenever it is already visible.
    if (markers.any((marker) => marker.ownerKey == workingKey)) {
      return markers;
    }
    final coordinate = switch (session.origin) {
      BoundaryEditOriginAdd(:final coordinate) => coordinate,
      BoundaryEditOriginEdit(:final place) => place.coordinate,
    };
    final workingMarker = MapMarker(
      owner: MapCoordinateOwner.savedPlace,
      recordId: workingRecordId,
      coordinate: coordinate,
      displayName: snapshot.label.isEmpty ? 'Place' : snapshot.label,
      colorValue: markerColorHexToArgb(snapshot.markerColorHex),
      placeMarkerMode: snapshot.markerMode,
      placeStandardCategory:
          snapshot.markerMode == SavedPlaceMarkerMode.standard
          ? snapshot.standardCategory
          : null,
      placeEmoji: snapshot.markerMode == SavedPlaceMarkerMode.custom
          ? snapshot.customEmoji
          : null,
    );
    return <MapMarker>[...markers, workingMarker];
  }

  /// Boundary-mode polygon overlay on the canonical map: the editing place's
  /// persisted polygon is REPLACED by a faint reference while the new outline
  /// is drawn; every other persisted boundary stays full-strength; the live
  /// draft rides on top.
  Set<Polygon> _boundaryOverlayPolygons(
    Set<Polygon> persisted,
    BoundaryEditSession session,
  ) {
    final overlay = <Polygon>{...persisted};
    final reference = switch (session.origin) {
      BoundaryEditOriginAdd() => null,
      BoundaryEditOriginEdit(:final place) => place.boundary,
    };
    if (reference != null) {
      final placeId = switch (session.origin) {
        BoundaryEditOriginEdit(:final place) => place.id,
        BoundaryEditOriginAdd() => null,
      };
      if (placeId != null) {
        overlay.removeWhere(
          (polygon) =>
              polygon.polygonId.value == 'saved-place-boundary-$placeId',
        );
      }
      overlay.add(boundaryReferencePolygon(reference));
    }
    if (boundaryDraftPolygon(
          vertices: session.controller.vertices,
          colorHex: session.snapshot.boundaryColorHex,
        )
        case final draftPolygon?) {
      overlay.add(draftPolygon);
    }
    return overlay;
  }

  void _invalidateMarkerOwner(MapCoordinateOwner owner) {
    ref.invalidate(mapOwnerMarkersProvider(owner));
    ref.invalidate(mapMarkersProvider);
    switch (owner) {
      case MapCoordinateOwner.contact:
        ref.invalidate(mapPeopleMarkersProvider);
      case MapCoordinateOwner.event:
        ref.invalidate(mapEventMarkersProvider);
        ref.invalidate(mapFocusedEventMarkersProvider);
      case MapCoordinateOwner.savedPlace:
        ref.invalidate(mapSavedPlaceMarkersProvider);
    }
    ref.invalidate(mapProjectedMarkersProvider);
  }
}

final class _MarkerLoadError extends StatelessWidget {
  const _MarkerLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('Maps could not be loaded'),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated host for the marker preview sheet: slides in from the bottom and
/// fades with the same drive that lifts the floating controls, so the two move
/// in sync instead of the sheet popping abruptly over a static control column.
final class _PreviewSheetHost extends StatelessWidget {
  const _PreviewSheetHost({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final value = Curves.easeOutCubic.transform(animation.value);
        return Transform.translate(
          offset: Offset(0, (1 - value) * 480),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: child,
    );
  }
}

/// Shared inline placement chrome: a fixed red center pin, a top helper bar,
/// and bottom X (cancel) + check (confirm). Used for both inline Edit Pin
/// Location and the dedicated Drop Pin flow. The map moves beneath the pin.
final class _PlacementChrome extends StatelessWidget {
  const _PlacementChrome({
    required this.helperText,
    required this.onCancel,
    required this.onConfirm,
  });

  final String helperText;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        IgnorePointer(
          child: Center(
            child: Transform.translate(
              offset: const Offset(0, -24),
              child: const Icon(
                Icons.location_pin,
                key: Key('maps-centering-pin'),
                color: Colors.red,
                size: 52,
                shadows: <Shadow>[Shadow(color: Colors.black38, blurRadius: 4)],
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                helperText,
                key: const Key('maps-centering-helper'),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 24,
          child: SafeArea(
            top: false,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: FloatingActionButton(
                    heroTag: null,
                    key: const Key('maps-centering-cancel'),
                    tooltip: 'Cancel',
                    onPressed: onCancel,
                    child: const Icon(Icons.close),
                  ),
                ),
                const SizedBox(width: 120),
                Expanded(
                  child: FloatingActionButton(
                    heroTag: null,
                    key: const Key('maps-centering-confirm'),
                    tooltip: 'Confirm',
                    onPressed: onConfirm,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    child: const Icon(Icons.check),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
