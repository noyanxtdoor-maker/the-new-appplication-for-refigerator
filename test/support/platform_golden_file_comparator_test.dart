import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'platform_golden_file_comparator.dart';

/// Records the URIs it is asked about and never touches the file system.
///
/// Extends [LocalFileComparator] so it inherits the real `getTestUri`
/// (version-suffix) behaviour and mirrors what `flutter test` installs in
/// production; only the I/O is replaced.
final class _RecordingComparator extends LocalFileComparator {
  _RecordingComparator()
    : super(Uri.parse('test/features/example/example_test.dart'));

  Uri? compared;
  Uri? updated;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    compared = golden;
    return true;
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {
    updated = golden;
  }
}

Uri _key(String path) => Uri.parse(path);

void main() {
  group('platform-scoped golden routing (issue #12)', () {
    test('GOLDEN-ROUTE-1 the repository test config installs the scoped '
        'comparator for this suite', () {
      expect(
        goldenFileComparator,
        isA<PlatformScopedGoldenFileComparator>(),
        reason:
            'test/flutter_test_config.dart must be discovered for every test '
            'under test/; without it the shared baseline tree comes back and '
            'CI goes red on Linux again',
      );
      expect(
        (goldenFileComparator as PlatformScopedGoldenFileComparator)
            .platformKey,
        goldenPlatformKey(),
        reason: 'the active baseline tree must be the host platform',
      );
    });

    test('GOLDEN-ROUTE-2 windows and linux resolve the same key to their own '
        'baseline trees', () {
      final delegate = _RecordingComparator();
      final windows = PlatformScopedGoldenFileComparator(
        delegate,
        platformKey: 'windows',
      );
      final linux = PlatformScopedGoldenFileComparator(
        delegate,
        platformKey: 'linux',
      );

      const key = 'goldens/home_pack1/01_default_canonical_home.png';
      expect(
        windows.getTestUri(_key(key), null).path,
        'goldens/windows/home_pack1/01_default_canonical_home.png',
      );
      expect(
        linux.getTestUri(_key(key), null).path,
        'goldens/linux/home_pack1/01_default_canonical_home.png',
      );
    });

    test('GOLDEN-ROUTE-3 every golden suite follows the same law', () {
      final comparator = PlatformScopedGoldenFileComparator(
        _RecordingComparator(),
        platformKey: 'linux',
      );
      const keys = <String>[
        'goldens/home_pack1/01_default_canonical_home.png',
        'goldens/home_skeleton/01_skeleton_360.png',
        'goldens/goal_icon_d1/context_home_goal_card_compact.png',
        'goldens/backup_event_accent/01_normal.png',
      ];
      for (final key in keys) {
        expect(
          comparator.getTestUri(_key(key), null).path,
          key.replaceFirst('goldens/', 'goldens/linux/'),
          reason: '$key must route under the platform segment',
        );
      }
    });

    test('GOLDEN-ROUTE-4 a platform never resolves into another platform '
        'baseline tree', () {
      final linux = PlatformScopedGoldenFileComparator(
        _RecordingComparator(),
        platformKey: 'linux',
      );
      final resolved = linux.getTestUri(
        _key('goldens/home_pack1/01_default_canonical_home.png'),
        null,
      );
      expect(resolved.pathSegments[1], 'linux');
      expect(
        resolved.path,
        isNot(contains('windows')),
        reason:
            'a missing platform tree must fail, never fall back to another '
            'platform\'s accepted images',
      );
    });

    test('GOLDEN-ROUTE-5 routing is idempotent across getTestUri, compare and '
        'update', () async {
      final delegate = _RecordingComparator();
      final comparator = PlatformScopedGoldenFileComparator(
        delegate,
        platformKey: 'linux',
      );
      final once = comparator.getTestUri(_key('goldens/x/a.png'), null);
      final twice = comparator.getTestUri(once, null);
      expect(twice, once, reason: 'the platform segment must not stack');

      // matchesGoldenFile() resolves the key and then hands the resolved URI
      // back to compare()/update(); neither may relocate it a second time.
      await comparator.compare(Uint8List(0), once);
      expect(delegate.compared, once);
      await comparator.update(once, Uint8List(0));
      expect(delegate.updated, once);
    });

    test(
      'GOLDEN-ROUTE-6 keys outside goldens/ are left exactly as authored',
      () {
        final comparator = PlatformScopedGoldenFileComparator(
          _RecordingComparator(),
          platformKey: 'linux',
        );
        expect(
          comparator.getTestUri(_key('elsewhere/a.png'), null).path,
          'elsewhere/a.png',
        );
      },
    );

    test('GOLDEN-ROUTE-7 versioned keys keep their version before the platform '
        'segment', () {
      final delegate = _RecordingComparator();
      final comparator = PlatformScopedGoldenFileComparator(
        delegate,
        platformKey: 'windows',
      );
      // `GoldenFileComparator.getTestUri` inserts the version before the
      // extension: `goldens/x/a.png` + 3 -> `goldens/x/a.3.png`.
      expect(
        delegate.getTestUri(_key('goldens/x/a.png'), 3).path,
        'goldens/x/a.3.png',
      );
      expect(
        comparator.getTestUri(_key('goldens/x/a.png'), 3).path,
        'goldens/windows/x/a.3.png',
      );
    });

    test('GOLDEN-ROUTE-8 the host platform key is the rasterising host', () {
      expect(goldenPlatformKey(), Platform.operatingSystem);
      expect(goldenPlatformKey(), isNotEmpty);
      expect(goldenRootSegment, 'goldens');
    });
  });
}
