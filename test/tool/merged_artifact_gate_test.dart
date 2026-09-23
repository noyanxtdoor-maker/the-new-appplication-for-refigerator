// M-4 (2026-09-21) — fail-first coverage for the merged-artifact gate.
//
// M-3 protects SOURCE manifest truth; nothing protected the ARTIFACT. The debug
// APK carries 15 permissions, 3 activities, 7 receivers and 5 services after
// Android manifest merging and plugin contributions, and before M-4 no gate in
// this repository observed any of it.
//
// This file proves BOTH directions of the artifact gate from synthetic decoded
// manifests, so it needs no APK, no aapt2 and no build output — CI runs `flutter
// test` before the APK build. The real artifact positive control (N-20) is
// exercised by the runner itself (locally against a real APK, and in CI by the
// added `Verify merged Android artifact against the accepted baseline` step),
// never by a synthetic fixture here.
//
// Covered here:
//   N-17   extra merged permission                  -> FAIL
//   N-17b  baseline permission missing              -> FAIL
//   N-17c  duplicate uses-permission                -> FAIL
//   N-18   applicationId changed                    -> FAIL
//   N-18b  versionCode changed                      -> FAIL
//   N-18c  versionName changed                      -> FAIL
//   N-18d  minSdk / targetSdk changed               -> FAIL
//   N-19   component added                          -> FAIL
//   N-19b  component removed                        -> FAIL
//   N-19c  exported flag flipped                    -> FAIL
//   N-19d  duplicate component                      -> FAIL
//   N-19e  exported attribute REMOVED               -> FAIL
//   F-1    malformed / truncated / garbage dump     -> FAIL (structural)
//   F-2    dump lacking identity fields             -> FAIL
//   F-4    malformed baseline JSON                  -> FAIL
//   F-5    empty / incomplete baseline              -> FAIL
//   SC-1   marker metadata value never leaves       -> enforced
//   SC-2   arbitrary attribute values never quoted  -> enforced
//
// The rules live in `tool/merged_artifact_rules.dart` and the runner in
// `tool/verify_merged_artifact.dart` (one source of truth, no new framework),
// matching the existing `tool/authority_rules.dart` +
// `test/tool/authority_gate_test.dart` pairing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/authority_rules.dart';
import '../../tool/merged_artifact_rules.dart';

const String _baselinePath = 'tool/merged_artifact_baseline.json';
const String _runnerPath = 'tool/verify_merged_artifact.dart';
const String _androidNamespace = 'http://schemas.android.com/apk/res/android';
const String _appScopedPermission =
    'com.nexttransfer.rmplanner.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION';

/// A synthetic sensitive value that must NEVER leave the process.
const String _markerMetadataValue = 'M4_MARKER_METADATA_VALUE';
const String _arbitraryAttributeValue = 'M4_ARBITRARY_ATTRIBUTE_VALUE';

/// The owner-locked packaged permission set (15, sorted).
const List<String> _acceptedPermissions = <String>[
  'android.permission.ACCESS_COARSE_LOCATION',
  'android.permission.ACCESS_FINE_LOCATION',
  'android.permission.ACCESS_NETWORK_STATE',
  'android.permission.ACCESS_WIFI_STATE',
  'android.permission.FOREGROUND_SERVICE',
  'android.permission.FOREGROUND_SERVICE_SHORT_SERVICE',
  'android.permission.INTERNET',
  'android.permission.POST_NOTIFICATIONS',
  'android.permission.READ_CONTACTS',
  'android.permission.RECEIVE_BOOT_COMPLETED',
  'android.permission.USE_BIOMETRIC',
  'android.permission.USE_FINGERPRINT',
  'android.permission.VIBRATE',
  'android.permission.WAKE_LOCK',
  _appScopedPermission,
];

/// The owner-locked component surface, as `name::exported` specs.
const List<String> _acceptedActivities = <String>[
  'com.google.android.gms.common.api.GoogleApiActivity::false',
  'com.nexttransfer.rmplanner.MainActivity::true',
  'io.flutter.plugins.urllauncher.WebViewActivity::false',
];

const List<String> _acceptedReceivers = <String>[
  'androidx.profileinstaller.ProfileInstallReceiver::true',
  'androidx.work.impl.background.systemalarm.RescheduleReceiver::false',
  'androidx.work.impl.diagnostics.DiagnosticsReceiver::true',
  'androidx.work.impl.utils.ForceStopRunnable\$BroadcastReceiver::false',
  'com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver::false',
  'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver::false',
  'com.nexttransfer.rmplanner.ReminderRecoveryReceiver::false',
];

const List<String> _acceptedServices = <String>[
  'androidx.room.MultiInstanceInvalidationService::false',
  'androidx.work.impl.background.systemjob.SystemJobService::true',
  'androidx.work.impl.foreground.SystemForegroundService::false',
  'com.baseflow.geolocator.GeolocatorLocationService::false',
  'org.maplibre.android.plugins.offline.offline.OfflineDownloadService::false',
];

