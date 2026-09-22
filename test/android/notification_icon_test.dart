import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Preserves the owner SVG paths AND their per-path translations, then checks
/// the uniform 24dp fit. Geometry checks protect composition, not owner acceptance.
void main() {
  final drawable = File(
    'android/app/src/main/res/drawable/ic_nt_notification.xml',
  );
  final markAsset = File('assets/branding/next_transfer_notification_mark.svg');
  final gateway = File(
    'lib/core/notifications/flutter_local_notifications_gateway.dart',
  );

  group('D25 notification identity selection', () {
    test('the owner-supplied mark is the identity, on one shared constant', () {
      expect(gateway.existsSync(), isTrue, reason: 'gateway must exist');
      final source = gateway.readAsStringSync();
      expect(
        source.contains(
          'AndroidInitializationSettings(ntNotificationIconResource)',
        ),
        isTrue,
        reason:
            'OWNER DECISION (2026-09-22, P3-M0): the notification identity is '
            'the owner-supplied mark, and the registered default must be the same '
            'resource every send names',
      );
      expect(
        source.contains(
          "const String ntNotificationIconResource = 'ic_nt_notification';",
        ),
        isTrue,
        reason: 'one named constant is the whole identity',
      );
      expect(
        source.contains('ntNotificationAppIconResource'),
        isFalse,
        reason:
            'the launcher-resource identity from the previous round must be gone '
            'entirely, so it cannot be re-wired by accident: the app logo now '
            'belongs to the launcher icon, not to the notification',
      );
    });
  });

  group('D26 the mark is the owner asset, never a redrawing', () {
    test('every path payload is byte-identical to the in-repo owner asset', () {
      expect(
        markAsset.existsSync(),
        isTrue,
        reason: 'the asset must be in-repo',
      );
      expect(drawable.existsSync(), isTrue, reason: 'drawable must exist');
      final fromAsset = _assetPathData(markAsset);
      final fromDrawable = _pathData(drawable);
      expect(
        fromAsset.length,
        8,
        reason:
            'the supplied vector carries eight paths; a different count means '
            'the asset itself changed and the conversion must be redone',
      );
      expect(
        fromDrawable,
        fromAsset,
        reason:
            'the Android drawable must carry the supplied artwork VERBATIM, in '
            'order. This is the law that makes "do not redraw/simplify/invent a '
            'different small icon" enforceable: any restyling, re-simplification '
            'or reordering fails here rather than on the owner\'s device.',
      );
    });

    test('the asset is the supplied vector, framed but not re-traced', () {
      final svg = _xmlOf(markAsset);
      // The supplied file declares no viewBox and draws at negative user
      // coordinates, so the in-repo copy only ADDS a viewBox that frames the ink
      // bounds: the eight payloads above are untouched (asserted in the previous
      // case), and the element is still a plain SVG with no script or extra shapes.
      expect(svg.contains('<svg'), isTrue);
      expect(RegExp(r'viewBox="[-\d. ]+"').hasMatch(svg), isTrue);
      expect(RegExp(r'<path\b').allMatches(svg).length, 8);
      expect(RegExp(r'<(?!path|/svg|svg|\?xml|!--)').hasMatch(svg), isFalse);
    });
  });

  group('D26b notification icon vector contract', () {
    test('a monochrome 24dp vector with one white fill and no background', () {
      expect(drawable.existsSync(), isTrue, reason: 'drawable must exist');
      final xml = _xmlOf(drawable);
      expect(xml.contains('<vector'), isTrue);
      expect(xml.contains('android:viewportWidth="24"'), isTrue);
      expect(xml.contains('android:viewportHeight="24"'), isTrue);
      expect(xml.contains('android:width="24dp"'), isTrue);
      expect(xml.contains('android:height="24dp"'), isTrue);
      // Monochrome: Android uses the ALPHA as the shape and recolours it, so
      // white fills over no background is the only lawful form. A gradient, a
      // bitmap, an alpha attribute or a second colour would all be discarded or
      // refused.
      expect(
        RegExp(r'android:fillColor="#FFFFFFFF"').allMatches(xml).length,
        8,
        reason: 'every one of the eight paths must be the same white fill',
      );
      expect(
        RegExp(r'android:fillColor="#[0-9A-Fa-f]{8}"').allMatches(xml).length,
        8,
        reason: 'no path may carry a second colour',
      );
      expect(RegExp(r'<gradient\b').hasMatch(xml), isFalse);
      expect(RegExp(r'<bitmap\b').hasMatch(xml), isFalse);
      expect(RegExp(r'android:alpha=').hasMatch(xml), isFalse);
      expect(RegExp(r'<path\b').allMatches(xml).length, 8);
    });

    test('all eight owner translations survive in matching path groups', () {
      const expected = <(double, double)>[
        (1007.109375, 274.44140625),
        (1052, 318),
        (706, 385),
        (713, 497),
        (590.26025390625, 589.663818359375),
        (721, 610),
        (227, 700),
        (872, 844),
      ];
      final groups = _pathTranslations(drawable);
      expect(groups, expected);
      final svg = _xmlOf(markAsset);
      final transforms = RegExp(r'transform="translate\(([-\d.]+),([-\d.]+)\)"')
          .allMatches(svg)
          .map((m) => (double.parse(m.group(1)!), double.parse(m.group(2)!)))
          .toList();
      expect(transforms, expected);
      expect(RegExp(r'<group\b').allMatches(_xmlOf(drawable)).length, 9);
      final t = _groupTransform(drawable)!;
      expect(t.scaleX, closeTo(t.scaleY, 1e-12));
      expect(t.scaleX, greaterThan(0));
      expect(
        RegExp(r'android:rotation|android:pivot').hasMatch(_xmlOf(drawable)),
        isFalse,
      );
    });

    test('transformed composition fits safely and is centred in 24dp', () {
      final b = _renderedBounds(drawable);
      expect(b.minX, greaterThanOrEqualTo(1.19));
      expect(b.minY, greaterThanOrEqualTo(1.19));
      expect(b.maxX, lessThanOrEqualTo(22.81));
      expect(b.maxY, lessThanOrEqualTo(22.81));
      expect(b.minX + b.maxX, closeTo(24, .02));
      expect(b.minY + b.maxY, closeTo(24, .02));
      expect(b.maxX - b.minX, closeTo(21.6, .02));
      // Independent source composition bounds, including all translations.
      expect(
        (b.maxX - b.minX) / (b.maxY - b.minY),
        closeTo(1031.23051465 / 720.07621373, .001),
      );
    });

    test('preview viewport is the inverse of the Android global fit', () {
      final t = _groupTransform(drawable)!;
      final viewBox = RegExp(r'viewBox="([^"]+)"')
          .firstMatch(_xmlOf(markAsset))!
          .group(1)!
          .split(' ')
          .map(double.parse)
          .toList();
      expect(viewBox[0], closeTo(-t.translateX / t.scaleX, .0001));
      expect(viewBox[1], closeTo(-t.translateY / t.scaleY, .0001));
      expect(viewBox[2], closeTo(24 / t.scaleX, .0001));
      expect(viewBox[3], closeTo(24 / t.scaleY, .0001));
    });
  });

  group('D27 the launcher carries the actual app logo', () {
    test('every launcher raster exists at its documented bucket size', () {
      // OWNER DECISION (2026-09-22, P3-M0): the app identity is the supplied app
      // logo PNG, applied to the LAUNCHER icon (the notification keeps the
      // monochrome mark). The existing bucket conventions were reused rather than
      // re-invented: the adaptive foreground is authored on the 108dp canvas, the
      // legacy icon on the classic dp ladder.
      const foreground = <String, int>{
        'mdpi': 108,
        'hdpi': 162,
        'xhdpi': 216,
        'xxhdpi': 324,
        'xxxhdpi': 432,
      };
      const legacy = <String, int>{
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      };
      for (final entry in foreground.entries) {
        final file = File(
          'android/app/src/main/res/drawable-${entry.key}/'
          'ic_launcher_foreground.png',
        );
        expect(file.existsSync(), isTrue, reason: '${entry.key} foreground');
        final bytes = file.readAsBytesSync();
        expect(bytes.sublist(1, 4), <int>[
          0x50,
          0x4E,
          0x47,
        ], reason: '${entry.key} foreground must be a PNG');
        expect(
          _pngSize(bytes),
          (entry.value, entry.value),
          reason: '${entry.key} foreground must be the 108dp bucket size',
        );
      }
      for (final entry in legacy.entries) {
        final file = File(
          'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
        );
        expect(file.existsSync(), isTrue, reason: '${entry.key} launcher');
        final bytes = file.readAsBytesSync();
        expect(bytes.sublist(1, 4), <int>[
          0x50,
          0x4E,
          0x47,
        ], reason: '${entry.key} launcher must remain a PNG');
        expect(
          _pngSize(bytes),
          (entry.value, entry.value),
          reason: '${entry.key} launcher must be the classic bucket size',
        );
      }
    });

    test('the adaptive foreground is the owner artwork, not a leftover', () async {
      final file = File(
        'android/app/src/main/res/drawable-xxxhdpi/'
        'ic_launcher_foreground.png',
      );
      final stats = await _pixelStats(file);
      // The supplied logo is a navy field with the white handoff mark on it. Both
      // halves are asserted, so neither a blank navy tile nor a washed-out
      // placeholder can pass.
      expect(
        stats.corner[2],
        greaterThan(stats.corner[0] + 30),
        reason: 'the field must be the artwork navy (blue channel dominant)',
      );
      expect(
        stats.corner[2],
        inInclusiveRange(60, 160),
        reason:
            'the navy must be the supplied artwork\'s own #FF002C66..family',
      );
      expect(
        stats.centre[0],
        greaterThan(200),
        reason: 'the centre of the mark (the notebook) must be near-white',
      );
      expect(
        stats.brightFraction,
        inInclusiveRange(0.03, 0.12),
        reason:
            'the white mark covers a few percent of the tile; a value outside '
            'this band means the artwork was replaced or rescaled',
      );
    });

    test('both raster families are the same artwork', () async {
      // The adaptive foreground and the legacy launcher icon are two resamplings
      // of ONE source. Their mean luminance must agree closely; a mismatch would
      // mean a stale bucket survived the swap.
      final foreground = await _pixelStats(
        File(
          'android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png',
        ),
      );
      final foregroundLarge = await _pixelStats(
        File(
          'android/app/src/main/res/drawable-xxxhdpi/'
          'ic_launcher_foreground.png',
        ),
      );
      final legacy = await _pixelStats(
        File('android/app/src/main/res/mipmap-mdpi/ic_launcher.png'),
      );
      expect(
        (foreground.meanLuma - foregroundLarge.meanLuma).abs(),
        lessThan(5),
        reason: 'the 108px and 432px foregrounds must be the same picture',
      );
      expect(
        (foreground.meanLuma - legacy.meanLuma).abs(),
        lessThan(5),
        reason: 'the legacy launcher must be the same picture too',
      );
    });
  });
}

