import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PRE-BETA RESPONSIVE (owner law, 2026-09-16) — orientation contract.
///
/// Next Transfer must NOT force portrait. This contract is about DECLARATIONS,
/// so it is asserted against the declarations themselves: the manifest element
/// that restricted the Activity and the runtime call that restricted the
/// engine. Comments are stripped first, so the historical explanation left in
/// `main.dart` cannot satisfy or break the contract.
///
/// This test FAILS on the pre-change baseline (which declared
/// `android:screenOrientation="portrait"` and called
/// `setPreferredOrientations([DeviceOrientation.portraitUp])`).
void main() {
  /// Removes `//` line comments (the only comment form used at the sites under
  /// test) so prose can never be mistaken for code.
  String codeOnly(String source) {
    return source
        .split('\n')
        .map((String line) {
          final int marker = line.indexOf('//');
          return marker < 0 ? line : line.substring(0, marker);
        })
        .join('\n');
  }

  final File mainFile = File('lib/main.dart');
  final File manifestFile = File('android/app/src/main/AndroidManifest.xml');

  group('no runtime orientation restriction', () {
    test('main.dart still declares the app entrypoint', () {
      expect(mainFile.existsSync(), isTrue);
      expect(mainFile.readAsStringSync(), contains('Future<void> main()'));
    });

    test('main.dart installs no fixed orientation', () {
      final String code = codeOnly(mainFile.readAsStringSync());
      for (final String forbidden in <String>[
        'DeviceOrientation.portraitUp',
        'DeviceOrientation.portraitDown',
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]) {
        expect(
          code,
          isNot(contains(forbidden)),
          reason:
              '$forbidden would force an orientation. The app must follow the '
              "device's rotation state instead.",
        );
      }
    });

    test('main.dart defers to the operating system default', () {
      final String code = codeOnly(
        mainFile.readAsStringSync(),
      ).replaceAll(' ', '');
      // The documented "defer to the OS default" contract is the empty list.
      expect(
        code,
        contains('SystemChrome.setPreferredOrientations('),
        reason: 'the orientation intent must stay explicit and reviewable',
      );
      expect(
        code,
        contains('setPreferredOrientations(const<DeviceOrientation>[])'),
        reason: 'an empty orientation list is what defers to the system',
      );
    });
  });

  group('no native orientation restriction', () {
    test('the manifest still declares the launcher activity', () {
      expect(manifestFile.existsSync(), isTrue);
      final String manifest = manifestFile.readAsStringSync();
      expect(manifest, contains('android:name=".MainActivity"'));
      expect(manifest, contains('android.intent.category.LAUNCHER'));
    });

    test('the Activity declares no screenOrientation', () {
      final String manifest = codeOnly(manifestFile.readAsStringSync());
      expect(
        manifest,
        isNot(contains('screenOrientation')),
        reason:
            'A manifest orientation lock is ignored on Android 16+ large '
            'screens and cannot be honoured, so it must not be declared.',
      );
    });

    test('no compatibility opt-out is smuggled in', () {
      final String manifest = codeOnly(manifestFile.readAsStringSync());
      expect(
        manifest,
        isNot(contains('PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY')),
        reason:
            'The Android 16 opt-out does not lock orientation and is removed '
            'entirely at API 37; it must not be used as a substitute lock.',
      );
    });

    test('the Activity stays resizable and keeps its configuration set', () {
      final String manifest = codeOnly(manifestFile.readAsStringSync());
      expect(manifest, isNot(contains('resizeableActivity')));
      // The engine must NOT be recreated on a configuration change: state
      // continuity for rotation and window resizing depends on this list.
      expect(manifest, contains('android:configChanges='));
      for (final String change in <String>[
        'orientation',
        'screenSize',
        'smallestScreenSize',
        'screenLayout',
        'density',
        'uiMode',
        'fontScale',
      ]) {
        expect(
          manifest,
          contains(change),
          reason: 'configChanges must still cover $change',
        );
      }
    });

    test('the launch and normal themes are untouched', () {
      final String manifest = manifestFile.readAsStringSync();
      expect(manifest, contains('android:theme="@style/LaunchTheme"'));
      expect(manifest, contains('io.flutter.embedding.android.NormalTheme'));
      expect(manifest, contains('android:windowSoftInputMode="adjustResize"'));
    });
  });

  group('exactly one reviewable orientation site', () {
    test('no other library file states an orientation intent', () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final String code = codeOnly(entity.readAsStringSync());
        if (code.contains('setPreferredOrientations') ||
            code.contains('DeviceOrientation.')) {
          offenders.add(entity.path.replaceAll('\\', '/'));
        }
      }
      expect(offenders, <String>[
        'lib/main.dart',
      ], reason: 'only main.dart may state the orientation intent');
    });
  });
}
