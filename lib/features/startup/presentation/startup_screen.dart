import 'package:flutter/material.dart';

final class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key});

  static const _background = Color(0xFF002A72);
  static const _logoAsset = 'assets/branding/next_transfer_splash_logo.png';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: SizedBox.expand(
        child: Center(
          child: Semantics(
            image: true,
            label: 'Next Transfer',
            child: const _StartupLogo(),
          ),
        ),
      ),
    );
  }
}

final class _StartupLogo extends StatelessWidget {
  const _StartupLogo();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return SizedBox(
      width: (width * 0.46).clamp(0, 360).toDouble(),
      child: const Image(
        image: AssetImage(StartupScreen._logoAsset),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}
