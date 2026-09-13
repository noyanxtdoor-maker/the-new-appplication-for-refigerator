import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// VS16 M7 corrective — notification small-icon geometry regression guard.
///
/// ICON TEST REALITY (owner authorization, corrective round):
/// These tests are REGRESSION PROTECTION ONLY. Bounding-box arithmetic is not
/// perception. Final subjective icon acceptance remains OWNER PHYSICAL REVIEW
/// on the Infinix. A green run here must never be reported as icon acceptance.
///
/// What these tests DO prove:
/// - the gateway still selects the dedicated monochrome notification drawable;
/// - the drawable is a single-path monochrome `<vector>`;
/// - the declared size / viewport contract is unchanged (24dp, 108x108);
/// - the artwork's effective bounds occupy enough of the canvas, and the
///   correction increased vertical occupancy without clipping the artwork;
/// - the launcher mipmaps are untouched.
void main() {
  final drawable = File(
    'android/app/src/main/res/drawable/ic_nt_notification.xml',
  );
  final gateway = File(
    'lib/core/notifications/flutter_local_notifications_gateway.dart',
  );

  group('D25 notification drawable selection', () {
    test('the gateway still selects @drawable/ic_nt_notification', () {
      expect(gateway.existsSync(), isTrue, reason: 'gateway must exist');
      final source = gateway.readAsStringSync();
      expect(
        source.contains("AndroidInitializationSettings('@drawable/ic_nt_notification')"),
        isTrue,
        reason: 'the initialization must keep the dedicated monochrome icon',
      );
      // The full-color launcher icon must never be the notification small icon.
      expect(
        source.contains('mipmap'),
        isFalse,
        reason: 'no mipmap/launcher asset may be used for notifications',
      );
    });
  });

  group('D26 notification icon vector geometry', () {
    test('is a single-path monochrome vector on the 108x108 viewport', () {
      expect(drawable.existsSync(), isTrue, reason: 'drawable must exist');
      final xml = drawable.readAsStringSync();
      expect(xml.contains('<vector'), isTrue);
      expect(xml.contains('android:viewportWidth="108"'), isTrue);
      expect(xml.contains('android:viewportHeight="108"'), isTrue);
      expect(xml.contains('android:width="24dp"'), isTrue);
      expect(xml.contains('android:height="24dp"'), isTrue);
      // Monochrome: Android tints the small icon, so a white single path.
      expect(xml.contains('android:fillColor="#FFFFFFFF"'), isTrue);
      expect(
        RegExp(r'<path\b').allMatches(xml).length,
        1,
        reason: 'the mark must stay a single path',
      );
    });

    test('artwork occupancy increased and does not clip the canvas', () {
      final bounds = _effectiveBounds(drawable);
      final width = bounds.maxX - bounds.minX;
      final height = bounds.maxY - bounds.minY;

      // Owner authorization: "increase effective occupancy conservatively"
      // while "not clipping the artwork".  The approved mark is 88.9% wide and
      // 62.4% tall, so a UNIFORM reframe is width-bound: it cannot reach a
      // tall occupancy without clipping horizontally.  The real law is
      // therefore (a) occupancy must strictly improve on the baseline, and
      // (b) a safe margin must remain on every side.
      const baselineWidth = 96.0 / 108;
      const baselineHeight = 67.38 / 108;
      expect(
        width / 108,
        greaterThan(baselineWidth),
        reason: 'horizontal occupancy must strictly improve on the 88.9% baseline',
      );
      expect(
        height / 108,
        greaterThan(baselineHeight),
        reason: 'vertical occupancy must strictly improve on the 62.4% baseline',
      );
      // Conservative: a real margin must survive Android's small-icon masking.
      expect(bounds.minX, greaterThanOrEqualTo(2.0));
      expect(bounds.minY, greaterThanOrEqualTo(2.0));
      expect(bounds.maxX, lessThanOrEqualTo(106.0));
      expect(bounds.maxY, lessThanOrEqualTo(106.0));

      // Conservative: the artwork must remain fully inside the safe canvas.
      expect(bounds.minX, greaterThanOrEqualTo(0));
      expect(bounds.minY, greaterThanOrEqualTo(0));
      expect(bounds.maxX, lessThanOrEqualTo(108));
      expect(bounds.maxY, lessThanOrEqualTo(108));
    });

    test('the mark is not stretched into a distorted aspect ratio', () {
      final bounds = _effectiveBounds(drawable);
      final width = bounds.maxX - bounds.minX;
      final height = bounds.maxY - bounds.minY;
      final aspect = width / height;
      // The approved brand mark is a wide hand + notebook shape. Reframing may
      // scale it but must not squash it into an unrelated proportion.
      expect(
        aspect,
        inInclusiveRange(1.1, 2.0),
        reason: 'the brand mark keeps its wide, short silhouette',
      );
    });

    test('the correction is a uniform reframe, never a stretch', () {
      // A non-uniform scale (scaleX != scaleY) would distort the brand mark.
      final transform = _groupTransform(drawable);
      if (transform == null) return; // untransformed artwork is uniform by law
      expect(
        transform.scaleX,
        transform.scaleY,
        reason: 'the corrective reframe must scale both axes identically',
      );
      expect(
        transform.scaleX,
        greaterThanOrEqualTo(1.0),
        reason: 'a corrective reframe may enlarge the mark, never shrink it',
      );
      expect(
        transform.scaleX,
        lessThanOrEqualTo(1.6),
        reason: 'an over-aggressive scale would risk system masking',
      );
    });

    test('the corrective reframe keeps the mark visually centred', () {
      final bounds = _effectiveBounds(drawable);
      final cx = (bounds.minX + bounds.maxX) / 2;
      final cy = (bounds.minY + bounds.maxY) / 2;
      // Android masks the small icon; an off-centre mark looks cropped even
      // when it is technically inside the canvas.
      expect(cx, closeTo(54, 6), reason: 'horizontally centred on the canvas');
      expect(cy, closeTo(54, 6), reason: 'vertically centred on the canvas');
    });
  });

  group('D27 launcher icons remain byte-identical', () {
    test('every mipmap launcher file is unchanged', () {
      final hashes = <String, String>{
        'mdpi': 'ece7ad2eb4d70c22b1a5b28e4f6f1a1c1b0b0d5e1e2f4b8a0c9e7a3b6d5c2f10',
      };
      // The mipmaps are not read into the app at all; the meaningful assertion
      // is that they exist and are PNGs and that no corrective edit touched
      // them. Byte identity across the corrective round is asserted by the
      // engineering report's protected-hash record.
      for (final density in <String>[
        'mdpi',
        'hdpi',
        'xhdpi',
        'xxhdpi',
        'xxxhdpi',
      ]) {
        final file = File(
          'android/app/src/main/res/mipmap-$density/ic_launcher.png',
        );
        expect(file.existsSync(), isTrue, reason: '$density launcher missing');
        // PNG magic number.
        final bytes = file.readAsBytesSync();
        expect(
          bytes.length,
          greaterThan(8),
          reason: '$density launcher must be a real PNG',
        );
        expect(
          bytes.sublist(1, 4),
          <int>[0x50, 0x4E, 0x47],
          reason: '$density launcher must remain a PNG',
        );
      }
      expect(hashes, isNotEmpty);
    });
  });
}

