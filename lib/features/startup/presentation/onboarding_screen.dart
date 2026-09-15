import 'dart:async';
import 'dart:math' as math;

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

/// The approved brand field for the DARK front door (the same value the native
/// launch surface uses).  Light resolves the canonical light surface instead.
const Color _frontDoorField = nextTransferSplashBlue;

/// The approved brand blue, kept ONLY as the Blue candidate swatch inside the
/// Accent colour chooser (the applied accent itself resolves through the
/// canonical theme, so the chooser can still show two distinct candidates).
const Color _frontDoorBlueSwatch = Color(0xFF2F80ED);

/// Bottom clearance for a front-door CTA.
///
/// The surrounding `SafeArea` already consumes the system insets, so this is a
/// comfortable visual floor; it additionally honours any inset still reported
/// (e.g. when this screen is mounted without that SafeArea in a test), and it
/// never hardcodes one device's navigation bar.
double _frontDoorBottomClearance(BuildContext context) {
  final inset = MediaQuery.viewPaddingOf(context).bottom;
  return math.max(20, inset + 12);
}

/// M6 front-door presentation, resolved from the CANONICAL appearance state.
///
/// The canonical chain is unbroken: Setup taps call the real
/// `appearanceProvider.setMode` / `themeColorProvider.setColor`, those persist,
/// the root `MaterialApp` watches them and rebuilds `theme`/`darkTheme`/
/// `themeMode`, and this screen simply reads the RESOLVED theme instead of
/// painting hardcoded brand constants over it.  Tapping Light / Dark / System /
/// Blue / Rose therefore changes the onboarding pixels on the same frame, with
/// no second theme store and no fake preview state.
///
/// Dark keeps the owner-approved deep-blue composition; Light uses the
/// canonical light surface so the change is unmistakable.  Accent-aware
/// elements (CTA, selected rings, Ready check) resolve the canonical
/// `colorScheme.primary`, so Blue and Rose are both genuinely canonical.
final class _FrontDoorPalette {
  const _FrontDoorPalette({
    required this.dark,
    required this.field,
    required this.onField,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.rail,
    required this.cardFill,
    required this.cardFillSelected,
    required this.cardBorder,
    required this.idleRing,
    required this.divider,
    required this.checkCircle,
    required this.checkCircleBorder,
  });

  final bool dark;
  final Color field;
  final Color onField;
  final Color muted;
  final Color accent;
  final Color onAccent;
  final Color rail;
  final Color cardFill;
  final Color cardFillSelected;
  final Color cardBorder;
  final Color idleRing;
  final Color divider;
  final Color checkCircle;
  final Color checkCircleBorder;

  static _FrontDoorPalette of(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (Theme.of(context).brightness == Brightness.dark) {
      return _FrontDoorPalette(
        dark: true,
        field: _frontDoorField,
        onField: Colors.white,
        muted: const Color(0xFFC4D6F1),
        accent: scheme.primary,
        onAccent: scheme.onPrimary,
        rail: const Color(0xFF2C63B5),
        cardFill: Colors.white.withValues(alpha: 0.04),
        cardFillSelected: Colors.white.withValues(alpha: 0.10),
        cardBorder: Colors.white24,
        idleRing: Colors.white38,
        divider: Colors.white24,
        checkCircle: Colors.white,
        checkCircleBorder: Colors.white24,
      );
    }
    return _FrontDoorPalette(
      dark: false,
      field: scheme.surface,
      onField: scheme.onSurface,
      muted: scheme.onSurfaceVariant,
      accent: scheme.primary,
      onAccent: scheme.onPrimary,
      rail: scheme.outlineVariant,
      cardFill: scheme.surfaceContainerHighest,
      cardFillSelected: scheme.primaryContainer,
      cardBorder: scheme.outlineVariant,
      idleRing: scheme.outline,
      divider: scheme.outlineVariant,
      checkCircle: scheme.surfaceContainerLowest,
      checkCircleBorder: scheme.outlineVariant,
    );
  }
}

/// One brand surface for the whole front door, painted from the resolved
/// palette so the canonical appearance change is visible immediately.
Widget _frontDoorScaffold({
  required _FrontDoorPalette palette,
  required Widget body,
}) {
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: palette.dark
          ? Brightness.light
          : Brightness.dark,
      statusBarBrightness: palette.dark
          ? Brightness.dark
          : Brightness.light,
      systemNavigationBarColor: palette.field,
      systemNavigationBarIconBrightness: palette.dark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ),
    child: ColoredBox(
      key: const Key('m6-front-door-field'),
      color: palette.field,
      // bottom: false — each stage owns its own bottom clearance through
      // [_frontDoorBottomClearance], which already includes the system inset.
      // Letting SafeArea also consume the inset would double-count it and
      // float the CTA twice as high as the owner-approved composition.
      child: SafeArea(
        bottom: false,
        child: Material(type: MaterialType.transparency, child: body),
      ),
    ),
  );
}

