import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// M5 — the owner-approved Next Transfer intro splash artwork.
///
/// This file is the single source of truth for the app-owned intro splash: the
/// registered asset path, the artwork's aspect ratio, the deep-blue field
/// profile sampled from that exact artwork, the backdrop gradient derived from it
/// for any screen size, and the decode preload that makes the artwork present on
/// the very first Flutter frame.
///
/// The approved artwork is the visual authority.  Nothing here reinterprets,
/// re-lays-out or re-typesets it: the artwork is painted whole, at its own aspect
/// ratio, and the surrounding backdrop only continues the artwork's own measured
/// edge colours so a device with a different aspect ratio never shows a visibly
/// wrong band.
const String kIntroSplashAsset =
    'assets/branding/m5/next_transfer_app_splash_screen.png';

/// Pixel aspect ratio (width / height) of [kIntroSplashAsset]: 941 x 1672.
///
/// The artwork is scaled uniformly to fit, so this is also the layout contract
/// for [introSplashBackdropGradient]: the backdrop reproduces the artwork's own
/// edge colours exactly where the artwork begins and ends, and extends them
/// beyond it.
const double kIntroSplashAspectRatio = 941 / 1672;

/// The approved artwork's own left/right edge colours, sampled down its height.
///
/// Only flat-field samples are used: the sampled rows deliberately avoid the
/// artwork's compositional band (the emblem, title and tagline all sit between
/// roughly 28% and 71% of the height), so the backdrop can never be tinted by
/// the artwork's content.
const List<Color> kIntroSplashEdgeColors = <Color>[
  Color(0xFF00388C), //   0%  rgb(0, 56, 140)
  Color(0xFF00398D), //  20%  rgb(0, 57, 141)
  Color(0xFF00317F), //  40%  rgb(0, 49, 127)
  Color(0xFF002A71), //  60%  rgb(0, 42, 113)
  Color(0xFF00296F), //  80%  rgb(0, 41, 111)
  Color(0xFF002461), // 100%  rgb(0, 36, 97)
];

/// Normalised heights of [kIntroSplashEdgeColors] within the artwork itself.
const List<double> kIntroSplashEdgeStops = <double>[0, 0.2, 0.4, 0.6, 0.8, 1];

/// The opaque backdrop painted behind the approved artwork on a [screen].
///
/// The artwork is displayed with a contain/safe fit (never stretched, never
/// cropped), so on a screen whose aspect ratio differs from the artwork's own
/// there is leftover area.  This gradient is anchored to the artwork's exact
/// position on that screen: the artwork's top edge colour sits precisely at the
/// artwork's top edge and its bottom edge colour precisely at the artwork's
/// bottom edge, with the sampled profile in between.  Anything outside the
/// artwork clamps to those same edge colours, so there is no seam and no band of
/// a visibly wrong colour, and the whole surface is fully opaque.
///
/// When the artwork fits by height (a screen wider than the artwork) the leftover
/// area is on the left and right; the gradient then spans the full height and its
/// vertical profile matches the artwork's own, which keeps the side bands in the
/// same colour family.
LinearGradient introSplashBackdropGradient(Size screen) {
  const begin = Alignment.topCenter;
  const end = Alignment.bottomCenter;
  if (screen.height <= 0 || screen.width <= 0) {
    return const LinearGradient(
      begin: begin,
      end: end,
      colors: kIntroSplashEdgeColors,
      stops: kIntroSplashEdgeStops,
    );
  }
  final artworkHeight = math.min(
    screen.height,
    screen.width / kIntroSplashAspectRatio,
  );
  final top = (screen.height - artworkHeight) / 2;
  final start = top / screen.height;
  final span = artworkHeight / screen.height;

  final colors = <Color>[];
  final stops = <double>[];
  void add(Color color, double stop) {
    final value = stop.clamp(0.0, 1.0);
    // A collapsed stop would make the shader's stop list non-monotonic; the
    // dropped entry is always a duplicate of the colour already kept.
    if (stops.isNotEmpty && value <= stops.last) return;
    colors.add(color);
    stops.add(value);
  }

  add(kIntroSplashEdgeColors.first, 0);
  for (var i = 0; i < kIntroSplashEdgeColors.length; i++) {
    add(kIntroSplashEdgeColors[i], start + kIntroSplashEdgeStops[i] * span);
  }
  add(kIntroSplashEdgeColors.last, 1);
  return LinearGradient(
    begin: begin,
    end: end,
    colors: colors,
    stops: stops,
  );
}

/// Starts decoding the approved intro splash artwork.
///
/// The intro splash owns the first Flutter frame, so the raster has to be in the
/// image cache before that frame is painted.  Starting the decode here overlaps
/// it with bootstrap work that has to happen anyway; the app then joins this
/// future just before `runApp`.  Because the resolved image lands in the shared
/// image cache, the splash surface's own `Image` finds it synchronously and the
/// FIRST painted frame is already the complete approved composition rather than a
/// bare branded field with the artwork arriving one frame later.
///
/// Failures complete the future instead of throwing: a missing or undecodable
/// asset must never hold startup, and the splash backdrop is opaque either way.
Future<void> preloadIntroSplashArtwork() {
  final completer = Completer<void>();
  final stream = const AssetImage(
    kIntroSplashAsset,
  ).resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  void settle() {
    stream.removeListener(listener);
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  listener = ImageStreamListener(
    (_, _) => settle(),
    onError: (_, _) => settle(),
  );
  stream.addListener(listener);
  return completer.future;
}