/// The file's markup with XML comments removed.
///
/// Every element-level assertion in this suite must read the STRIPPED document:
/// the drawable's own header comment legitimately discusses the `<group>` that
/// re-frames the artwork, and a naive regex over the raw text would count the
/// prose as markup and silently read an identity transform (or a phantom path).
String _xmlOf(File file) =>
    file.readAsStringSync().replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// Bounds in device units.
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
  final xml = _xmlOf(file);
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
  final xml = _xmlOf(file);
  final matches = RegExp(
    r'android:pathData="(.*?)"',
    dotAll: true,
  ).allMatches(xml).map((m) => m.group(1)!).toList();
  if (matches.isEmpty) {
    throw StateError('ic_nt_notification.xml has no android:pathData');
  }
  return matches;
}

/// Every `d` payload of the in-repo owner asset, in document order.
List<String> _assetPathData(File file) {
  final svg = _xmlOf(file);
  return RegExp(
    r'<path[^>]*\bd="([^"]+)"',
  ).allMatches(svg).map((m) => m.group(1)!).toList();
}

/// The artwork bounds AS RENDERED, i.e. after any `<group>` re-framing, and
/// unioned across every path in the drawable, sampling the real cubic curves.
_Bounds _renderedBounds(File file) {
  final paths = _pathData(file);
  final translations = _pathTranslations(file);
  if (translations.length != paths.length) {
    throw StateError('Every owner path requires its source translation');
  }
  final raw = _unionBounds([
    for (var i = 0; i < paths.length; i++)
      _translated(_sampledBounds(paths[i]), translations[i]),
  ]);
  final t = _groupTransform(file);
  if (t == null) return raw;
  double fx(double x) => x * t.scaleX + t.translateX;
  double fy(double y) => y * t.scaleY + t.translateY;
  return _Bounds(fx(raw.minX), fy(raw.minY), fx(raw.maxX), fy(raw.maxY));
}

