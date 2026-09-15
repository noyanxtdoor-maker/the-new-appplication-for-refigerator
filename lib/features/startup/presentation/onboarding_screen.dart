import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/m5_app_splash.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/features/settings/application/appearance_providers.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

/// M6 front door: Welcome -> Setup -> You're Ready -> Go to Home.
///
/// The three screens are presentation substates of the EXISTING
/// `/onboarding` destination.  They own no new route, no new persisted stage
/// format and no parallel state system:
/// - StartupWelcome renders Welcome.
/// - StartupOnboarding renders Setup (Welcome and You're Ready are local
///   presentation states beneath it).
/// - Only "Go to Home" calls [StartupController.completeOnboarding]; Continue
///   and Skip intentionally do not complete.  A process death on Setup or
///   Ready resumes Setup on restart, which is the deterministic, audited
///   resume law.
final class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Stage { welcome, setup, ready }

final class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  /// Local presentation stage.  Null means "follow the startup state":
  /// StartupWelcome shows Welcome and StartupOnboarding shows Setup.
  _Stage? _stage;

  /// Blocks a second Get Started while the checkpoint transaction runs.
  bool _getStartedPending = false;

  /// Blocks Back and duplicate taps while completion + re-resolution runs.
  bool _goHomePending = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(startupControllerProvider);
    final stage = switch (state) {
      StartupWelcome() =>
        _stage == _Stage.setup ? _Stage.setup : _Stage.welcome,
      StartupOnboarding() => switch (_stage) {
        null || _Stage.setup => _Stage.setup,
        final other => other,
      },
      _ => null,
    };
    return switch (stage) {
      _Stage.welcome => _WelcomeStage(
        onGetStarted: _onGetStarted,
        getStartedPending: _getStartedPending,
      ),
      _Stage.setup => _SetupStage(
        onBack: () => setState(() => _stage = _Stage.welcome),
        onContinue: () => setState(() => _stage = _Stage.ready),
      ),
      _Stage.ready => _ReadyStage(
        onBack: () => setState(() => _stage = _Stage.setup),
        onGoHome: _onGoHome,
        goHomePending: _goHomePending,
      ),
      // StartupOpening/Recovery/Protected are transient here; the route guard
      // redirects to the canonical destination for each of them.
      null => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }

  /// One-shot checkpoint creation/resume: only a successful
  /// [StartupController.continueLocalOnly] flips the startup state (and
  /// therefore the persistence law) to Setup.  The optimistic stage change
  /// keeps the presentation deterministic if the user is already resuming an
  /// existing checkpoint (Welcome Back never deletes it).
  void _onGetStarted() {
    if (_getStartedPending) {
      return;
    }
    setState(() {
      _getStartedPending = true;
      _stage = _Stage.setup;
    });
    unawaited(
      ref
          .read(startupControllerProvider.notifier)
          .continueLocalOnly()
          .whenComplete(() {
            if (mounted) {
              setState(() => _getStartedPending = false);
            }
          }),
    );
  }

  /// The single completion path.  The controller is single-flight; the local
  /// pending flag additionally blocks Back and duplicate taps until the
  /// completion + re-resolution settles and the guarded redirect lands.
  Future<void> _onGoHome() async {
    if (_goHomePending) {
      return;
    }
    setState(() => _goHomePending = true);
    try {
      await ref.read(startupControllerProvider.notifier).completeOnboarding();
    } finally {
      if (mounted) {
        setState(() => _goHomePending = false);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Shared front-door chrome
// ---------------------------------------------------------------------------

/// One brand surface for the whole front door, sampled from the edge of the
/// approved splash artwork (the same value the native launch surface uses).
const Color _frontDoorField = nextTransferSplashBlue;

/// The approved front-door action blue (CTA, selected rings, success check).
const Color _frontDoorActionBlue = Color(0xFF2F80ED);

/// Approved M6 front-door visual language: premium deep-blue field, white
/// artwork and headline, light-blue supporting copy, brand-blue filled CTA.
/// Applied as an explicit local presentation only — no global theme change.
Widget _frontDoorScaffold({required Widget body}) {
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: _frontDoorField,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ),
    child: ColoredBox(
      color: _frontDoorField,
      child: SafeArea(
        child: Material(type: MaterialType.transparency, child: body),
      ),
    ),
  );
}

final class _FrontDoorTitleBar extends StatelessWidget {
  const _FrontDoorTitleBar({required this.title, this.onBack});

  final String title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          if (onBack != null)
            Align(
              alignment: Alignment.centerLeft,
              child: _FrontDoorBackButton(onPressed: onBack!),
            ),
          Center(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _FrontDoorBackButton extends StatelessWidget {
  const _FrontDoorBackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Back',
      child: IconButton(
        onPressed: onPressed,
        icon: const Icon(Icons.arrow_back, color: Colors.white, size: 26),
      ),
    );
  }
}

/// The approved three-node progress rail (done / current / pending).
final class _FrontDoorProgress extends StatelessWidget {
  const _FrontDoorProgress({required this.current});

  final int current;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 88),
      child: Row(
        children: <Widget>[
          for (var index = 0; index < 3; index += 1) ...<Widget>[
            if (index > 0)
              const Expanded(
                child: SizedBox(
                  height: 2,
                  child: ColoredBox(color: Color(0xFF2C63B5)),
                ),
              ),
            _ProgressNode(index: index, current: current),
          ],
        ],
      ),
    );
  }
}

