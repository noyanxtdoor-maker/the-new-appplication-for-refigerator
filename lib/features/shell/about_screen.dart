import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/shell/window_size_class.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/core/platform/app_info.dart';

/// Canonical About screen (Pack 3, locked policy 6).
///
/// Shows the actual app name, the actual version/build metadata from
/// [AppInfo] (mirroring `pubspec.yaml`), the approved Next Transfer
/// tagline, and only existing approved links (the canonical Privacy and
/// Data surface).  No invented legal text, no copied PMG content.
final class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: InternalAppBar(title: const Text('About')),
      body: SafeArea(
        // PRE-BETA RESPONSIVE (owner law, 2026-09-16): ordinary support content
        // is capped on a wide window.  Layout-neutral at phone widths.
        child: MaxContentWidth(
          child: ListView(
            padding: InternalScreen.pagePadding,
            children: <Widget>[
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.rose.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    'NT',
                    style: TextStyle(
                      color: AppTheme.rose,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Center(
                child: Text(
                  AppInfo.appName,
                  key: Key('about-app-name'),
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 20,
                    height: 26 / 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Center(
                child: Text(
                  AppInfo.tagline,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 13,
                    height: 18 / 13,
                    fontWeight: FontWeight.w400,
                    color: Colors.white60,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Center(
                child: Text(
                  'Version ${AppInfo.version} (build ${AppInfo.buildNumber})',
                  key: Key('about-version'),
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 12,
                    height: 16 / 12,
                    fontWeight: FontWeight.w400,
                    color: Colors.white38,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Card(
                margin: EdgeInsets.zero,
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: AppTheme.outline),
                ),
                child: ListTile(
                  key: const Key('about-privacy-link'),
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Privacy and Data'),
                  subtitle: const Text(
                    'Privacy Lock, permissions, local data, diagnostics',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => context.push(RoutePaths.privacyCenter),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
