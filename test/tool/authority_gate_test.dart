// M7: fail-first coverage for the reconciled authority gate.
//
// `tool/verify_authority.dart` is the repository's own authority gate and runs
// in `.github/workflows/quality.yml`. M7 (2026-09-16) reconciled four stale
// VS-08-era expectations against the ACCEPTED M1-M6 product:
//
//   1. MainActivity: `addFlags` was rejected wholesale, but the accepted
//      `social_app_home` bridge legitimately calls
//      `intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)`. The guard is narrowed
//      to window/screenshot manipulation.
//   2. Manifest: exactly one permission was demanded; the accepted scope is the
//      exact seven-permission set. Exact-set verification is used so an EIGHTH
//      permission still fails.
//   3. Dependencies: `workmanager:` was forbidden but is accepted at `90d5fd0`
//      and pinned `0.10.9`; the pin must be exact and other forbidden families
//      stay forbidden.
//   4. Schema: `?? 10` was demanded; the frozen product law is `?? 47`.
//
// M-3 (2026-09-21) replaced the manifest permission regex with real XML
// parsing. The final group pins the shapes that regex could not see, the
// structural laws (duplicates, scope attributes, missing names, malformed
// XML), and the positives that must still pass (whitespace, XML comments,
// attribute order on non-permission elements).
//
// This file proves BOTH directions, so the reconciliation cannot silently
// weaken the protections it preserves.
//
// The rule set lives in `tool/authority_rules.dart` (one source of truth, no
// new framework). The same MainActivity window guard is additionally asserted
// from the security suite in
// `test/core/security/screen_capture_policy_test.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/authority_rules.dart';

const String _mainActivityPath =
    'android/app/src/main/kotlin/com/nexttransfer/rmplanner/MainActivity.kt';