final class _ProgressNode extends StatelessWidget {
  const _ProgressNode({required this.index, required this.current});

  final int index;
  final int current;

  @override
  Widget build(BuildContext context) {
    final done = index < current;
    final active = index == current;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done
            ? _frontDoorActionBlue
            : active
            ? Colors.white
            : Colors.transparent,
        border: Border.all(
          color: done || active ? Colors.transparent : Colors.white38,
          width: 2,
        ),
      ),
      child: done
          ? const Icon(Icons.check, size: 18, color: Colors.white)
          : active
          ? Center(
              child: Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: _frontDoorActionBlue,
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// Filled pill CTA in the approved brand blue.
final class _FrontDoorPrimaryButton extends StatelessWidget {
  const _FrontDoorPrimaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // The Text child already publishes the accessible name; wrapping the
    // button in another labeled Semantics would duplicate the label.
    return SizedBox(
      height: 56,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: _frontDoorActionBlue,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        onPressed: onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward, size: 20),
          ],
        ),
      ),
    );
  }
}

final class _FrontDoorOutlinedButton extends StatelessWidget {
  const _FrontDoorOutlinedButton({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // The Text child already publishes the accessible name.
    return SizedBox(
      height: 56,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white38, width: 1.5),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// The approved app mark, cropped from the center of the already-registered
/// splash artwork (the protected rounded-square mark on the brand field).  No
/// new asset, no pubspec change, no launcher-icon reuse.
final class _FrontDoorLogo extends StatelessWidget {
  const _FrontDoorLogo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        width: size,
        height: size,
        child: Image(
          image: nextTransferSplashImage,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}

final class _FrontDoorDots extends StatelessWidget {
  const _FrontDoorDots({required this.activeIndex});

  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var index = 0; index < 3; index += 1) ...<Widget>[
          if (index > 0) const SizedBox(width: 12),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: index == activeIndex
                  ? Colors.white
                  : const Color(0xFF2C63B5),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 1 — Welcome
// ---------------------------------------------------------------------------

final class _WelcomeStage extends StatelessWidget {
  const _WelcomeStage({
    required this.onGetStarted,
    required this.getStartedPending,
  });

  final VoidCallback onGetStarted;
  final bool getStartedPending;

  @override
  Widget build(BuildContext context) {
    return _frontDoorScaffold(
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          children: <Widget>[
            SizedBox(height: constraints.maxHeight * 0.06),
            const Center(child: _FrontDoorLogo(size: 132)),
            const SizedBox(height: 44),
            const Text(
              'Your next transfer\nstarts here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 36,
                height: 1.2,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Plan what matters, privately on this device.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFFC4D6F1),
                fontSize: 18,
                height: 1.35,
                decoration: TextDecoration.none,
              ),
            ),
            SizedBox(height: constraints.maxHeight * 0.08),
            const SizedBox(
              height: 12,
              child: Center(child: _FrontDoorDots(activeIndex: 0)),
            ),
            SizedBox(height: constraints.maxHeight * 0.06),
            _FrontDoorPrimaryButton(
              label: 'Get Started',
              // Blocked while the one-shot checkpoint transaction settles.
              onPressed: getStartedPending ? null : onGetStarted,
            ),
            SizedBox(
              height: 36,
              child: Center(
                child: getStartedPending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 2 — Setup (real Appearance; truthful deferred rows)
// ---------------------------------------------------------------------------

final class _SetupStage extends ConsumerStatefulWidget {
  const _SetupStage({required this.onBack, required this.onContinue});

  final VoidCallback onBack;
  final VoidCallback onContinue;

  @override
  ConsumerState<_SetupStage> createState() => _SetupStageState();
}

final class _SetupStageState extends ConsumerState<_SetupStage> {
  bool _saving = false;
  bool _saveFailed = false;

  Future<void> _selectMode(AppearanceMode mode) async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    // Canonical appearance API: persist first, apply only on success.  A
    // failed save is surfaced truthfully and the selection keeps the last
    // confirmed value.  A successful save survives Skip, Back, and restarts.
    final saved = await ref.read(appearanceProvider.notifier).setMode(mode);
    if (!mounted) {
      return;
    }
    setState(() {
      _saving = false;
      _saveFailed = !saved;
    });
  }

  Future<void> _selectColor(ThemeColorMode color) async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    final saved = await ref.read(themeColorProvider.notifier).setColor(color);
    if (!mounted) {
      return;
    }
    setState(() {
      _saving = false;
      _saveFailed = !saved;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appearanceProvider);
    final color = ref.watch(themeColorProvider);
    return _frontDoorScaffold(
      // The approved composition pins the title bar and progress rail above
      // the scrolling body, so Back and the step indicator stay mounted.
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: _FrontDoorTitleBar(title: 'Setup', onBack: widget.onBack),
          ),
          const SizedBox(height: 8),
          const _FrontDoorProgress(current: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
              children: <Widget>[
                const Text(
                  'Choose your\nappearance',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Make Next Transfer look the way you like.',
                  style: TextStyle(
                    color: Color(0xFFC4D6F1),
                    fontSize: 16,
                    height: 1.35,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Theme',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    for (final option in _themeOptions) ...<Widget>[
                      if (option != _themeOptions.first)
                        const SizedBox(width: 10),
                      Expanded(
                        child: _AppearanceChoiceCard(
                          selected: option.mode == mode,
                          label: option.label,
                          icon: option.icon,
                          onTap: _saving
                              ? null
                              : () => unawaited(_selectMode(option.mode)),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 20),
                const Text(
                  'Accent colour',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    for (final accent in _accentOptions) ...<Widget>[
                      if (accent != _accentOptions.first)
                        const SizedBox(width: 10),
                      Expanded(
                        child: _AppearanceChoiceCard(
                          selected: accent.mode == color,
                          label: accent.label,
                          swatch: accent.swatch,
                          onTap: _saving
                              ? null
                              : () => unawaited(_selectColor(accent.mode)),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 28),
                const _FrontDoorDivider(),
                const SizedBox(height: 4),
                const _DeferredSetupRow(
                  icon: Icons.notifications_none,
                  title: 'Notifications',
                  detail: 'You can set this up later.',
                ),
                const _DeferredSetupRow(
                  icon: Icons.calendar_month_outlined,
                  title: 'Planner preferences',
                  detail: 'You can set this up later.',
                ),
                const _DeferredSetupRow(
                  icon: Icons.people_alt_outlined,
                  title: 'Contacts',
                  detail: 'You can add contacts later.',
                ),
                const SizedBox(height: 20),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _FrontDoorOutlinedButton(
                        label: 'Skip for now',
                        // Continue and Skip both advance to You're Ready without
                        // completing onboarding.  Neither resets the appearance.
                        onPressed: _saving ? null : widget.onContinue,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _FrontDoorPrimaryButton(
                        label: 'Continue',
                        onPressed: _saving ? null : widget.onContinue,
                      ),
                    ),
                  ],
                ),
                // Truthful in-flight / failure feedback while the write settles.
                AnimatedSize(
                  duration: const Duration(milliseconds: 150),
                  alignment: Alignment.topCenter,
                  child: _saving
                      ? const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white70,
                            ),
                          ),
                        )
                      : _saveFailed
                      ? const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                            'Appearance could not be saved. Your choice was not '
                            'changed.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : const SizedBox(height: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _ThemeOption {
  const _ThemeOption(this.mode, this.label, this.icon);

  final AppearanceMode mode;
  final String label;
  final IconData icon;
}

const List<_ThemeOption> _themeOptions = <_ThemeOption>[
  _ThemeOption(AppearanceMode.system, 'System', Icons.brightness_auto_outlined),
  _ThemeOption(AppearanceMode.light, 'Light', Icons.light_mode_outlined),
  _ThemeOption(AppearanceMode.dark, 'Dark', Icons.dark_mode_outlined),
];

final class _AccentOption {
  const _AccentOption(this.mode, this.label, this.swatch);

  final ThemeColorMode mode;
  final String label;
  final Color swatch;
}

const List<_AccentOption> _accentOptions = <_AccentOption>[
  _AccentOption(ThemeColorMode.blue, 'Blue', _frontDoorActionBlue),
  _AccentOption(ThemeColorMode.rose, 'Rose', AppTheme.roseLightProgress),
];

/// A rounded selectable card with the approved selected ring.
final class _AppearanceChoiceCard extends StatelessWidget {
  const _AppearanceChoiceCard({
    required this.selected,
    required this.label,
    required this.onTap,
    this.icon,
    this.swatch,
  });

  final bool selected;
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final Color? swatch;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // Traits only: the Text child publishes the accessible name, so no
      // explicit label here (it would duplicate the name for TalkBack and
      // semantic finders).
      button: true,
      selected: selected,
      child: Material(
        color: Colors.white.withValues(alpha: selected ? 0.10 : 0.04),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? _frontDoorActionBlue : Colors.white24,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (icon != null)
                  Icon(icon, size: 26, color: Colors.white)
                else if (swatch != null)
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: swatch,
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _FrontDoorDivider extends StatelessWidget {
  const _FrontDoorDivider();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(height: 1, child: ColoredBox(color: Colors.white24));
  }
}

/// Informational deferral row.  These areas are configured after onboarding;
/// M6 deliberately exposes no controls, no deep link and no permission prompt
/// for them, and never labels them "Coming soon".
final class _DeferredSetupRow extends StatelessWidget {
  const _DeferredSetupRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 26, color: Colors.white),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Color(0xFFC4D6F1),
                    fontSize: 14,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 3 — You're Ready
// ---------------------------------------------------------------------------

final class _ReadyStage extends StatelessWidget {
  const _ReadyStage({
    required this.onBack,
    required this.onGoHome,
    required this.goHomePending,
  });

  final VoidCallback onBack;
  final VoidCallback onGoHome;
  final bool goHomePending;

  @override
  Widget build(BuildContext context) {
    final pending = goHomePending;
    return _frontDoorScaffold(
      // The approved composition pins the title bar and progress rail above
      // the scrolling body, matching the Setup screen.
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
            child: _FrontDoorTitleBar(
              title: "You're Ready",
              // Back is blocked while completion + re-resolution is running.
              onBack: pending ? null : onBack,
            ),
          ),
          const SizedBox(height: 8),
          const _FrontDoorProgress(current: 2),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                children: <Widget>[
                  SizedBox(height: constraints.maxHeight * 0.08),
                  const Center(child: _ReadyArtwork()),
                  const SizedBox(height: 36),
                  const Text(
                    "You're ready.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Your next transfer starts with one step.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFC4D6F1),
                      fontSize: 18,
                      height: 1.35,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  SizedBox(height: constraints.maxHeight * 0.06),
                  _FrontDoorPrimaryButton(
                    label: 'Go to Home',
                    // Single-flight completion: Back and duplicate taps are blocked
                    // until completion + re-resolution settles.
                    onPressed: pending ? null : onGoHome,
                  ),
                  SizedBox(
                    height: 36,
                    child: Center(
                      child: pending
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white70,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Success mark over the approved landscape artwork, matching the accepted
/// composition: a white circle with the brand-blue check floating above the
/// cropped splash landscape.  No asset change is involved.
final class _ReadyArtwork extends StatelessWidget {
  const _ReadyArtwork();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      height: 240,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned(
            bottom: 0,
            child: ClipRect(
              child: SizedBox(
                width: 260,
                height: 180,
                child: Image(
                  image: nextTransferSplashImage,
                  fit: BoxFit.cover,
                  alignment: const Alignment(0, 0.55),
                  filterQuality: FilterQuality.medium,
                  excludeFromSemantics: true,
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            child: Container(
              width: 110,
              height: 110,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
              child: const Icon(
                Icons.check,
                size: 64,
                color: _frontDoorActionBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
