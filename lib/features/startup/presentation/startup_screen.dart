import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rmplanner/app/intro_splash.dart';

/// M5 — the owner-approved Next Transfer intro splash, and the first Flutter
/// frame of the app.
///
/// What this surface guarantees:
///
///  * it owns the whole screen and its root is FULLY OPAQUE, so no destination
///    (Home, Planner, Contacts, Maps) and no private content can ever be visible
///    through it, and no white or black frame is possible while it is shown;
///  * the approved artwork is painted whole at its own aspect ratio (contain /
///    safe fit), so the brand mark, the `Next Transfer` title and the approved
///    tagline can never be cropped, and the raster can never be stretched
///    non-uniformly on any device ratio;
///  * the leftover area on other ratios is filled with the artwork's OWN sampled
///    edge colours through [introSplashBackdropGradient], so it reads as a
///    continuous extension of the approved background rather than a wrong band;
///  * there is no spinner, no progress bar, no button, no explicit opacity or
///    fade wrapper, and no artificial hold.  The splash occupies real
///    bootstrap / privacy-resolution time only: the bootstrap resolves startup
///    and the first resolved state routes away from here.
///
/// The splash is branding, not authentication.  When the Privacy Lock is enabled
/// the resolved state is `StartupProtected` and this surface is replaced by the
/// existing Privacy Lock, which remains fail-closed and untouched.
final class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key});

  /// The one visible status announcement for this surface.
  ///
  /// The artwork carries the title and tagline as pixels, so this label is what a
  /// screen reader is given.  It deliberately repeats the approved visible text
  /// rather than paraphrasing it.
  static const String semanticsLabel =
      'Next Transfer. The mission ended. The next transfer begins.';

  @override
  Widget build(BuildContext context) {
    return const _ApprovedIntroSplash();
  }
}

final class _ApprovedIntroSplash extends StatelessWidget {
  const _ApprovedIntroSplash();

  @override
  Widget build(BuildContext context) {
    // The splash field is deep blue and always opaque, so the system bars are
    // annotated for light icons for exactly as long as this route is the visible
    // one.  Replacing this route restores the app's own overlay style, so no
    // lasting system-UI change is made.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Color(0xFF002461),
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Semantics(
        liveRegion: true,
        label: StartupScreen.semanticsLabel,
        child: const _OpaqueSplashSurface(),
      ),
    );
  }
}

final class _OpaqueSplashSurface extends StatelessWidget {
  const _OpaqueSplashSurface();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: introSplashBackdropGradient(constraints.biggest),
          ),
          child: const SizedBox.expand(
            child: Image(
              image: AssetImage(kIntroSplashAsset),
              fit: BoxFit.contain,
              alignment: Alignment.center,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              excludeFromSemantics: true,
            ),
          ),
        );
      },
    );
  }
}