const String _manifestPath = 'android/app/src/main/AndroidManifest.xml';
const String _pubspecPath = 'pubspec.yaml';
const String _schemaPath = 'lib/core/database/app_database.dart';
const String _toolchainPath = 'tool/toolchain.json';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('authority gate — the accepted tree passes', () {
    test('accepted MainActivity keeps identity, the Intent bridge and no '
        'window/privacy manipulation', () {
      final text = _read(_mainActivityPath);

      expect(checkMainActivityKt(text), isEmpty);
      expect(text, contains(approvedMainActivityIntentFlag));
    });

    test('accepted manifest declares exactly the approved permission set', () {
      final text = _read(_manifestPath);

      expect(checkProductionManifest(text), isEmpty);
      expect(
        scanManifestPermissions(text).declarations.map((d) => d.name).toSet(),
        approvedManifestPermissions,
      );
      expect(approvedManifestPermissions, hasLength(7));
    });

    test('accepted pubspec pins every approved dependency exactly and carries '
        'no forbidden dependency family', () {
      final text = _read(_pubspecPath);

      expect(checkPubspec(text), isEmpty);
      expect(pinnedVersionOf(text, 'workmanager'), '0.10.9');
    });

    test('frozen schema boundary holds at version $approvedSchemaVersion', () {
      final text = _read(_schemaPath);

      expect(checkSchemaBoundary(text), isEmpty);
      expect(
        text,
        contains(
          'int get schemaVersion => '
          '_schemaVersionOverride ?? $approvedSchemaVersion',
        ),
      );
    });
  });

  group('authority gate — negative direction still fails', () {
    late String mainActivity;
    late String manifest;
    late String pubspec;
    late String schema;

    setUp(() {
      mainActivity = _read(_mainActivityPath);
      manifest = _read(_manifestPath);
      pubspec = _read(_pubspecPath);
      schema = _read(_schemaPath);
    });

    test('FLAG_SECURE introduced in MainActivity fails', () {
      expect(
        checkMainActivityKt('$mainActivity\nval blocked = "FLAG_SECURE"\n'),
        isNotEmpty,
      );
    });

    test('WindowManager privacy manipulation fails', () {
      expect(
        checkMainActivityKt(
          '$mainActivity\nimport android.view.WindowManager\n',
        ),
        isNotEmpty,
      );
    });

    test('window.addFlags manipulation fails', () {
      expect(
        checkMainActivityKt('$mainActivity\nwindow.addFlags(0)\n'),
        isNotEmpty,
      );
    });

    test('window.clearFlags manipulation fails', () {
      expect(
        checkMainActivityKt('$mainActivity\nwindow.clearFlags(0)\n'),
        isNotEmpty,
      );
    });

    test('losing the accepted Intent bridge flag fails', () {
      final stripped = mainActivity.replaceAll(
        'intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)',
        '// bridge flag removed',
      );

      expect(checkMainActivityKt(stripped), isNotEmpty);
    });

    test(
      'the accepted Intent bridge alone is authorized (no false positive)',
      () {
        const minimal =
            'package com.nexttransfer.rmplanner\n'
            'class MainActivity : FlutterFragmentActivity() {\n'
            '    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)\n'
            '}\n';

        expect(checkMainActivityKt(minimal), isEmpty);
      },
    );

    test('an eighth unexpected Android permission fails', () {
      final mutated = manifest.replaceFirst(
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission android:name="android.permission.INTERNET"/>\n'
            '    <uses-permission android:name="android.permission.CAMERA"/>',
      );

      expect(scanManifestPermissions(mutated).declarations, hasLength(8));
      expect(checkProductionManifest(mutated), isNotEmpty);
    });

    test('removing an expected permission fails', () {
      final mutated = manifest.replaceFirst(
        '<uses-permission android:name="android.permission.USE_BIOMETRIC"/>',
        '',
      );

      expect(checkProductionManifest(mutated), isNotEmpty);
    });

    test('weakening the backup policy fails', () {
      final mutated = manifest.replaceFirst(
        'android:allowBackup="false"',
        'android:allowBackup="true"',
      );

      expect(checkProductionManifest(mutated), isNotEmpty);
    });

    test('a changed WorkManager pin fails', () {
      final mutated = pubspec.replaceFirst(
        'workmanager: 0.10.9',
        'workmanager: 0.11.0',
      );

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('a loose WorkManager version spec fails', () {
      final mutated = pubspec.replaceFirst(
        'workmanager: 0.10.9',
        'workmanager: ^0.10.9',
      );

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('an unapproved dependency family fails', () {
      final mutated = pubspec.replaceFirst(
        '  workmanager: 0.10.9',
        '  workmanager: 0.10.9\n  file_picker: 10.0.0',
      );

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('the superseded schema 47 fails', () {
      final mutated = schema.replaceFirst('?? 48', '?? 47');

      expect(checkSchemaBoundary(mutated), isNotEmpty);
    });

    test('the superseded schema 10 fails', () {
      final mutated = schema.replaceFirst('?? 48', '?? 10');

      expect(checkSchemaBoundary(mutated), isNotEmpty);
    });

    test('a sensitive/token field entering the schema fails', () {
      final mutated = '$schema\n// StringColumn get accessToken => _x;\n';

      expect(checkSchemaBoundary(mutated), isNotEmpty);
    });

    test('removing a frozen schema declaration fails', () {
      final mutated = schema.replaceAll('WeeklyPlanGoalMemberships', 'X');

      expect(checkSchemaBoundary(mutated), isNotEmpty);
    });
  });

  group('authority gate — pin parsing', () {
    test('reads an exact pin from the dependencies block', () {
      expect(
        pinnedVersionOf('dependencies:\n  local_auth: 3.0.2\n', 'local_auth'),
        '3.0.2',
      );
    });

    test(
      'ignores comment lines and returns null when the package is absent',
      () {
        expect(
          pinnedVersionOf(
            'dependencies:\n  # local_auth: 9.9.9\n',
            'local_auth',
          ),
          isNull,
        );
      },
    );

    test('a dev_dependencies pin does not satisfy a dependencies pin', () {
      final pubspec =
          'dependencies:\n  intl: 0.20.3\n'
          'dev_dependencies:\n  local_auth: 3.0.2\n';

      expect(pinnedVersionOf(pubspec, 'local_auth'), isNull);
    });

    test('moving an approved pin out of dependencies fails the gate', () {
      final pubspec =
          'dependencies:\n  intl: 0.20.3\n'
          'dev_dependencies:\n  workmanager: 0.10.9\n';

      expect(checkPubspec(pubspec), isNotEmpty);
    });
  });

  // M-1c (2026-09-21): one ambiguous `"java": "17"` field became two explicit
  // ones. Both directions are proven for BOTH values, so neither the bytecode
  // target nor the build JDK can drift unnoticed again.
  group('authority gate — toolchain authority', () {
    late String toolchain;

    setUp(() {
      toolchain = _read(_toolchainPath);
    });

    test('the live toolchain.json satisfies the locked baseline', () {
      expect(checkToolchain(toolchain), isEmpty);
      expect(toolchain, contains('"flutter": "$approvedFlutterVersion"'));
      expect(
        toolchain,
        contains('"android_organization": "$approvedOrganization"'),
      );
    });

    test('the ambiguous single java field is gone', () {
      expect(toolchain, isNot(contains('"java"')));
    });

    test('the two Java facts are stated separately', () {
      expect(
        toolchain,
        contains('"java_bytecode_target": $approvedJavaBytecodeTarget'),
      );
      expect(toolchain, contains('"java_build_jdk": $approvedJavaBuildJdk'));
      expect(approvedJavaBytecodeTarget, 17);
      expect(approvedJavaBuildJdk, 21);
    });

    test('a build JDK pinned back to 17 fails', () {
      final mutated = toolchain.replaceFirst(
        '"java_build_jdk": 21',
        '"java_build_jdk": 17',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('a bytecode target raised to 21 fails', () {
      final mutated = toolchain.replaceFirst(
        '"java_bytecode_target": 17',
        '"java_bytecode_target": 21',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('a missing build JDK fails', () {
      final mutated = toolchain.replaceFirst(
        RegExp(r'\s*"java_build_jdk": 21,'),
        '',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('a missing bytecode target fails', () {
      final mutated = toolchain.replaceFirst(
        RegExp(r'\s*"java_bytecode_target": 17,'),
        '',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('a changed Flutter pin fails', () {
      final mutated = toolchain.replaceFirst(
        '"flutter": "3.44.7"',
        '"flutter": "3.44.6"',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('malformed JSON fails closed instead of throwing', () {
      expect(checkToolchain('{ not json'), isNotEmpty);
    });

    test('the controls are real: correcting a mutation restores a pass', () {
      final mutated = toolchain.replaceFirst(
        '"java_build_jdk": 21',
        '"java_build_jdk": 17',
      );

      expect(checkToolchain(mutated), isNotEmpty);
      expect(
        checkToolchain(
          mutated.replaceFirst('"java_build_jdk": 17', '"java_build_jdk": 21'),
        ),
        isEmpty,
      );
    });
  });

  // M-3: the source manifest is parsed as XML. Every mutation below is applied
  // to the REAL manifest text, so each case is a shape a real edit could take.
  //
  // N-8 (an eighth permission in the previously-matched shape) stays covered by
  // `an eighth unexpected Android permission fails` in the group above, and
  // N-13 / N-14 by `removing an expected permission fails` and `weakening the
  // backup policy fails`. This group covers the shapes the regex could not see
  // plus the structural laws.
  group('authority gate — M-3 manifest permissions are parsed as XML', () {
    const camera = 'android.permission.CAMERA';
    late String manifest;

    setUp(() => manifest = _read(_manifestPath));

    String withExtraPermission(String declaration) => manifest.replaceFirst(
      '<uses-permission android:name="android.permission.INTERNET"/>',
      '<uses-permission android:name="android.permission.INTERNET"/>\r\n'
          '    $declaration',
    );

    test('N-9 an eighth permission carrying android:maxSdkVersion fails', () {
      final failures = checkProductionManifest(
        withExtraPermission(
          '<uses-permission android:name="$camera" '
          'android:maxSdkVersion="32"/>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains(camera));
    });

    test('N-10 a reversed attribute order fails', () {
      final failures = checkProductionManifest(
        withExtraPermission(
          '<uses-permission android:maxSdkVersion="32" '
          'android:name="$camera"/>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains(camera));
    });

    test('N-11 an explicit closing tag fails', () {
      final failures = checkProductionManifest(
        withExtraPermission(
          '<uses-permission android:name="$camera"></uses-permission>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains(camera));
    });

    test('N-12 uses-permission-sdk-23 fails', () {
      final failures = checkProductionManifest(
        withExtraPermission('<uses-permission-sdk-23 android:name="$camera"/>'),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains(camera));
    });

    test('a bare <permission> definition is an unapproved declaration', () {
      final failures = checkProductionManifest(
        manifest.replaceFirst(
          '<application',
          '<permission android:name="com.example.ROGUE"/>\r\n    '
              '<application',
        ),
      );

      expect(failures, isNotEmpty);
    });

    test('N-16A a duplicated approved permission fails', () {
      final failures = checkProductionManifest(
        withExtraPermission(
          '<uses-permission android:name="android.permission.INTERNET"/>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('Duplicate Android permission'));
    });

    test('N-16B an approved permission carrying a scope attribute fails', () {
      final failures = checkProductionManifest(
        manifest.replaceFirst(
          '<uses-permission android:name="android.permission.INTERNET"/>',
          '<uses-permission android:name="android.permission.INTERNET" '
              'android:maxSdkVersion="32"/>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('unapproved attribute'));
      expect(failures.join(' '), contains('android:maxSdkVersion'));
    });

    test('N-16C a permission element with no android:name fails closed', () {
      final failures = checkProductionManifest(
        withExtraPermission('<uses-permission android:maxSdkVersion="32"/>'),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('has no android:name'));
    });

    test('N-16C2 an empty android:name fails closed', () {
      final failures = checkProductionManifest(
        withExtraPermission('<uses-permission android:name=""/>'),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('has no android:name'));
    });

    test('N-16D malformed manifest XML fails closed instead of throwing', () {
      final failures = checkProductionManifest(
        manifest.replaceFirst('</manifest>', '</manifest'),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('not well-formed XML'));
    });

    test('P-2 legal whitespace and line wrapping do not change authority', () {
      final rewrapped = manifest.replaceFirst(
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission\r\n'
            '        android:name="android.permission.INTERNET"\r\n'
            '        />',
      );

      expect(checkProductionManifest(rewrapped), isEmpty);
    });

    test('P-3 permission-looking text inside an XML comment is not a '
        'declaration', () {
      final commented = manifest.replaceFirst(
        '<manifest',
        '<!-- <uses-permission android:name="$camera"/> -->\r\n<manifest',
      );

      expect(checkProductionManifest(commented), isEmpty);
      expect(
        scanManifestPermissions(commented).declarations,
        hasLength(approvedManifestPermissions.length),
      );
    });

    test('P-4 attribute order on a non-permission element is irrelevant', () {
      final reordered = manifest.replaceFirstMapped(
        RegExp(
          r'(android:name="com\.google\.android\.geo\.API_KEY")\s+'
          r'(android:value="[^"]*")',
        ),
        (match) => '${match.group(2)}\n            ${match.group(1)}',
      );

      expect(
        reordered,
        isNot(equals(manifest)),
        reason: 'the reorder mutation must actually apply',
      );
      expect(checkProductionManifest(reordered), isEmpty);
    });
  });

  // M-7 (2026-09-22): the dependency law became structurally parsed. The M-7
  // forensic audit re-proved that the old raw-text rule had BOTH failure
  // directions at once — a quoted forbidden key evaded it, and a comment
  // mentioning a forbidden family failed it anywhere in the file. This group
  // pins the corrected behaviour, and the accepted tree, in both directions.
  group('authority gate — M-7 structural pubspec dependency law', () {
    late String pubspec;

    setUpAll(() => pubspec = _read(_pubspecPath));

    /// A synthetic pubspec satisfying every approved pin, so the only possible
    /// failure source is the rule under test.
    String approvedPins() {
      final buffer = StringBuffer('dependencies:\n');
      for (final entry in approvedDependencyPins.entries) {
        buffer.writeln('  ${entry.key}: ${entry.value}');
      }
      return buffer.toString();
    }

    test('LOCK-P1 the accepted pubspec parses cleanly and passes', () {
      final scan = scanPubspecDependencies(pubspec);

      expect(scan.failures, isEmpty);
      expect(scan.declarations, isNotEmpty);
      expect(checkPubspec(pubspec), isEmpty);
    });

    test('the synthetic baseline itself is clean', () {
      expect(checkPubspec(approvedPins()), isEmpty);
    });

    test('LF-N31A a double-quoted forbidden dependency fails', () {
      final mutated = '${approvedPins()}  "supabase_flutter": 1.0.0\n';

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('LF-N31B a single-quoted forbidden dependency fails', () {
      final mutated = "${approvedPins()}  'sentry_flutter': 8.0.0\n";

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('LF-N31C a quoted forbidden direct dev dependency fails', () {
      final mutated =
          '${approvedPins()}\ndev_dependencies:\n'
          '  "posthog_flutter": 4.0.0\n';

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('an unquoted forbidden dependency still fails (control)', () {
      final mutated = '${approvedPins()}  file_picker: 10.0.0\n';

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('LF-N32A a forbidden family only inside a dependency-block comment '
        'passes', () {
      final mutated =
          '${approvedPins()}  # supabase_flutter: forbidden by product policy\n';

      expect(checkPubspec(mutated), isEmpty);
    });

    test('LF-N32B a forbidden family only in a file-level comment passes', () {
      final mutated =
          '${approvedPins()}\n'
          '# do not add sentry_flutter: or firebase_analytics: here\n';

      expect(checkPubspec(mutated), isEmpty);
    });

    test('a forbidden family outside a dependency section is not a '
        'dependency', () {
      final mutated =
          '${approvedPins()}\nflutter:\n'
          '  # supabase_flutter: mentioned while documenting assets\n'
          '  uses-material-design: true\n';

      expect(checkPubspec(mutated), isEmpty);
    });

    test('an @insforge source marker in a dependency value fails', () {
      final mutated =
          '${approvedPins()}  custom_pkg:\n    git:\n'
          '      url: git@insforge.example.com:team/custom_pkg.git\n';

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('an @insforge mention inside a comment passes', () {
      final mutated = '${approvedPins()}  # never use @insforge sources\n';

      expect(checkPubspec(mutated), isEmpty);
    });

    test('nested map keys are not mistaken for package names', () {
      final scan = scanPubspecDependencies(
        'dependencies:\n  flutter:\n    sdk: flutter\n',
      );

      expect(scan.declarations.map((d) => d.name), ['flutter']);
      expect(scan.declarations.single.nestedKeys, ['sdk']);
      expect(scan.declarations.single.inlineVersion, isNull);
    });

    test('quoted, inline-commented and plain pins all resolve exactly', () {
      expect(
        pinnedVersionOf('dependencies:\n  intl: 0.20.3\n', 'intl'),
        '0.20.3',
      );
      expect(
        pinnedVersionOf('dependencies:\n  "intl": 0.20.3\n', 'intl'),
        '0.20.3',
      );
      expect(
        pinnedVersionOf('dependencies:\n  intl: 0.20.3 # pinned\n', 'intl'),
        '0.20.3',
      );
      // A git/map form carries no inline version; it must return null rather
      // than the old literal `git:` misparse.
      expect(
        pinnedVersionOf(
          'dependencies:\n  intl:\n    git:\n      url: x\n',
          'intl',
        ),
        isNull,
      );
    });

    test('a quoted approved pin still satisfies the exact pin law', () {
      final quoted = approvedPins().replaceFirst(
        '  local_auth: 3.0.2',
        '  "local_auth": 3.0.2',
      );

      expect(checkPubspec(quoted), isEmpty);
    });

    test('a large indentation delta still parses and is not silently '
        'dropped', () {
      final indented = approvedPins().replaceAll('\n  ', '\n    ');

      expect(checkPubspec(indented), isEmpty);
    });

    test('malformed dependency structure fails closed', () {
      final malformed = 'dependencies:\n  "unterminated: 1.0.0\n';

      expect(checkPubspec(malformed), isNotEmpty);
    });
  });

  // M-7: the RESOLVED graph. `pubspec.yaml` alone was never sufficient —
  // `flutter pub get`, `flutter pub deps` and an implicit `dart run`
  // resolution can each silently repair or regenerate `pubspec.lock` before any
  // gate observes it.
  group('authority gate — M-7 structural lockfile law', () {
    late String lockfile;

    setUpAll(() => lockfile = _read('pubspec.lock'));

    String entry(String name, String classification) =>
        '  $name:\n'
        '    dependency: $classification\n'
        '    description:\n'
        '      name: $name\n'
        '      sha256: "${'0' * 64}"\n'
        '      url: "https://pub.dev"\n'
        '    source: hosted\n'
        '    version: "1.0.0"\n';

    String lockOf(List<String> entries) => 'packages:\n${entries.join()}';

    test('LOCK-P1 the accepted lockfile parses cleanly and passes', () {
      final scan = scanLockfilePackages(lockfile);

      expect(scan.failures, isEmpty);
      expect(scan.packages, isNotEmpty);
      expect(checkLockfile(lockfile), isEmpty);
      expect(scan.packages.map((p) => p.name), contains('crypto'));
      expect(
        scan.packages.every((p) => p.classification.isNotEmpty),
        isTrue,
        reason: 'every resolved package must carry a classification',
      );
    });

    test('LF-N30 a forbidden family resolved only in the lockfile fails', () {
      final candidate = lockOf([
        entry('crypto', 'transitive'),
        entry('supabase_flutter', 'transitive'),
      ]);

      expect(checkLockfile(candidate), isNotEmpty);
    });

    test('a forbidden direct dev family fails and reports its '
        'classification', () {
      final failures = checkLockfile(
        lockOf([entry('sentry_flutter', '"direct dev"')]),
      );

      expect(failures, isNotEmpty);
      expect(failures.single, contains('direct dev'));
    });

    test('an insforge-sourced package fails', () {
      expect(
        checkLockfile(lockOf([entry('insforge_core', 'transitive')])),
        isNotEmpty,
      );
    });

    test('LF-F2 a duplicate package key fails', () {
      final failures = checkLockfile(
        lockOf([entry('crypto', 'transitive'), entry('crypto', 'transitive')]),
      );

      expect(failures, isNotEmpty);
      expect(failures.any((f) => f.contains('more than once')), isTrue);
    });

    test('LF-F1 a malformed lockfile fails closed instead of throwing', () {
      const malformed =
          'packages:\n  good:\n    dependency: transitive\n  broken\n';

      expect(() => checkLockfile(malformed), returnsNormally);
      expect(checkLockfile(malformed), isNotEmpty);
    });

    test('a lockfile with no packages map fails closed', () {
      expect(checkLockfile('not a lockfile'), isNotEmpty);
      expect(checkLockfile(''), isNotEmpty);
    });

    test('a package without a dependency classification fails', () {
      expect(
        checkLockfile('packages:\n  good:\n    source: hosted\n'),
        isNotEmpty,
      );
    });

    test('an empty resolution fails closed', () {
      expect(checkLockfile('packages:\n'), isNotEmpty);
    });

    test('lockfile failures never quote hashes, urls or description '
        'content', () {
      const canary = 'ZZ_M7_LEAK_CANARY';
      final candidate =
          'packages:\n'
          '  supabase_flutter:\n'
          '    dependency: transitive\n'
          '    description:\n'
          '      name: supabase_flutter\n'
          '      sha256: "${'a' * 64}"\n'
          '      url: "https://$canary.example.com"\n'
          '    source: hosted\n'
          '    version: "9.9.9"\n';

      final failures = checkLockfile(candidate).join('\n');

      expect(failures, contains('supabase_flutter'));
      expect(failures.contains(canary), isFalse);
      expect(failures.contains('https://'), isFalse);
      expect(failures.contains('a' * 64), isFalse);
      expect(failures.contains('9.9.9'), isFalse);
    });
  });

  // M-7: the workflow law. Detection only survives if the CI steps that
  // establish it cannot be quietly removed, replaced by the non-enforcing
  // command, or suppressed.
  group('authority gate — M-7 workflow lockfile law', () {
    late String workflow;

    setUpAll(() => workflow = _read('.github/workflows/quality.yml'));

    String stepBlock(String name) {
      final start = workflow.indexOf('- name: $name');
      expect(start, isNonNegative, reason: 'step not found: $name');
      final next = workflow.indexOf('- name:', start + 8);
      return workflow.substring(start, next == -1 ? workflow.length : next);
    }

    test(
      'dependency resolution is enforced against the committed lockfile',
      () {
        expect(workflow.contains('flutter pub get --enforce-lockfile'), isTrue);
      },
    );

    test(
      'ordinary non-enforced resolution is not substituted in its place',
      () {
        final bare = RegExp(r'^\s*flutter pub get\s*$', multiLine: true);

        expect(bare.hasMatch(workflow), isFalse);
        expect(
          stepBlock(
            'Resolve locked dependencies',
          ).contains('flutter pub get --enforce-lockfile'),
          isTrue,
        );
      },
    );

    test('the lockfile tree is asserted after enforced resolution', () {
      final block = stepBlock(
        'Verify the locked dependency resolution was not rewritten',
      );

      expect(block.contains('git status --porcelain -- pubspec.lock'), isTrue);
      expect(block.contains('exit 1'), isTrue);
    });

    test('the lockfile tree is asserted again after the dependency report', () {
      final assertion = workflow.indexOf(
        '- name: Verify pubspec.lock survived the dependency resolution report',
      );
      final report = workflow.indexOf('- name: Dependency resolution report');
      final tests = workflow.indexOf(
        '- name: VS-01 through VS-08 unit, repository, migration, and widget '
        'tests',
      );

      expect(assertion, isNonNegative);
      expect(report, isNonNegative);
      expect(assertion, greaterThan(report));
      if (tests != -1) expect(assertion, lessThan(tests));
      expect(
        stepBlock(
          'Verify pubspec.lock survived the dependency resolution report',
        ).contains('git status --porcelain -- pubspec.lock'),
        isTrue,
      );
    });

    test('the assertion uses git status, not git diff, for deletion safety', () {
      final block = stepBlock(
        'Verify the locked dependency resolution was not rewritten',
      );

      // `git diff -- pubspec.lock` misses a committed deletion, so it must not
      // be the assertion used here.
      expect(block.contains('git diff'), isFalse);
    });

    test('the lockfile steps cannot be suppressed or self-healed', () {
      for (final name in [
        'Verify the locked dependency resolution was not rewritten',
        'Verify pubspec.lock survived the dependency resolution report',
      ]) {
        final block = stepBlock(name);
        expect(block.contains('continue-on-error'), isFalse, reason: name);
        expect(block.contains('|| true'), isFalse, reason: name);
        expect(block.contains('git checkout'), isFalse, reason: name);
        expect(block.contains('git restore'), isFalse, reason: name);
        // The assertion steps observe; they must never resolve again.
        expect(block.contains('flutter pub'), isFalse, reason: name);
      }
    });
  });

  // M-7: the gitleaks configuration must stay demonstrably explicit and
  // maximally narrow, so the one proven historical false positive is retired
  // without disabling detection anywhere else.
  group('authority gate — M-7 gitleaks configuration', () {
    const sha = '25663c219e911608add8d05c2bcf024ef98c2b8c';
    const path = 'test/features/goals/domain/goal_icon_registry_test.dart';
    late String workflow;
    late String config;

    setUpAll(() {
      workflow = _read('.github/workflows/quality.yml');
      config = _read('.gitleaks.toml');
    });

    test(
      'the gitleaks step still exists and pins the explicit config path',
      () {
        expect(workflow.contains('gitleaks/gitleaks-action@v2'), isTrue);
        expect(workflow.contains('GITLEAKS_CONFIG: .gitleaks.toml'), isTrue);
      },
    );

    test('default rules are extended, never replaced', () {
      expect(config.contains('[extend]'), isTrue);
      expect(config.contains('useDefault = true'), isTrue);
    });

    test('the allowlist is scoped to generic-api-key only', () {
      expect(config.contains('id = "generic-api-key"'), isTrue);
      expect(
        RegExp(
          r'^\s*\[\[rules\]\]\s*$',
          multiLine: true,
        ).allMatches(config).length,
        1,
      );
      expect(
        RegExp(
          r'^\s*\[\[rules\.allowlists\]\]\s*$',
          multiLine: true,
        ).allMatches(config).length,
        1,
      );
    });

    test('the exact historical commit appears exactly once', () {
      expect(RegExp(sha).allMatches(config).length, 1);
    });

    test('the exact historical path is allowlisted', () {
      expect(config.contains(path.replaceAll('.', r'\.')), isTrue);
    });

    test('the allowlist requires BOTH the commit and the path', () {
      expect(config.contains('condition = "AND"'), isTrue);
    });

    test('no rule is disabled and no blanket path is exempted', () {
      expect(config.contains('disabled = '), isFalse);
      expect(config.contains('test/**'), isFalse);
      expect(config.contains('_test.dart'), isFalse);
      expect(config.contains('regexes'), isFalse);
      expect(config.contains('regexTarget'), isFalse);
      expect(config.contains('stopwords'), isFalse);
    });

    test('the matched value is not reproduced in the configuration', () {
      expect(RegExp(r'\b[0-9a-f]{64}\b').hasMatch(config), isFalse);
    });
  });
}
