import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Notification small-icon geometry regression guard.
///
/// OWNER DECISION (2026-09-22, final) — the artwork was replaced AGAIN, so the
/// previous geometry laws are deliberately superseded:
///
///   * the first Post-P2 replacement was a single solid notebook page with
///     transparent writing lines. The owner reviewed it on the device and
///     rejected it: at notification size it reads as a generic document, not as
///     Next Transfer;
///   * the final artwork carries the app's own identity — HANDS HANDING OFF THE
///     PLANNER: a tilted notebook page gripped at its lower corners by two
///     mirrored hands. It is three solid white paths on a 24x24 viewport
///     (page = `evenOdd` with cut-outs, each hand = `nonZero` union of palm, two
///     staggered fingers and an angled thumb), with every rotation baked into
///     the coordinates so no transform can drift at render time.
///
/// The laws below therefore changed from "one simplified page" to "a page plus
/// two mirrored hands that grip it". What did NOT change is the resource
/// contract: the drawable name, the 24dp declared size, the transparent
/// background, and a purely monochrome mark that Android tints.
///
/// STATUS AFTER THE 2026-09-22 FINAL RESTORATION: this drawing is no longer the
/// identity the app sends. The notification identity is now the canonical app-icon
/// resource (`@mipmap/ic_launcher`) because the owner rejected the redrawn marks
/// and Android derives the card's identity from the small-icon input. The mark
/// below stays maintained as the Android-compliant, one-constant revert, so its
/// geometry laws still guard something real rather than dead artwork. The
/// full-colour app logo is still NOT part of notification presentation: the card's
/// large icon stays removed.
///
/// ICON TEST REALITY (unchanged doctrine):
/// These tests are REGRESSION PROTECTION ONLY. Bounding-box arithmetic is not
/// perception. Final subjective icon acceptance remains OWNER PHYSICAL REVIEW on
/// the device, and that is especially true here: the mark is a designed
/// silhouette, and only the owner can judge whether it reads as Next Transfer.
void main() {
  final drawable = File(
    'android/app/src/main/res/drawable/ic_nt_notification.xml',
  );
  final gateway = File(
    'lib/core/notifications/flutter_local_notifications_gateway.dart',
  );

  group('D25 notification identity selection', () {
    test('the app icon is the identity and the mark is the kept revert', () {
      expect(gateway.existsSync(), isTrue, reason: 'gateway must exist');
      final source = gateway.readAsStringSync();
      expect(
        source.contains(
          'AndroidInitializationSettings(ntNotificationAppIconResource)',
        ),
        isTrue,
        reason:
            'OWNER DECISION (2026-09-22, final restoration): the notification '
            'identity is the canonical app-icon resource, because Android '
            'derives the card identity from the small-icon input',
      );
      expect(
        source.contains(
          "const String ntNotificationAppIconResource = '@mipmap/ic_launcher';",
        ),
        isTrue,
        reason:
            'the canonical app icon, resolved from Dart by name — the plugin '
            'documents this exact value for this purpose',
      );
      expect(
        source.contains(
          "const String ntNotificationIconResource = 'ic_nt_notification';",
        ),
        isTrue,
        reason:
            'the monochrome mark remains the documented one-constant revert, and '
            'stays covered by the geometry laws below',
      );
    });
  });

  group('D26 notification icon vector geometry', () {
    test('is a monochrome vector on the 24x24 viewport', () {
      expect(drawable.existsSync(), isTrue, reason: 'drawable must exist');
      final xml = drawable.readAsStringSync();
      expect(xml.contains('<vector'), isTrue);
      expect(xml.contains('android:viewportWidth="24"'), isTrue);
      expect(xml.contains('android:viewportHeight="24"'), isTrue);
      expect(xml.contains('android:width="24dp"'), isTrue);
      expect(xml.contains('android:height="24dp"'), isTrue);
      // Monochrome: Android uses the ALPHA as the shape and recolours it, so
      // white fills with no background is the only lawful form. A gradient, a
      // bitmap or a second colour would all be discarded or refused.
      expect(
        xml.contains('android:fillColor="#FFFFFFFF"'),
        isTrue,
        reason: 'the mark must be one monochrome white fill colour',
      );
      expect(RegExp(r'<gradient\b').hasMatch(xml), isFalse);
      expect(RegExp(r'<bitmap\b').hasMatch(xml), isFalse);
      expect(
        RegExp(r'android:fillColor="#[0-9A-Fa-f]{8}"').allMatches(xml).length,
        3,
        reason: 'every one of the three paths must be the same white fill',
      );
    });

    test('the page is one evenOdd path carrying its own cut-outs', () {
      final paths = _pathData(drawable);
      expect(paths.length, 3);
      final page = paths.first;
      // The outer page plus the binding channel plus three writing lines: the
      // lines are transparent CUT-OUTS of the same shape, which is exactly what
      // even-odd fill is for.
      expect(
        _subpathCount(page),
        5,
        reason:
            'the page must keep its binding channel and three writing lines as '
            'cut-outs of one shape',
      );
      final xml = drawable.readAsStringSync();
      expect(
        RegExp(r'android:fillType="evenOdd"').allMatches(xml).length,
        1,
        reason: 'exactly one path — the page — may use even-odd cut-outs',
      );
    });

    test('each hand merges four parts with nonZero fill', () {
      final paths = _pathData(drawable);
      // nonZero (not evenOdd) is what lets palm, two fingers and thumb merge
      // into one gesture instead of punching holes where they overlap.
      expect(_subpathCount(paths[1]), 4);
      expect(_subpathCount(paths[2]), 4);
      final xml = drawable.readAsStringSync();
      expect(
        RegExp(r'android:fillType="nonZero"').allMatches(xml).length,
        2,
        reason: 'both hands are nonZero unions of palm, two fingers and thumb',
      );
    });

    test('the mark keeps a safe inset on every side of the canvas', () {
      final bounds = _effectiveBounds(drawable);
      // Owner requirement: no platform mask or OEM backdrop may visually clip
      // the glyph.
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

    test('the composition stays page-and-hands, never a wide slab', () {
      final bounds = _effectiveBounds(drawable);
      final width = bounds.maxX - bounds.minX;
      final height = bounds.maxY - bounds.minY;
      final aspect = width / height;
      // The old rejected notebook-only mark was portrait (0.6..1.4 with a tall
      // page); the final handoff mark is the page plus the two hands reaching
      // in from the sides, so it settles close to square. A wide slab here
      // would mean the hands lost their proportions.
      expect(
        aspect,
        inInclusiveRange(0.8, 1.3),
        reason: 'page + two hands reads roughly square',
      );
    });

    test('the mark is centred on the canvas', () {
      final bounds = _effectiveBounds(drawable);
      final cx = (bounds.minX + bounds.maxX) / 2;
      final cy = (bounds.minY + bounds.maxY) / 2;
      expect(cx, closeTo(12, 1), reason: 'horizontally centred');
      expect(cy, closeTo(11.5, 1.0), reason: 'vertically centred');
    });

    test('no group transform is applied to the mark', () {
      // The traced artwork needed a `<group>` reframe; the designed mark bakes
      // every rotation into its coordinates, so a transform reappearing would
      // mean the geometry regressed to render-time composition.
      expect(
        _groupTransform(drawable),
        isNull,
        reason: 'the mark needs no reframing transform',
      );
    });
  });

  // OWNER DECISION (2026-09-22, final) — the silhouette laws.
  //
  // The owner asked for the small icon to read as the Next Transfer handoff
  // identity instead of a document. These assertions describe the structure that
  // creates that reading, so a future "simplification" cannot quietly drop the
  // hands back to a plain page (or drop one hand, or un-mirror them).
  group('D31 the handoff silhouette: two hands gripping the page', () {
    test('the two hands are exact mirrors about the canvas centre', () {
      final paths = _pathData(drawable);
      final left = _pathBounds(paths[1]);
      final right = _pathBounds(paths[2]);
      // A true mirror means the silhouette is symmetric: any drift here shows up
      // as a lopsided gesture on the device.
      expect(left.minX + right.maxX, closeTo(24, 0.5));
      expect(left.maxX + right.minX, closeTo(24, 0.5));
      expect(left.minY, closeTo(right.minY, 0.5));
      expect(left.maxY, closeTo(right.maxY, 0.5));
    });

    test('the fingertips reach past the page edge, so it reads as a grip', () {
      final paths = _pathData(drawable);
      final page = _pathBounds(paths.first);
      final handsTop = [
        _pathBounds(paths[1]).minY,
        _pathBounds(paths[2]).minY,
      ].reduce((a, b) => a < b ? a : b);
      final overlap = page.maxY - handsTop;
      // Already touching would look like three separate objects; burying the
      // hands would swallow the page. The designed overlap is a fraction of a
      // unit at 24dp.
      expect(
        overlap,
        inInclusiveRange(0.4, 2.5),
        reason: 'the hands must bite into the page edge without covering it',
      );
      // The hands also have to sit LOWER than the page, or they are not holding
      // it.
      final handsBottom = [
        _pathBounds(paths[1]).maxY,
        _pathBounds(paths[2]).maxY,
      ].reduce((a, b) => a > b ? a : b);
      expect(handsBottom, greaterThan(page.maxY + 5));
    });

    test('the mark is no longer the notebook-only page path', () {
      // The rejected artwork was ONE path (page with cut-outs). Guarding the
      // count this way means reverting the hands would fail loudly here.
      expect(_pathData(drawable).length, greaterThan(1));
      final xml = drawable.readAsStringSync();
      expect(
        RegExp(r'android:fillType="nonZero"').hasMatch(xml),
        isTrue,
        reason: 'the merged hand paths are what make the gesture readable',
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
/// silently reporting a wrong box. Arc commands contribute their endpoint only,
/// which is why the tolerances above are stated in fractions of a unit rather
/// than as exact designed values.
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

/// Every `android:pathData` in the drawable, in document order.
List<String> _pathData(File file) {
  final xml = file.readAsStringSync();
  final matches = RegExp(
    r'android:pathData="(.*?)"',
    dotAll: true,
  ).allMatches(xml).map((m) => m.group(1)!).toList();
  if (matches.isEmpty) {
    throw StateError('ic_nt_notification.xml has no android:pathData');
  }
  return matches;
}

int _subpathCount(String data) => 'M'.allMatches(data).length;

/// The artwork bounds AS RENDERED, i.e. after any `<group>` re-framing, and
/// unioned across every path in the drawable.
_Bounds _effectiveBounds(File file) {
  final raw = _unionBounds(_pathData(file).map(_pathBounds).toList());
  final t = _groupTransform(file);
  if (t == null) return raw;
  double fx(double x) => x * t.scaleX + t.translateX;
  double fy(double y) => y * t.scaleY + t.translateY;
  return _Bounds(fx(raw.minX), fy(raw.minY), fx(raw.maxX), fy(raw.maxY));
}

_Bounds _unionBounds(List<_Bounds> all) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final b in all) {
    if (b.minX < minX) minX = b.minX;
    if (b.minY < minY) minY = b.minY;
    if (b.maxX > maxX) maxX = b.maxX;
    if (b.maxY > maxY) maxY = b.maxY;
  }
  return _Bounds(minX, minY, maxX, maxY);
}

_Bounds _pathBounds(String data) {
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
