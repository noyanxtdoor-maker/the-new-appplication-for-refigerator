import 'package:flutter/material.dart';

import 'package:rmplanner/features/planner/domain/event_color_math.dart';
import 'package:rmplanner/features/planner/domain/recommended_event_colors.dart';

/// Adaptive layout strategy for Calendar Event blocks on the Day timeline.
///
/// The Planner Day view renders blocks at heights derived from minute
/// spans and the zoomed hour-height. A block can be as small as
/// ~15 minutes (and below the visible line-height) or as tall as several
/// hours. The same widget tree needs to render at every height without
/// a RenderFlex overflow and without leaving the user looking at a
/// Flutter debug stripe.
///
/// The policy in [PlannerEventBlockLayoutPolicy] chooses how much
/// information to reveal based on the available height. This mirrors
/// the approved thresholds in the temporary patch scope:
///
///   * VERY SHORT  (≤ 24 px)        — title with ellipsis only.
///   * SHORT       (> 24 ≤ 44 px)   — title; time only if it fits.
///   * MEDIUM      (> 44 ≤ 70 px)   — title; time; one compact status.
///   * TALL        (> 70 px)        — title; time; status; resize handle.
abstract final class PlannerEventBlockLayoutPolicy {
  /// Compact silhouette constants for the rendered Event block. Keeping
  /// these in the layout policy makes the reference shape testable without
  /// coupling tests to Flutter's internal Material shape objects.
  ///
  /// PMG-style solid block geometry (Part 7): restrained ~3 dp base corner
  /// radius, ~3 dp accent strip, and ~2 dp lane gap.  No shadow, no
  /// elevation, no soft card surface.
  static const double eventBorderRadius = 3;
  static const double eventAccentWidth = 3;

  /// Horizontal gap between adjacent Event lanes (PMG target ~2 dp).
  static const double eventLaneGap = 2;
  // Backup Events use the same fixed accent width as normal Events. The
  // striped painter is clipped to this exact strip before it can paint any
  // diagonal segment outside its local bounds.
  static const double backupEventAccentWidth = eventAccentWidth;
  static const Color backupStripeDark = Color(0xFF1B1C1D);
  static const double backupStripeSpacing = 5;
  static const double backupStripeWidth = 2.2;
  static const double contentHorizontalPadding = 8;
  // Delta 3: the repeat icon is a small 12-14 dp top-right affordance, not
  // a dominant badge — 'Meetin… ↻' before the icon disappears.
  static const double recurrenceRightInset = 8;
  static const double recurrenceIconSize = 14;
  static const double recurringContentRightPadding =
      recurrenceRightInset + recurrenceIconSize + 4;

  static double titleFontSize(Density density) {
    return switch (density) {
      Density.veryShort ||
      Density.short ||
      Density.medium ||
      Density.tall => 14,
    };
  }

  static double timeFontSize(Density density) {
    return switch (density) {
      Density.veryShort ||
      Density.short ||
      Density.medium ||
      Density.tall => 13,
    };
  }

  static double recurrenceIconSizeFor(Density density) {
    return density == Density.veryShort ? 12 : recurrenceIconSize;
  }

  /// Approximate line height for title text at the block's font size.
  static const double titleLineHeight = 18;

  /// Approximate line height for the time text.
  static const double timeLineHeight = 14;

  /// Approximate vertical spacing between title and time rows.
  static const double rowGap = 4;

  /// Inner vertical padding (top + bottom) reserved inside the block.
  static const double verticalPadding = 11;

  /// Threshold for the [Density.veryShort] regime.
  static const double veryShortThreshold = 24;

  /// Threshold for the [Density.short] regime.
  static const double shortThreshold = 44;

  /// Threshold for the [Density.medium] regime.
  static const double mediumThreshold = 70;

  /// The shortest factual sub-hour detail footprint is 15 px at 60 px/hour.
  /// Between 15 and 24 px the shared Event/Task primitives scale their compact
  /// metrics from the same live geometry instead of flipping at a density
  /// threshold while the zoom-display law is transitioning.
  static const double minimumContinuousContentHeight = 15;