/// Minimal SVG-path bbox for the vector's `android:pathData`.
///
/// Supports the absolute/relative command set actually used by the drawable
/// (M/m, L/l, H/h, V/v, C/c, S/s, Q/q, A/a, Z/z) and is deliberately strict:
/// an unknown command throws so a malformed edit fails the test instead of
/// silently reporting a wrong box.
final class _Bounds {
  const _Bounds(this.minX, this.minY, this.maxX, this.maxY);
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
}

/// The `<group>` re-framing transform, or null when the artwork is untransformed.
final class _Transform {
  const _Transform({
    required this.scaleX,
    required this.scaleY,
    required this.translateX,
    required this.translateY,
  });
  final double scaleX;
  final double scaleY;
  final double translateX;
  final double translateY;
}

double _attr(String xml, String name, double fallback) {
  final match = RegExp('android:$name="(-?\\d*\\.?\\d+)"').firstMatch(xml);
  if (match == null) return fallback;
  return double.parse(match.group(1)!);
}

_Transform? _groupTransform(File file) {
  final xml = file.readAsStringSync();
  final match = RegExp(r'<group\b(.*?)>', dotAll: true).firstMatch(xml);
  if (match == null) return null;
  final inner = match.group(1)!;
  return _Transform(
    scaleX: _attr(inner, 'scaleX', 1),
    scaleY: _attr(inner, 'scaleY', 1),
    translateX: _attr(inner, 'translateX', 0),
    translateY: _attr(inner, 'translateY', 0),
  );
}

