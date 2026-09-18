import 'package:flutter/material.dart';
import 'package:rmplanner/app/intro_splash.dart';

final class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // This route is reachable only while StartupState is StartupOpening. The
    // route guard replaces it with Privacy Lock or the established destination
    // after actual resolution, so no private app content sits below this fully
    // opaque, full-screen surface.
    return const NextTransferIntroSplash();
  }
}