  static double compactContentProgress(double height) =>
      ((height - minimumContinuousContentHeight) /
              (veryShortThreshold - minimumContinuousContentHeight))
          .clamp(0.0, 1.0)
          .toDouble();

  static double titleLineHeightForHeight(double height) =>
      1.0 + 0.1 * compactContentProgress(height);

  static double verticalPaddingForHeight(double height) =>
      4.0 * compactContentProgress(height);

  static double statusBadgeDiameterForHeight(double height) =>
      11.0 + 4.0 * compactContentProgress(height);

  static double recurrenceIconSizeForHeight(double height) =>
      12.0 + 2.0 * compactContentProgress(height);

  static double recurrenceTopForHeight(double height) =>
      1.0 + 2.0 * compactContentProgress(height);

  /// Classify the visible density for a given block height in pixels.
  static Density classify(double height) {
    if (height <= veryShortThreshold) {
      return Density.veryShort;
    }
    if (height <= shortThreshold) {
      return Density.short;
    }
    if (height <= mediumThreshold) {
      return Density.medium;
    }
    return Density.tall;
  }

  /// Maximum number of title text lines the policy exposes at [density].
  static int titleMaxLines(Density density) {
    return switch (density) {
      Density.veryShort => 1,
      Density.short => 1,
      Density.medium => 1,
      Density.tall => 2,
    };
  }

  /// Whether the time row should render at [density].
  ///
  /// The `short` regime keeps the time in the inline title (see
  /// [showTimeInline]) rather than as a separate row, because the
  /// remaining height after title + padding would not reliably
  /// accommodate the time row without exceeding the available block
  /// height (which would surface as a 1-pixel RenderFlex overflow on
  /// ~32 px blocks, e.g. after a minimum-duration resize).
  static bool showTime(Density density) {
    return switch (density) {
      Density.veryShort => false,
      Density.short => false,
      Density.medium => true,
      Density.tall => true,
    };
  }

  /// Whether the time range should be inlined into the title text
  /// for blocks that are too short to host a second text line.
  ///
  /// Owner-correction: short Events (15- and 30-minute) must still
  /// show useful schedule information. The block renders the title
  /// and the time range together on a single line, separated by a
  /// thin gap, with ellipsis applied to the combined text. This
  /// prevents the RenderFlex overflow that would occur if we tried
  /// to host a separate time row inside these compact blocks.
  static bool showTimeInline(Density density) {
    return density == Density.veryShort || density == Density.short;
  }

  /// Whether the compact status icon row should render at [density].
  static bool showStatusIcons(Density density) {
    return switch (density) {
      Density.veryShort => false,
      Density.short => false,
      Density.medium => true,
      Density.tall => true,
    };
  }

  /// Whether the resize handle should render at [density].
  static bool showResizeHandle(Density density, bool interactive) {
    // Resize remains discoverable through the invisible edge hit zones below;
    // the approved timeline surface does not render a visible grip.
    return false;
  }

  /// Effective corner radius for a card of [height] display pixels.
  ///
  /// `min(3 dp, height / 4)` prevents pill shapes: very short overview cards
  /// round only as far as their own height allows, and the radius NEVER
  /// scales upward when zooming out (Part 7 lock).
  static double effectiveRadiusFor(double height) {
    final radius = height / 4;
    return radius < eventBorderRadius ? radius : eventBorderRadius;
  }

  /// Minimum height that still admits a meaningful resize affordance.
  static const double minimumInteractiveHeight = 40;

  /// Height of the invisible resize hit area at the bottom of every
  /// interactive Event block. Clamped to the available height so very
  /// short blocks never expose a hit area larger than the block itself.
  ///
  /// Sized to the approved 10–12 logical-pixel edge zone so the surrounding
  /// Event body remains the primary tap and long-press move target.
  static const double resizeHitAreaHeight = 12;

