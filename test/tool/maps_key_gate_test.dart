// OWNER REVIEW #4 — fail-first coverage for the Maps API key gate.
//
// The forensic audit proved the shipped profile APK carried
// `com.google.android.geo.API_KEY = "DEFAULT_API_KEY"`, the tracked fallback,
// because `android/secrets.properties` was missing from the worktree. The
// Google Maps Android SDK cannot authorize against a placeholder, so the map
// could not load on a build that passed the entire suite.
//
// This file proves BOTH directions of the gate so it cannot be satisfied by
// simply weakening it: a real key must pass, and every way of NOT having a real
// key must fail. The rules live in `tool/maps_key_rules.dart` and the runner in
// `tool/verify_maps_key.dart` (one source of truth, no new framework), matching
// the existing `tool/verify_authority.dart` + `test/tool/authority_gate_test.dart`
// pairing.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/maps_key_rules.dart';

void main() {
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
          localSecrets: 'MAPS_API_KEY=AIzaSyREALKEY',
          defaults: 'MAPS_API_KEY=$mapsKeyPlaceholder',
        ),
        'AIzaSyREALKEY',
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

    test('accepts a real key', () {
      expect(mapsKeyIsUsable('AIzaSyREALKEY'), isTrue);
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

    test('passes a manifest dump carrying a real key', () {
      const dump = '''
          E: meta-data
            A: android:name="com.google.android.geo.API_KEY"
            A: android:value="AIzaSyREALKEY"
''';
      expect(packagedManifestHasPlaceholder(dump), isFalse);
    });
  });

  group('redacted', () {
    test('never reveals a real key', () {
      final value = redacted('AIzaSyREALKEYMATERIAL');
      expect(value, isNot(contains('REALKEYMATERIAL')));
      expect(value, startsWith('AIzaSy'));
    });

    test('marks the placeholder and the empty case distinctly', () {
      expect(redacted(mapsKeyPlaceholder), mapsKeyPlaceholder);
      expect(redacted(''), '<empty>');
    });
  });
}
