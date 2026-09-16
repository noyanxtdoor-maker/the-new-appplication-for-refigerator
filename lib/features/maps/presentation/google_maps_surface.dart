import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/contacts/presentation/c3_contact_primitives.dart';
import 'package:rmplanner/features/maps/application/current_location_service.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_interaction_trace.dart';
import 'package:rmplanner/features/maps/application/map_marker_target.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/application/map_session_provider.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_provider.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_repository.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/domain/saved_place.dart';
import 'package:rmplanner/features/maps/presentation/saved_place_marker_visuals.dart';
import 'package:rmplanner/features/planner/presentation/widgets/anchored_top_bar_popup.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';

export 'package:rmplanner/features/maps/application/map_session_provider.dart'
    show NextTransferMapType;

extension NextTransferMapTypePresentation on NextTransferMapType {
  String get label => switch (this) {
    NextTransferMapType.road => 'Road',
    NextTransferMapType.satellite => 'Satellite',
    NextTransferMapType.hybrid => 'Hybrid',
    NextTransferMapType.terrain => 'Terrain',
  };

  MapType get googleType => switch (this) {
    NextTransferMapType.road => MapType.normal,
    NextTransferMapType.satellite => MapType.hybrid,
    NextTransferMapType.hybrid => MapType.hybrid,
    NextTransferMapType.terrain => MapType.terrain,
  };
}

@visibleForTesting
double mapControlColumnBottom({
  required bool hasVisibleMarkers,
  required double previewLift,
  bool placementActive = false,
}) {
  final restingBottom = hasVisibleMarkers ? 24.0 : 112.0;
  final activeLift = math.max(
    previewLift.clamp(0.0, 276.0),
    placementActive ? 96.0 : 0.0,
  );
  return restingBottom + activeLift;
}

@visibleForTesting
Future<BitmapDescriptor> renderMapMarkerForTesting(
  MapMarker marker, {
  required bool selected,
}) => _GoogleMapsSurfaceState._buildMarkerIcon(marker, selected: selected);

@visibleForTesting
Future<BitmapDescriptor> renderSelectedGroupForTesting(
  Uint8List bitmap, {
  double width = 34,
  double height = 34,
}) => _GoogleMapsSurfaceState._composeSelectedGroup(
  bitmap,
  width: width,
  height: height,
);

final class GoogleMapsSurface extends ConsumerStatefulWidget {
  const GoogleMapsSurface({
    super.key,
    required this.markers,
    required this.initialCoordinate,
    required this.onMarkerTap,
    this.provisionalPlaceCoordinate,
    this.onMapLongPress,
    this.onMapTap,
    this.onDropPin,
    this.onCameraCenterChanged,
    this.placementTarget,
    this.placementActive = false,
    this.controlsLift,
    this.mapBuilder,
    this.polygons = const <Polygon>{},
    this.circles = const <Circle>{},
    this.onMapTapCoordinate,
    this.controlsEnabled = true,
    this.interactionPaused = false,
    this.myLocationOverride,
    this.onMapController,
  });

  final List<MapMarker> markers;
  final MapCoordinate? initialCoordinate;
  final ValueChanged<MapMarker> onMarkerTap;
  final MapCoordinate? provisionalPlaceCoordinate;
  final ValueChanged<MapCoordinate>? onMapLongPress;
  final VoidCallback? onMapTap;
  final VoidCallback? onDropPin;

  /// VS-15 M6.1: persisted Saved Place boundary polygons, projected by
  /// [savedPlacePolygonsProvider]. Purely additive ground-layer visuals —
  /// tap-consuming off, no onTap wiring — so markers, clusters and the
  /// frozen M3 native precision-tap pipeline are untouched.
  final Set<Polygon> polygons;

  /// VS-15 M6.1 Pass 2: editor-only vertex handles for the same-map Define
  /// Boundary mode. Purely additive; never enters the marker/cluster pipeline.
  final Set<Circle> circles;

  /// VS-15 M6.1 Pass 2: when non-null, a plain map tap reports its exact
  /// coordinate to the owner (boundary vertex) instead of running the normal
  /// selection/clear path. The owning screen sets this ONLY in boundary mode.
  final ValueChanged<MapCoordinate>? onMapTapCoordinate;

  /// VS-15 M6.1 Pass 2: hides the floating control column while an owning
  /// same-map session provides its own chrome (Drop Pin/Map Type suppressed,
  /// Current Location rendered by the session chrome).
  final bool controlsEnabled;

  /// VS-15 M6.1 Pass 2: temporarily pauses the native precision-tap patch
  /// (and marker/cluster selection callbacks) while the same-map Define
  /// Boundary mode owns map taps. Resuming re-applies the stored selection.
  /// The native patch code itself is byte-untouched; only the existing
  /// `configure(enabled:)` channel command is driven by this flag.
  final bool interactionPaused;

  /// VS-15 M6.1 Pass 2: explicit override for the blue-dot visibility while
  /// an owning same-map session locates (null keeps the canonical behavior).
  final bool? myLocationOverride;

  /// VS-15 M6.1 Pass 2: reports the live GoogleMapController so an owning
  /// same-map session can run its own Current Location camera animation on
  /// the SAME map (never creating a second map instance).
  final ValueChanged<GoogleMapController>? onMapController;

  /// Reports the live camera target so an owning inline edit / drop-pin
  /// session can persist the exact center on confirm without its own map.
  final ValueChanged<MapCoordinate>? onCameraCenterChanged;

  /// One explicit same-surface placement command. Entering Edit Pin Location
  /// centers the existing marker without changing zoom, bearing, or tilt.
  /// Direct marker selection never supplies this value and remains camera-free.
  final MapCoordinate? placementTarget;

  /// Lifts the complete three-control family clear of the placement X/check
  /// chrome. The owning screen changes this only for inline placement modes.
  final bool placementActive;

  /// Drives the floating map controls upward smoothly as the preview sheet
  /// rises; maps to the DraggableScrollableSheet extent in the owning screen.
  final ValueListenable<double>? controlsLift;
  final Widget Function(BuildContext, List<MapMarker>)? mapBuilder;

  @override
  ConsumerState<GoogleMapsSurface> createState() => _GoogleMapsSurfaceState();
}

