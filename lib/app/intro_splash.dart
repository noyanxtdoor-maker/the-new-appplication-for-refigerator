import 'package:flutter/material.dart';

/// The first Flutter-owned presentation after Android's required system
/// launch surface. It is deliberately stateless: it occupies only genuine
/// startup resolution time and never adds an artificial minimum duration.
final class NextTransferIntroSplash extends StatelessWidget {
  const NextTransferIntroSplash({super.key});

  static const Color backgroundColor = Color(0xFF002B73);
  static const String assetPath =
      'assets/branding/next_transfer_journey_begins.png';
  static const String semanticLabel =
      'Next Transfer. THE MISSION ENDED. THE NEXT TRANSFER BEGINS.';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      image: true,
      child: ColoredBox(
        key: const Key('next-transfer-intro-splash'),
        color: backgroundColor,
        child: SizedBox.expand(
          // The approved artwork is portrait-first. Cover fills modern tall
          // Android phones by trimming only its empty side background; the
          // title and two-line tagline remain vertically intact.
          child: Image.asset(
            assetPath,
            key: const Key('next-transfer-intro-splash-artwork'),
            fit: BoxFit.cover,
            alignment: Alignment.center,
            filterQuality: FilterQuality.high,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}