MergedArtifactBaseline _committedBaseline() =>
    MergedArtifactBaseline.parse(File(_baselinePath).readAsStringSync());

MergedArtifactModel _acceptedArtifact({
  int indentWidth = 2,
  String applicationId = 'com.nexttransfer.rmplanner',
  String versionName = '0.1.1',
  String versionCode = '5',
  String minSdk = '24',
  String targetSdk = '36',
  List<String>? usesPermissions,
  List<String>? declaredPermissions,
  List<String>? activities,
  List<String>? receivers,
  List<String>? services,
  bool exportedBeforeName = false,
  bool typedHexIntegers = false,
  bool booleanHexForm = false,
}) => parseMergedManifestDump(
  _manifestDump(
    indentWidth: indentWidth,
    applicationId: applicationId,
    versionName: versionName,
    versionCode: versionCode,
    minSdk: minSdk,
    targetSdk: targetSdk,
    usesPermissions: usesPermissions,
    declaredPermissions: declaredPermissions,
    activities: activities,
    receivers: receivers,
    services: services,
    exportedBeforeName: exportedBeforeName,
    typedHexIntegers: typedHexIntegers,
    booleanHexForm: booleanHexForm,
  ),
);

/// Builds a realistic `aapt2 dump xmltree` fixture (aapt2 36.0.0 shapes:
/// 2-space nesting, CRLF, `(Raw: "...")` echoes, resource-id suffixes), and
/// deliberately carries decoys that must never enter the model: a `queries`
/// package, an application-level `meta-data` holding a marker value, a
/// `provider`, and a nested `intent-filter`/`action` inside every component.
String _manifestDump({
  int indentWidth = 2,
  String applicationId = 'com.nexttransfer.rmplanner',
  String versionName = '0.1.1',
  String versionCode = '5',
  String minSdk = '24',
  String targetSdk = '36',
  List<String>? usesPermissions,
  List<String>? declaredPermissions,
  List<String>? activities,
  List<String>? receivers,
  List<String>? services,
  bool exportedBeforeName = false,
  bool typedHexIntegers = false,
  bool booleanHexForm = false,
  bool includeManifestElement = true,
  bool includeApplicationElement = true,
  bool includeUsesSdkElement = true,
  bool includePackageAttribute = true,
  bool includeVersionNameAttribute = true,
  bool includeVersionCodeAttribute = true,
  String format = 'crlf',
}) {
  final unit = ' ' * indentWidth;
  String at(int depth) => unit * depth;
  final permissions = usesPermissions ?? _acceptedPermissions;
  final declared = declaredPermissions ?? const <String>[_appScopedPermission];
  final terminal = format == 'crlf' ? '\r\n' : '\n';
  final buffer = StringBuffer();

  void line(int depth, String text) =>
      buffer.write('${at(depth)}$text$terminal');
  void attribute(int depth, String key, String value) =>
      line(depth, 'A: $_androidNamespace:$key(0x01010003)=$value');

  line(0, 'N: android=$_androidNamespace (line=2)');
  if (includeManifestElement) {
    line(1, 'E: manifest (line=2)');
    if (includeVersionCodeAttribute) {
      line(
        2,
        'A: $_androidNamespace:versionCode(0x0101021b)='
        '${typedHexIntegers ? '(type 0x10)0x${int.parse(versionCode).toRadixString(16)}' : versionCode}',
      );
    }
    if (includeVersionNameAttribute) {
      line(
        2,
        'A: $_androidNamespace:versionName(0x0101021c)="$versionName" '
        '(Raw: "$versionName")',
      );
    }
    if (includePackageAttribute) {
      line(2, 'A: package="$applicationId" (Raw: "$applicationId")');
    }
    line(2, 'A: platformBuildVersionCode=36');
    line(2, 'A: platformBuildVersionName=16');

    if (includeUsesSdkElement) {
      line(3, 'E: uses-sdk (line=7)');
      line(
        4,
        'A: $_androidNamespace:minSdkVersion(0x0101020c)='
        '${typedHexIntegers ? '(type 0x10)0x${int.parse(minSdk).toRadixString(16)}' : minSdk}',
      );
      line(
        4,
        'A: $_androidNamespace:targetSdkVersion(0x01010270)='
        '${typedHexIntegers ? '(type 0x10)0x${int.parse(targetSdk).toRadixString(16)}' : targetSdk}',
      );
    }

    for (final permission in permissions) {
      line(3, 'E: uses-permission (line=15)');
      attribute(4, 'name', '"$permission" (Raw: "$permission")');
    }

    for (final declaration in declared) {
      line(3, 'E: permission (line=19)');
      attribute(4, 'name', '"$declaration" (Raw: "$declaration")');
      line(4, 'A: $_androidNamespace:protectionLevel(0x01010009)=0x2');
    }

    // Decoy: a <queries> block. Its <package> children are NOT components.
    line(3, 'E: queries (line=30)');
    line(4, 'E: package (line=31)');
    attribute(
      5,
      'name',
      '"com.dexterous.flutterlocalnotifications" '
          '(Raw: "com.dexterous.flutterlocalnotifications")',
    );

    if (includeApplicationElement) {
      line(3, 'E: application (line=40)');
      line(4, 'A: $_androidNamespace:label(0x01010001)="Next Transfer"');
      line(4, 'A: $_androidNamespace:allowBackup(0x01010280)=false');

      // Decoy: application-level meta-data carrying a sensitive marker.
      line(4, 'E: meta-data (line=44)');
      attribute(5, 'name', '"com.google.android.geo.API_KEY"');
      line(
        5,
        'A: $_androidNamespace:value(0x01010024)="$_markerMetadataValue"',
      );

      // Decoy: a provider. Providers are deliberately NOT baselined in M-4.
      line(4, 'E: provider (line=48)');
      attribute(5, 'name', '"androidx.startup.InitializationProvider"');

      _writeComponents(
        buffer: buffer,
        element: 'activity',
        specs: activities ?? _acceptedActivities,
        depth: 4,
        indentWidth: indentWidth,
        exportedBeforeName: exportedBeforeName,
        booleanHexForm: booleanHexForm,
      );
      _writeComponents(
        buffer: buffer,
        element: 'receiver',
        specs: receivers ?? _acceptedReceivers,
        depth: 4,
        indentWidth: indentWidth,
        exportedBeforeName: exportedBeforeName,
        booleanHexForm: booleanHexForm,
      );
      _writeComponents(
        buffer: buffer,
        element: 'service',
        specs: services ?? _acceptedServices,
        depth: 4,
        indentWidth: indentWidth,
        exportedBeforeName: exportedBeforeName,
        booleanHexForm: booleanHexForm,
      );
    }
  }
  return buffer.toString();
}

