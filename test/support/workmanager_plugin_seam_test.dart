import 'package:flutter_test/flutter_test.dart';
import 'package:workmanager/workmanager.dart';

import 'workmanager_plugin_seam.dart';

/// Records `cancelByTag` calls so a test can prove the canonical gateway call
/// path reaches the installed fake instead of a host implementation.
final class _RecordingWorkmanagerPlatform extends WorkmanagerPlatform {
  final List<String> cancelledTags = <String>[];

  @override
  Future<void> cancelByTag(String tag) async {
    cancelledTags.add(tag);
  }
}

void main() {
  // The suite must leave the platform interface as it found it, so the ordering
  // fix cannot leak into any other test in this isolate.
  final original = WorkmanagerPlatform.instance;
  tearDown(() => WorkmanagerPlatform.instance = original);

  group('workmanager test seam (issue #12)', () {
    test('WM-SEAM-1 the installed fake survives the plugin registration', () {
      final fake = _RecordingWorkmanagerPlatform();
      installWorkmanagerPlatform(fake);
      expect(WorkmanagerPlatform.instance, same(fake));
    });

    test(
      'WM-SEAM-2 touching the singleton afterwards never replaces the fake',
      () {
        final fake = _RecordingWorkmanagerPlatform();
        installWorkmanagerPlatform(fake);
        // `schedule()` evaluates `Workmanager()` before every platform call.
        Workmanager();
        Workmanager();
        expect(
          WorkmanagerPlatform.instance,
          same(fake),
          reason:
              'a bare `WorkmanagerPlatform.instance = …` assignment loses the '
              'fake to Workmanager\'s lazily-installed host implementation on '
              'Linux, which is what made these suites pass on Windows and fail '
              'on CI',
        );
      },
    );

    test(
      'WM-SEAM-3 the canonical cancelByTag path reaches the installed fake',
      () async {
        final fake = _RecordingWorkmanagerPlatform();
        installWorkmanagerPlatform(fake);
        await Workmanager().cancelByTag('nt.reminder.456');
        expect(fake.cancelledTags, <String>['nt.reminder.456']);
      },
    );

    test('WM-SEAM-4 installing twice keeps the most recent fake', () {
      final first = _RecordingWorkmanagerPlatform();
      final second = _RecordingWorkmanagerPlatform();
      installWorkmanagerPlatform(first);
      installWorkmanagerPlatform(second);
      expect(WorkmanagerPlatform.instance, same(second));
    });
  });
}
