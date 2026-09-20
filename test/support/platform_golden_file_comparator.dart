import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The directory segment under which every golden key in this repository is
/// authored, e.g. `goldens/home_pack1/01_default_canonical_home.png`.
const String goldenRootSegment = 'goldens';

/// The host platform key that selects the raster baselines for this run.
///
/// Derived from `dart:io` rather than `defaultTargetPlatform`: a golden baseline
/// is produced by the *host* rasteriser (fonts, hinting, antialiasing), and
/// `defaultTargetPlatform` is deliberately overridable by tests, which would
/// make baseline routing depend on test configuration instead of the machine
/// that actually drew the pixels.
String goldenPlatformKey() => Platform.operatingSystem;

/// Routes golden baselines into a platform-scoped directory.
///
/// ## Why this exists
///
/// `LocalFileComparator` compares rendered pixels against a committed PNG with
/// **zero tolerance**. The committed baselines in this repository were rasterised
/// on Windows; GitHub Actions rasterises on Linux. The two hosts use different
/// font rasterisers, so text glyph coverage differs by a fraction of a percent
/// of pixels (measured: 0.23%–0.74%) and every text-bearing golden failed on CI.
///
/// Rather than loosen the comparison (which would blind the tests) or skip them
/// (which would remove them), each supported rasterising platform gets its own
/// canonical baseline tree, and the same assertions run against both.
///
/// ## Routing law
///
/// For any golden key whose first path segment is [goldenRootSegment], the host
/// platform key is inserted immediately after it:
///
/// ```
/// goldens/home_pack1/01_x.png   ->  goldens/windows/home_pack1/01_x.png
/// goldens/home_pack1/01_x.png   ->  goldens/linux/home_pack1/01_x.png
/// ```
///
/// Keys that are not under [goldenRootSegment] are left exactly as authored, so
/// the rule can never silently relocate an unrelated reference.
///
/// The rewrite is idempotent: a key that already carries the platform segment is
/// returned unchanged. `matchesGoldenFile` resolves a key through
/// [getTestUri] and then hands that resolved URI back to `compare`/`update`, so
/// without idempotency the platform segment would be inserted twice.
///
/// When a platform's baseline tree has not been generated yet the delegate
/// reports the file as missing (`Could not be compared against non-existent
/// file`) — a platform never falls back to another platform's baselines.
final class PlatformScopedGoldenFileComparator implements GoldenFileComparator {
  PlatformScopedGoldenFileComparator(
    this._delegate, {
    required this.platformKey,
  });

  /// The comparator installed by `flutter test` for the current test file.
  ///
  /// All real work — pixel comparison, failure diff images and `--update-goldens`
  /// writes — stays with the delegate; this class only relocates the baseline.
  final GoldenFileComparator _delegate;

  /// The host platform whose baselines this run must use.
  final String platformKey;

  @override
  Uri getTestUri(Uri key, int? version) =>
      _scope(_delegate.getTestUri(key, version));

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) =>
      _delegate.compare(imageBytes, _scope(golden));

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) =>
      _delegate.update(_scope(golden), imageBytes);

  Uri _scope(Uri golden) {
    final List<String> segments = golden.pathSegments;
    if (segments.isEmpty || segments.first != goldenRootSegment) {
      return golden;
    }
    if (segments.length > 1 && segments[1] == platformKey) {
      return golden;
    }
    return Uri(
      pathSegments: <String>[segments.first, platformKey, ...segments.skip(1)],
    );
  }
}