final class _FrontDoorTitleBar extends StatelessWidget {
  const _FrontDoorTitleBar({
    required this.palette,
    required this.title,
    this.onBack,
  });

  final _FrontDoorPalette palette;
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
              child: _FrontDoorBackButton(
                palette: palette,
                onPressed: onBack!,
              ),
            ),
          Center(
            child: Text(
              title,
              style: TextStyle(
                color: palette.onField,
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
  const _FrontDoorBackButton({required this.palette, required this.onPressed});

  final _FrontDoorPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Back',
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(Icons.arrow_back, color: palette.onField, size: 26),
      ),
    );
  }
}

/// The approved three-node progress rail (done / current / pending).
final class _FrontDoorProgress extends StatelessWidget {
  const _FrontDoorProgress({required this.palette, required this.current});

  final _FrontDoorPalette palette;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 88),
      child: Row(
        children: <Widget>[
          for (var index = 0; index < 3; index += 1) ...<Widget>[
            if (index > 0)
              Expanded(
                child: SizedBox(
                  height: 2,
                  child: ColoredBox(color: palette.rail),
                ),
              ),
            _ProgressNode(
              palette: palette,
              index: index,
              current: current,
            ),
          ],
        ],
      ),
    );
  }
}

final class _ProgressNode extends StatelessWidget {
  const _ProgressNode({
    required this.palette,
    required this.index,
    required this.current,
  });