  /// A compact top-edge target that leaves the Event body available for its
  /// existing tap and long-press move behavior.
  static const double topResizeHitAreaHeight = 12;

  /// Top and bottom targets remain distinct once a block is tall enough to
  /// expose both edges without making short blocks gesture-ambiguous.
  static const double topResizeMinimumHeight = 76;
}

/// Applies the approved diagonal backup treatment without changing the
/// Event Type surface or accent. The dark stripe is deliberately near-black,
/// while the adjacent stripe uses the original Event Type accent.
final class PlannerBackupStripeBackground extends StatelessWidget {
  const PlannerBackupStripeBackground({
    required this.accent,
    required this.surfaceColor,
    required this.child,
    this.accentKey,
    this.surfaceKey,
    super.key,
  });

  final Color accent;
  final Color surfaceColor;
  final Widget child;
  final Key? accentKey;
  final Key? surfaceKey;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        PlannerEventBlockLayoutPolicy.eventBorderRadius,
      ),
      child: ColoredBox(
        color: surfaceColor,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              key: accentKey,
              width: PlannerEventBlockLayoutPolicy.backupEventAccentWidth,
              child: ClipRect(
                clipBehavior: Clip.hardEdge,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _PlannerBackupStripePainter(accent: accent),
                  ),
                ),
              ),
            ),
            Expanded(
              child: SizedBox.expand(key: surfaceKey, child: child),
            ),
          ],
        ),
      ),
    );
  }
}

final class _PlannerBackupStripePainter extends CustomPainter {
  const _PlannerBackupStripePainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final extent = size.width + size.height;
    final darkPaint = Paint()
      ..color = PlannerEventBlockLayoutPolicy.backupStripeDark
      ..strokeWidth = PlannerEventBlockLayoutPolicy.backupStripeWidth
      ..style = PaintingStyle.stroke;
    final accentPaint = Paint()
      ..color = accent
      ..strokeWidth = PlannerEventBlockLayoutPolicy.backupStripeWidth
      ..style = PaintingStyle.stroke;
    for (
      var offset = -size.height;
      offset <= extent;
      offset += PlannerEventBlockLayoutPolicy.backupStripeSpacing
    ) {
      canvas.drawLine(
        Offset(offset, size.height),
        Offset(offset + size.height, 0),
        darkPaint,
      );
      canvas.drawLine(
        Offset(
          offset + PlannerEventBlockLayoutPolicy.backupStripeWidth + 1,
          size.height,
        ),
        Offset(
          offset +
              size.height +
              PlannerEventBlockLayoutPolicy.backupStripeWidth +
              1,
          0,
        ),
        accentPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PlannerBackupStripePainter oldDelegate) =>
      oldDelegate.accent != accent;
}

enum Density { veryShort, short, medium, tall }

/// Color policy for the fully-opaque Calendar Event block surface.
///
/// The Planner Day view must fully cover the timeline grid lines
/// beneath the Event. We derive an opaque surface color from the
/// Event Type's base color using the HSL color space so the
/// resulting block stays legible against the dark background
/// regardless of which base color the user picked.
///
/// The policy intentionally avoids low-alpha backgrounds. Backup
/// Backup Events receive their approved grayscale surface and neutral
/// leading strip, and Unreported still receives its approved
/// indicator — those status overlays do not reduce the opacity of
/// the block body itself.
abstract final class PlannerEventBlockColorPolicy {
  /// Resolves the automatic block surface for an accent: an exact
  /// Recommended Color accent uses its locked dark partner; every other
  /// accent uses the generic light-muted derivation.  Shared by the
  /// no-preference render fallback, the accent-change pipeline, and the
  /// repository repair so the same accent always produces the same surface.
  static int _automaticSurfaceArgb(int accentArgb) {
    return recommendedSurfaceArgbForAccent(accentArgb) ??
        EventColorMath.lightMutedSurfaceArgb(accentArgb);
  }

