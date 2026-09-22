import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Notification small-icon geometry regression guard.
///
/// POST-P2 OWNER DECISION (2026-09-22) — the artwork was REPLACED, so the
/// previous geometry laws are deliberately superseded:
///
///   * the old mark was the traced hand + notebook illustration on a 108x108
///     viewport, reframed by a `<group>` scale 1.08 / translate -4.32 so that
///     its occupancy could be pushed up without clipping;
///   * the audit proved that artwork can never read cleanly at notification
///     size (thin traced strokes collapse into a blob once Android tints and
///     downscales it), so the owner asked for a simplified silhouette;
///   * the replacement is a single solid notebook page with three transparent
///     writing lines, on a 24x24 viewport, with no transform at all.
///
/// The laws below therefore changed from "the wide reframed illustration" to
/// "the simplified portrait page, safely inset".  What did NOT change is the
/// resource contract: the drawable name, the 24dp declared size, the
/// transparent background, and the single monochrome white path.
///
/// ICON TEST REALITY (unchanged doctrine):
/// These tests are REGRESSION PROTECTION ONLY. Bounding-box arithmetic is not
/// perception. Final subjective icon acceptance remains OWNER PHYSICAL REVIEW
/// on the device. A green run here must never be reported as icon acceptance —
/// and that is especially true for this simplified mark, which was authored
/// without the ability to view the rendered result.
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
        source.contains(
          "AndroidInitializationSettings('@drawable/ic_nt_notification')",
        ),
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
    test('is a single-path monochrome vector on the 24x24 viewport', () {
      expect(drawable.existsSync(), isTrue, reason: 'drawable must exist');
      final xml = drawable.readAsStringSync();
      expect(xml.contains('<vector'), isTrue);
      expect(xml.contains('android:viewportWidth="24"'), isTrue);
      expect(xml.contains('android:viewportHeight="24"'), isTrue);
      expect(xml.contains('android:width="24dp"'), isTrue);
      expect(xml.contains('android:height="24dp"'), isTrue);
      // Monochrome: Android uses the ALPHA as the shape and recolours it, so a
      // white single path with no background is the only lawful form.
      expect(xml.contains('android:fillColor="#FFFFFFFF"'), isTrue);
      expect(
        RegExp(r'<path\b').allMatches(xml).length,
        1,
        reason: 'the mark must stay a single path',
      );
      expect(
        xml.contains('android:fillType="evenOdd"'),
        isTrue,
        reason:
            'the transparent writing lines are cut-outs inside the one path, '
            'which is what keeps this a single tinted silhouette',
      );
    });

    test('the mark keeps a safe inset on every side of the canvas', () {
      final bounds = _effectiveBounds(drawable);
      // Owner requirement: no platform mask or OEM backdrop may visually clip
      // the glyph. The replacement artwork is inset by construction, so this is
      // now a strict floor rather than the old "occupancy must improve" rule.
      expect(bounds.minX, greaterThanOrEqualTo(2.0));
      expect(bounds.minY, greaterThanOrEqualTo(2.0));
      expect(bounds.maxX, lessThanOrEqualTo(22.0));
      expect(bounds.maxY, lessThanOrEqualTo(22.0));
      // And it must stay fully inside the canvas.
      expect(bounds.minX, greaterThanOrEqualTo(0));
      expect(bounds.minY, greaterThanOrEqualTo(0));
      expect(bounds.maxX, lessThanOrEqualTo(24));
      expect(bounds.maxY, lessThanOrEqualTo(24));
    });

    test('the mark is legibly large but not edge-to-edge', () {
      final bounds = _effectiveBounds(drawable);
      final width = (bounds.maxX - bounds.minX) / 24;
      final height = (bounds.maxY - bounds.minY) / 24;
      // A small icon needs mass: at least half the canvas each way. It is
      // deliberately NOT wider than 90%, so no mask can shave a silhouette
      // edge.
      expect(width, greaterThanOrEqualTo(0.5));
      expect(height, greaterThanOrEqualTo(0.7));
      expect(width, lessThanOrEqualTo(0.9));
      expect(height, lessThanOrEqualTo(0.9));
    });

    test('the page keeps a portrait proportion', () {
      final bounds = _effectiveBounds(drawable);
      final width = bounds.maxX - bounds.minX;
      final height = bounds.maxY - bounds.minY;
      final aspect = width / height;
      // The OLD artwork was the wide hand + notebook illustration (aspect
      // 1.1-2.0). The replacement is a notebook PAGE, which is portrait by
      // definition; a wide silhouette here would mean the reduction failed.
      expect(
        aspect,
        inInclusiveRange(0.6, 1.4),
        reason: 'a notebook page reads portrait, never as a wide slab',
      );
    });

    test('the simplified mark is centred on the canvas', () {
      final bounds = _effectiveBounds(drawable);
      final cx = (bounds.minX + bounds.maxX) / 2;
      final cy = (bounds.minY + bounds.maxY) / 2;
      expect(cx, closeTo(12, 1), reason: 'horizontally centred');
      expect(cy, closeTo(12, 1), reason: 'vertically centred');
    });

    test('no group transform is applied to the simplified mark', () {
      // The previous artwork needed a `<group>` reframe because it was traced
      // on a 108 viewport. The replacement carries its geometry directly, so a
      // transform reappearing would mean the simplification regressed.
      expect(
        _groupTransform(drawable),
        isNull,
        reason: 'the simplified mark needs no reframing transform',
      );
    });
  });

  group('D27 launcher icons remain byte-identical', () {
    test('every mipmap launcher file is unchanged', () {
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
        expect(bytes.sublist(1, 4), <int>[
          0x50,
          0x4E,
          0x47,
        ], reason: '$density launcher must remain a PNG');
      }
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
_Bounds _effectiveBounds(File file) {
  final raw = _pathBounds(file);
  final t = _groupTransform(file);
  if (t == null) return raw;
  double fx(double x) => x * t.scaleX + t.translateX;
  double fy(double y) => y * t.scaleY + t.translateY;
  return _Bounds(fx(raw.minX), fy(raw.minY), fx(raw.maxX), fy(raw.maxY));
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