List<(double, double)> _pathTranslations(File file) =>
    RegExp(r'<group\b([^>]*)>\s*<path\b', dotAll: true)
        .allMatches(_xmlOf(file))
        .map(
          (m) => (
            _attr(m.group(1)!, 'translateX', 0),
            _attr(m.group(1)!, 'translateY', 0),
          ),
        )
        .toList();

_Bounds _translated(_Bounds b, (double, double) t) =>
    _Bounds(b.minX + t.$1, b.minY + t.$2, b.maxX + t.$1, b.maxY + t.$2);

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

/// Samples every cubic in one path payload, so the box describes the PAINTED
/// curve rather than its control polygon.
_Bounds _sampledBounds(String data, {int steps = 64}) {
  final tokens = RegExp(
    r'[MmLlHhVvCcSsQqTtAaZz]|-?\d*\.?\d+(?:[eE]-?\d+)?',
  ).allMatches(data).map((m) => m.group(0)!).toList();

  var i = 0;
  double x = 0, y = 0;
  String? command;
  final xs = <double>[];
  final ys = <double>[];

  double next() => double.parse(tokens[i++]);

  while (i < tokens.length) {
    final token = tokens[i];
    if (RegExp(r'^[A-Za-z]$').hasMatch(token)) {
      command = token;
      i++;
      continue;
    }
    switch (command) {
      case 'M':
        x = next();
        y = next();
        xs.add(x);
        ys.add(y);
        command = 'L';
      case 'C':
        final x1 = next();
        final y1 = next();
        final x2 = next();
        final y2 = next();
        final x3 = next();
        final y3 = next();
        for (var k = 1; k <= steps; k++) {
          final u = k / steps;
          final v = 1 - u;
          xs.add(
            v * v * v * x +
                3 * v * v * u * x1 +
                3 * v * u * u * x2 +
                u * u * u * x3,
          );
          ys.add(
            v * v * v * y +
                3 * v * v * u * y1 +
                3 * v * u * u * y2 +
                u * u * u * y3,
          );
        }
        x = x3;
        y = y3;
      case 'Z':
      case 'z':
        break;
      default:
        throw StateError('Unsupported path command: $command');
    }
  }

  xs.sort();
  ys.sort();
  return _Bounds(xs.first, ys.first, xs.last, ys.last);
}

/// `(width, height)` straight out of the PNG IHDR chunk.
(int, int) _pngSize(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}

/// Mean luminance, near-white coverage and two sampled pixels of a PNG.
Future<
  ({double meanLuma, double brightFraction, List<int> corner, List<int> centre})
>
_pixelStats(File file, {int step = 4}) async {
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final width = image.width;
  final height = image.height;

  var sum = 0.0;
  var count = 0;
  var bright = 0;
  for (var y = 0; y < height; y += step) {
    for (var x = 0; x < width; x += step) {
      final index = (y * width + x) * 4;
      final luma =
          (data.getUint8(index) +
              data.getUint8(index + 1) +
              data.getUint8(index + 2)) /
          3;
      sum += luma;
      count++;
      if (luma > 200) bright++;
    }
  }

  List<int> at(int x, int y) {
    final index = (y * width + x) * 4;
    return <int>[
      data.getUint8(index),
      data.getUint8(index + 1),
      data.getUint8(index + 2),
    ];
  }

  final stats = (
    meanLuma: sum / count,
    brightFraction: bright / count,
    corner: at(width ~/ 64, height ~/ 64),
    centre: at(width ~/ 2, height ~/ 2),
  );
  image.dispose();
  return stats;
}
