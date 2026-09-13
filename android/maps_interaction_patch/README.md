# NT Maps interaction patch — VS15 M3.2 Pass 2

This is a project-owned source substitution for **google_maps_flutter_android
2.19.13**, with its existing **android-maps-utils 4.1.0** dependency. Neither
package is upgraded or broadly copied. Pub cache is read-only input.

## Reproduction

`android/build.gradle.kts` applies `android/maps-interaction-patch.gradle`.
The plugin's `prepareNtMapsInteractionPatch` task reads `patch.json`, verifies
each original source SHA-256 and exact replacement count, then writes only
three substituted Java files beneath the project's ignored build directory.
JavaCompile replaces those three original inputs and includes this directory's
two Java helpers. All other plugin sources and dependencies remain untouched.
The original Flutter license headers remain in the generated source files.

Original sources, relative to the pinned plugin's `android/src/main/java/`:

- `io/flutter/plugins/googlemaps/GoogleMapController.java`
- `io/flutter/plugins/googlemaps/MarkersController.java`
- `io/flutter/plugins/googlemaps/ClusterManagersController.java`

`patch.json` contains the precise original hashes, before/after text and
replacement counts. The preparation fails closed if upstream input changes.

## Why native code is needed

The Dart marker callback receives Google's already-chosen ID, not the original
touch point or the native count bitmap. It cannot reverse the native nearby
marker cycling policy or guarantee click consumption before camera centering.

`NtPrecisionMapView` observes native-local coordinates. Only a completed
single-finger tap (within Android touch slop and shorter than long press)
is intercepted. It delivers CANCEL to the SDK before UP and dispatches through
`NtMapInteraction`. Pan, multi-touch and long press follow the original SDK
path. Other GoogleMap screens do not opt into the new method channel.

A press that starts inside a docked SDK control is never intercepted. The SDK
installs its built-in controls — the top-left needle compass above all — as
corner-sized views (at most 48 logical pixels) beneath the map surface, which
is never that small, so the walk in `overSdkControl` matches controls and
nothing else. The SDK therefore keeps the completed tap and its accepted
meaning: a compass tap returns the camera to north-up while target, zoom and
the rest of the camera stay put. Without that exception the interception
cancelled every completed tap before the SDK saw UP, so the needle stayed
visible and rotated with the bearing but could no longer reset it.

## Hit policy

The bridge registers the actual current rendered Marker handles and their
canonical IDs/builders. It uses their current projected position, unchanged
bottom-center anchor, and the same density-scaled bitmap pixels that are sent
to Maps. Pixels below alpha 128, transparent margins and faint shadows are
not selectable. No hit padding is added. If painted shapes truly overlap,
distance to the measured painted identity center wins, then stable ID.
Selected z-order cannot steal another distinct identity's visible center.
Old builder identities and superseded cluster memberships are rejected.

Exact-coordinate remainders are visually separated 34 logical pixels left
of the selected individual by an otherwise transparent canvas. Their LatLng
and normalized anchor stay unchanged; the individual compositor is untouched.
Native alpha picking rejects all additional transparent canvas pixels.

The native count bitmap producer uses the unchanged android-maps-utils 4.1.0
recipe (SquareTextView, 12-density-pixel padding, original text appearance,
color/bucket getters, and 3-density-pixel outline). Capturing these exact pixels
avoids guessing the native hit dimensions. A native graphics regression compares
its non-empty bitmap to the upstream renderer.
Recipe source: https://github.com/googlemaps/android-maps-utils/blob/v4.1.0/library/src/main/java/com/google/maps/android/clustering/view/DefaultClusterRenderer.java
That recipe is derived from Google Maps Android Utility Library (Apache-2.0).

## Selection membership and [3]

Dart removes the selected owner before exact-coordinate aggregation. The
selected individual and remainder therefore represent disjoint owner sets.
Clear restores the complete set. Group selection retains its actual reported
native displayed position; it never modifies member coordinates.

For a selected cluster member, the original native member IDs identify the
permitted remainder. For a directly selected individual without such context,
a read-only hypothetical membership query uses the same pinned native algorithm
and distance to identify only that individual's would-be cluster. It never adds
the selected record to the live manager. An exact-coordinate remainder is
handled by Dart and is excluded from that inference.

Only that remainder can render below the unchanged global minimum of 4.
Other three-record groups retain upstream behavior. Membership changes and
selection clear trigger clustering without a camera action. A read-only
remainder query on camera idle keeps the exception consistent with the current
zoom, without replacing the live clustering algorithm.

The accepted Dart red-pin painter is reused to compose selected count imagery.
Native selection updates modify the existing count marker rather than adding
a second overlapping tap target. Selection-generation checks reject stale
bitmap commands. The red ornament does not enlarge native count hit regions.

The native cluster-click callback now returns true, suppressing default camera
centering. No counter-pan or camera-restoration workaround exists.
Non-touch/accessibility SDK callbacks retain their canonical callback route.

## Diagnostics and tests

Diagnostics are bounded to 256 entries per runtime/surface and enabled only
for debug builds (`NT_MAP_TRACE`, default true in debug). Payloads contain
gesture/selection/render tokens, IDs and timings, never record names/details.
Native T-1/T0 uses native monotonic time; Dart T0-received/T1/T2/T3/T4 uses its
own stopwatch. Do not subtract absolute timestamps across those clocks.

Run the focused native tests:

`gradlew :google_maps_flutter_android:testDebugUnitTest --tests io.flutter.plugins.googlemaps.NtMapInteractionTest`

These tests execute the native gesture boundary, pixel resolver, real bitmap
render comparison, remainder exception and stale-generation guards. They are
not handset acceptance or a physical tap-latency benchmark.

## Removing the patch later

When upstream supplies equivalent precise touch dispatch, group presentation
and camera consumption, replace the Dart method-channel use with that supported
API, preserve the existing regressions, remove the single Gradle apply line and
this patch directory/script, then verify native and Flutter suites. Do not
remove only the native half while Dart still requires its channel. No Pub-cache
restoration is necessary because its source files were never edited.