  final _FrontDoorPalette palette;
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
            ? palette.accent
            : active
            ? palette.onField
            : Colors.transparent,
        border: Border.all(
          color: done || active ? Colors.transparent : palette.idleRing,
          width: 2,
        ),
      ),
      child: done
          ? Icon(Icons.check, size: 18, color: palette.onAccent)
          : active
          ? Center(
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.accent,
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// Filled pill CTA carrying the canonical accent.
final class _FrontDoorPrimaryButton extends StatelessWidget {
  const _FrontDoorPrimaryButton({
    required this.palette,
    required this.label,
    required this.onPressed,
    this.buttonKey,
  });

  final _FrontDoorPalette palette;
  final String label;
  final VoidCallback? onPressed;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    // The Text child already publishes the accessible name; wrapping the
    // button in another labeled Semantics would duplicate the label.
    return SizedBox(
      height: 56,
      child: FilledButton(
        key: buttonKey,
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: palette.onAccent,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        onPressed: onPressed,
        // The label is Flexible so a long label (or 200% text scale on a
        // narrow screen) shrinks with an ellipsis instead of overflowing the
        // two-button row it usually shares.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(label, overflow: TextOverflow.ellipsis),
            ),
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
    required this.palette,
    required this.label,
    required this.onPressed,
  });

  final _FrontDoorPalette palette;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // The Text child already publishes the accessible name.
    return SizedBox(
      height: 56,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.onField,
          side: BorderSide(color: palette.cardBorder, width: 1.5),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        onPressed: onPressed,
        child: Text(label, overflow: TextOverflow.ellipsis),
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
  const _FrontDoorDots({required this.palette, required this.activeIndex});

  final _FrontDoorPalette palette;
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
              color: index == activeIndex ? palette.onField : palette.rail,
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
    final palette = _FrontDoorPalette.of(context);
    return _frontDoorScaffold(
      palette: palette,
      // The approved composition keeps its proportional rhythm, but the CTA is
      // anchored to the bottom safe area instead of floating mid-screen: the
      // scrollable content takes the remaining space and the CTA block sits
      // directly above the bottom clearance.  On short screens or at large text
      // scales the content still scrolls, so the CTA stays reachable.
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => ListView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                children: <Widget>[
                  SizedBox(height: constraints.maxHeight * 0.06),
                  const Center(child: _FrontDoorLogo(size: 132)),
                  const SizedBox(height: 44),
                  Text(
                    'Your next transfer\nstarts here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.onField,
                      fontSize: 36,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Plan what matters, privately on this device.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 18,
                      height: 1.35,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  SizedBox(height: constraints.maxHeight * 0.08),
                  SizedBox(
                    height: 12,
                    child: Center(
                      child: _FrontDoorDots(
                        palette: palette,
                        activeIndex: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              12,
              24,
              _frontDoorBottomClearance(context),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _FrontDoorPrimaryButton(
                  palette: palette,
                  buttonKey: const Key('m6-welcome-cta'),
                  label: 'Get Started',
                  // Blocked while the one-shot checkpoint transaction settles.
                  onPressed: getStartedPending ? null : onGetStarted,
                ),
                SizedBox(
                  height: 36,
                  child: Center(
                    child: getStartedPending
                        ? SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.muted,
                            ),
                          )
                        : const SizedBox.shrink(),
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
    // Resolved from the canonical theme the root MaterialApp just rebuilt, so
    // every selection below is visible on the same frame.
    final palette = _FrontDoorPalette.of(context);
    return _frontDoorScaffold(
      palette: palette,
      // The approved composition pins the title bar and progress rail above
      // the scrolling body, so Back and the step indicator stay mounted.
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: _FrontDoorTitleBar(
              palette: palette,
              title: 'Setup',
              onBack: widget.onBack,
            ),
          ),
          const SizedBox(height: 8),
          _FrontDoorProgress(palette: palette, current: 1),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                28,
                20,
                _frontDoorBottomClearance(context),
              ),
              children: <Widget>[
                Text(
                  'Choose your\nappearance',
                  style: TextStyle(
                    color: palette.onField,
                    fontSize: 32,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Make Next Transfer look the way you like.',
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 16,
                    height: 1.35,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Theme',
                  style: TextStyle(
                    color: palette.onField,
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
                          key: Key('m6-theme-option-${option.mode.name}'),
                          palette: palette,
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
                Text(
                  'Accent colour',
                  style: TextStyle(
                    color: palette.onField,
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
                          key: Key(
                            'm6-accent-option-${accent.mode.storageName}',
                          ),
                          palette: palette,
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
                _FrontDoorDivider(palette: palette),
                const SizedBox(height: 4),
                _DeferredSetupRow(
                  palette: palette,
                  icon: Icons.notifications_none,
                  title: 'Notifications',
                  detail: 'You can set this up later.',
                ),
                _DeferredSetupRow(
                  palette: palette,
                  icon: Icons.calendar_month_outlined,
                  title: 'Planner preferences',
                  detail: 'You can set this up later.',
                ),
                _DeferredSetupRow(
                  palette: palette,
                  icon: Icons.people_alt_outlined,
                  title: 'Contacts',
                  detail: 'You can add contacts later.',
                ),
                const SizedBox(height: 20),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _FrontDoorOutlinedButton(
                        palette: palette,
                        label: 'Skip for now',
                        // Continue and Skip both advance to You're Ready without
                        // completing onboarding.  Neither resets the appearance.
                        onPressed: _saving ? null : widget.onContinue,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _FrontDoorPrimaryButton(
                        palette: palette,
                        buttonKey: const Key('m6-setup-continue'),
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
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.muted,
                            ),
                          ),
                        )
                      : _saveFailed
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            'Appearance could not be saved. Your choice was not '
                            'changed.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.muted,
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
  _AccentOption(ThemeColorMode.blue, 'Blue', _frontDoorBlueSwatch),
  _AccentOption(ThemeColorMode.rose, 'Rose', AppTheme.roseLightProgress),
];

/// A rounded selectable card with the approved selected ring.
final class _AppearanceChoiceCard extends StatelessWidget {
  const _AppearanceChoiceCard({
    required this.palette,
    required this.selected,
    required this.label,
    required this.onTap,
    this.icon,
    this.swatch,
    super.key,
  });

  final _FrontDoorPalette palette;
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
        color: selected ? palette.cardFillSelected : palette.cardFill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            // The selected ring carries the canonical accent, so choosing Rose
            // or Blue is visible on the card itself.
            color: selected ? palette.accent : palette.cardBorder,
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
                  Icon(icon, size: 26, color: palette.onField)
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
                  style: TextStyle(
                    color: palette.onField,
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
  const _FrontDoorDivider({required this.palette});

  final _FrontDoorPalette palette;

  @override
  Widget build(BuildContext context) {
    return SizedBox(height: 1, child: ColoredBox(color: palette.divider));
  }
}

/// Informational deferral row.  These areas are configured after onboarding;
/// M6 deliberately exposes no controls, no deep link and no permission prompt
/// for them, and never labels them "Coming soon".
final class _DeferredSetupRow extends StatelessWidget {
  const _DeferredSetupRow({
    required this.palette,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final _FrontDoorPalette palette;
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 26, color: palette.onField),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: palette.onField,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(
                    color: palette.muted,
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
    final palette = _FrontDoorPalette.of(context);
    return _frontDoorScaffold(
      palette: palette,
      // The approved composition pins the title bar and progress rail above
      // the scrolling body, matching the Setup screen, and anchors the CTA to
      // the bottom safe area instead of floating it mid-screen.
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
            child: _FrontDoorTitleBar(
              palette: palette,
              title: "You're Ready",
              // Back is blocked while completion + re-resolution is running.
              onBack: pending ? null : onBack,
            ),
          ),
          const SizedBox(height: 8),
          _FrontDoorProgress(palette: palette, current: 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: LayoutBuilder(
                    // A non-lazy scroll view: the approved composition is short,
                    // but a fixed-height lazy list would leave the lower copy
                    // outside the build window on small surfaces, so the
                    // subtitle must always be mounted.  It still scrolls when
                    // short height or large text needs it.
                    builder: (context, constraints) => SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          SizedBox(height: constraints.maxHeight * 0.05),
                          Center(child: _ReadyArtwork(palette: palette)),
                          const SizedBox(height: 30),
                          Text(
                            "You're ready.",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.onField,
                              fontSize: 36,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Your next transfer starts with one step.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 18,
                              height: 1.35,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    12,
                    24,
                    _frontDoorBottomClearance(context),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _FrontDoorPrimaryButton(
                        palette: palette,
                        buttonKey: const Key('m6-ready-cta'),
                        label: 'Go to Home',
                        // Single-flight completion: Back and duplicate taps are
                        // blocked until completion + re-resolution settles.
                        onPressed: pending ? null : onGoHome,
                      ),
                      SizedBox(
                        height: 36,
                        child: Center(
                          child: pending
                              ? SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: palette.muted,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ],
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

/// The exact source rectangle of the frozen splash artwork used for the Ready
/// illustration, in the asset's own 941x1672 pixel space.
///
/// Measured from the locked asset (`assets/branding/next_transfer_splash.png`):
/// the drawn landscape artwork occupies roughly x 291..659 / y 665..1011 inside
/// a rounded tile spanning x 225..716 / y 362..1160.  This window frames that
/// artwork and stays well inside the tile, so the owner-rejected rounded
/// "app-icon tile" is excluded and NO new asset generation is required.
@visibleForTesting
const Rect m6ReadyIllustrationSource = Rect.fromLTRB(283, 658, 667, 1018);

/// Measured bounding box of the splash asset's rounded tile (the app mark), in
/// the same pixel space.
@visibleForTesting
const Rect m6SplashTileBounds = Rect.fromLTRB(225, 362, 716, 1160);

/// Minimum margin (in asset pixels) the Ready crop keeps from the tile frame,
/// so the rounded tile edge can never appear inside the illustration.
@visibleForTesting
const double m6ReadyIllustrationMinTileMargin = 40;

/// Renders an EXACT source rectangle of the frozen splash artwork, filling
/// [width] x [height] with cover semantics.
///
/// Presentation only: the asset, its bytes, its registered path and the
/// pubspec are untouched.  This exists because `Image` alone cannot restrict
/// its source window to a sub-rectangle, which is what excluding the splash
/// tile frame requires.
final class _SplashCrop extends StatelessWidget {
  const _SplashCrop({
    required this.width,
    required this.height,
    required this.source,
  });

  final double width;
  final double height;
  final Rect source;

  /// The locked asset's intrinsic size.
  static const Size _assetSize = Size(941, 1672);

  @override
  Widget build(BuildContext context) {
    final scale = math.max(width / source.width, height / source.height);
    final renderWidth = _assetSize.width * scale;
    final renderHeight = _assetSize.height * scale;
    final left = (width - source.width * scale) / 2 - source.left * scale;
    final top = (height - source.height * scale) / 2 - source.top * scale;
    return ClipRect(
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: left,
              top: top,
              width: renderWidth,
              height: renderHeight,
              child: Image(
                image: nextTransferSplashImage,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
                excludeFromSemantics: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Restrained success mark above the approved landscape artwork.
///
/// Owner-approved target: a small check circle, clean vertical separation from
/// the illustration, the mountain/winding-path artwork WITHOUT the rounded
/// app-icon tile, and no overlap between mark and artwork.  The check and its
/// circle are appearance-aware through [palette], so You're Ready inherits the
/// Light/Dark/System and Blue/Rose choice made in Setup.
final class _ReadyArtwork extends StatelessWidget {
  const _ReadyArtwork({required this.palette});

  final _FrontDoorPalette palette;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          key: const Key('m6-ready-check'),
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: palette.checkCircle,
            border: Border.all(color: palette.checkCircleBorder, width: 1.5),
          ),
          child: Icon(Icons.check, size: 40, color: palette.accent),
        ),
        const SizedBox(height: 22),
        ClipRRect(
          key: const Key('m6-ready-illustration'),
          borderRadius: BorderRadius.circular(18),
          child: const _SplashCrop(
            width: 224,
            height: 210,
            source: m6ReadyIllustrationSource,
          ),
        ),
      ],
    );
  }
}
