// OWNER REVIEW #4 — fail-first coverage for the Maps API key gate.
//
// The forensic audit proved the shipped profile APK carried
// `com.google.android.geo.API_KEY = "DEFAULT_API_KEY"`, the tracked fallback,
// because `android/secrets.properties` was missing from the worktree. The
// Google Maps Android SDK cannot authorize against a placeholder, so the map
// could not load on a build that passed the entire suite.
//
// M-6 added the layer that was missing: the audit showed the Gradle guard, the
// runner CLI and the packaged artifact were all UNOBSERVED, so N-25 (guard
// removed) and N-26 (placeholder rejection relaxed) both escaped every gate, and
// the guard accepted configuration sources the secrets plugin cannot substitute
// from (a proven false negative). This file now proves, in four layers:
//
//   1. the pure rules (`tool/maps_key_rules.dart`);
//   2. the structure of the Gradle guard in `android/app/build.gradle.kts`;
//   3. the structure of the inverted Maps CI control in `quality.yml`;
//   4. the REAL runner (`tool/verify_maps_key.dart`) as a subprocess, covering
//      SOURCE mode and the strict CLI law, using only synthetic values in
//      temporary directories.
//
// SECRET OUTPUT — FULL OPACITY. No assertion here, and no code path under test,
// may print a configured value or anything derived from it: no prefix, no
// suffix, no length, no hash, no encoded form. Failures report a value CLASS.
//
// The tests never use a real Maps key and never touch a key-bearing artifact.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/maps_key_rules.dart';

/// The only value classes the gate may ever report.
const Set<String> _opaqueLabels = {'<empty>', '<placeholder>', '<configured>'};

