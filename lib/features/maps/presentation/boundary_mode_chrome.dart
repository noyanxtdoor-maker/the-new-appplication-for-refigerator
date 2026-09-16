import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/maps/application/saved_place_providers.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/domain/saved_place.dart';

/// The live draft polygon rendered ON the canonical map during Define
/// Boundary mode. Auto-closes last -> first natively once 3+ vertices exist;
/// fill uses the boundary color @ 0.32 alpha, the stroke the full color, and
/// tap consumption stays OFF (the frozen M3 pipeline is never engaged).
Polygon? boundaryDraftPolygon({
  required List<MapCoordinate> vertices,
  required String colorHex,
}) {
  if (vertices.length < minBoundaryVertices) return null;
  final color = Color(markerColorHexToArgb(colorHex));
  return Polygon(
    polygonId: const PolygonId('boundary-editor-draft'),
    points: <LatLng>[
      for (final vertex in vertices) LatLng(vertex.latitude, vertex.longitude),
    ],
    fillColor: color.withValues(alpha: boundaryFillOpacity),
    strokeColor: color,
    strokeWidth: boundaryStrokeWidthPx,
    consumeTapEvents: false,
    zIndex: 2,
  );
}

/// Edit mode only: the persisted boundary as a faint, handle-free reference
/// that stays visually distinct from the active draft. The user taps NEW
/// vertices to replace it (redefine-by-taps, no draggable handles).
Polygon boundaryReferencePolygon(SavedPlaceBoundary existing) {
  return Polygon(
    polygonId: const PolygonId('boundary-editor-existing'),
    points: <LatLng>[
      for (final vertex in existing.vertices)
        LatLng(vertex.latitude, vertex.longitude),
    ],
    fillColor: Color(existing.markerColorArgb).withValues(alpha: 0.10),
    strokeColor: Color(existing.markerColorArgb).withValues(alpha: 0.45),
    strokeWidth: 1,
    consumeTapEvents: false,
    zIndex: 1,
  );
}

/// High-contrast neutral ring for vertex handles so they stay visible against
/// both road and satellite imagery: dark boundaries get a white ring, light
/// boundaries a dark ring.
Color boundaryVertexRingColor(Color boundary) =>
    boundary.computeLuminance() > 0.45 ? Colors.black87 : Colors.white;

/// Editor-only vertex artifacts: small clean handles whose CENTER uses the
/// selected boundary color and whose RING is a high-contrast neutral. These
/// never join the marker/cluster pipeline and never become persisted records.
Set<Circle> boundaryVertexHandles({
  required List<MapCoordinate> vertices,
  required String colorHex,
}) {
  final center = Color(markerColorHexToArgb(colorHex));
  final ring = boundaryVertexRingColor(center);
  return <Circle>{
    for (var i = 0; i < vertices.length; i++)
      Circle(
        circleId: CircleId('boundary-editor-vertex-$i'),
        center: LatLng(vertices[i].latitude, vertices[i].longitude),
        radius: 6,
        fillColor: center,
        strokeColor: ring,
        strokeWidth: 2,
        consumeTapEvents: false,
      ),
  };
}

/// The same-map Define Boundary chrome (M6.1 Pass 2).
///
/// Overlays the CANONICAL map while the Add/Edit Place form has yielded: the
/// map itself (contacts, events, places, clusters, persisted boundaries, the
/// working place marker, the blue dot, camera and map type) keeps rendering
/// beneath. Visual geometry is FROZEN from the owner-reviewed M6.1 editor:
/// Undo bottom-left, Done bottom-right, Clear top-center, instruction card
/// lower-center — with ONLY the Current Location control lifted clear of the
/// instruction card. Nothing here persists; Done returns the draft to the
/// owning form.
final class BoundaryModeChrome extends StatelessWidget {
  const BoundaryModeChrome({
    required this.verticesCount,
    required this.canDone,
    required this.locating,
    required this.onUndo,
    required this.onClear,
    required this.onDone,
    required this.onLocate,
    super.key,
  });

  final int verticesCount;
  final bool canDone;
  final bool locating;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onDone;
  final VoidCallback onLocate;

  bool get _hasVertices => verticesCount > 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        if (_hasVertices)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: BoundaryPillButton(
                key: const Key('boundary-editor-clear'),
                label: 'Clear Boundary',
                onPressed: onClear,
              ),
            ),
          ),
        if (!_hasVertices)
          Positioned(
            left: 24,
            right: 24,
            bottom: 104,
            child: Align(
              child: Material(
                key: const Key('boundary-editor-instruction'),
                color: AppTheme.surfaceOf(context),
                elevation: 6,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  child: Text(
                    'Tap to create an outline of your boundary',
                    textAlign: TextAlign.center,
                    style: AppTypography.body,
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: SafeArea(
            top: false,
            child: Row(
              children: <Widget>[
                if (_hasVertices) ...<Widget>[
                  BoundaryPillButton(
                    key: const Key('boundary-editor-undo'),
                    label: 'Undo',
                    onPressed: onUndo,
                  ),
                  const Spacer(),
                ],
                if (canDone)
                  BoundaryPillButton(
                    key: const Key('boundary-editor-done'),
                    label: 'Done',
                    onPressed: onDone,
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 170,
          child: SafeArea(
            top: false,
            child: FloatingActionButton(
              key: const Key('boundary-editor-locate'),
              heroTag: null,
              tooltip: 'Current location',
              onPressed: locating ? null : onLocate,
              // POST-M7 CLOSURE: inherit the canonical FAB role (surface +
              // WHITE glyph) rather than bypassing it with a local pair.
              child: locating
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shared pill button: identical geometry/typography to the owner-approved
/// M6.1 editor pills.
final class BoundaryPillButton extends StatelessWidget {
  const BoundaryPillButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surfaceOf(context),
      elevation: 6,
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        borderRadius: BorderRadius.circular(26),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
          child: Text(
            label,
            style: AppTypography.body.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