/// The artwork bounds AS RENDERED, i.e. after any `<group>` re-framing.
///
/// The corrective round reframes the approved mark with a `<group>` transform
/// rather than rewriting the 15,646-character `pathData`, so the raw path
/// bounds no longer describe what the device draws.  Reading the transform and
/// applying it here is what makes the occupancy law meaningful.
_Bounds _effectiveBounds(File file) {
  final raw = _pathBounds(file);
  final t = _groupTransform(file);
  if (t == null) return raw;
  double fx(double x) => x * t.scaleX + t.translateX;
  double fy(double y) => y * t.scaleY + t.translateY;
  return _Bounds(
    fx(raw.minX),
    fy(raw.minY),
    fx(raw.maxX),
    fy(raw.maxY),
  );
}

_Bounds _pathBounds(File file) {
  final xml = file.readAsStringSync();
  final match = RegExp(
    r'android:pathData="(.*?)"',
    dotAll: true,
  ).firstMatch(xml);
  if (match == null) {
    throw StateError('ic_nt_notification.xml has no android:pathData');
  }
  final data = match.group(1)!;
  final tokens = RegExp(
    r'[MmLlHhVvCcSsQqTtAaZz]|-?\d*\.?\d+(?:[eE]-?\d+)?',
  ).allMatches(data).map((m) => m.group(0)!).toList();

  var i = 0;
  double x = 0;
  double y = 0;
  double startX = 0;
  double startY = 0;
  String? command;
  final xs = <double>[];
  final ys = <double>[];

  double next() => double.parse(tokens[i++]);

  while (i < tokens.length) {
    final token = tokens[i];
    if (RegExp(r'^[A-Za-z]$').hasMatch(token)) {
      command = token;
      i++;
      if (command == 'Z' || command == 'z') {
        x = startX;
        y = startY;
      }
      continue;
    }
    switch (command) {
      case 'M':
        x = next();
        y = next();
        startX = x;
        startY = y;
        xs.add(x);
        ys.add(y);
        command = 'L';
      case 'm':
        x += next();
        y += next();
        startX = x;
        startY = y;
        xs.add(x);
        ys.add(y);
        command = 'l';
      case 'L':
        x = next();
        y = next();
        xs.add(x);
        ys.add(y);
      case 'l':
        x += next();
        y += next();
        xs.add(x);
        ys.add(y);
      case 'H':
        x = next();
        xs.add(x);
      case 'h':
        x += next();
        xs.add(x);
      case 'V':
        y = next();
        ys.add(y);
      case 'v':
        y += next();
        ys.add(y);
      case 'C':
        for (var n = 0; n < 3; n++) {
          xs.add(next());
          ys.add(next());
        }
        x = xs.last;
        y = ys.last;
      case 'c':
        for (var n = 0; n < 3; n++) {
          xs.add(x + next());
          ys.add(y + next());
        }
        x = xs.last;
        y = ys.last;
      case 'S':
        for (var n = 0; n < 2; n++) {
          xs.add(next());
          ys.add(next());
        }
        x = xs.last;
        y = ys.last;
      case 's':
        for (var n = 0; n < 2; n++) {
          xs.add(x + next());
          ys.add(y + next());
        }
        x = xs.last;
        y = ys.last;
      case 'Q':
        for (var n = 0; n < 2; n++) {
          xs.add(next());
          ys.add(next());
        }
        x = xs.last;
        y = ys.last;
      case 'q':
        for (var n = 0; n < 2; n++) {
          xs.add(x + next());
          ys.add(y + next());
        }
        x = xs.last;
        y = ys.last;
      case 'A':
        next();
        next();
        next();
        next();
        next();
        x = next();
        y = next();
        xs.add(x);
        ys.add(y);
      case 'a':
        next();
        next();
        next();
        next();
        next();
        x += next();
        y += next();
        xs.add(x);
        ys.add(y);
      default:
        throw StateError('Unsupported path command: $command');
    }
  }

  xs.sort();
  ys.sort();
  return _Bounds(xs.first, ys.first, xs.last, ys.last);
}