void main() {
  final root = _repositoryRoot();
  String pathOf(String relative) =>
      '${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

  String read(String relative) => File(pathOf(relative)).readAsStringSync();

  group('readMapsKey', () {
    test('reads a plain declaration', () {
      expect(readMapsKey('MAPS_API_KEY=AIzaSyEXAMPLE'), 'AIzaSyEXAMPLE');
    });

    test('ignores surrounding whitespace and a CRLF terminator', () {
      expect(
        readMapsKey('MAPS_API_KEY = AIzaSyEXAMPLE\r\nOTHER=1\r\n'),
        'AIzaSyEXAMPLE',
      );
    });

    test('ignores commented declarations', () {
      expect(readMapsKey('#MAPS_API_KEY=AIzaSyEXAMPLE'), isNull);
      expect(readMapsKey('!MAPS_API_KEY=AIzaSyEXAMPLE'), isNull);
      expect(
        readMapsKey(
          '# Safe tracked fallback used by non-local tooling.\n'
          'MAPS_API_KEY=DEFAULT_API_KEY\n',
        ),
        mapsKeyPlaceholder,
      );
    });

    test('returns null when the key is absent or the file is missing', () {
      expect(readMapsKey('OTHER=1'), isNull);
      expect(readMapsKey(''), isNull);
      expect(readMapsKey(null), isNull);
    });
  });

  group('resolveMapsKey precedence', () {
    test('the untracked local file wins over the tracked defaults', () {
      expect(
        resolveMapsKey(
          localSecrets: 'MAPS_API_KEY=SYNTHETIC_LOCAL_VALUE',
          defaults: 'MAPS_API_KEY=$mapsKeyPlaceholder',
        ),
        'SYNTHETIC_LOCAL_VALUE',
      );
    });

    test('an absent local file falls back to the placeholder', () {
      expect(
        resolveMapsKey(
          localSecrets: null,
          defaults: 'MAPS_API_KEY=$mapsKeyPlaceholder',
        ),
        mapsKeyPlaceholder,
      );
    });

    test('nothing declared anywhere resolves to the empty string', () {
      expect(resolveMapsKey(localSecrets: null, defaults: null), '');
      expect(resolveMapsKey(localSecrets: '# nothing', defaults: ''), '');
    });
  });

  group('mapsKeyIsUsable', () {
    test('rejects missing, blank and placeholder values', () {
      expect(mapsKeyIsUsable(''), isFalse);
      expect(mapsKeyIsUsable('   '), isFalse);
      expect(mapsKeyIsUsable(mapsKeyPlaceholder), isFalse);
      expect(mapsKeyIsUsable('  $mapsKeyPlaceholder  '), isFalse);
    });

    test('accepts a configured value', () {
      expect(mapsKeyIsUsable('SYNTHETIC_LOCAL_VALUE'), isTrue);
    });
  });

  group('packagedManifestHasPlaceholder', () {
    test('detects a placeholder-bearing manifest dump', () {
      const dump = '''
          E: meta-data
            A: android:name="com.google.android.geo.API_KEY"
            A: android:value="DEFAULT_API_KEY"
''';
      expect(packagedManifestHasPlaceholder(dump), isTrue);
    });

    test('passes a manifest dump carrying a configured value', () {
      const dump = '''
          E: meta-data
            A: android:name="com.google.android.geo.API_KEY"
            A: android:value="SYNTHETIC_MANIFEST_VALUE"
''';
      expect(packagedManifestHasPlaceholder(dump), isFalse);
    });
  });

  group('classifyMapsKey — full opacity', () {
    test('only ever returns one of the three opaque labels', () {
      expect(
        MapsKeyClass.values.map((value) => value.label).toSet(),
        _opaqueLabels,
      );
      for (final sample in <String>[
        '',
        '   ',
        mapsKeyPlaceholder,
        '  $mapsKeyPlaceholder  ',
        'SYNTHETIC_LOCAL_VALUE',
        'SYNTHETIC_NOT_A_REAL_KEY_M6AUDIT',
      ]) {
        expect(_opaqueLabels.contains(classifyMapsKey(sample).label), isTrue);
      }
    });

    test('never returns the value itself, any prefix, or a length', () {
      const configured = 'SYNTHETIC_NOT_A_REAL_KEY_M6AUDIT';
      final label = classifyMapsKey(configured).label;
      expect(label, isNot(contains(configured)));
      expect(label, isNot(contains(configured.substring(0, 6))));
      expect(label.toLowerCase(), isNot(contains('chars')));
      expect(label, isNot(contains(configured.length.toString())));
    });

    test('distinguishes empty, placeholder and configured', () {
      expect(classifyMapsKey(''), MapsKeyClass.empty);
      expect(classifyMapsKey('   '), MapsKeyClass.empty);
      expect(classifyMapsKey(mapsKeyPlaceholder), MapsKeyClass.placeholder);
      expect(
        classifyMapsKey('  $mapsKeyPlaceholder '),
        MapsKeyClass.placeholder,
      );
      expect(classifyMapsKey('SYNTHETIC_LOCAL_VALUE'), MapsKeyClass.configured);
    });

    test('no prefix/length capability remains in the gate sources', () {
      // Anti-regression guard for the removed `redacted()` helper, which used to
      // emit a six-character prefix plus the exact length of a configured value.
      // `readMapsKey` still legitimately splits a declaration with
      // `substring(0, separator)`, so the check targets the removed shapes
      // specifically rather than `substring` in general.
      for (final relative in <String>[
        'tool/maps_key_rules.dart',
        'tool/verify_maps_key.dart',
      ]) {
        final source = read(relative);
        expect(source.contains('substring(0, 6)'), isFalse, reason: relative);
        expect(
          source.toLowerCase().contains('chars'),
          isFalse,
          reason: relative,
        );
        expect(source.contains('redacted'), isFalse, reason: relative);
      }
    });
  });

  group('Gradle Maps guard structure', () {
    late String gradle;

    setUpAll(() => gradle = read('android/app/build.gradle.kts'));

    String mapsKeyRequestedBlock() {
      final start = gradle.indexOf('val mapsKeyRequested');
      expect(start, isNonNegative);
      final end = gradle.indexOf('}', start);
      return gradle.substring(start, end);
    }

    test('declares the plugin property name and the tracked placeholder', () {
      expect(
        gradle.contains('val mapsApiKeyProperty = "$mapsPropertyName"'),
        isTrue,
      );
      expect(
        gradle.contains('val mapsApiKeyPlaceholder = "$mapsKeyPlaceholder"'),
        isTrue,
      );
    });

    test('guards profile tasks and release tasks', () {
      final block = mapsKeyRequestedBlock();
      expect(block.contains('"Release"'), isTrue);
      expect(block.contains('"Profile"'), isTrue);
      expect(block.contains('ignoreCase = true'), isTrue);
    });

    test('leaves debug unguarded', () {
      // A debug build must stay buildable without a local secret, otherwise
      // ordinary `flutter run` and the widget suites stop working.
      expect(mapsKeyRequestedBlock().toLowerCase().contains('debug'), isFalse);
    });

    test('fails closed on blank and on the placeholder', () {
      expect(gradle.contains('resolvedMapsApiKey.isNullOrBlank()'), isTrue);
      expect(
        gradle.contains('resolvedMapsApiKey == mapsApiKeyPlaceholder'),
        isTrue,
      );
      expect(gradle.contains('mapsKeyRequested &&'), isTrue);
      expect(gradle.contains('throw GradleException('), isTrue);
    });

    test(
      'resolves from the two root-project files the plugin can substitute',
      () {
        expect(
          gradle.contains('rootProject.file("secrets.properties")'),
          isTrue,
        );
        expect(
          gradle.contains('rootProject.file("secrets.defaults.properties")'),
          isTrue,
        );
      },
    );

    test('accepts no source outside the plugin substitution law', () {
      // `project.file(...)` (module level) and the Gradle-property /
      // environment-variable fallbacks are NOT part of what
      // secrets-gradle-plugin 2.0.1 substitutes. Accepting them was a proven
      // false negative: the guard approved a build that still packaged the
      // placeholder. Strip the legitimate root-project references, then require
      // that no other file or fallback source remains.
      final withoutRootProject = gradle.replaceAll('rootProject.file(', '');
      expect(
        withoutRootProject.contains('.file("secrets.properties")'),
        isFalse,
      );
      expect(
        withoutRootProject.contains('.file("secrets.defaults.properties")'),
        isFalse,
      );
      // The release-signing guard legitimately reads its own environment
      // variables; the MAPS property specifically must not come from either
      // fallback.
      expect(
        withoutRootProject.contains('gradleProperty(mapsApiKeyProperty)'),
        isFalse,
      );
      expect(
        withoutRootProject.contains('environmentVariable(mapsApiKeyProperty)'),
        isFalse,
      );
    });

    test('parses properties the way the plugin does', () {
      // `java.util.Properties` cannot be referenced as `java.util.Properties()`
      // inside a .kts script: the bare name `java` resolves to Gradle's java
      // extension. The import supplies the type explicitly.
      expect(gradle.contains('import java.util.Properties'), isTrue);
      expect(gradle.contains('Properties()'), isTrue);
      expect(gradle.contains('properties.load('), isTrue);
    });
  });

  group('quality workflow — inverted Maps control', () {
    late String workflow;

    const marker =
        '- name: Verify Maps key gate rejects the placeholder artifact';

    setUpAll(() => workflow = read('.github/workflows/quality.yml'));

    String stepBlock(String name) {
      final start = workflow.indexOf('- name: $name');
      expect(start, isNonNegative, reason: 'step not found: $name');
      final next = workflow.indexOf('- name:', start + 8);
      return workflow.substring(start, next == -1 ? workflow.length : next);
    }

    test('the inverted Maps step exists', () {
      expect(workflow.contains(marker), isTrue);
    });

    test('it runs the real verifier against the debug artifact', () {
      final block = stepBlock(
        'Verify Maps key gate rejects the placeholder artifact',
      );
      expect(block.contains('dart run tool/verify_maps_key.dart'), isTrue);
      expect(
        block.contains('build/app/outputs/flutter-apk/app-debug.apk'),
        isTrue,
      );
    });

    test('it fails CI when the verifier unexpectedly passes', () {
      final block = stepBlock(
        'Verify Maps key gate rejects the placeholder artifact',
      );
      // Unexpected pass (exit 0) and unexpected failure (exit != 1) both fail CI.
      expect(block.contains('-eq 0'), isTrue);
      expect(block.contains('-ne 1'), isTrue);
      expect(block.contains('exit 1'), isTrue);
    });

    test(
      'it is positioned after Build debug APK and before the secret scan',
      () {
        final build = workflow.indexOf('- name: Build debug APK');
        final maps = workflow.indexOf(marker);
        final secrets = workflow.indexOf('- name: Scan repository for secrets');
        expect(build, isNonNegative);
        expect(secrets, isNonNegative);
        expect(maps, greaterThan(build));
        expect(maps, lessThan(secrets));
      },
    );

    test('it cannot be suppressed or disabled', () {
      final block = stepBlock(
        'Verify Maps key gate rejects the placeholder artifact',
      );
      expect(block.contains('continue-on-error'), isFalse);
      expect(block.contains('|| true'), isFalse);
      expect(block.contains('flutter build apk'), isFalse);
    });
  });

  group('secret path protection', () {
    test('both secret locations are ignored, the tracked defaults are not', () {
      final lines = read(
        '.gitignore',
      ).split('\n').map((line) => line.trim()).toSet();
      expect(lines.contains('android/secrets.properties'), isTrue);
      expect(lines.contains('android/app/secrets.properties'), isTrue);
      // The tracked fallback must stay tracked; a broad ignore that swallowed it
      // would silently remove the placeholder from the repository.
      expect(lines.contains('android/secrets.defaults.properties'), isFalse);
    });
  });

  group('runner SOURCE mode (real subprocess)', () {
    test('SOURCE-F1 no local secret and no defaults fails', () async {
      final repo = _syntheticRepo();
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root);
      expect(result.exitCode, 1);
    });

    test('SOURCE-F2 placeholder defaults fail', () async {
      final repo = _syntheticRepo(
        defaults: 'MAPS_API_KEY=$mapsKeyPlaceholder\n',
      );
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root);
      expect(result.exitCode, 1);
      expect(
        result.stderr.toString(),
        contains(MapsKeyClass.placeholder.label),
      );
    });

    test('SOURCE-F3 a blank local declaration fails as empty', () async {
      final repo = _syntheticRepo(
        local: 'MAPS_API_KEY=\n',
        defaults: 'MAPS_API_KEY=$mapsKeyPlaceholder\n',
      );
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root);
      expect(result.exitCode, 1);
      expect(result.stderr.toString(), contains(MapsKeyClass.empty.label));
    });

    test('SOURCE-F4 a synthetic configured local value passes', () async {
      final repo = _syntheticRepo(local: 'MAPS_API_KEY=$_syntheticValue\n');
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), contains('verify_maps_key: PASS'));
    });

    test('SOURCE-F5 the local file wins over placeholder defaults', () async {
      final repo = _syntheticRepo(
        local: 'MAPS_API_KEY=$_syntheticValue\n',
        defaults: 'MAPS_API_KEY=$mapsKeyPlaceholder\n',
      );
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root);
      expect(result.exitCode, 0);
    });

    test(
      'SOURCE-F6 output never carries the configured value or a prefix',
      () async {
        final repo = _syntheticRepo(local: 'MAPS_API_KEY=$_syntheticValue\n');
        addTearDown(() => repo.deleteSync(recursive: true));
        final result = await _runRunner(repo, root);
        final output = '${result.stdout}${result.stderr}';
        expect(output.contains(_syntheticValue), isFalse);
        expect(output.contains(_syntheticValue.substring(0, 6)), isFalse);
        expect(output.toLowerCase().contains('chars'), isFalse);
        expect(output.contains(_syntheticValue.length.toString()), isFalse);
      },
    );
  });

  group('runner CLI law', () {
    test('CLI-F1 an unknown argument is a usage error', () async {
      final repo = _syntheticRepo();
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root, ['--bogus']);
      expect(result.exitCode, 2);
    });

    test('CLI-F2 --apk without a path is a usage error', () async {
      final repo = _syntheticRepo();
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root, ['--apk']);
      expect(result.exitCode, 2);
    });

    test('CLI-F3 a duplicate --apk is a usage error', () async {
      final repo = _syntheticRepo();
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root, [
        '--apk',
        'first.apk',
        '--apk',
        'second.apk',
      ]);
      expect(result.exitCode, 2);
    });

    test('CLI-F4 an extra positional argument is a usage error', () async {
      final repo = _syntheticRepo();
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root, ['extra.apk']);
      expect(result.exitCode, 2);
    });

    test('CLI-F5 an unknown argument never falls back to SOURCE mode', () async {
      // SOURCE mode here would PASS (a configured synthetic value is present),
      // so a silent fallback would be indistinguishable from success. It must be
      // a usage error instead.
      final repo = _syntheticRepo(local: 'MAPS_API_KEY=$_syntheticValue\n');
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root, ['--not-a-flag']);
      expect(result.exitCode, 2);
      expect(result.stdout.toString(), isNot(contains('PASS')));
    });

    test('CLI-F6 usage text never echoes the offending argument', () async {
      final repo = _syntheticRepo();
      addTearDown(() => repo.deleteSync(recursive: true));
      final result = await _runRunner(repo, root, ['--$_syntheticValue']);
      expect(result.exitCode, 2);
      final output = '${result.stdout}${result.stderr}';
      expect(output.contains(_syntheticValue), isFalse);
    });
  });
}

