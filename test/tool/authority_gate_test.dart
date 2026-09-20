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
      expect(declaredPermissions(text), approvedManifestPermissions);
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

      expect(declaredPermissions(mutated), hasLength(8));
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
}