void _writeComponents({
  required StringBuffer buffer,
  required String element,
  required List<String> specs,
  required int depth,
  required int indentWidth,
  required bool exportedBeforeName,
  required bool booleanHexForm,
}) {
  final unit = ' ' * indentWidth;
  String at(int value) => unit * value;
  final terminal = buffer.toString().endsWith('\r\n') ? '\r\n' : '\n';
  for (final spec in specs) {
    final separator = spec.lastIndexOf('::');
    final name = spec.substring(0, separator);
    final exportedToken = spec.substring(separator + 2);
    buffer.write('${at(depth)}E: $element (line=100)$terminal');
    final nameLine =
        '${at(depth + 1)}A: $_androidNamespace:name(0x01010003)="$name" '
        '(Raw: "$name")$terminal';
    final exportedLine = exportedToken == 'absent'
        ? ''
        : '${at(depth + 1)}A: $_androidNamespace:exported(0x01010010)='
              '${booleanHexForm ? (exportedToken == 'true' ? '(type 0x12)0xffffffff' : '(type 0x12)0x0') : exportedToken}$terminal';
    if (exportedBeforeName) {
      buffer
        ..write(exportedLine)
        ..write(nameLine);
    } else {
      buffer
        ..write(nameLine)
        ..write(exportedLine);
    }
    // Nested decoys: these names must never be mistaken for the component.
    buffer
      ..write('${at(depth + 1)}E: intent-filter (line=101)$terminal')
      ..write(
        '${at(depth + 2)}A: $_androidNamespace:priority(0x0101001c)=0$terminal',
      )
      ..write('${at(depth + 2)}E: action (line=102)$terminal')
      ..write(
        '${at(depth + 3)}A: $_androidNamespace:name(0x01010003)='
        '"android.intent.action.MAIN" (Raw: "android.intent.action.MAIN")$terminal',
      );
  }
}