  /// Returns the fully-opaque surface color derived from [base].
  ///
  /// Light-muted bases (the approved palette) keep their hue family with only
  /// a restrained ~10% lightness reduction (the 8-12% perceptual darkening
  /// band from Part 14) so the block never turns dark or muddy.  Dark custom
  /// bases are lifted toward a readable light-muted surface, keeping the
  /// legacy behavior for non-light accents.  A base that is an exact
  /// Recommended Color accent resolves its locked dark partner instead (the
  /// dark-surface correction), so the no-preference fallback matches the
  /// saved-preference path exactly.
  static Color surfaceColor(Color base) {
    // Every exact canonical recommendation must use the same automatic dark
    // surface as its save path. Some of the newly approved muted colors have
    // a lower HSL lightness than the original fifteen; letting those fall
    // through the legacy lift branch would make an unsaved/no-preference
    // Event render differently from the exact same saved Event.
    if (RecommendedEventColorPalette.byArgb(base.toARGB32()) != null) {
      return Color(_automaticSurfaceArgb(base.toARGB32()));
    }
    final hsl = HSLColor.fromColor(base);
    if (hsl.lightness >= 0.45) {
      return Color(_automaticSurfaceArgb(base.toARGB32()));
    }
    final lightness = (hsl.lightness * 0.6 + 0.32).clamp(0.0, 0.85);
    final saturation = (hsl.saturation * 0.85 + 0.1).clamp(0.0, 1.0);
    return hsl.withLightness(lightness).withSaturation(saturation).toColor();
  }

  /// Returns the restrained block surface derived from a canonical Event
  /// Type accent color.
  ///
  /// The Planner Correction Pack locks the color pipeline so the block
  /// surface always follows the current canonical Event Type color: when a
  /// user changes an accent (recommended swatch or custom hex), the saved
  /// surface is derived from that same accent so no stale old-color surface
  /// can linger.  The derivation keeps the accent hue and applies only the
  /// approved 8-12% perceptual darkening — it never blends toward
  /// near-black, never applies the old 40-60% dark blend, and never turns a
  /// light-muted color into a dark muddy card (Part 14 lock).  An exact
  /// Recommended Color accent resolves its locked dark partner instead of
  /// the generic light-muted derivation (dark-surface correction).
  static Color mutedSurfaceFromAccent(Color accent) {
    return Color(_automaticSurfaceArgb(accent.toARGB32()));
  }

  /// Resolves the persisted block surface for an accent change.
  ///
  /// The surface follows the canonical accent whenever the accent actually
  /// changes (so a stale old-color surface can never linger), but an
  /// unchanged accent keeps its existing curated surface untouched.  A
  /// changed accent that is an exact Recommended Color member resolves its
  /// locked dark partner; any other changed accent keeps the generic
  /// light-muted derivation.
  static int resolvedSurfaceArgb({
    required int accentArgb,
    required int currentAccentArgb,
    required int currentSurfaceArgb,
  }) {
    if (accentArgb == currentAccentArgb) {
      return currentSurfaceArgb;
    }
    return _automaticSurfaceArgb(accentArgb);
  }

  /// Returns the border color used to outline the block.
  static Color borderColor(Color base) {
    return base.withValues(alpha: 0.95);
  }

  /// Returns the Planner Event block text color.
  ///
  /// B2-CORRECTION: the rule is now brightness-aware.  DARK keeps the locked
  /// white-text rule byte-identical (title and time stay white/near-white on
  /// the approved dark PMG-style surface pairs).  LIGHT uses the Light
  /// onSurface so Event text stays readable (>= 4.5:1) on the pastel Light
  /// surfaces; if a custom surface ever lowers contrast, the surface (not
  /// the text) is the fix.
  static Color textColor(Color surface, Brightness brightness) {
    if (brightness == Brightness.light) {
      return const Color(0xFF1A1C1F);
    }
    return Colors.white;
  }

