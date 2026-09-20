import 'package:flutter_test/flutter_test.dart';

import 'support/platform_golden_file_comparator.dart';

/// Repository-wide test configuration, discovered by `flutter test` for every
/// test under `test/` (`flutter_tools` walks up from each test file's directory
/// and stops at the `pubspec.yaml` sentinel).
///
/// The runner has already installed, for this specific test file,
/// `goldenFileComparator = LocalFileComparator(Uri.parse(testUrl))` and set
/// `autoUpdateGoldenFiles` before calling this function
/// (`flutter_tools/lib/src/test/flutter_platform.dart`). Wrapping that
/// comparator here is the supported seam for golden configuration, so the only
/// thing this file changes is *where* baselines live: each host platform reads
/// and writes its own canonical baseline tree instead of one shared tree that
/// can only ever match one of the platforms.
///
/// See [PlatformScopedGoldenFileComparator] for the routing law and rationale.
/// No test is skipped, relaxed or made platform-conditional by this file.
Future<void> testExecutable(Future<void> Function() testMain) async {
  goldenFileComparator = PlatformScopedGoldenFileComparator(
    goldenFileComparator,
    platformKey: goldenPlatformKey(),
  );
  await testMain();
}
