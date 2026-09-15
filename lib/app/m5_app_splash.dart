import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// M5: the single owner-approved splash asset.
///
/// The file is a byte-for-byte copy of the approved artwork. It is presented
/// full-screen with [BoxFit.cover], so no phone aspect ratio can produce an
/// empty band at the top or the bottom of the screen.
const String nextTransferSplashAsset =
    'assets/branding/next_transfer_splash.png';

/// M5: the approved brand field, sampled from the edge of the approved splash
/// asset (rgb(0, 33, 97)).
///
/// Android's launch window, the Android 12+ platform splash and this overlay
/// all use this exact colour, so the whole launch reads as one continuous
/// surface and there is no white or black flash at any hand-off.
const Color nextTransferSplashBlue = Color(0xFF002161);

/// M5: how long the approved emblem takes to fade in over the brand field.
const Duration nextTransferSplashFadeIn = Duration(milliseconds: 160);

/// M5: how long the finished splash holds before it starts to leave.
const Duration nextTransferSplashHold = Duration(milliseconds: 600);

/// M5: how long the splash takes to fade away and reveal the app.
const Duration nextTransferSplashFadeOut = Duration(milliseconds: 240);

/// M5: whether the app-owned startup splash is mounted.
///
/// Defaults to the shipped behaviour. The shared widget-test harness turns it
/// off, because it mounts the real app to assert on startup and Privacy Lock
/// journeys and the branded overlay is a ~1 s presentation window in front of
/// them. The splash itself is covered directly by
/// `test/app/m5_app_splash_test.dart`.
final appSplashEnabledProvider = Provider<bool>((ref) => true);

/// M5: the app-owned startup splash.
///
/// Presentation only. It owns no route, no startup decision and no privacy
/// state: the existing startup gate, recovery route and Privacy Lock all
/// resolve underneath it exactly as before. It is painted above the router,
/// is fully opaque for its whole lifetime, and blocks pointers while mounted,
/// so no private app surface is ever visible or reachable behind it.
class M5AppSplash extends StatefulWidget {
  const M5AppSplash({super.key, required this.onFinished});

  /// Called once the fade-out completes and the overlay may be removed.
  final VoidCallback onFinished;

  @override
  State<M5AppSplash> createState() => _M5AppSplashState();
}

final class _M5AppSplashState extends State<M5AppSplash> {
  bool _emblemVisible = false;
  bool _fieldVisible = true;
  Timer? _holdTimer;
  Timer? _finishTimer;

  @override
  void initState() {
    super.initState();
    // The first frame is the plain brand field, which is exactly what the
    // Android launch window showed a moment earlier. Starting opaque and
    // fading only the emblem in (rather than fading the whole overlay in) is
    // what keeps whatever is resolving behind the splash hidden.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _emblemVisible = true);
    });
    _holdTimer = Timer(nextTransferSplashFadeIn + nextTransferSplashHold, () {
      if (!mounted) return;
      setState(() => _fieldVisible = false);
      _finishTimer = Timer(nextTransferSplashFadeOut, () {
        if (mounted) widget.onFinished();
      });
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _finishTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: AnimatedOpacity(
        opacity: _fieldVisible ? 1 : 0,
        duration: nextTransferSplashFadeOut,
        curve: Curves.easeOut,
        child: ColoredBox(
          color: nextTransferSplashBlue,
          child: AnimatedOpacity(
            opacity: _emblemVisible ? 1 : 0,
            duration: nextTransferSplashFadeIn,
            curve: Curves.easeOut,
            child: Image.asset(
              nextTransferSplashAsset,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              excludeFromSemantics: true,
            ),
          ),
        ),
      ),
    );
  }
}
