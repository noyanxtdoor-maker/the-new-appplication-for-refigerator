import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// M5's app-owned launch surface.
///
/// It deliberately sits above the existing router: startup and Privacy Lock
/// continue to select the first application route while this opaque surface is
/// visible, so no private route can be exposed during launch.
final class M5AppSplashGate extends StatefulWidget {
  const M5AppSplashGate({required this.child, super.key});

  final Widget child;

  @override
  State<M5AppSplashGate> createState() => _M5AppSplashGateState();
}

final class _M5AppSplashGateState extends State<M5AppSplashGate> {
  static const _minimumPresentation = Duration(milliseconds: 550);
  var _visible = true;
  var _removed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_dismissAfterMinimumPresentation());
  }

  Future<void> _dismissAfterMinimumPresentation() async {
    await Future<void>.delayed(_minimumPresentation);
    if (mounted) setState(() => _visible = false);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        widget.child,
        if (!_removed)
          IgnorePointer(
            ignoring: !_visible,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              onEnd: () {
                if (!_visible && mounted) setState(() => _removed = true);
              },
              child: const M5AppSplashScreen(),
            ),
          ),
      ],
    );
  }
}

final class M5AppSplashScreen extends StatelessWidget {
  const M5AppSplashScreen({super.key});

  static const backgroundColor = Color(0xFF052F72);

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: backgroundColor,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: backgroundColor,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
      child: ColoredBox(
        color: backgroundColor,
        child: Semantics(
          label: 'Next Transfer is opening',
          image: true,
          child: Image.asset(
            'assets/branding/next_transfer_splash.png',
            key: const Key('m5-app-owned-splash'),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            alignment: Alignment.center,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}