final class _GoogleMapsSurfaceState extends ConsumerState<GoogleMapsSurface>
    with WidgetsBindingObserver {
  static const double _markerEdgeWidth = 2;
  static const double _markerLogicalSize = 34;
  // Selected-marker composition constants. The pin lives entirely in the
  // bitmap space added ABOVE the unchanged identity zone, so the default
  // bottom-center Google anchor keeps the base record pixel-stable.
  // M3.1 final alignment: the pin is moderately larger and its tip reaches
  // deeper into the identity's upper half so the composition reads as one
  // selected-state pin meeting the marker, per the approved PMG reference.
  static const double _selectedPinCanvasExtension = 80;
  static const double _selectedPinGlyphSize = 96;
  static const double _selectedIdentityRadius = 35;
  static const ClusterManagerId _peopleClusterId = ClusterManagerId(
    'maps-people',
  );
  static const ClusterManagerId _eventsClusterId = ClusterManagerId(
    'maps-events',
  );
  static const ClusterManagerId _placesClusterId = ClusterManagerId(
    'maps-places',
  );
  late final Set<ClusterManager> _clusterManagers = <ClusterManager>{
    for (final id in [_peopleClusterId, _eventsClusterId, _placesClusterId])
      ClusterManager(clusterManagerId: id, onClusterTap: _onClusterTap),
  };
  MethodChannel? _interactionChannel;
  int _selectionGeneration = 0;
  int _lastNativeToken = 0;
  String? _targetExclusion;
  List<MapMarker>? _targetInput;
  List<MapMarkerTarget> _targets = const [];
  final Map<String, Marker> _normalMarkers = {};

  // No Dart camera command is issued here. The installed Android plugin's
  // onClusterClick returns false; suppressing native default click behavior
  // requires an upstream dependency change outside this pass.
  void _onClusterTap(Cluster cluster) {
    final targets = {
      for (final target in _interactionTargets) target.key: target,
    };
    _selectGroup(
      [
        for (final id in cluster.markerIds)
          if (targets[id.value] case final target?) ...target.members,
      ],
      MapMarkerGrouping.zoomCluster,
      origin: MapMarkerGroupContext(
        members: [
          for (final id in cluster.markerIds)
            if (targets[id.value] case final target?) ...target.members,
        ],
        position: MapCoordinate(
          latitude: cluster.position.latitude,
          longitude: cluster.position.longitude,
        ),
        nativeMarkerIds: cluster.markerIds.map((id) => id.value).toList(),
      ),
    );
  }

  void _selectGroup(
    List<MapMarker> members,
    MapMarkerGrouping grouping, {
    MapMarkerGroupContext? origin,
  }) {
    // Same-map Define Boundary mode owns map taps; marker selection is
    // temporarily suppressed (markers stay visible, never selected).
    if (widget.interactionPaused) return;
    if (members.isEmpty) return; // Ignore a stale native callback.
    if (members.length == 1) {
      _selectMarker(members.single);
    } else {
      ref
          .read(mapSelectedMarkerProvider.notifier)
          .selectGroup(members, grouping, origin: origin);
    }
  }

  void _selectMarker(MapMarker marker) {
    // Same-map Define Boundary mode owns map taps; marker selection is
    // temporarily suppressed (markers stay visible, never selected).
    if (widget.interactionPaused) return;
    ref.read(mapSelectedMarkerProvider.notifier).select(marker);
    widget.onMarkerTap(marker);
  }

  List<MapMarkerTarget> get _interactionTargets {
    final visible = _visibleMarkerData;
    final exclusion = ref.read(mapSelectedMarkerProvider)?.excludedOwnerKey;
    final grouping = _groupNearby;
    final dataChanged = !listEquals(_targetInput, visible);
    final groupingChanged = grouping != _lastGroupingMode;
    if (dataChanged || groupingChanged || _targetExclusion != exclusion) {
      _targetInput = visible;
      _targetExclusion = exclusion;
      _lastGroupingMode = grouping;
      // Grouping ON: the accepted exact-coordinate aggregate pipeline.
      // Grouping OFF: one target per visible record, no aggregates, and the
      // selected stable owner key is still excluded exactly as current logic
      // requires.
      _targets = grouping
          ? exactCoordinateTargets(visible, excludedOwnerKey: exclusion)
          : <MapMarkerTarget>[
              for (final marker in visible)
                if (marker.ownerKey != exclusion)
                  MapMarkerTarget(<MapMarker>[marker]),
            ];
      // CRITICAL cache safety: an OFF marker must never reuse an ON Marker
      // carrying a stale clusterManagerId (and vice versa), so a grouping
      // transition clears the normal-marker cache exactly like data change.
      if (dataChanged || groupingChanged) {
        _normalMarkers.clear();
      } else {
        _normalMarkers.removeWhere(
          (key, _) => key.startsWith('maps-location:'),
        );
      }
    }
    return _targets;
  }

  void _reconcileGroup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref
            .read(mapSelectedMarkerProvider.notifier)
            .retainVisibleGroupMembers(_visibleMarkerData);
      }
    });
  }

  /// Selection transition law (M6.2): when grouping turns OFF while a GROUP
  /// is selected, that group selection is safely cleared; an individual
  /// selection may remain when its stable identity is still valid. Every
  /// durable preference change also reconciles open groups against the new
  /// visibility.
  void _onMapsPreferencesChanged(
    MapsPreferencesModel? previous,
    MapsPreferencesModel next,
  ) {
    if (previous?.groupNearbyMarkers == true &&
        next.groupNearbyMarkers == false) {
      final selection = ref.read(mapSelectedMarkerProvider);
      if (selection?.isGroup == true) {
        ref.read(mapSelectedMarkerProvider.notifier).clear();
      }
    }
    _reconcileGroup();
  }

  GoogleMapController? _controller;
  NextTransferMapType get _mapType => ref.read(mapsSessionProvider).mapType;
  late final CameraPosition _initialCameraPosition;
  late CameraPosition _lastCameraPosition;
  bool _startupCameraClaimed = false;
  int? _lastDispatchedFocusNonce;
  bool _locating = false;
  bool _showMyLocation = false;

  /// True after an explicit Locate whose permission Android is blocking.  A
  /// resume that finds Location now enabled continues the SAME intent, so the
  /// user never has to leave Maps, reopen it and find Locate again.
  bool _locateIntentPending = false;

  /// Bounded base-map readiness watchdog — the only honest signal Dart has.
  /// If the platform view never reports a created controller inside the window
  /// the map surface did not come up; this NEVER claims to detect a native
  /// tile/authorization failure, which is invisible from Dart.
  Timer? _mapReadyWatchdog;
  bool _mapLoadFailed = false;
  int _mapGeneration = 0;

  static const Duration _mapReadyTimeout = Duration(seconds: 12);
  // VS-15 M6.2: layer visibility and grouping derive from the ONE durable
  // MapsPreferences provider (device-scoped). The old independent local
  // booleans are retired — a recreated surface cannot reset a user choice.
  bool get _showPeople => ref.read(mapsPreferencesProvider).showContacts;
  bool get _showEvents => ref.read(mapsPreferencesProvider).showEvents;
  bool get _showPlaces => ref.read(mapsPreferencesProvider).showSavedPlaces;
  bool get _groupNearby => ref.read(mapsPreferencesProvider).groupNearbyMarkers;
  bool _lastGroupingMode = true;
  int _cameraIntent = 0;
  bool _appliedPassiveCoordinate = false;
  final GlobalKey _mapTypeAnchorKey = GlobalKey();
  static final Map<String, BitmapDescriptor> _markerIcons =
      <String, BitmapDescriptor>{};
  static final Map<String, Future<BitmapDescriptor>> _loadingMarkerIcons = {};
  static final Map<int, BitmapDescriptor> _aggregateIcons = {};
  static final Map<int, BitmapDescriptor> _selectedAggregateIcons = {};
  final Set<int> _loadingSelectedAggregates = {};
  static final Map<String, BitmapDescriptor> _separatedRemainderIcons = {};
  final Set<String> _loadingSeparatedRemainders = {};
  static final Map<int, Future<BitmapDescriptor>> _loadingAggregateIcons = {};

  @override
  void initState() {
    super.initState();
    final session = ref.read(mapsSessionProvider);
    final initial = widget.initialCoordinate;
    _initialCameraPosition =
        session.camera ??
        CameraPosition(
          target: LatLng(initial?.latitude ?? 20, initial?.longitude ?? 0),
          zoom: initial == null ? 1.4 : 16,
        );
    _lastCameraPosition = _initialCameraPosition;
    _startupCameraClaimed = session.camera != null;
    _appliedPassiveCoordinate = session.camera != null || initial != null;
    _showMyLocation = initial != null;
    ref.listenManual(mapTransientFocusProvider, (_, focusState) {
      final request = focusState.pending;
      if (request != null) {
        unawaited(_handleFocus(request));
      }
    });
    unawaited(_primeMarkerIcons());
    ref.listenManual(mapSelectedMarkerProvider, (_, selection) {
      _cameraIntent += 1; // A late navigation result cannot replace a new tap.
      _selectionGeneration += 1;
      unawaited(_syncNativeSelection(selection, _selectionGeneration));
      unawaited(_primeSelectedIcon(selection));
      if (mounted) setState(() {});
    });
    ref.listenManual(mapsPreferencesProvider, _onMapsPreferencesChanged);
    WidgetsBinding.instance.addObserver(this);
    _armMapReadyWatchdog();
  }

  /// Armed only for the REAL platform map.  A test double that injects a
  /// `mapBuilder` never creates a platform view, so it must never trip the
  /// watchdog.
  void _armMapReadyWatchdog() {
    _mapReadyWatchdog?.cancel();
    _mapReadyWatchdog = null;
    if (widget.mapBuilder != null) {
      return;
    }
    _mapReadyWatchdog = Timer(_mapReadyTimeout, () {
      if (!mounted || _controller != null) {
        return;
      }
      setState(() => _mapLoadFailed = true);
    });
  }

  /// Recreates the platform view instead of recycling a dead one.  The
  /// generation is part of the GoogleMap key, so Flutter disposes the old
  /// view and builds a fresh one.
  void _retryMapLoad() {
    setState(() {
      _mapLoadFailed = false;
      _mapGeneration += 1;
      _controller = null;
    });
    _armMapReadyWatchdog();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_locateIntentPending) {
      return;
    }
    unawaited(_resumePendingLocate());
  }

  /// Passive recovery only — it NEVER prompts.  If the user turned Location on
  /// in Android Settings and came back, the pending Locate continues on its
  /// own.  Uses the existing no-prompt capability, never background location.
  Future<void> _resumePendingLocate() async {
    if (_locating || !mounted) {
      return;
    }
    final service = ref.read(currentLocationServiceProvider);
    if (service is! PassiveCurrentLocationService) {
      return;
    }
    final result = await (service as PassiveCurrentLocationService)
        .locateIfAlreadyGranted();
    if (!mounted || result.status != CurrentLocationStatus.located) {
      return;
    }
    final coordinate = result.coordinate;
    if (coordinate == null) {
      return;
    }
    _locateIntentPending = false;
    _startupCameraClaimed = true;
    _cameraIntent += 1;
    setState(() => _showMyLocation = true);
    await _animateTo(coordinate, zoom: 16);
  }

  @override
  void didUpdateWidget(covariant GoogleMapsSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.markers, widget.markers) ||
        oldWidget.provisionalPlaceCoordinate !=
            widget.provisionalPlaceCoordinate) {
      unawaited(_primeMarkerIcons());
      _reconcileGroup();
    }
    final coordinate = widget.initialCoordinate;
    if (coordinate != null && oldWidget.initialCoordinate != coordinate) {
      unawaited(_applyPassiveCoordinate(coordinate));
    }
    final placementTarget = widget.placementTarget;
    if (placementTarget != null &&
        oldWidget.placementTarget != placementTarget) {
      unawaited(_moveToPlacementTarget(placementTarget));
    }
    if (oldWidget.interactionPaused != widget.interactionPaused) {
      unawaited(_syncInteractionPaused(widget.interactionPaused));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mapReadyWatchdog?.cancel();
    _mapReadyWatchdog = null;
    _interactionChannel?.setMethodCallHandler(null);
    _controller?.dispose();
    super.dispose();
  }

  List<MapMarker> get _visibleMarkerData {
    final focusedKey = ref
        .read(mapTransientFocusProvider)
        .visibilityLease
        ?.markerKey;
    // Define Boundary editor exception (M6.2): while the same-map boundary
    // editor is active, the working Saved Place marker stays visible even
    // when the Saved Places layer preference is OFF — the editor must never
    // be made impossible by layer visibility.
    final boundaryEditorActive = widget.interactionPaused;
    return widget.markers
        .where(
          (marker) =>
              marker.ownerKey == focusedKey ||
              (marker.owner == MapCoordinateOwner.contact && _showPeople) ||
              (marker.owner == MapCoordinateOwner.event && _showEvents) ||
              (marker.owner == MapCoordinateOwner.savedPlace &&
                  (_showPlaces || boundaryEditorActive)),
        )
        .toList(growable: false);
  }

  Set<Marker> get _markers {
    final selection = ref.read(mapSelectedMarkerProvider);
    final selectedKey = selection?.excludedOwnerKey;
    final result = <Marker>{};
    for (final target in _interactionTargets) {
      final marker = target.members.first;
      if (target.isAggregate) {
        final count = target.members.length;
        final selectedGroup =
            selection?.isGroup == true &&
            selection!.grouping == MapMarkerGrouping.exactCoordinate &&
            target.coordinate == selection.origin?.position;
        if (selectedGroup && !_selectedAggregateIcons.containsKey(count)) {
          unawaited(_primeSelectedAggregateIcon(count));
        }
        final separateRemainder =
            selectedKey != null &&
            _visibleMarkerData.any(
              (member) =>
                  member.ownerKey == selectedKey &&
                  member.coordinate == target.coordinate,
            );
        final remainderKey = '$count:$selectedGroup';
        if (separateRemainder &&
            !_separatedRemainderIcons.containsKey(remainderKey)) {
          unawaited(_primeSeparatedRemainder(count, selectedGroup));
        }
        final icon =
            (separateRemainder
                ? _separatedRemainderIcons[remainderKey]
                : null) ??
            (selectedGroup ? _selectedAggregateIcons[count] : null) ??
            _aggregateIcons[count];
        if (!_aggregateIcons.containsKey(count)) {
          unawaited(_primeAggregateIcon(count));
        }
        final cached = _normalMarkers[target.key];
        result.add(
          cached != null && cached.icon == icon
              ? cached
              : _normalMarkers[target.key] = Marker(
                  markerId: MarkerId(target.key),
                  position: LatLng(
                    target.coordinate.latitude,
                    target.coordinate.longitude,
                  ),
                  icon: icon ?? BitmapDescriptor.defaultMarker,
                  consumeTapEvents: true,
                  clusterManagerId: selectedGroup
                      ? null
                      : _clusterIdFor(marker.owner),
                  zIndexInt: selectedGroup ? 20 : 0,
                  onTap: () => _selectGroup(
                    target.members,
                    MapMarkerGrouping.exactCoordinate,
                  ),
                ),
        );
      } else {
        result.add(_recordMarker(marker, false));
      }
    }
    if (selectedKey != null) {
      for (final marker in _visibleMarkerData) {
        if (marker.ownerKey == selectedKey) {
          final selected = _recordMarker(marker, selection?.isGroup == false);
          // A selected remainder group keeps the former member outside it,
          // without a second red pin or duplicated cluster membership.
          result.add(
            selection?.isGroup == true
                ? Marker(
                    markerId: selected.markerId,
                    position: selected.position,
                    icon: selected.icon,
                    consumeTapEvents: true,
                    infoWindow: selected.infoWindow,
                    onTap: selected.onTap,
                  )
                : selected,
          );
          break;
        }
      }
    }
    final provisional = widget.provisionalPlaceCoordinate;
    if (provisional != null) {
      final marker = _provisionalMarker(provisional);
      result.add(
        Marker(
          markerId: const MarkerId('provisional-place'),
          position: LatLng(provisional.latitude, provisional.longitude),
          icon:
              _markerIcons[_markerIconKey(marker, false)] ??
              BitmapDescriptor.defaultMarker,
          zIndexInt: 30,
          flat: false,
        ),
      );
    }
    return result;
  }

  Marker _recordMarker(MapMarker marker, bool selected) {
    final normalIcon =
        _markerIcons[_markerIconKey(marker, false)] ??
        BitmapDescriptor.defaultMarker;
    var normal = _normalMarkers[marker.ownerKey];
    if (normal == null || normal.icon != normalIcon) {
      normal = _normalMarkers[marker.ownerKey] = Marker(
        markerId: MarkerId(marker.ownerKey),
        position: LatLng(
          marker.coordinate.latitude,
          marker.coordinate.longitude,
        ),
        infoWindow: InfoWindow(title: marker.displayName),
        consumeTapEvents: true,
        flat: false,
        icon: normalIcon,
        clusterManagerId: _groupNearby ? _clusterIdFor(marker.owner) : null,
        onTap: () => _selectMarker(marker),
      );
    }
    if (!selected) return normal;
    // Keep the accepted direct-selection anchor and native cluster exclusion.
    return Marker(
      markerId: normal.markerId,
      position: normal.position,
      infoWindow: normal.infoWindow,
      consumeTapEvents: true,
      flat: false,
      icon: _markerIcons[_markerIconKey(marker, true)] ?? normalIcon,
      zIndexInt: 20,
      onTap: normal.onTap,
    );
  }

  ClusterManagerId _clusterIdFor(MapCoordinateOwner owner) => switch (owner) {
    MapCoordinateOwner.contact => _peopleClusterId,
    MapCoordinateOwner.event => _eventsClusterId,
    MapCoordinateOwner.savedPlace => _placesClusterId,
  };

  MapMarker _provisionalMarker(MapCoordinate coordinate) => MapMarker(
    owner: MapCoordinateOwner.savedPlace,
    recordId: 'provisional',
    coordinate: coordinate,
    displayName: 'New Place',
    colorValue: AppTheme.blueLightPrimary.toARGB32(),
  );

  Future<void> _onMapCreated(GoogleMapController controller) async {
    _mapReadyWatchdog?.cancel();
    _mapReadyWatchdog = null;
    _controller = controller;
    if (_mapLoadFailed && mounted) {
      setState(() => _mapLoadFailed = false);
    }
    widget.onMapController?.call(controller);
    ref.read(mapsSessionProvider.notifier).recordCamera(_initialCameraPosition);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _interactionChannel = MethodChannel(
        'nexttransfer/maps_interaction/${controller.mapId}',
      );
      _interactionChannel!.setMethodCallHandler(_onNativeInteraction);
      await _interactionChannel!.invokeMethod<void>('configure', {
        'enabled': !widget.interactionPaused,
        'trace': MapInteractionTrace.enabled,
      });
      if (!mounted) return;
      await _syncNativeSelection(
        ref.read(mapSelectedMarkerProvider),
        _selectionGeneration,
      );
    }
    if (widget.placementTarget case final placementTarget?) {
      await _moveToPlacementTarget(placementTarget);
      return;
    }
    final focus = ref.read(mapTransientFocusProvider).pending;
    if (focus != null) {
      await _handleFocus(focus);
    } else if (widget.initialCoordinate case final coordinate?) {
      await _applyPassiveCoordinate(coordinate);
    }
  }

  Future<void> _handleFocus(MapFocusRequest request) async {
    if (_controller == null || _lastDispatchedFocusNonce == request.nonce) {
      return;
    }
    _lastDispatchedFocusNonce = request.nonce;
    _startupCameraClaimed = true;
    final intent = ++_cameraIntent;
    final animation = _animateTo(
      request.coordinate,
      zoom: 15,
      duration: const Duration(milliseconds: 650),
    );
    // Consume after dispatch, not after an asynchronous completion: tab
    // recreation must never replay a camera command already sent to Maps.
    ref.read(mapTransientFocusProvider.notifier).consume(request.nonce);
    await animation;
    if (!mounted || intent != _cameraIntent) return;
    if (request.ownerKind == MapFocusOwnerKind.savedPlace) {
      for (final marker in widget.markers) {
        if (marker.ownerKey == request.markerKey) {
          ref.read(mapSelectedMarkerProvider.notifier).select(marker);
          break;
        }
      }
    }
  }

  static String _markerIconKey(MapMarker marker, bool selected) => <Object?>[
    marker.owner.name,
    marker.colorValue,
    marker.isFavorite,
    marker.placeMarkerMode,
    marker.placeStandardCategory,
    marker.placeEmoji,
    selected,
  ].join(':');

  Future<void> _primeMarkerIcons() async {
    unawaited(_primeSelectedIcon(ref.read(mapSelectedMarkerProvider)));
    final unique = <String, MapMarker>{
      for (final marker in widget.markers)
        _markerIconKey(marker, false): marker,
      if (widget.provisionalPlaceCoordinate case final point?)
        _markerIconKey(_provisionalMarker(point), false): _provisionalMarker(
          point,
        ),
    };
    await Future.wait([
      for (final marker in unique.values) _loadMarkerIcon(marker, false),
    ]);
    if (!mounted) return;
    setState(() {});
    // Warm each visual identity once, not once per record/occurrence. Direct
    // taps can join an in-flight request without waiting for this queue.
    for (final marker in unique.values) {
      if (!mounted) return;
      await _loadMarkerIcon(marker, true);
    }
  }

  Future<void> _primeSelectedIcon(MapSelectedMarker? selection) async {
    if (selection == null || selection.isGroup) return;
    final marker = selection.marker;
    final gesture = MapInteractionTrace.token;
    if (_markerIcons.containsKey(_markerIconKey(marker, true))) {
      MapInteractionTrace.record(
        'T2',
        marker.ownerKey,
        gesture: gesture,
        extra: 'cache-hit',
      );
      return;
    }
    await _loadMarkerIcon(marker, true);
    MapInteractionTrace.record(
      'T2',
      marker.ownerKey,
      gesture: gesture,
      extra: 'bitmap-ready',
    );
    // Bitmaps never write selection. A stale completion only warms the cache.
    if (mounted && identical(ref.read(mapSelectedMarkerProvider), selection)) {
      setState(() {});
    }
  }

  static Future<BitmapDescriptor> _loadMarkerIcon(
    MapMarker marker,
    bool selected,
  ) {
    final key = _markerIconKey(marker, selected);
    final cached = _markerIcons[key];
    if (cached != null) return Future.value(cached);
    return _loadingMarkerIcons.putIfAbsent(key, () async {
      try {
        final icon = await _buildMarkerIcon(marker, selected: selected);
        _markerIcons[key] = icon;
        return icon;
      } finally {
        unawaited(_loadingMarkerIcons.remove(key));
      }
    });
  }

  Future<void> _primeAggregateIcon(int count) async {
    final icon = await _loadingAggregateIcons.putIfAbsent(count, () async {
      const size = 96.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawCircle(
        const Offset(48, 48),
        41,
        Paint()..color = const Color(0xFF175A8F),
      );
      canvas.drawCircle(
        const Offset(48, 48),
        41,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      _paintText(
        canvas,
        '$count',
        const Offset(48, 48),
        Offset(48, count < 100 ? 40 : 28),
        color: Colors.white,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(size.toInt(), size.toInt());
      picture.dispose();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes == null
          ? BitmapDescriptor.defaultMarker
          : BitmapDescriptor.bytes(
              bytes.buffer.asUint8List(),
              width: _markerLogicalSize,
              height: _markerLogicalSize,
            );
    });
    _aggregateIcons[count] = icon;
    if (mounted) setState(() {});
  }

  Future<void> _onNativeInteraction(MethodCall call) async {
    if (!mounted || call.method != 'tap') return;
    final data = Map<Object?, Object?>.from(call.arguments as Map);
    final token = (data['token'] as num).toInt();
    if (token <= _lastNativeToken) return;
    _lastNativeToken = token;
    MapInteractionTrace.nativeTap(
      _controller!.mapId,
      token,
      (data['renderGeneration'] as num).toInt(),
    );
    final targets = {
      for (final target in _interactionTargets) target.key: target,
    };
    final recordId = data['recordId'] as String?;
    if (recordId != null) {
      final target = targets[recordId];
      if (target != null) {
        _selectGroup(target.members, MapMarkerGrouping.exactCoordinate);
      } else {
        // The selected individual is intentionally outside the target set.
        for (final marker in _visibleMarkerData) {
          if (marker.ownerKey == recordId) {
            _selectMarker(marker);
            break;
          }
        }
      }
      return;
    }
    final ids = (data['ids'] as List?)?.cast<String>() ?? const <String>[];
    if (ids.isEmpty) {
      if (widget.onMapTap != null) {
        widget.onMapTap!();
      } else {
        ref.read(mapSelectedMarkerProvider.notifier).clear();
      }
      return;
    }
    // Reject stale native membership rather than reopening an older group.
    if (ids.any((id) => !targets.containsKey(id))) return;
    final members = [for (final id in ids) ...targets[id]!.members];
    _selectGroup(
      members,
      MapMarkerGrouping.zoomCluster,
      origin: MapMarkerGroupContext(
        members: members,
        position: MapCoordinate(
          latitude: (data['latitude'] as num).toDouble(),
          longitude: (data['longitude'] as num).toDouble(),
        ),
        nativeMarkerIds: ids,
        nativeGroupKey: data['groupKey'] as String?,
        bitmap: data['bitmap'] as Uint8List?,
        width: (data['width'] as num?)?.toDouble() ?? 34,
        height: (data['height'] as num?)?.toDouble() ?? 34,
      ),
    );
  }

  Future<void> _syncNativeSelection(
    MapSelectedMarker? selection,
    int generation,
  ) async {
    final channel = _interactionChannel;
    if (channel == null) return;
    final origin = selection?.origin;
    final exclusion = selection?.excludedOwnerKey;
    final liveTargets = _interactionTargets.map((target) => target.key).toSet();
    final remainderIds = exclusion == null
        ? <String>[]
        : [
            for (final id in origin?.nativeMarkerIds ?? const <String>[])
              if (id != exclusion && liveTargets.contains(id)) id,
          ];
    final groupKey = selection?.isGroup == true ? origin?.nativeGroupKey : null;
    final args = <String, Object?>{
      'generation': generation,
      'selectedOwnerId': exclusion,
      'selectedManagerId': selection == null
          ? null
          : _clusterIdFor(selection.marker.owner).value,
      'inferRemainder':
          selection != null && !selection.isGroup && origin == null,
      'remainderIds': remainderIds,
      'groupKey': groupKey,
    };
    await channel.invokeMethod<void>('selection', args);
    if (groupKey == null || origin?.bitmap == null) return;
    final gesture = MapInteractionTrace.token;
    final bitmap =
        await _composeSelectedGroup(
              origin!.bitmap!,
              width: origin.width,
              height: origin.height,
            )
            as BytesMapBitmap;
    if (!mounted ||
        generation != _selectionGeneration ||
        !identical(ref.read(mapSelectedMarkerProvider), selection)) {
      return;
    }
    MapInteractionTrace.record(
      'T2',
      groupKey,
      gesture: gesture,
      extra: 'group-pin-ready',
    );
    await channel.invokeMethod<void>('selection', {
      ...args,
      'groupPin': bitmap.byteData,
      'width': bitmap.width,
      'height': bitmap.height,
    });
  }

  Future<void> _primeSeparatedRemainder(int count, bool selected) async {
    final key = '$count:$selected';
    if (!_loadingSeparatedRemainders.add(key)) return;
    try {
      if (!_aggregateIcons.containsKey(count)) await _primeAggregateIcon(count);
      if (selected && !_selectedAggregateIcons.containsKey(count)) {
        await _primeSelectedAggregateIcon(count);
      }
      final base = selected
          ? _selectedAggregateIcons[count]
          : _aggregateIcons[count];
      if (base is! BytesMapBitmap) return;
      final codec = await ui.instantiateImageCodec(base.byteData);
      final input = (await codec.getNextFrame()).image;
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImage(input, Offset.zero, Paint());
      final picture = recorder.endRecording();
      final image = await picture.toImage(input.width * 3, input.height);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      _separatedRemainderIcons[key] = BitmapDescriptor.bytes(
        bytes!.buffer.asUint8List(),
        width: _markerLogicalSize * 3,
        height: base.height,
      );
      // The anchor and LatLng are unchanged. Only this remainder's painted
      // count sits 34 logical px left of the shared anchor, clear of the
      // individual. Native alpha picking rejects the transparent canvas.
      input.dispose();
      image.dispose();
      picture.dispose();
      codec.dispose();
      if (mounted) setState(() {});
    } finally {
      _loadingSeparatedRemainders.remove(key);
    }
  }

  Future<void> _primeSelectedAggregateIcon(int count) async {
    if (!_loadingSelectedAggregates.add(count)) return;
    try {
      if (!_aggregateIcons.containsKey(count)) await _primeAggregateIcon(count);
      final base = _aggregateIcons[count];
      if (base is! BytesMapBitmap) return;
      _selectedAggregateIcons[count] = await _composeSelectedGroup(
        base.byteData,
        width: 34,
        height: 34,
      );
      if (mounted) setState(() {});
    } finally {
      _loadingSelectedAggregates.remove(count);
    }
  }

  /// Reuse the frozen pin painter at its accepted logical scale. The native
  /// count bitmap keeps its original pixels/size and bottom-center anchor.
  static Future<BitmapDescriptor> _composeSelectedGroup(
    Uint8List bytes, {
    required double width,
    required double height,
  }) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final base = (await codec.getNextFrame()).image;
    final ratio = base.width / width;
    final extension = _selectedPinCanvasExtension * _markerLogicalSize / 96;
    final outputHeight = height + extension;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(base, Offset(0, extension * ratio), Paint());
    final scale = ratio * _markerLogicalSize / 96;
    canvas.save();
    canvas.scale(scale);
    final identityCenter = Offset(
      base.width / scale / 2,
      (extension * ratio + base.height / 2) / scale,
    );
    _paintSelectedLocationPinGlyph(
      canvas,
      Offset(
        identityCenter.dx,
        identityCenter.dy -
            _selectedIdentityRadius -
            _selectedPinGlyphSize / 2 +
            32,
      ),
    );
    canvas.restore();
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      base.width,
      (outputHeight * ratio).ceil(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    base.dispose();
    codec.dispose();
    return BitmapDescriptor.bytes(
      data!.buffer.asUint8List(),
      width: width,
      height: outputHeight,
    );
  }

  static Future<BitmapDescriptor> _buildMarkerIcon(
    MapMarker marker, {
    required bool selected,
  }) async {
    const size = 96.0;
    // Selection extends the bitmap UPWARD only. The identity keeps its exact
    // unselected canvas position (48 bitmap pixels above the bottom map
    // anchor), so the base record never moves to another geographic position
    // when selection changes and the red pin can sit directly above it.
    final canvasHeight = selected ? size + _selectedPinCanvasExtension : size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final identityCenter = Offset(size / 2, canvasHeight - size / 2);
    final color = Color(marker.colorValue);
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = _markerEdgeWidth;
    if (marker.owner == MapCoordinateOwner.contact && marker.isFavorite) {
      final star = _starPath(identityCenter, 38, 16);
      canvas.drawPath(
        star.shift(const Offset(0, 3)),
        Paint()
          ..color = Colors.black.withValues(alpha: .24)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawPath(star, fill);
      canvas.drawPath(star, outline);
    } else if (marker.owner == MapCoordinateOwner.contact) {
      canvas.drawCircle(identityCenter, 35, fill);
      canvas.drawCircle(identityCenter, 35, outline);
    } else if (marker.owner == MapCoordinateOwner.event) {
      final eventRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: identityCenter, width: 66, height: 66),
        const Radius.circular(14),
      );
      canvas.drawRRect(eventRect, fill);
      canvas.drawRRect(eventRect, outline);
      canvas.drawLine(
        Offset(identityCenter.dx - 18, identityCenter.dy - 10),
        Offset(identityCenter.dx + 18, identityCenter.dy - 10),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );
      final calendarInk = Paint()..color = Colors.white;
      for (final x in <double>[-11, 11]) {
        canvas.drawLine(
          Offset(identityCenter.dx + x, identityCenter.dy - 27),
          Offset(identityCenter.dx + x, identityCenter.dy - 18),
          Paint()
            ..color = Colors.white
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round,
        );
      }
      for (final point in <Offset>[
        Offset(identityCenter.dx - 11, identityCenter.dy + 3),
        Offset(identityCenter.dx + 11, identityCenter.dy + 3),
        Offset(identityCenter.dx - 11, identityCenter.dy + 17),
        Offset(identityCenter.dx + 11, identityCenter.dy + 17),
      ]) {
        canvas.drawCircle(point, 4, calendarInk);
      }
    } else {
      _paintPlaceIdentity(canvas, marker, identityCenter);
    }
    if (selected) {
      // Tighten only the bitmap composition. The base center and the Google
      // bottom-center anchor stay unchanged. Paint the semantic red pin last
      // so only its tip meets the identity; no record color enters its head.
      final identityTop = identityCenter.dy - _selectedIdentityRadius;
      _paintSelectedLocationPinGlyph(
        canvas,
        Offset(size / 2, identityTop - _selectedPinGlyphSize / 2 + 32),
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), canvasHeight.toInt());
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return BitmapDescriptor.defaultMarker;
    return BitmapDescriptor.bytes(
      data.buffer.asUint8List(),
      width: _markerLogicalSize,
      height: _markerLogicalSize * canvasHeight / size,
    );
  }

  /// Draws the Saved Place identity as an upright, screen-facing square in the
  /// persisted color; from the marker's mode it renders either the category
  /// glyph concept or the custom emoji inside the white center disc. A thin
  /// white edge preserves separation without replacing the identity.
  static void _paintPlaceIdentity(
    Canvas canvas,
    MapMarker marker,
    Offset identityCenter,
  ) {
    final identity = SavedPlaceVisualIdentity.resolve(
      mode: marker.placeMarkerMode ?? SavedPlaceMarkerMode.standard,
      category:
          marker.placeStandardCategory ??
          SavedPlaceStandardCategory.information,
      color: Color(marker.colorValue),
      emoji: marker.placeEmoji?.trim(),
    );
    final emoji = identity.emoji;
    if (emoji != null && emoji.isNotEmpty) {
      _paintText(canvas, emoji, identityCenter, const Offset(64, 64));
      return;
    }
    final color = identity.color;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = _markerEdgeWidth;
    final square = RRect.fromRectAndRadius(
      Rect.fromCenter(center: identityCenter, width: 66, height: 66),
      const Radius.circular(10),
    );
    canvas.drawRRect(square, fill);
    canvas.drawRRect(square, outline);
    {
      final icon = identity.icon!;
      _paintText(
        canvas,
        String.fromCharCode(icon.codePoint),
        identityCenter,
        const Offset(46, 46),
        color: identity.foreground,
        isMaterialIcon: true,
      );
    }
  }

  static void _paintText(
    Canvas canvas,
    String text,
    Offset center,
    Offset logicalSize, {
    Color? color,
    bool isMaterialIcon = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: logicalSize.dy,
          fontFamily: isMaterialIcon ? 'MaterialIcons' : null,
          color: color,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  /// Paints Flutter's real location-pin glyph with a restrained white
  /// separation edge and the pin's own darker-red head detail. The head is
  /// semantic red only — it must never inherit the app theme accent, and no
  /// blue/teal dot is drawn inside it. The manually approximated Pass 1
  /// Bézier pin was malformed on the physical device and is removed.
  static void _paintSelectedLocationPinGlyph(Canvas canvas, Offset center) {
    _paintMaterialIconGlyph(
      canvas,
      Icons.location_pin,
      center,
      size: _selectedPinGlyphSize,
      color: Colors.white,
    );
    _paintMaterialIconGlyph(
      canvas,
      Icons.location_pin,
      center,
      size: _selectedPinGlyphSize - 4,
      color: Colors.red.shade700,
    );
    // The pin's own darker-red head detail (PMG reference). This is a fixed
    // semantic red, deliberately independent of the active theme accent.
    canvas.drawCircle(
      Offset(center.dx, center.dy - _selectedPinGlyphSize * 0.14),
      _selectedPinGlyphSize * 0.11,
      Paint()..color = Colors.red.shade900,
    );
  }

  static void _paintMaterialIconGlyph(
    Canvas canvas,
    IconData icon,
    Offset center, {
    required double size,
    required Color color,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          color: color,
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  static Path _starPath(Offset center, double outerRadius, double innerRadius) {
    final path = Path();
    for (var index = 0; index < 10; index += 1) {
      final radius = index.isEven ? outerRadius : innerRadius;
      final angle = -math.pi / 2 + (math.pi * index / 5);
      final point = Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      );
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  Future<void> _animateTo(
    MapCoordinate coordinate, {
    required double zoom,
    Duration? duration,
  }) async {
    await _controller?.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(coordinate.latitude, coordinate.longitude),
        zoom,
      ),
      duration: duration,
    );
  }

  Future<void> _moveToPlacementTarget(MapCoordinate coordinate) async {
    _startupCameraClaimed = true;
    await _controller?.moveCamera(
      CameraUpdate.newLatLng(LatLng(coordinate.latitude, coordinate.longitude)),
    );
  }

  /// Same-map Define Boundary enter/exit. The native patch code is
  /// untouched; only its existing enable/disable command is driven, and the
  /// stored selection context is restored when the pause window ends.
  Future<void> _syncInteractionPaused(bool paused) async {
    final channel = _interactionChannel;
    if (channel == null) return;
    await channel.invokeMethod<void>('configure', {
      'enabled': !paused,
      'trace': MapInteractionTrace.enabled,
    });
    if (!paused) {
      await _syncNativeSelection(
        ref.read(mapSelectedMarkerProvider),
        _selectionGeneration,
      );
    }
  }

  Future<void> _locate() async {
    if (_locating) return;
    _startupCameraClaimed = true;
    _cameraIntent += 1;
    setState(() => _locating = true);
    final result = await ref.read(currentLocationServiceProvider).locate();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (result.status == CurrentLocationStatus.located) {
        _showMyLocation = true;
      }
    });
    final coordinate = result.coordinate;
    if (coordinate != null) {
      await _animateTo(coordinate, zoom: 16);
      return;
    }
    if (!mounted) return;
    final message = switch (result.status) {
      CurrentLocationStatus.denied =>
        'Location permission was denied. You can still use the map.',
      CurrentLocationStatus.permanentlyDenied =>
        'Location is blocked for Next Transfer. Turn it on in Android '
            'Settings and come back — the map continues on its own.',
      CurrentLocationStatus.serviceDisabled =>
        'Turn on device location, then try Locate again.',
      CurrentLocationStatus.unavailable =>
        'Your current location could not be determined. Try again.',
      CurrentLocationStatus.located => null,
    };
    // M6 FINAL CORRECTION: a blocked Locate gets a truthful route to the one
    // place that can change it, and the intent survives the Settings trip.
    final needsSettings =
        result.status == CurrentLocationStatus.permanentlyDenied;
    _locateIntentPending = needsSettings;
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: needsSettings
              ? const Duration(seconds: 8)
              : const Duration(seconds: 4),
          action: needsSettings
              ? SnackBarAction(
                  label: 'Settings',
                  onPressed: () => unawaited(_openAppSettings()),
                )
              : null,
        ),
      );
    }
  }

  Future<void> _openAppSettings() async {
    await ref.read(permissionGatewayProvider).openSystemSettings();
  }

  Future<void> _applyPassiveCoordinate(MapCoordinate coordinate) async {
    if (!_showMyLocation && mounted) setState(() => _showMyLocation = true);
    if (_controller == null ||
        _appliedPassiveCoordinate ||
        _startupCameraClaimed) {
      return;
    }
    _appliedPassiveCoordinate = true;
    final intent = ++_cameraIntent;
    await _animateTo(coordinate, zoom: 16);
    if (mounted && intent == _cameraIntent) {
      _appliedPassiveCoordinate = true;
    }
  }

  void _recordCamera(CameraPosition position) {
    if (!mounted) return;
    _lastCameraPosition = position;
    ref.read(mapsSessionProvider.notifier).recordCamera(position);
    widget.onCameraCenterChanged?.call(
      MapCoordinate(
        latitude: position.target.latitude,
        longitude: position.target.longitude,
      ),
    );
  }

  void _claimUserCameraIntent() {
    _startupCameraClaimed = true;
    _cameraIntent += 1;
    final pending = ref.read(mapTransientFocusProvider).pending;
    if (pending != null) {
      ref.read(mapTransientFocusProvider.notifier).consume(pending.nonce);
    }
  }

  Future<void> _showMapTypes() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, updateSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.44,
          minChildSize: 0.31,
          maxChildSize: 0.64,
          builder: (context, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: <Widget>[
              Text(
                'Map Type',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Divider(height: 20, color: AppTheme.sectionDividerOf(context)),
              PmgStyleSortField(
                key: const Key('maps-type-dropdown'),
                labelText: 'Map Type',
                value: _mapType.label,
                anchorKey: _mapTypeAnchorKey,
                onTap: () => unawaited(_chooseMapType(updateSheet)),
              ),
              const SizedBox(height: 16),
              Text(
                'Markers',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Divider(height: 20, color: AppTheme.sectionDividerOf(context)),
              _CompactMarkerToggle(
                key: const Key('maps-layer-people'),
                icon: Icons.people_outline,
                label: 'Contacts',
                value: _showPeople,
                onChanged: (value) async {
                  final ok = await ref
                      .read(mapsPreferencesProvider.notifier)
                      .setShowContacts(value);
                  if (ok) {
                    _reconcileGroup();
                  }
                  updateSheet(() {});
                },
              ),
              _CompactMarkerToggle(
                key: const Key('maps-layer-events'),
                icon: Icons.event_outlined,
                label: "Today's Events",
                value: _showEvents,
                onChanged: (value) async {
                  final ok = await ref
                      .read(mapsPreferencesProvider.notifier)
                      .setShowEvents(value);
                  if (ok) {
                    _reconcileGroup();
                  }
                  updateSheet(() {});
                },
              ),
              _CompactMarkerToggle(
                key: const Key('maps-layer-places'),
                icon: Icons.place_outlined,
                label: 'Places',
                value: _showPlaces,
                onChanged: (value) async {
                  final ok = await ref
                      .read(mapsPreferencesProvider.notifier)
                      .setShowSavedPlaces(value);
                  if (ok) {
                    _reconcileGroup();
                  }
                  updateSheet(() {});
                },
              ),
              const SizedBox(height: 16),
              Text(
                'MARKER GROUPING',
                key: const Key('maps-marker-grouping-section'),
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Divider(height: 20, color: AppTheme.sectionDividerOf(context)),
              _CompactMarkerToggle(
                key: const Key('maps-group-nearby'),
                icon: Icons.hub_outlined,
                label: 'Group nearby markers',
                value: _groupNearby,
                onChanged: (value) async {
                  final ok = await ref
                      .read(mapsPreferencesProvider.notifier)
                      .setGroupNearbyMarkers(value);
                  if (!context.mounted) return;
                  if (!ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          "Couldn't save this setting. Please try again.",
                        ),
                      ),
                    );
                  }
                  updateSheet(() {});
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _chooseMapType(StateSetter updateSheet) async {
    final fieldContext = _mapTypeAnchorKey.currentContext;
    final fieldBox = fieldContext?.findRenderObject() as RenderBox?;
    if (fieldBox == null || !fieldBox.hasSize) return;
    NextTransferMapType? chosen;
    await showAnchoredTopBarPopup(
      context: context,
      triggerKey: _mapTypeAnchorKey,
      width: fieldBox.size.width,
      maxHeight: 224,
      topGap: 5,
      borderRadius: 5,
      builder: (popupContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final type in NextTransferMapType.values)
            SizedBox(
              height: 48,
              child: InkWell(
                key: Key('maps-type-${type.name}'),
                onTap: () {
                  chosen = type;
                  anchoredTopBarPopupController.dismiss();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          type.label,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: type == _mapType
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (type == _mapType) const Icon(Icons.check, size: 20),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen != null && mounted) {
      await ref.read(mapsSessionProvider.notifier).selectMapType(chosen!);
      if (mounted) {
        updateSheet(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(mapsPreferencesProvider); // Durable visibility/grouping truth.
    final visibleMarkers = _visibleMarkerData;
    final mapType = ref.watch(
      mapsSessionProvider.select((session) => session.mapType),
    );
    final replacement = widget.mapBuilder?.call(context, visibleMarkers);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        replacement ??
            Listener(
              onPointerDown: (_) => _claimUserCameraIntent(),
              child: GoogleMap(
                // M6 FINAL CORRECTION: the generation lets Retry recreate the
                // platform view instead of recycling a dead one.
                key: Key('maps-screen-map-$_mapGeneration'),
                initialCameraPosition: _initialCameraPosition,
                mapType: mapType.googleType,
                markers: _markers,
                polygons: widget.polygons,
                circles: widget.circles,
                clusterManagers: _groupNearby
                    ? _clusterManagers
                    : const <ClusterManager>{},
                myLocationEnabled: widget.myLocationOverride ?? _showMyLocation,
                myLocationButtonEnabled: false,
                // The Google Maps SDK owns the top-left needle compass: it
                // appears for a non-north bearing and resets only the bearing
                // when tapped. Keep it explicit so plugin/default changes
                // cannot silently remove that accepted Maps behavior.
                compassEnabled: true,
                rotateGesturesEnabled: true,
                mapToolbarEnabled: false,
                zoomControlsEnabled: false,
                onMapCreated: _onMapCreated,
                onCameraMove: _recordCamera,
                onCameraIdle: () => _recordCamera(_lastCameraPosition),
                onLongPress: widget.onMapLongPress == null
                    ? null
                    : (position) => widget.onMapLongPress!(
                        MapCoordinate(
                          latitude: position.latitude,
                          longitude: position.longitude,
                        ),
                      ),
                onTap: (latLng) {
                  final tapCoordinate = widget.onMapTapCoordinate;
                  if (tapCoordinate != null) {
                    // Same-map Define Boundary mode: the tap IS a vertex.
                    tapCoordinate(
                      MapCoordinate(
                        latitude: latLng.latitude,
                        longitude: latLng.longitude,
                      ),
                    );
                    return;
                  }
                  final onMapTap = widget.onMapTap;
                  if (onMapTap != null) {
                    onMapTap();
                  } else {
                    ref.read(mapSelectedMarkerProvider.notifier).clear();
                  }
                },
              ),
            ),
        // M6 FINAL CORRECTION: a bounded, truthful base-map failure surface.
        // It sits UNDER the floating controls so they stay usable, and it can
        // only be visible while no platform controller ever came up, so a
        // healthy map is never covered.
        if (_mapLoadFailed)
          Positioned.fill(child: _MapLoadFailure(onRetry: _retryMapLoad)),
        ValueListenableBuilder<double>(
          valueListenable: widget.controlsLift ?? _ZeroValueListenable(),
          builder: (context, lift, _) {
            if (!widget.controlsEnabled) {
              // Same-map session owns its own controls (Drop Pin and Map
              // Type are temporarily suppressed; Current Location is
              // rendered by the session chrome at its lifted position).
              return const SizedBox.shrink();
            }
            return AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              right: 16,
              bottom: mapControlColumnBottom(
                hasVisibleMarkers: visibleMarkers.isNotEmpty,
                previewLift: lift,
                placementActive: widget.placementActive,
              ),
              child: Column(
                children: <Widget>[
                  FloatingActionButton(
                    heroTag: null,
                    key: const Key('maps-drop-pin-button'),
                    tooltip: 'Drop pin',
                    onPressed: widget.onDropPin,
                    child: const Icon(Icons.location_pin),
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton(
                    heroTag: null,
                    key: const Key('maps-type-button'),
                    tooltip: 'Map type',
                    onPressed: _showMapTypes,
                    child: const Icon(Icons.layers_outlined),
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton(
                    heroTag: null,
                    key: const Key('maps-locate-button'),
                    tooltip: 'Locate me',
                    onPressed: _locating ? null : _locate,
                    child: _locating
                        ? SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          )
                        : const Icon(Icons.my_location),
                  ),
                ],
              ),
            );
          },
        ),
        if (visibleMarkers.isEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'No saved map pins yet. Pan, zoom, change map type, '
                  'or use Locate. Set pins from a Contact or Event.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The actual canonical unselected map bitmap, shared with grouped rows.
/// This keeps Contact/Favorite/Event and native emoji paint byte-identical;
/// there is no separate grouped-preview icon or color lookup.
final class MapMarkerIdentityIcon extends StatelessWidget {
  const MapMarkerIdentityIcon({required this.marker, super.key});
  final MapMarker marker;
  @override
  Widget build(BuildContext context) => FutureBuilder<BitmapDescriptor>(
    initialData: _GoogleMapsSurfaceState
        ._markerIcons[_GoogleMapsSurfaceState._markerIconKey(marker, false)],
    future: _GoogleMapsSurfaceState._loadMarkerIcon(marker, false),
    builder: (context, snapshot) => SizedBox.square(
      dimension: 34,
      child: snapshot.data is BytesMapBitmap
          ? Image.memory(
              (snapshot.data! as BytesMapBitmap).byteData,
              width: 34,
              height: 34,
              semanticLabel: marker.displayName,
            )
          : const SizedBox.shrink(),
    ),
  );
}

final class _CompactMarkerToggle extends StatelessWidget {
  const _CompactMarkerToggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        leading: Icon(icon, size: 20),
        title: Text(label, style: const TextStyle(fontSize: 15)),
        onTap: () => onChanged(!value),
        trailing: SizedBox.square(
          dimension: 48,
          child: Center(
            child: Transform.scale(
              scale: .84,
              child: Switch(value: value, onChanged: onChanged),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bounded base-map failure surface.
///
/// Dart cannot observe a native tile/authorization failure, so this is shown
/// only after the map surface failed to report a created controller inside the
/// watchdog window.  It states the situation truthfully, never blames Location
/// permission (the base map does not need it) and never leaks a credential.
final class _MapLoadFailure extends StatelessWidget {
  const _MapLoadFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            key: const Key('maps-load-failure'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.map_outlined,
                size: 48,
                color: AppTheme.secondaryTextOf(context),
              ),
              const SizedBox(height: 16),
              const Text(
                'The map could not load',
                textAlign: TextAlign.center,
                style: AppTypography.sectionTitle,
              ),
              const SizedBox(height: 8),
              Text(
                'Next Transfer could not start the map surface on this device. '
                'Check your connection and try again. Your saved pins are '
                'untouched.',
                textAlign: TextAlign.center,
                style: AppTypography.secondary,
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('maps-load-retry'),
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ZeroValueListenable extends ValueNotifier<double> {
  _ZeroValueListenable() : super(0.0);
}