/// A synthetic value that is obviously not a real key.
const String _syntheticValue = 'SYNTHETIC_NOT_A_REAL_KEY_M6AUDIT';

/// Creates a throwaway repository-shaped directory with synthetic secrets.
Directory _syntheticRepo({String? local, String? defaults}) {
  final repo = Directory.systemTemp.createTempSync('nt_m6_maps_');
  final android = Directory('${repo.path}${Platform.pathSeparator}android')
    ..createSync(recursive: true);
  final separator = Platform.pathSeparator;
  if (local != null) {
    File(
      '${android.path}${separator}secrets.properties',
    ).writeAsStringSync(local);
  }
  if (defaults != null) {
    File(
      '${android.path}${separator}secrets.defaults.properties',
    ).writeAsStringSync(defaults);
  }
  return repo;
}

/// Runs the REAL repository runner from [workingDirectory].
Future<ProcessResult> _runRunner(
  Directory workingDirectory,
  Directory root, [
  List<String> arguments = const <String>[],
]) {
  final runner = File(
    '${root.path}${Platform.pathSeparator}tool${Platform.pathSeparator}'
    'verify_maps_key.dart',
  );
  return Process.run(_dartExecutable(), <String>[
    'run',
    runner.path,
    ...arguments,
  ], workingDirectory: workingDirectory.path);
}

/// Locates the Dart SDK that is running this test, falling back to PATH.
String _dartExecutable() {
  final name = Platform.isWindows ? 'dart.exe' : 'dart';
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    final candidate = File(
      <String>[
        directory.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        name,
      ].join(Platform.pathSeparator),
    );
    if (candidate.existsSync()) return candidate.path;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  try {
    final probe = Process.runSync(name, const <String>['--version']);
    if (probe.exitCode == 0) return name;
  } on ProcessException {
    // Fall through to the explicit failure below.
  }
  fail(
    'Could not locate a Dart executable to subprocess the Maps runner. '
    'Ensure the Flutter/Dart SDK bin directory is on PATH.',
  );
}

/// Walks up from the working directory to the package root.
Directory _repositoryRoot() {
  var directory = Directory.current;
  for (var depth = 0; depth < 6; depth++) {
    final marker = File(
      <String>[
        directory.path,
        'tool',
        'maps_key_rules.dart',
      ].join(Platform.pathSeparator),
    );
    if (marker.existsSync()) return directory;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return Directory.current;
}