  /// WCAG-style contrast ratio for two opaque colors.
  static double contrastRatio(Color foreground, Color background) {
    final foregroundLuminance = foreground.computeLuminance();
    final backgroundLuminance = background.computeLuminance();
    final lighter = foregroundLuminance > backgroundLuminance
        ? foregroundLuminance
        : backgroundLuminance;
    final darker = foregroundLuminance > backgroundLuminance
        ? backgroundLuminance
        : foregroundLuminance;
    return (lighter + 0.05) / (darker + 0.05);
  }
}

/// Adaptive visible-content descriptor for a Calendar Event block.
///
/// The descriptor is computed once per layout pass from the available
/// pixel height. It decides what the block renders so that the
/// [Column] never overflows its parent.
final class PlannerEventBlockContent {
  const PlannerEventBlockContent({
    required this.density,
    required this.titleMaxLines,
    required this.showTitle,
    required this.showTime,
    required this.showTimeInline,
    this.showRecurrence = true,
    required this.showStatusIcons,
    required this.showResizeHandle,
    this.showTimeOnly = false,
    this.visibleHeight = double.infinity,
  });

  factory PlannerEventBlockContent.forHeight(
    double height, {
    required bool interactive,
    bool showTimeOnly = false,
  }) {
    final density = PlannerEventBlockLayoutPolicy.classify(height);
    return PlannerEventBlockContent(
      density: density,
      titleMaxLines: PlannerEventBlockLayoutPolicy.titleMaxLines(density),
      // Short-block identity stays visible down to the factual 15 px detail
      // endpoint. Typography and padding scale continuously above rather than
      // disappearing at 18 px during the shared 44->60 zoom transition.
      showTitle: height >=
          PlannerEventBlockLayoutPolicy.minimumContinuousContentHeight,
      // Keep short blocks in one stable inline title/time presentation until
      // a genuinely tall card has room for a separate row. This prevents the
      // 44 px short/medium density boundary from creating a second visual
      // snap while geometry itself changes continuously.
      showTime: height >= 70,
      showTimeInline: height >=
              PlannerEventBlockLayoutPolicy.minimumContinuousContentHeight &&
          height < 70,
      showRecurrence: height >=
          PlannerEventBlockLayoutPolicy.minimumContinuousContentHeight,
      // Report-required status badges remain independently visible. The
      // optional Backup/linked text row waits for tall geometry so it cannot
      // pop inside the sub-hour interpolation band.
      showStatusIcons: height >= 70,
      showResizeHandle: PlannerEventBlockLayoutPolicy.showResizeHandle(
        density,
        interactive,
      ),
      // Approved provisional draft (Delta 4.1 D4.1-04): the unsaved pink
      // block renders TIME ONLY — never the Event Type title — so it reads
      // as a pure provisional surface.  Saved Events keep their normal
      // title/time content.
      showTimeOnly: showTimeOnly,
      visibleHeight: height,
    );
  }

  final Density density;
  final int titleMaxLines;
  final bool showTitle;
  final bool showTime;
  final bool showTimeInline;
  final bool showRecurrence;
  final bool showStatusIcons;
  final bool showResizeHandle;

  /// Provisional-draft flag: the block shows only its time range.
  final bool showTimeOnly;

  /// Live painted height from the shared display geometry. Both Event and
  /// Task primitives consume it for continuous compact metrics.
  final double visibleHeight;

  /// Manual descriptors predate the live-height field. Preserve their
  /// density semantics while production layout always supplies the exact
  /// fractional display height through [forHeight].
  double get liveHeight {
    if (visibleHeight.isFinite) {
      return visibleHeight;
    }
    return switch (density) {
      Density.veryShort =>
        PlannerEventBlockLayoutPolicy.minimumContinuousContentHeight,
      Density.short => PlannerEventBlockLayoutPolicy.veryShortThreshold + 1,
      Density.medium => PlannerEventBlockLayoutPolicy.shortThreshold + 1,
      Density.tall => PlannerEventBlockLayoutPolicy.mediumThreshold + 1,
    };
  }
}