void main() {
  group('parser — the accepted packaged surface', () {
    test('decodes identity, the 15 permissions, the declared permission and '
        'the 3/7/5 component surface', () {
      final artifact = _acceptedArtifact();

      expect(artifact.identity.applicationId, 'com.nexttransfer.rmplanner');
      expect(artifact.identity.versionName, '0.1.1');
      expect(artifact.identity.versionCode, 5);
      expect(artifact.identity.minSdk, 24);
      expect(artifact.identity.targetSdk, 36);
      expect(artifact.usesPermissions.toSet(), _acceptedPermissions.toSet());
      expect(artifact.usesPermissions, hasLength(15));
      expect(artifact.declaredPermissions, <String>[_appScopedPermission]);
      expect(
        artifact.activities.map((component) => component.name).toList(),
        <String>[
          'com.google.android.gms.common.api.GoogleApiActivity',
          'com.nexttransfer.rmplanner.MainActivity',
          'io.flutter.plugins.urllauncher.WebViewActivity',
        ],
      );
      expect(artifact.activities[1].exported, isTrue);
      expect(artifact.receivers, hasLength(7));
      expect(artifact.services, hasLength(5));
      expect(
        artifact.services
            .firstWhere(
              (component) =>
                  component.name ==
                  'androidx.work.impl.background.systemjob.SystemJobService',
            )
            .exported,
        isTrue,
      );
    });

    test('the accepted packaged surface matches the committed baseline '
        'exactly', () {
      expect(
        compareMergedArtifact(
          artifact: _acceptedArtifact(),
          baseline: _committedBaseline(),
        ),
        isEmpty,
      );
    });

    test('nested intent-filter/action names never leak into component names '
        '(the indentation-naive trap)', () {
      final artifact = _acceptedArtifact();

      final allNames = <String>{
        ...artifact.activities.map((component) => component.name),
        ...artifact.receivers.map((component) => component.name),
        ...artifact.services.map((component) => component.name),
      };
      expect(allNames, hasLength(15));
      expect(
        allNames.where((name) => name.startsWith('android.intent.')),
        isEmpty,
      );
    });

    test('queries packages and providers are not components', () {
      final artifact = _acceptedArtifact();

      final names = <String>[
        ...artifact.activities.map((component) => component.name),
        ...artifact.receivers.map((component) => component.name),
        ...artifact.services.map((component) => component.name),
      ];
      expect(names, isNot(contains('com.dexterous.flutterlocalnotifications')));
      expect(names, isNot(contains('androidx.startup.InitializationProvider')));
    });

    test('serializing the sanitized model exposes whitelisted fields only', () {
      final sanitized = _acceptedArtifact().toSanitizedJson();
      final encoded = const JsonEncoder.withIndent('  ').convert(sanitized);

      expect(sanitized.keys, <String>[
        'applicationId',
        'versionName',
        'versionCode',
        'minSdk',
        'targetSdk',
        'usesPermissions',
        'declaredPermissions',
        'activities',
        'receivers',
        'services',
      ]);
      expect(encoded, isNot(contains(_markerMetadataValue)));
      expect(encoded, isNot(contains('com.google.android.geo.API_KEY')));
      expect(encoded, isNot(contains('InitializationProvider')));
      expect(encoded, isNot(contains('android.intent.action.MAIN')));
      expect(encoded, isNot(contains('E: ')));
      expect(encoded, isNot(contains('A: ')));
    });
  });

  group('parser — robustness (shape must not decide the answer)', () {
    test('indentation WIDTH does not matter', () {
      final reference = _acceptedArtifact().toSanitizedJson();

      for (final width in <int>[1, 2, 4, 8]) {
        expect(
          _acceptedArtifact(indentWidth: width).toSanitizedJson(),
          reference,
          reason: 'indent width $width',
        );
      }
    });

    test('attribute order does not matter', () {
      expect(
        _acceptedArtifact(exportedBeforeName: true).toSanitizedJson(),
        _acceptedArtifact().toSanitizedJson(),
      );
    });

    test('typed-hex integers decode like bare integers', () {
      final typed = _acceptedArtifact(typedHexIntegers: true);

      expect(typed.identity.versionCode, 5);
      expect(typed.identity.minSdk, 24);
      expect(typed.identity.targetSdk, 36);
      expect(typed.toSanitizedJson(), _acceptedArtifact().toSanitizedJson());
    });

    test('hex-encoded booleans decode like literal booleans', () {
      expect(
        _acceptedArtifact(booleanHexForm: true).toSanitizedJson(),
        _acceptedArtifact().toSanitizedJson(),
      );
    });

    test('LF and CRLF line endings decode identically', () {
      expect(
        _acceptedArtifact().toSanitizedJson(),
        parseMergedManifestDump(_manifestDump(format: 'lf')).toSanitizedJson(),
      );
    });

    test('a class name containing \$ is preserved verbatim', () {
      final artifact = _acceptedArtifact();

      expect(
        artifact.receivers.map((component) => component.name),
        contains(
          'androidx.work.impl.utils.ForceStopRunnable\$BroadcastReceiver',
        ),
      );
    });

    test('exportedFromDecoded is tri-state and rejects nonsense', () {
      expect(exportedFromDecoded(null), isNull);
      expect(exportedFromDecoded(true), isTrue);
      expect(exportedFromDecoded(false), isFalse);
      expect(exportedFromDecoded(1), isTrue);
      expect(exportedFromDecoded(-1), isTrue);
      expect(exportedFromDecoded(0), isFalse);
      expect(
        () => exportedFromDecoded(42),
        throwsA(isA<MergedArtifactParseException>()),
      );
      expect(
        () => exportedFromDecoded('yes'),
        throwsA(isA<MergedArtifactParseException>()),
      );
    });
  });

  group('parser — fail-closed (F-1, F-2)', () {
    test('F-1: an empty decode fails with a structural message', () {
      expect(
        () => parseMergedManifestDump(''),
        throwsA(
          isA<MergedArtifactParseException>().having(
            (error) => error.message,
            'message',
            contains('empty'),
          ),
        ),
      );
      expect(
        () => parseMergedManifestDump('   \r\n  \r\n'),
        throwsA(isA<MergedArtifactParseException>()),
      );
    });

    test('F-1: garbage and truncated decodes fail, never crash', () {
      expect(
        () => parseMergedManifestDump('not aapt2 output at all'),
        throwsA(isA<MergedArtifactParseException>()),
      );
      expect(
        () => parseMergedManifestDump(
          '  E: manifest (line=2)\r\n    A: package="x" (Raw: "x")',
        ),
        throwsA(isA<MergedArtifactParseException>()),
      );
      expect(
        () => parseMergedManifestDump(
          _manifestDump(includeManifestElement: false),
        ),
        throwsA(
          isA<MergedArtifactParseException>().having(
            (error) => error.message,
            'message',
            contains('<manifest>'),
          ),
        ),
      );
      expect(
        () => parseMergedManifestDump(
          _manifestDump(includeApplicationElement: false),
        ),
        throwsA(
          isA<MergedArtifactParseException>().having(
            (error) => error.message,
            'message',
            contains('<application>'),
          ),
        ),
      );
    });

    test('F-2: missing identity fields fail with the field named', () {
      expect(
        () => parseMergedManifestDump(
          _manifestDump(includeUsesSdkElement: false),
        ),
        throwsA(
          isA<MergedArtifactParseException>().having(
            (error) => error.message,
            'message',
            contains('uses-sdk'),
          ),
        ),
      );
      expect(
        () => parseMergedManifestDump(
          _manifestDump(includePackageAttribute: false),
        ),
        throwsA(
          isA<MergedArtifactParseException>().having(
            (error) => error.message,
            'message',
            contains('package'),
          ),
        ),
      );
      expect(
        () => parseMergedManifestDump(
          _manifestDump(includeVersionNameAttribute: false),
        ),
        throwsA(
          isA<MergedArtifactParseException>().having(
            (error) => error.message,
            'message',
            contains('versionName'),
          ),
        ),
      );
      expect(
        () => parseMergedManifestDump(
          _manifestDump(includeVersionCodeAttribute: false),
        ),
        throwsA(
          isA<MergedArtifactParseException>().having(
            (error) => error.message,
            'message',
            contains('versionCode'),
          ),
        ),
      );
    });

    test(
      'F-2: an unrecognised value FORM is named structurally, never echoed',
      () {
        final dump = _manifestDump().replaceFirst(
          'versionCode(0x0101021b)=5',
          'versionCode(0x0101021b)=@ref/0x7f0a0000',
        );

        expect(
          () => parseMergedManifestDump(dump),
          throwsA(
            isA<MergedArtifactParseException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('versionCode'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('0x7f0a0000')),
                ),
          ),
        );
      },
    );
  });

  group('baseline — fail-closed (F-4, F-5)', () {
    final valid = _committedBaseline();

    test(
      'the committed baseline parses and pins the owner-locked identity',
      () {
        expect(valid.identity.applicationId, 'com.nexttransfer.rmplanner');
        expect(valid.identity.versionName, '0.1.1');
        expect(valid.identity.versionCode, 5);
        expect(valid.identity.minSdk, 24);
        expect(valid.identity.targetSdk, 36);
      },
    );

    test('F-5: an empty baseline fails', () {
      expect(
        () => MergedArtifactBaseline.parse(''),
        throwsA(isA<MergedArtifactBaselineException>()),
      );
      expect(
        () => MergedArtifactBaseline.parse('   '),
        throwsA(isA<MergedArtifactBaselineException>()),
      );
    });

    test('F-4: malformed JSON fails', () {
      expect(
        () => MergedArtifactBaseline.parse('{ "baselineFormat": '),
        throwsA(
          isA<MergedArtifactBaselineException>().having(
            (error) => error.message,
            'message',
            contains('valid JSON'),
          ),
        ),
      );
      expect(
        () => MergedArtifactBaseline.parse('[1, 2, 3]'),
        throwsA(
          isA<MergedArtifactBaselineException>().having(
            (error) => error.message,
            'message',
            contains('JSON object'),
          ),
        ),
      );
    });

    test('F-5: a wrong or missing format marker fails', () {
      expect(
        () => MergedArtifactBaseline.parse('{"applicationId": "x"}'),
        throwsA(
          isA<MergedArtifactBaselineException>().having(
            (error) => error.message,
            'message',
            contains('baselineFormat'),
          ),
        ),
      );
      final wrongFormat = Map<String, Object?>.from(
        jsonDecode(File(_baselinePath).readAsStringSync()) as Map,
      )..['baselineFormat'] = 2;
      expect(
        () => MergedArtifactBaseline.parseJson(wrongFormat),
        throwsA(isA<MergedArtifactBaselineException>()),
      );
    });

    test(
      'F-5: empty identity fields, empty lists and incomplete entries fail',
      () {
        Map<String, Object?> copy() => Map<String, Object?>.from(
          jsonDecode(File(_baselinePath).readAsStringSync()) as Map,
        );

        expect(
          () =>
              MergedArtifactBaseline.parseJson(copy()..['applicationId'] = ''),
          throwsA(isA<MergedArtifactBaselineException>()),
        );
        expect(
          () => MergedArtifactBaseline.parseJson(copy()..['minSdk'] = null),
          throwsA(
            isA<MergedArtifactBaselineException>().having(
              (error) => error.message,
              'message',
              contains('minSdk'),
            ),
          ),
        );
        expect(
          () => MergedArtifactBaseline.parseJson(
            copy()..['usesPermissions'] = <String>[],
          ),
          throwsA(isA<MergedArtifactBaselineException>()),
        );
        expect(
          () => MergedArtifactBaseline.parseJson(
            copy()..['services'] = <Object?>[],
          ),
          throwsA(isA<MergedArtifactBaselineException>()),
        );
        expect(
          () => MergedArtifactBaseline.parseJson(copy()..remove('receivers')),
          throwsA(isA<MergedArtifactBaselineException>()),
        );
        expect(
          () => MergedArtifactBaseline.parseJson(
            copy()
              ..['activities'] = <Object?>[
                <String, Object?>{'name': 'a.b.C'},
              ],
          ),
          throwsA(
            isA<MergedArtifactBaselineException>().having(
              (error) => error.message,
              'message',
              contains('exported'),
            ),
          ),
        );
        expect(
          () => MergedArtifactBaseline.parseJson(
            copy()
              ..['activities'] = <Object?>[
                <String, Object?>{'name': '', 'exported': true},
              ],
          ),
          throwsA(isA<MergedArtifactBaselineException>()),
        );
      },
    );

    test('F-5: duplicate baseline entries fail closed', () {
      Map<String, Object?> copy() => Map<String, Object?>.from(
        jsonDecode(File(_baselinePath).readAsStringSync()) as Map,
      );

      expect(
        () => MergedArtifactBaseline.parseJson(
          copy()
            ..['usesPermissions'] = <String>[
              'android.permission.INTERNET',
              'android.permission.INTERNET',
            ],
        ),
        throwsA(
          isA<MergedArtifactBaselineException>().having(
            (error) => error.message,
            'message',
            contains('duplicate'),
          ),
        ),
      );
      expect(
        () => MergedArtifactBaseline.parseJson(
          copy()
            ..['activities'] = <Object?>[
              <String, Object?>{'name': 'a.b.C', 'exported': true},
              <String, Object?>{'name': 'a.b.C', 'exported': false},
            ],
        ),
        throwsA(
          isA<MergedArtifactBaselineException>().having(
            (error) => error.message,
            'message',
            contains('duplicate'),
          ),
        ),
      );
    });
  });

  group('negative controls N-17 .. N-19e', () {
    final baseline = _committedBaseline();

    List<String> differencesFor(MergedArtifactModel artifact) =>
        compareMergedArtifact(artifact: artifact, baseline: baseline);

    test('N-17: an extra merged permission fails', () {
      final differences = differencesFor(
        _acceptedArtifact(
          usesPermissions: <String>[
            ..._acceptedPermissions,
            'android.permission.CAMERA',
          ],
        ),
      );

      expect(
        differences,
        contains(
          'Unexpected merged permission in the artifact: '
          'android.permission.CAMERA',
        ),
      );
    });

    test('N-17b: a baseline permission missing from the artifact fails', () {
      final differences = differencesFor(
        _acceptedArtifact(
          usesPermissions: <String>[
            for (final permission in _acceptedPermissions)
              if (permission != 'android.permission.INTERNET') permission,
          ],
        ),
      );

      expect(
        differences,
        contains(
          'Baseline merged permission missing from the artifact: '
          'android.permission.INTERNET',
        ),
      );
    });

    test('N-17c: a duplicate uses-permission fails', () {
      final differences = differencesFor(
        _acceptedArtifact(
          usesPermissions: <String>[
            ..._acceptedPermissions,
            'android.permission.INTERNET',
          ],
        ),
      );

      expect(
        differences,
        contains(
          'Duplicate merged permission in the artifact: '
          'android.permission.INTERNET appears 2 times; the baseline declares '
          'it exactly once',
        ),
      );
    });

    test('N-18: a changed applicationId fails', () {
      expect(
        differencesFor(_acceptedArtifact(applicationId: 'com.example.other')),
        contains(
          'applicationId is com.example.other; baseline expects '
          'com.nexttransfer.rmplanner',
        ),
      );
    });

    test('N-18b: a changed versionCode fails', () {
      expect(
        differencesFor(_acceptedArtifact(versionCode: '4')),
        contains('versionCode is 4; baseline expects 5'),
      );
    });

    test('N-18c: a changed versionName fails', () {
      expect(
        differencesFor(_acceptedArtifact(versionName: '0.1.2')),
        contains('versionName is 0.1.2; baseline expects 0.1.1'),
      );
    });

    test('N-18d: a changed minSdk or targetSdk fails', () {
      expect(
        differencesFor(_acceptedArtifact(minSdk: '26')),
        contains('minSdk is 26; baseline expects 24'),
      );
      expect(
        differencesFor(_acceptedArtifact(targetSdk: '35')),
        contains('targetSdk is 35; baseline expects 36'),
      );
    });

    test('N-19: an added activity, receiver or service fails', () {
      expect(
        differencesFor(
          _acceptedArtifact(
            activities: <String>[
              ..._acceptedActivities,
              'com.example.InjectedActivity::false',
            ],
          ),
        ),
        contains(
          'Unexpected activity in the artifact: com.example.InjectedActivity '
          '(exported false)',
        ),
      );
      expect(
        differencesFor(
          _acceptedArtifact(
            receivers: <String>[
              ..._acceptedReceivers,
              'com.example.InjectedReceiver::true',
            ],
          ),
        ),
        contains(
          'Unexpected receiver in the artifact: com.example.InjectedReceiver '
          '(exported true)',
        ),
      );
      expect(
        differencesFor(
          _acceptedArtifact(
            services: <String>[
              ..._acceptedServices,
              'com.example.InjectedService::false',
            ],
          ),
        ),
        contains(
          'Unexpected service in the artifact: com.example.InjectedService '
          '(exported false)',
        ),
      );
    });

    test('N-19b: a removed component fails', () {
      expect(
        differencesFor(
          _acceptedArtifact(
            services: <String>[
              for (final service in _acceptedServices)
                if (!service.startsWith('com.baseflow.geolocator')) service,
            ],
          ),
        ),
        contains(
          'Baseline service missing from the artifact: '
          'com.baseflow.geolocator.GeolocatorLocationService',
        ),
      );
    });

    test('N-19c: a flipped exported flag fails', () {
      expect(
        differencesFor(
          _acceptedArtifact(
            receivers: <String>[
              for (final receiver in _acceptedReceivers)
                if (receiver.startsWith('com.nexttransfer.rmplanner'))
                  'com.nexttransfer.rmplanner.ReminderRecoveryReceiver::true'
                else
                  receiver,
            ],
          ),
        ),
        contains(
          'Merged receiver com.nexttransfer.rmplanner.ReminderRecoveryReceiver '
          'exported is true; baseline expects false',
        ),
      );
    });

    test('N-19d: a duplicate component fails', () {
      expect(
        differencesFor(
          _acceptedArtifact(
            receivers: <String>[
              ..._acceptedReceivers,
              'com.nexttransfer.rmplanner.ReminderRecoveryReceiver::false',
            ],
          ),
        ),
        contains(
          'Duplicate receiver in the artifact: '
          'com.nexttransfer.rmplanner.ReminderRecoveryReceiver appears 2 times; '
          'the baseline declares it exactly once',
        ),
      );
    });

    test('N-19e: a REMOVED exported attribute fails', () {
      expect(
        differencesFor(
          _acceptedArtifact(
            activities: <String>[
              for (final activity in _acceptedActivities)
                if (activity.startsWith('com.nexttransfer.rmplanner'))
                  'com.nexttransfer.rmplanner.MainActivity::absent'
                else
                  activity,
            ],
          ),
        ),
        contains(
          'Merged activity com.nexttransfer.rmplanner.MainActivity exported is '
          'absent (no android:exported attribute); baseline expects true',
        ),
      );
    });

    test(
      'all twelve controls fail loudly and none of them passes silently',
      () {
        final mutations = <String, MergedArtifactModel>{
          'extra permission': _acceptedArtifact(
            usesPermissions: <String>[
              ..._acceptedPermissions,
              'android.permission.CAMERA',
            ],
          ),
          'missing permission': _acceptedArtifact(
            usesPermissions: <String>['android.permission.INTERNET'],
          ),
          'changed identity': _acceptedArtifact(versionName: '9.9.9'),
          'added component': _acceptedArtifact(
            services: <String>[..._acceptedServices, 'com.example.X::false'],
          ),
          'removed component': _acceptedArtifact(services: <String>[]),
          'flipped exported': _acceptedArtifact(
            activities: <String>[
              'com.nexttransfer.rmplanner.MainActivity::false',
            ],
          ),
        };

        for (final entry in mutations.entries) {
          expect(differencesFor(entry.value), isNotEmpty, reason: entry.key);
        }
      },
    );
  });

  group('sanitization controls SC-1 / SC-2', () {
    test('SC-1: the marker metadata value is never exposed, even on FAIL', () {
      final differences = compareMergedArtifact(
        artifact: _acceptedArtifact(
          usesPermissions: <String>[
            ..._acceptedPermissions,
            'android.permission.CAMERA',
          ],
        ),
        baseline: _committedBaseline(),
      );

      expect(differences, isNotEmpty);
      final joined = differences.join('\n');
      expect(joined, isNot(contains(_markerMetadataValue)));
      expect(joined, isNot(contains('com.google.android.geo.API_KEY')));
      expect(joined, isNot(contains('E: ')));
      expect(joined, isNot(contains('A: ')));
      expect(joined, isNot(contains('(Raw:')));
    });

    test('SC-2: a malformed dump with arbitrary attribute values reports '
        'structure only', () {
      final dump =
          _manifestDump(
            includePackageAttribute: false,
            includeApplicationElement: false,
          ).replaceFirst(
            'minSdkVersion(0x0101020c)=24',
            'minSdkVersion(0x0101020c)="$_arbitraryAttributeValue"',
          );

      Object? captured;
      try {
        parseMergedManifestDump(dump);
      } on MergedArtifactParseException catch (error) {
        captured = error;
      }

      expect(captured, isA<MergedArtifactParseException>());
      final message = captured.toString();
      expect(message, isNot(contains(_arbitraryAttributeValue)));
      expect(message, isNot(contains('A: ')));
      expect(message, isNot(contains('(Raw:')));
      expect(message, isNot(contains('E: ')));
    });
  });

  group('committed baseline self-integrity and drift visibility', () {
    final baseline = _committedBaseline();

    test('declares exactly the owner-locked 15 permissions', () {
      expect(baseline.usesPermissions, hasLength(15));
      expect(baseline.usesPermissions.toSet(), _acceptedPermissions.toSet());
      expect(baseline.declaredPermissions, <String>[_appScopedPermission]);
    });

    test('declares exactly 3 activities, 7 receivers and 5 services with '
        'tri-state exported', () {
      expect(baseline.activities, hasLength(3));
      expect(baseline.receivers, hasLength(7));
      expect(baseline.services, hasLength(5));
      expect(
        baseline.activities.map((component) => component.name).toSet(),
        <String>{
          for (final spec in _acceptedActivities)
            spec.substring(0, spec.lastIndexOf('::')),
        },
      );
      expect(
        baseline.receivers.map((component) => component.name).toSet(),
        <String>{
          for (final spec in _acceptedReceivers)
            spec.substring(0, spec.lastIndexOf('::')),
        },
      );
      expect(
        baseline.services.map((component) => component.name).toSet(),
        <String>{
          for (final spec in _acceptedServices)
            spec.substring(0, spec.lastIndexOf('::')),
        },
      );
      // The baseline must state an exported value for every component, and the
      // real packaged surface uses both values, so the tri-state is exercised
      // rather than nominal.
      expect(
        baseline.activities.every((component) => component.exported != null),
        isTrue,
      );
      expect(
        baseline.receivers.every((component) => component.exported != null),
        isTrue,
      );
      expect(
        baseline.services.every((component) => component.exported != null),
        isTrue,
      );
      expect(
        <bool?>{
          ...baseline.activities.map((component) => component.exported),
          ...baseline.receivers.map((component) => component.exported),
          ...baseline.services.map((component) => component.exported),
        },
        <bool?>{true, false},
      );
    });

    test('the baseline file is deterministic, sorted and LF-terminated', () {
      final text = File(_baselinePath).readAsStringSync();

      expect(text, isNot(contains('\r')));
      final decoded = jsonDecode(text) as Map<String, Object?>;
      final permissions = (decoded['usesPermissions']! as List).cast<String>();
      expect(permissions, List<String>.from(permissions)..sort());
      for (final key in <String>['activities', 'receivers', 'services']) {
        final names = <String>[
          for (final entry in decoded[key]! as List)
            (entry as Map)['name']! as String,
        ];
        expect(names, List<String>.from(names)..sort(), reason: key);
      }
    });

    test('identity equals the authority constants (drift forces a visible '
        'baseline reconsideration)', () {
      expect(baseline.identity.applicationId, approvedApplicationId);
      expect(baseline.identity.minSdk, approvedMinSdk);
      expect(baseline.identity.targetSdk, approvedTargetSdk);
    });

    test('version equals the pubspec version (drift forces a visible baseline '
        'reconsideration)', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(
        r'^version:\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec);
      expect(match, isNotNull);

      final version = match!.group(1)!;
      final separator = version.indexOf('+');
      expect(separator, greaterThan(0));
      expect(baseline.identity.versionName, version.substring(0, separator));
      expect(
        baseline.identity.versionCode,
        int.parse(version.substring(separator + 1)),
      );
    });
  });

  group('the gate cannot be weakened or self-heal', () {
    test('the runner has no baseline-writing or auto-accept path', () {
      final runner = File(_runnerPath).readAsStringSync();

      // No argument is ever compared against a baseline-update flag, so no
      // such flag can be added without this test failing first.
      expect(runner, isNot(contains("'--update-baseline'")));
      expect(runner, isNot(contains("'--accept-baseline'")));
      expect(runner, isNot(contains("'--write-baseline'")));
      expect(runner, isNot(contains('writeAsString')));
      expect(runner, isNot(contains('writeAsBytes')));
      expect(runner, isNot(contains('autoAccept')));
    });

    test('the runner never persists or echoes the raw dump', () {
      final runner = File(_runnerPath).readAsStringSync();

      expect(runner, isNot(contains('writeln(dump)')));
      expect(runner, isNot(contains('writeln(result.stdout)')));
      expect(runner, isNot(contains('File(dump')));
    });

    test('the rules are pure: no dart:io import, no process spawning', () {
      final rules = File('tool/merged_artifact_rules.dart').readAsStringSync();

      expect(rules, isNot(contains("import 'dart:io'")));
      expect(rules, isNot(contains('Process.')));
      expect(rules, isNot(contains('File(')));
    });
  });
}
