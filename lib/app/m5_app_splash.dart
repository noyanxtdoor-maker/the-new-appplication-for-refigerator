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

/// The exact [ImageProvider] shared by predecode and rendering. Keeping this
/// configuration in one place prevents a cache-key mismatch from releasing the
/// first Flutter frame before its intended branded pixels are available.
const AssetImage nextTransferSplashImage = AssetImage(nextTransferSplashAsset);

/// Owns one balanced Flutter first-frame deferral. It is started before
/// [runApp] and is released only after the app root has incorporated either the
/// approved image or an explicit non-private image-load failure surface.
final class SplashFirstFrameGate {
  SplashFirstFrameGate({
    void Function()? deferFirstFrame,
    void Function()? allowFirstFrame,
  }) : _deferFirstFrame =
           deferFirstFrame ?? WidgetsBinding.instance.deferFirstFrame,
       _allowFirstFrame =
           allowFirstFrame ?? WidgetsBinding.instance.allowFirstFrame;

  final void Function() _deferFirstFrame;
  final void Function() _allowFirstFrame;
  var _deferred = false;
  var _released = false;

  void defer() {
    if (_deferred) return;
    _deferred = true;
    _deferFirstFrame();
  }

  void release() {
    if (!_deferred || _released) return;
    _released = true;
    _allowFirstFrame();
  }
}

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
/// state. It is fully opaque from its first submitted Flutter frame and blocks
/// both pointer and underlying semantics while mounted.
final class M5AppSplash extends StatelessWidget {
  const M5AppSplash({
    super.key,
    this.imageReady = true,
    this.imageFailed = false,
    this.onFailureAcknowledged,
  });

  final bool imageReady;
  final bool imageFailed;
  final VoidCallback? onFailureAcknowledged;

  @override
  Widget build(BuildContext context) {
    final content = imageFailed
        ? _SplashImageFailure(onAcknowledged: onFailureAcknowledged)
        : imageReady
        ? Image(
            image: nextTransferSplashImage,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            excludeFromSemantics: true,
          )
        : const SizedBox.expand();
    final overlay = ColoredBox(color: nextTransferSplashBlue, child: content);
    return BlockSemantics(
      child: Semantics(
        container: true,
        label: imageFailed
            ? 'Next Transfer launch artwork unavailable'
            : 'Opening Next Transfer',
        // The failure surface covers the whole window but leaves its own
        // explicit acknowledgement actionable. All normal splash states absorb
        // every pointer while startup resolves behind the opaque overlay.
        child: imageFailed
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: overlay,
              )
            : AbsorbPointer(child: overlay),
      ),
    );
  }
}

final class _SplashImageFailure extends StatelessWidget {
  const _SplashImageFailure({this.onAcknowledged});

  final VoidCallback? onAcknowledged;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.broken_image_outlined,
              color: Colors.white,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'Next Transfer could not load its approved launch artwork.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (onAcknowledged != null) ...<Widget>[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onAcknowledged,
                child: const Text('Continue safely'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
