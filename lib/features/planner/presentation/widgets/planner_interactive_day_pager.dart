// Planner interactive day pager (Stage B3-R1 Slice D3-A1).
//
// Three-day horizontal pager that lets the user page through
// yesterday, today, and tomorrow with a finger-following drag
// while preserving the Planner's single vertical ScrollController
// and the locked pinch coordinator from D2.
//
// Layout (single-offset model):
//
//   ClipRect
//     └── Stack (viewport-wide, height = timelineHeight)
//           └── Positioned (left: 0, width: viewportWidth * 3)
//                 └── Transform.translate(offset: (translationX, 0))
//                       └── Row (3 children, each viewportWidth wide)
//                             ├── previous-day page   (read-only preview)
//                             ├── current-day  page   (interactive)
//                             └── next-day     page   (read-only preview)
//
// The Row begins at horizontal position 0. At rest the
// Transform.translate is `translationX == -viewportWidth`, which
// puts the second Row child (the current-day page) in the
// visible viewport without ever straddling the centerline.
//
// During a left drag liveDragOffset is negative so the
// Transform translation becomes more negative than the rest
// value of `-viewportWidth`; the entire Row shifts leftward,
// the current-day column slides off the left edge of the
// ClipRect, and the next-day column enters from the right.
//
// During a right drag liveDragOffset is positive so the
// translation becomes less negative than the rest value; the
// Row shifts rightward, the current-day column slides off the
// right edge, and the previous-day column enters from the
// left.
//
// `liveDragOffset` is maintained as the live, finger-relative
// delta and stored as `0` at rest. The visible translation is
// always `-viewportWidth + liveDragOffset`, so the only
// interpretation any code path needs is:
//
//   - at rest: translationX = -viewportWidth
//   - left drag in progress: liveDragOffset is negative
//   - right drag in progress: liveDragOffset is positive
//   - left commit target: liveDragOffset = -viewportWidth
//   - right commit target: liveDragOffset = +viewportWidth
//
// After a successful commit and the parent's selectedDate
// rebuild the Row is reset to `liveDragOffset == 0`. Since the
// parent passes a different `currentPage` widget whose dates
// have already advanced, no second visible slide is needed.
//
// Adjacent pages are wrapped in `IgnorePointer` so their
// surfaces cannot open Event details, move or resize Events,
// or create empty-time Events. Only the centered current page
// owns the existing pinch recognizer; the D2 pinch coordinator
// remains authoritative regardless of which column the pointers
// land on.
//
// DayFlow is referenced only as an interaction concept (side-by-
// side pages, finger-following drag, settle one page on release,
// recenter on date change). No code, layout, or styling is
// copied from that source.

import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_display_geometry.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/planner/domain/planner_timeline_layout.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_content.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_layout_policy.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_color_resolver.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_shared_viewport.dart';

/// Minimum logical-pixel travel before a horizontal gesture
/// can be considered for page navigation. Phase 8 minimum.
const double kPlannerPagerMinDistance = 64;

/// Explicit named velocity contract: release velocity in
/// logical PIXELS PER SECOND at pointer-up that allows a
/// deliberately fast fling shorter than the distance threshold
/// to commit one day. The Phase 4 contract is unambiguous:
/// `0.7 logical pixels per millisecond` == `700 logical pixels
/// per second`. Tests reference the named constant directly so
/// future value changes cannot silently shift the contract.
const double kPlannerPagerCommitVelocityPixelsPerSecond = 700.0;

/// Internal storage unit for [commitVelocity] (logical pixels
/// per millisecond). Derived once from
/// [kPlannerPagerCommitVelocityPixelsPerSecond] for tight-loop
/// comparisons; the published contract remains pixels/second.
final double _commitVelocityPixelsPerMillisecond =
    kPlannerPagerCommitVelocityPixelsPerSecond / 1000.0;

/// Direction-lock distance (logical pixels) before the pager
/// claims the gesture for horizontal paging. While within
/// this distance of the start, the underlying vertical scroll
/// recognizer is still allowed to operate.
const double kPlannerPagerDirectionLockDistance = 10;

/// Horizontal-dominance ratio: once the gesture has moved
/// further than the direction-lock distance, the pager only
/// takes over when |dx| > |dy| * 1.60. The ratio matches the
/// Planner's vertical-scroll cancellation threshold so a
/// diagonal one-finger drag cannot both page and move the
/// timeline.
const double kPlannerPagerHorizontalDominanceRatio = 1.60;

/// Fraction of viewport width whose release past the threshold
/// is sufficient to commit one day. Phase 8 default.
const double kPlannerPagerDistanceFraction = 0.22;

/// Absolute floor for the distance threshold in logical pixels.
/// Phase 8 minimum.
const double kPlannerPagerAbsoluteMinDistance = 72.0;

/// Settle animation duration, per Phase 9.
const Duration kPlannerPagerSettleDuration = Duration(milliseconds: 240);

/// R7-04: settle duration for a cross-date drag advance. A short horizontal
/// transition of the Planner date/page layer runs UNDER the finger-held
/// ghost (which lives in the screen-level drag overlay and is excluded from
/// the page transform). Kept within the approved 160-220 ms band and the
/// existing easeOutCubic motion discipline.
const Duration kPlannerCrossDateSettleDuration = Duration(milliseconds: 200);

/// Narrow command surface that the parent Planner screen uses to
/// invoke the pager from outside its widget tree.
///
/// The controller replaces the previous unsafe
/// `GlobalKey<State> _pagerKey` design. The pager's own
/// [State] class is library-private
/// (`_PlannerInteractiveDayPagerState`); the controller exposes
/// only a single recenter command so the parent does not need
/// any type from the private State, dynamic invocation, or a
/// `BuildContext` lookup. Attach happens automatically via
/// [PlannerInteractiveDayPager] when it mounts; the pager
/// detaches itself when it disposes.
///
/// The controller is intentionally not a [ChangeNotifier] —
/// it is a plain mutable object that the parent reads/writes
/// synchronously. The pager's animation and rebuild lifecycle
/// remain driven by the pager's own animation controller, so
/// no external listener bookkeeping is required.
class PlannerInteractiveDayPagerController {
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  /// Normalized live pager progress shared with the Planner date strip.
  ///
  /// `0` is the centered current page, `-1` fully exposes the next page, and
  /// `+1` fully exposes the previous page. The pager owns writes; consumers
  /// such as the date strip only listen and transform from this value.
  ValueListenable<double> get progress => _progress;

  void _setProgress(double value) {
    _progress.value = value.clamp(-1.0, 1.0).toDouble();
  }

  /// Test-only: pin the normalized pager progress directly, bypassing the
  /// gesture arena, so widget tests can capture deterministic partial
  /// page-offset frames (MP-04 screen-space preview accent). Mirrors the
  /// existing `liveDragOffsetForTest` hook; not part of the public
  /// production contract.
  void setProgressForTest(double value) {
    _setProgress(value);
  }

  /// The most recently attached recenter callback. The pager
  /// holds a private implementation in
  /// [_PlannerInteractiveDayPagerState]; the controller does
  /// not know about the State type.
  VoidCallback? _recenter;

  /// R7-04: the most recently attached cross-date commit callback. The pager
  /// holds a private implementation in
  /// [_PlannerInteractiveDayPagerState]; the controller does not know about
  /// the State type.
  Future<void> Function(int delta)? _commitDayChange;

  /// R7-04: advance the Planner page layer by [delta] days through the
  /// pager's commit path (animate the strip under the ghost, await the
  /// authoritative day load, then recenter). Returns `null` when the pager
  /// has not been attached yet so the caller can fall back to a direct
  /// navigation.
  Future<void>? commitDayChange(int delta) {
    final commit = _commitDayChange;
    if (commit == null) {
      return null;
    }
    return commit(delta);
  }

  /// The pager's [recenterFromExternalCancel] entry point.
  ///
  /// The parent registers this method with the
  /// `_DaySwipeCoordinator` cancel listener so a competing
  /// recognizer (long-press move, vertical drag, pinch scale)
  /// can drop a pending pager gesture and animate back to the
  /// centered resting position.
  ///
  /// The method is a no-op when:
  ///   * the pager has not been attached yet (first build has
  ///     not happened);
  ///   * the pager has been disposed (the attached reference
  ///     is cleared on disposal).
  void recenterFromExternalCancel() {
    _recenter?.call();
  }

  /// Wire the controller's recenter + cross-date commit callbacks. Called
  /// from the pager's [State.initState] and [State.didUpdateWidget] when
  /// the same controller instance is provided; called from [State.dispose]
  /// when the widget is torn down. The controller does not own any timers
  /// or listeners, so there is nothing to release in [dispose].
  void _attach(
    VoidCallback callback, {
    Future<void> Function(int delta)? commitDayChange,
  }) {
    _recenter = callback;
    _commitDayChange = commitDayChange;
  }

  /// Drop the recenter + commit callbacks. Called from [State.dispose].
  /// Subsequent calls to [recenterFromExternalCancel] / [commitDayChange]
  /// are silent no-ops until a new pager attaches.
  void _detach(VoidCallback callback) {
    if (identical(_recenter, callback)) {
      _recenter = null;
      _commitDayChange = null;
    }
  }

  /// Release the notifier owned by this controller. The Planner screen owns
  /// the controller for the route lifetime; standalone pager tests may also
  /// call this when they create a controller explicitly.
  void dispose() {
    _recenter = null;
    _commitDayChange = null;
    _progress.dispose();
  }
}

/// Shared R5-05 horizontal geometry for the centered timeline and read-only
/// pager previews. The dot center is the fixed 56 dp time-gutter / Event-
/// canvas boundary; label width can never move it.
abstract final class PlannerCurrentTimeHorizontalGeometry {
  static const double indicatorHeight = 12;
  static const double timeColumnWidth = 56;
  static const double dotSize = 10;
  static const double labelToDotGap = 2;
  static const double dotToLineGap = 6;
  static const double dotCenterX = timeColumnWidth;
  static const double dotLeft = dotCenterX - dotSize / 2;
  static const double labelRight = dotLeft - labelToDotGap;
  static const double lineLeft = dotLeft + dotSize + dotToLineGap;

  // ----------------------------------------------------------- CT-01
  // Compact capsule + attached circular anchor + thin line-from-anchor
  // structure.  The anchor circle stays centered on the timeline boundary
  // (timeColumnWidth); the capsule's right edge is TANGENT to the anchor's
  // left edge (no gap, no overlap), and the thin line begins at the anchor's
  // right edge and continues across the Event canvas.
  static const double anchorCenterX = timeColumnWidth;
  static const double anchorSize = dotSize;
  static const double anchorLeft = anchorCenterX - anchorSize / 2;
  static const double anchorRight = anchorLeft + anchorSize;
  static const double capsuleRight = anchorLeft;
  // CT-03: dedicated label-area width.  The label area widens LEFTWARD
  // (labelLeft = anchorLeft - labelWidth) so its right edge stays tangent to
  // the unchanged anchor boundary while longer 12h labels render larger.
  static const double labelWidth = 62;
  static const double labelLeft = anchorLeft - labelWidth;
  static const double lineStartX = anchorRight;

  /// Capsule vertical extent; the fully-rounded radius is half of this.
  static const double capsuleHeight = 18;
  static const double capsuleRadius = capsuleHeight / 2;
}

const double kPlannerPagerCurrentTimeIndicatorHeight =
    PlannerCurrentTimeHorizontalGeometry.indicatorHeight;
const double kPlannerPagerCurrentTimeDotSize =
    PlannerCurrentTimeHorizontalGeometry.dotSize;
const double kPlannerPagerCurrentTimeDotToLineGap =
    PlannerCurrentTimeHorizontalGeometry.dotToLineGap;
const double kPlannerPagerTimeColumnWidth =
    PlannerCurrentTimeHorizontalGeometry.timeColumnWidth;
const double kPlannerPagerCurrentTimeLabelToDotGap =
    PlannerCurrentTimeHorizontalGeometry.labelToDotGap;

/// Horizontal rectangle math for a read-only preview Event block.
///
/// Preview-center parity contract (Event Layout Forensic Audit, verdict R9):
/// the preview must paint the EXACT same rectangle as the centered timeline
/// for the same canonical placement, viewport width, and time gutter, so a
/// date that slides in as a preview never shifts/widens when it becomes
/// centered. This is the single shared pure helper the preview renderer
/// calls, which keeps the parity regression test on the REAL production path
/// instead of a private inline copy.
final class PlannerPagerEventHorizontalGeometry {
  static ({double left, double width}) resolve({
    required PlannerDisplayPlacement placement,
    required double width,
    required double timeColumnWidth,
    required double laneGap,
  }) {
    // Parity correction: the preview must use the SAME content basis as the
    // centered timeline (width - time gutter) with no preview-only inset.
    final contentWidth = width - timeColumnWidth;
    final columnGap = placement.columnCount > 1 ? laneGap : 0.0;
    final splitWidth = placement.widthFactor != null;
    final spanWidth = placement.spanCount != null;
    final widthBasis = splitWidth && !spanWidth
        ? contentWidth - columnGap
        : contentWidth - columnGap * (placement.columnCount - 1);
    final baseColumnWidth = widthBasis / placement.columnCount;
    final blockWidth = spanWidth
        ? baseColumnWidth * placement.spanCount! +
              columnGap * (placement.spanCount! - 1)
        : splitWidth
        ? widthBasis * placement.widthFactor!
        : baseColumnWidth;
    final left = spanWidth
        ? timeColumnWidth + placement.spanStart! * (baseColumnWidth + columnGap)
        : splitWidth
        ? timeColumnWidth +
              (widthBasis * placement.offsetFactor!) +
              (placement.column > 0 ? columnGap : 0)
        : timeColumnWidth + placement.column * (blockWidth + columnGap);
    return (left: left, width: blockWidth);
  }
}

/// How far the final hour label (12 AM at a midnight end) sits above its
/// line. The micro label is 18 dp tall, so 20 dp keeps the whole label
/// inside the preview while the pager clip never cuts its descenders.

/// Format a `DateTime` to the 12-hour AM/PM string the
/// centered column's current-time label uses. Replicated
/// inline because the same formatter is private to the
/// planner screen module; the formatted text is the only
/// fact that crosses the module boundary.
String _formatCurrentTimeLabel(DateTime now) {
  final hour24 = now.hour;
  final minute = now.minute;
  final displayHour = hour24 == 0
      ? 12
      : hour24 > 12
      ? hour24 - 12
      : hour24;
  final period = hour24 >= 12 ? 'PM' : 'AM';
  return '$displayHour:${minute.toString().padLeft(2, '0')} $period';
}

String _hourLabel(int hour24, bool use24HourTime) {
  if (use24HourTime) {
    return '${hour24.toString().padLeft(2, '0')}:00';
  }
  final normalized = hour24 % 24;
  final hour = normalized == 0
      ? 12
      : normalized > 12
      ? normalized - 12
      : normalized;
  return '$hour ${normalized >= 12 ? 'PM' : 'AM'}';
}

/// Active session of a horizontal page gesture.
class _PageDragSession {
  _PageDragSession({required this.startPosition, required this.startTime});

  final Offset startPosition;
  final Duration startTime;

  /// True once the pager has accepted ownership of the gesture
  /// (direction locked + horizontal dominance). Before true,
  /// the parent recognizer (vertical scroll, pinch, long-press,
  /// resize) keeps operating and the pager does not paint a
  /// translated transform.
  bool horizontalIntentLocked = false;

  /// Latest accumulated dx in logical pixels. Drives the
  /// live Transform.translate (via
  /// `-viewportWidth + sessionDx`).
  double sessionDx = 0;
}

/// Optional plug-points so the parent can wire the pager into
/// the existing `_DaySwipeCoordinator` and `_PinchCoordinator`
/// without exporting the underlying types. Each callback is
/// invoked once per relevant pointer event; the parent decides
/// how to forward to its private coordinators.
typedef SwipeCoordinatorOnDown = void Function();
typedef SwipeCoordinatorOnUp = void Function();
typedef SwipeCoordinatorCancel = void Function();
typedef SwipeCoordinatorIsCancelled = bool Function();

bool _pagerSwipeNeverCancelled() => false;

/// Reports the active pointer count after the parent's pinch
/// coordinator has been updated. Values `>= 2` indicate pinch
/// authority. Returning the count (rather than a one-shot
/// transition flag) lets the pager detect simultaneous and
/// racing pointer-down events without depending on whether
/// the parent's Listener ran before or after this widget's
/// Listener.
typedef PinchCoordinatorOnCount = int Function();
typedef PinchCoordinatorClearCancel = void Function();

/// State for the pager. Owns the settle animation and the
/// per-gesture drag session. Library-private: only the
/// [PlannerInteractiveDayPager] widget and its in-file
/// controller can reference this type. External callers
/// communicate with the pager through
/// [PlannerInteractiveDayPagerController.recenterFromExternalCancel].
class _PlannerInteractiveDayPagerState extends State<PlannerInteractiveDayPager>
    with SingleTickerProviderStateMixin {
  _PageDragSession? _dragSession;

  /// The settle animation. Created eagerly in [initState] so
  /// [dispose] is the sole owner of its lifetime; the previous
  /// `late final` initializer would lazily construct the
  /// controller the first time `_settle` was touched, and that
  /// could land during teardown when [vsync] access through
  /// the deactivated element tree is unsafe.
  AnimationController? _settle;

  /// Pixel view of the controller's normalized progress. The controller is
  /// the single authoritative value; this getter only converts it to the
  /// current viewport's logical pixels for the existing settlement math and
  /// compatibility accessors.
  double get _liveDragOffset =>
      widget.controller.progress.value * widget.viewportWidth;

  void _setLiveDragOffset(double value) {
    if (widget.viewportWidth <= 0) {
      widget.controller._setProgress(0);
      return;
    }
    widget.controller._setProgress(value / widget.viewportWidth);
  }

  /// True while the settle animation is running. During this
  /// window a fresh pointer-down is buffered (S1B-07) rather than
  /// silently dropped, so a deliberate rapid swipe is never lost.
  bool _settling = false;

  /// S1B-07: the deliberate horizontal gesture that began while a settle
  /// animation was still running. Its pointer-down is not rejected; instead
  /// the session is buffered here, its moves accumulate `sessionDx`, and at
  /// the end of the current commit's handoff the buffered gesture either
  /// chains a follow-up commit (if it was released with a valid swipe) or
  /// takes over as a live drag session (if the finger is still down).
  /// One date step per committed swipe is preserved because each buffered
  /// gesture resolves to exactly one [_animateCommit] delta.
  _PageDragSession? _pendingDragSession;

  /// S1B-07: commit directions awaiting settle handoffs, FIFO. Each entry is
  /// pushed when a buffered gesture is released with a valid swipe while a
  /// settle is still running, and one is popped per [_animateCommit] end, so
  /// rapid swipes that land inside a single settle window chain one day step
  /// EACH in input order (Law 14) instead of overwriting each other.
  final List<int> _pendingCommitDirections = <int>[];

  /// Live drag-offset accessor for tests. Not part of the
  /// public production contract.
  double get liveDragOffsetForTest =>
      widget.controller.progress.value * widget.viewportWidth;

  /// External cancel entry point. The parent registers this
  /// with the shared `_DaySwipeCoordinator`'s cancel-listener
  /// so a competing recognizer (long-press, vertical drag,
  /// pinch scale) can drop a pending pager gesture and
  /// animate back to center. No-op when no session is
  /// active or the pager is already centered. Safe to call
  /// after [dispose] because it short-circuits on `!mounted`.
  void recenterFromExternalCancel() {
    if (!mounted) {
      return;
    }
    _dragSession = null;
    if (_settling) {
      // S1B-07: a competing recognizer won the gesture; drop any buffered
      // rapid-swipe candidate so it cannot chain after the settle.
      _pendingDragSession = null;
      _pendingCommitDirections.clear();
      return;
    }
    if (_liveDragOffset.abs() < 0.5) {
      if (_liveDragOffset != 0) {
        setState(() {
          _setLiveDragOffset(0);
        });
      }
      return;
    }
    unawaited(_animateRecenter());
  }

  @override
  void initState() {
    super.initState();
    widget.controller._setProgress(0);
    _settle = AnimationController(
      vsync: this,
      duration: kPlannerPagerSettleDuration,
    );
    widget.controller._attach(
      recenterFromExternalCancel,
      commitDayChange: _commitDayChange,
    );
    widget.onPinchClearCancel();
  }

  @override
  void didUpdateWidget(covariant PlannerInteractiveDayPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller._detach(recenterFromExternalCancel);
      widget.controller._attach(
        recenterFromExternalCancel,
        commitDayChange: _commitDayChange,
      );
    }
    if (oldWidget.viewportWidth != widget.viewportWidth) {
      // Keep the transform aligned to the visible window when
      // the layout changes (rotation, resize). The pager only
      // needs to ensure the centered column stays centered.
      if (!_settling && _dragSession == null) {
        _setLiveDragOffset(0);
      }
    }
    if (oldWidget.selectedDate != widget.selectedDate) {
      // Parent has rebuilt with the new date — reset the
      // transform so the (now-different) currentPage is
      // recentered without a second visible slide.
      //
      // Delta 4.2R2 R2-09: even a live drag session is dropped on an
      // authoritative date change (e.g. Go-to-Today tapped mid-swipe) so
      // the pager snaps to the centered resting position immediately
      // instead of keeping a stale horizontal offset that would make the
      // jump feel delayed. Normal swipe commits publish the new date only
      // after their own settle animation, so this path does not disturb
      // ordinary day navigation.
      if (!_settling) {
        _dragSession = null;
        _setLiveDragOffset(0);
      }
    }
  }

  @override
  void dispose() {
    widget.controller._detach(recenterFromExternalCancel);
    _settle?.dispose();
    _settle = null;
    super.dispose();
  }

  double _commitDistanceThreshold(double viewportWidth) {
    final fraction = viewportWidth * kPlannerPagerDistanceFraction;
    return fraction > kPlannerPagerAbsoluteMinDistance
        ? fraction
        : kPlannerPagerAbsoluteMinDistance;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_settling) {
      // S1B-07: a deliberate new swipe landed inside the settle window.
      // Buffer it instead of dropping it. A pinch or an externally cancelled
      // gesture must still win, exactly like the non-settling path.
      if (widget.onPinchPointerCount() >= 2 || widget.isSwipeCancelled()) {
        _pendingDragSession = null;
        _pendingCommitDirections.clear();
        return;
      }
      _pendingDragSession = _PageDragSession(
        startPosition: event.position,
        startTime: event.timeStamp,
      );
      return;
    }
    widget.onSwipePointerDown();
    if (widget.isSwipeCancelled()) {
      _dragSession = null;
      return;
    }
    final pinchCount = widget.onPinchPointerCount();
    if (pinchCount >= 2) {
      // Pinch owns the gesture. Drop any in-progress drag
      // session and stay centered. The parent observer will
      // rebuild the SingleChildScrollView physics through its
      // own pinch listener.
      _dragSession = null;
      if (_liveDragOffset != 0) {
        unawaited(_animateRecenter());
      }
      return;
    }
    _dragSession = _PageDragSession(
      startPosition: event.position,
      startTime: event.timeStamp,
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    final pending = _pendingDragSession;
    if (pending != null && _settling) {
      // S1B-07: track the buffered gesture's travel so the chain decision at
      // the end of the settle is based on real input, not a blind commit.
      if (widget.isSwipeCancelled() || widget.onPinchPointerCount() >= 2) {
        _pendingDragSession = null;
        _pendingCommitDirections.clear();
        return;
      }
      final dx = event.position.dx - pending.startPosition.dx;
      final dy = event.position.dy - pending.startPosition.dy;
      if (!pending.horizontalIntentLocked) {
        if (dx.abs() >= kPlannerPagerDirectionLockDistance &&
            dx.abs() > dy.abs() * kPlannerPagerHorizontalDominanceRatio) {
          pending.horizontalIntentLocked = true;
        }
      }
      if (pending.horizontalIntentLocked) {
        pending.sessionDx = dx.clamp(
          -widget.viewportWidth,
          widget.viewportWidth,
        );
      }
      return;
    }
    final session = _dragSession;
    if (session == null) {
      return;
    }
    if (widget.isSwipeCancelled()) {
      _dragSession = null;
      if (_liveDragOffset != 0) {
        unawaited(_animateRecenter());
      }
      return;
    }
    // A second pointer may have arrived between the previous
    // move and this one. The pinch coordinator's listener
    // lives inside the centered current page, which is
    // deeper in the tree than the pager, so its pointer-down
    // can dispatch after the pager's on the same frame.
    // Re-checking the count here means a pinch that arrives
    // late still wins the gesture.
    if (widget.onPinchPointerCount() >= 2) {
      _dragSession = null;
      if (_liveDragOffset != 0) {
        unawaited(_animateRecenter());
      }
      return;
    }
    final dx = event.position.dx - session.startPosition.dx;
    final dy = event.position.dy - session.startPosition.dy;
    final dxAbs = dx.abs();
    final dyAbs = dy.abs();
    if (!session.horizontalIntentLocked) {
      if (dxAbs < kPlannerPagerDirectionLockDistance &&
          dyAbs < kPlannerPagerDirectionLockDistance) {
        return;
      }
      if (dxAbs <= dyAbs * kPlannerPagerHorizontalDominanceRatio) {
        // Vertical-dominant motion; the parent recognizer
        // (vertical scroll / pinch / long-press / resize) owns
        // the gesture. Drop the session and stay centered.
        _dragSession = null;
        return;
      }
      // Horizontal paging has won the arena for this gesture.
      // Cancel the shared swipe coordinator so the long-press
      // move / resize / pinch hooks cannot also claim the
      // pointer.
      widget.onSwipeCancel();
      session.horizontalIntentLocked = true;
    }
    final maxOffset = widget.viewportWidth;
    final clampedDx = dx.clamp(-maxOffset, maxOffset);
    session.sessionDx = clampedDx;
    setState(() {
      _setLiveDragOffset(clampedDx);
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    widget.onSwipePointerUp();
    widget.onPinchClearCancel();
    final pending = _pendingDragSession;
    if (pending != null && _settling) {
      // S1B-07: the buffered gesture was released while the settle was still
      // running. Decide its commit now and chain it when the current commit
      // completes its logical handoff.
      _pendingDragSession = null;
      if (pending.horizontalIntentLocked) {
        final dx = pending.sessionDx;
        final elapsedMicroseconds =
            (event.timeStamp - pending.startTime).inMicroseconds;
        final velocityX = elapsedMicroseconds == 0
            ? 0.0
            : (dx.abs() / (elapsedMicroseconds / 1000.0));
        final distanceThreshold = _commitDistanceThreshold(
          widget.viewportWidth,
        );
        final passesDistance =
            dx.abs() >= distanceThreshold &&
            dx.abs() >= kPlannerPagerMinDistance;
        final passesVelocity =
            velocityX >= _commitVelocityPixelsPerMillisecond && dx.abs() > 0;
        if ((passesDistance || passesVelocity) && dx != 0) {
          _pendingCommitDirections.add(dx < 0 ? 1 : -1);
        }
      }
      return;
    }
    final session = _dragSession;
    if (session == null) {
      return;
    }
    _dragSession = null;
    if (!session.horizontalIntentLocked) {
      setState(() {
        _setLiveDragOffset(0);
      });
      return;
    }
    final dx = session.sessionDx;
    final elapsedMicroseconds =
        (event.timeStamp - session.startTime).inMicroseconds;
    final velocityX = elapsedMicroseconds == 0
        ? 0.0
        : (dx.abs() / (elapsedMicroseconds / 1000.0));
    final distanceThreshold = _commitDistanceThreshold(widget.viewportWidth);
    final passesDistance =
        dx.abs() >= distanceThreshold && dx.abs() >= kPlannerPagerMinDistance;
    final passesVelocity =
        velocityX >= _commitVelocityPixelsPerMillisecond && dx.abs() > 0;
    if ((passesDistance || passesVelocity) && dx != 0) {
      unawaited(_animateCommit(dx < 0 ? 1 : -1));
      return;
    }
    unawaited(_animateRecenter());
  }

  void _onPointerCancel(PointerCancelEvent event) {
    widget.onSwipePointerUp();
    widget.onPinchClearCancel();
    _pendingDragSession = null;
    _pendingCommitDirections.clear();
    if (_dragSession == null) {
      return;
    }
    _dragSession = null;
    unawaited(_animateRecenter());
  }

  /// R7-04: advance the Planner page layer by [delta] through the same
  /// commit path as a settled swipe, but with the shorter cross-date
  /// transition duration. The ghost (rendered in the screen-level drag
  /// overlay) is excluded from this page transform and stays under the
  /// finger while the strip slides.
  Future<void> _commitDayChange(int delta) {
    return _animateCommit(
      delta,
      settleDuration: kPlannerCrossDateSettleDuration,
    );
  }

  Future<void> _animateCommit(int delta, {Duration? settleDuration}) async {
    assert(delta == 1 || delta == -1);
    // Target the resting translation for the destination page
    // before the parent rebuild swaps the previous/current/next
    // dates. With the spec's coordinate model
    // (`translationX = -viewportWidth + liveDragOffset`), the
    // resting translation for the next page centered is
    // `-2 * viewportWidth` so `liveDragOffset` must equal
    // `-viewportWidth` at the end of a left commit
    // (`delta == +1`). Symmetrically a right commit
    // (`delta == -1`) lands on `liveDragOffset == +viewportWidth`.
    final target = delta < 0 ? widget.viewportWidth : -widget.viewportWidth;
    final from = _liveDragOffset;
    _settling = true;
    final settle = _settle!;
    if (settleDuration != null) {
      settle.duration = settleDuration;
    }
    final tween = Tween<double>(begin: from, end: target);
    final curved = CurvedAnimation(parent: settle, curve: Curves.easeOutCubic);
    final animation = tween.animate(curved);
    void listener() {
      if (!mounted) {
        return;
      }
      setState(() {
        _setLiveDragOffset(animation.value);
      });
    }

    animation.addListener(listener);
    try {
      settle.reset();
      await settle.forward().orCancel;
    } on TickerCanceled {
      animation.removeListener(listener);
      _settling = false;
      _pendingDragSession = null;
      _pendingCommitDirections.clear();
      return;
    } catch (_) {
      animation.removeListener(listener);
      rethrow;
    }
    animation.removeListener(listener);
    if (!mounted) {
      return;
    }
    // Keep the destination page fully exposed until the parent has prepared
    // the authoritative page data. The parent publishes selectedDate only
    // after that read completes; this prevents a new page key from painting
    // the previous day's schedule while the pager recenters.
    final commit = widget.onDayChanged(delta);
    try {
      if (commit is Future<void>) {
        await commit;
      }
    } on Object {
      // A failed adjacent read leaves the current page authoritative. Return
      // the settled translation to center without preparing the date strip
      // or publishing a second callback.
      _pendingDragSession = null;
      _pendingCommitDirections.clear();
      if (mounted) {
        await _animateRecenter();
      }
      return;
    }
    if (!mounted) {
      return;
    }
    // The strip and pager now hand off in one event turn: adjust its cached
    // scroll offset, recenter normalized progress, and expose the committed
    // page together. There is no second catch-up animation.
    widget.onPagerCommitPrepared?.call(delta);
    setState(() {
      _setLiveDragOffset(0);
    });
    _settling = false;
    // S1B-07: the settle lock is now released. If a deliberate rapid swipe
    // landed during the settle, chain it (released) or hand it the live
    // drag ownership (finger still down). Each chained gesture resolves to
    // exactly one day step, so the input order is preserved.
    if (_pendingCommitDirections.isNotEmpty) {
      final chainedDirection = _pendingCommitDirections.removeAt(0);
      unawaited(_animateCommit(chainedDirection));
      return;
    }
    final buffered = _pendingDragSession;
    if (buffered != null) {
      _pendingDragSession = null;
      _dragSession = buffered;
      if (buffered.horizontalIntentLocked) {
        // Claim the paging gesture (no cancel-listener feedback) and let the
        // page follow the finger from wherever the settle left it.
        widget.onSwipeCancel();
        setState(() {
          _setLiveDragOffset(buffered.sessionDx);
        });
      }
    }
  }

  Future<void> _animateRecenter() async {
    final from = _liveDragOffset;
    if (from.abs() < 0.5) {
      setState(() {
        _setLiveDragOffset(0);
      });
      return;
    }
    _settling = true;
    final settle = _settle!;
    final tween = Tween<double>(begin: from, end: 0);
    final curved = CurvedAnimation(parent: settle, curve: Curves.easeOutCubic);
    final animation = tween.animate(curved);
    void listener() {
      if (!mounted) {
        return;
      }
      setState(() {
        _setLiveDragOffset(animation.value);
      });
    }

    animation.addListener(listener);
    try {
      settle.reset();
      await settle.forward().orCancel;
    } on TickerCanceled {
      animation.removeListener(listener);
      _settling = false;
      return;
    } catch (_) {
      animation.removeListener(listener);
      rethrow;
    }
    animation.removeListener(listener);
    _settling = false;
    if (!mounted) {
      return;
    }
    setState(() {
      _setLiveDragOffset(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final preservedCurrentPageDate = widget.preservedCurrentPageDate;
    final preservingCurrentPage =
        preservedCurrentPageDate != null &&
        preservedCurrentPageDate != widget.selectedDate;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportWidth = constraints.maxWidth;
          final translationX = -viewportWidth + _liveDragOffset;
          return SizedBox(
            width: viewportWidth,
            height: widget.timelineHeight,
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: <Widget>[
                  Positioned(
                    key: const Key('planner-day-pager-strip-host'),
                    left: 0,
                    top: 0,
                    width: viewportWidth * 3,
                    height: widget.timelineHeight,
                    child: Transform.translate(
                      offset: Offset(translationX, 0),
                      key: const Key('planner-day-pager-strip'),
                      child: Row(
                        children: <Widget>[
                          _PagerPreviewColumn(
                            key: Key(
                              preservingCurrentPage
                                  ? 'planner-drag-preview-previous-${widget.previousDate.iso8601}'
                                  : 'planner-day-page-${widget.previousDate.iso8601}',
                            ),
                            pageDate: widget.previousDate,
                            pageDay: widget.previousDay,
                            settings: widget.settings,
                            eventColorsByTypeId: widget.eventColorsByTypeId,
                            // S2A: the offscreen previews stay on the
                            // committed height while the pinch is live; only
                            // the centered page follows the live scale.
                            hourHeight:
                                widget.previewHourHeight ?? widget.hourHeight,
                            viewportHeight: widget.viewportHeight,
                            width: viewportWidth,
                            isToday: widget.today == widget.previousDate,
                            currentTimeListenable: widget.currentTimeListenable,
                          ),
                          KeyedSubtree(
                            key: Key(
                              'planner-day-page-${(preservedCurrentPageDate ?? widget.selectedDate).iso8601}',
                            ),
                            child: SizedBox(
                              width: viewportWidth,
                              height: widget.timelineHeight,
                              child: widget.currentPage,
                            ),
                          ),
                          _PagerPreviewColumn(
                            key: Key(
                              preservingCurrentPage
                                  ? 'planner-drag-preview-next-${widget.nextDate.iso8601}'
                                  : 'planner-day-page-${widget.nextDate.iso8601}',
                            ),
                            pageDate: widget.nextDate,
                            pageDay: widget.nextDay,
                            settings: widget.settings,
                            eventColorsByTypeId: widget.eventColorsByTypeId,
                            // S2A: see previous-column comment.
                            hourHeight:
                                widget.previewHourHeight ?? widget.hourHeight,
                            viewportHeight: widget.viewportHeight,
                            width: viewportWidth,
                            isToday: widget.today == widget.nextDate,
                            currentTimeListenable: widget.currentTimeListenable,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // MP-04 (owner evidence 2026-08-16): during a horizontal
                  // rightward pager transition the previous day's wide Event
                  // body becomes visible in the viewport BEFORE its true left
                  // edge — and its left accent strip — enters. This
                  // preview-only overlay paints the accent at the visible
                  // fragment boundary (the viewport's left edge) in the SAME
                  // frame, and disappears the moment the true accent becomes
                  // visible (no double accent, no accent pop on settle, no
                  // settled delta). Anchored to the pager's own Stack so the
                  // screen-space position is exact regardless of preview
                  // column coordinate conventions.
                  ..._previewFragmentAccentStrips(
                    context: context,
                    viewportWidth: viewportWidth,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// MP-04: preview-only fragment-accent overlay strips for the previous
  /// day's Events while a rightward drag reveals them from the left. Painted
  /// at the pager Stack's left edge (the viewport's left edge) — the exact
  /// screen-space fragment boundary — for every preview Event whose body is
  /// already visible but whose true left accent is still clipped offscreen.
  List<Widget> _previewFragmentAccentStrips({
    required BuildContext context,
    required double viewportWidth,
  }) {
    final liveDrag = _liveDragOffset;
    // Only a rightward partial reveal needs the fragment accent: the
    // incoming-from-left previous day's blocks enter with their left edges
    // (and accents) last. Leftward drags reveal the next day from the right,
    // whose true left accents enter first.
    if (liveDrag < kPlannerPagerMinDistance) {
      return const <Widget>[];
    }
    final pageDay = widget.previousDay;
    final settings = widget.settings;
    if (pageDay == null) {
      return const <Widget>[];
    }
    final events = pageDay.timedEvents
        .where(
          (event) =>
              event.startLocal != null &&
              event.endLocal != null &&
              (settings.showCancelledItems ||
                  event.state != PlannerEventState.cancelled),
        )
        .toList(growable: false);
    if (events.isEmpty) {
      return const <Widget>[];
    }
    final placements = PlannerDisplayGeometry.resolve(
      events: events,
      hourHeight: widget.previewHourHeight ?? widget.hourHeight,
      viewportHeight: widget.viewportHeight,
      configuredHours: settings.visibleEndHour - settings.visibleStartHour,
    );
    final accentWidth = PlannerEventBlockLayoutPolicy.eventAccentWidth;
    final strips = <Widget>[];
    for (final placement in placements) {
      final event = placement.event;
      final horizontal = PlannerPagerEventHorizontalGeometry.resolve(
        placement: placement,
        width: viewportWidth,
        timeColumnWidth: kPlannerPagerTimeColumnWidth,
        laneGap: PlannerEventBlockLayoutPolicy.eventLaneGap,
      );
      // The previous column sits at Row x 0, so the block's left edge in
      // viewport coordinates is the strip translation plus its column-local
      // left. The strip translation already includes the live drag offset.
      final blockLeftInViewport =
          -viewportWidth + liveDrag + horizontal.left;
      final blockRightInViewport = blockLeftInViewport + horizontal.width;
      // Fragment accent only when the body is visible but the true left
      // accent (the first `accentWidth` px of the block) is fully clipped.
      if (blockLeftInViewport < -accentWidth &&
          blockRightInViewport > accentWidth) {
        final resolvedAccent = PlannerEventColorResolver.accentColor(
          context,
          event,
          widget.eventColorsByTypeId,
        );
        final resolvedSurface = PlannerEventColorResolver.surfaceColor(
          context,
          event,
          widget.eventColorsByTypeId,
        );
        strips.add(
          Positioned(
            key: Key('planner-pager-fragment-accent-${event.id}'),
            left: 0,
            top: placement.top,
            width: accentWidth,
            height: placement.height,
            child: IgnorePointer(
              child: event.isBackupAppointment
                  ? PlannerBackupStripeBackground(
                      accent: resolvedAccent,
                      surfaceColor: resolvedSurface,
                      child: SizedBox(width: accentWidth),
                    )
                  : ColoredBox(color: resolvedAccent),
            ),
          ),
        );
      }
    }
    return strips;
  }
}

/// Public entry point. Sits inside the Planner's
/// SingleChildScrollView above the existing
/// `_TimedEventTimeline`.
class PlannerInteractiveDayPager extends StatefulWidget {
  PlannerInteractiveDayPager({
    super.key,
    required this.selectedDate,
    required this.previousDate,
    required this.nextDate,
    required this.previousDay,
    required this.currentDay,
    required this.nextDay,
    required this.today,
    required this.settings,
    this.eventColorsByTypeId = const <String, EventColorPreference>{},
    required this.hourHeight,
    // S2A: the committed hour height shown by the offscreen previous/next
    // preview columns. During an active pinch this stays frozen at the last
    // committed value (the centered page owns the live pinch height); it
    // advances to the final committed height once the pinch persists. When
    // null the previews follow the live [hourHeight] (default, keeps
    // non-pinch callers and tests unchanged).
    this.previewHourHeight,
    required this.timelineHeight,
    required this.viewportWidth,
    this.viewportHeight = 0,
    required this.onSwipePointerDown,
    required this.onSwipePointerUp,
    required this.onSwipeCancel,
    this.isSwipeCancelled = _pagerSwipeNeverCancelled,
    this.preservedCurrentPageDate,
    required this.onPinchPointerCount,
    required this.onPinchClearCancel,
    required this.onDayChanged,
    this.onPagerCommitPrepared,
    required this.currentPage,
    required this.currentTimeListenable,
    PlannerInteractiveDayPagerController? controller,
  }) : controller = controller ?? PlannerInteractiveDayPagerController();

  final PlannerDate selectedDate;
  final PlannerDate previousDate;
  final PlannerDate nextDate;
  final PlannerDate today;

  /// Read-only snapshots for the previous, current, and next
  /// days. Preview snapshots must not be written to Drift
  /// from this widget — Phase 14.
  final PlannerDay? previousDay;
  final PlannerDay? currentDay;
  final PlannerDay? nextDay;

  final PlannerSettings settings;
  final Map<String, EventColorPreference> eventColorsByTypeId;
  final double hourHeight;

  /// S2A committed preview height; see constructor docs.
  final double? previewHourHeight;

  final double timelineHeight;
  final double viewportWidth;

  /// The usable vertical viewport height of the day scroll view.  Shared by
  /// every page so the PMG overview visual floor (and its smooth zoom
  /// interpolation) is identical across the centered page and both preview
  /// pages during a swipe.
  final double viewportHeight;

  /// Authoritative current-time source shared with the
  /// centered timeline. The preview columns use this
  /// listenable to render the current-time indicator so the
  /// centered page and the preview pages read from the same
  /// instant — production keeps a minute-boundary Timer; the
  /// focused tests inject a deterministic
  /// [ValueListenable] to drive ownership, geometry, and
  /// midnight transition checks.
  final ValueListenable<DateTime> currentTimeListenable;

  /// External command surface. The parent may either pass its
  /// own controller instance (so a long-lived
  /// [PlannerInteractiveDayPagerController] can hold a stable
  /// reference to the live pager) or omit it (the pager
  /// creates an internal one for tests). The screen owns a
  /// single long-lived controller instance for the lifetime
  /// of the Planner route.
  final PlannerInteractiveDayPagerController controller;

  final SwipeCoordinatorOnDown onSwipePointerDown;
  final SwipeCoordinatorOnUp onSwipePointerUp;
  final SwipeCoordinatorCancel onSwipeCancel;
  final SwipeCoordinatorIsCancelled isSwipeCancelled;

  /// Keeps the interactive current-page subtree mounted while a selected
  /// Event crosses a date boundary with its pointer still down. Ordinary day
  /// paging leaves this null and retains the existing per-selected-date key.
  final PlannerDate? preservedCurrentPageDate;

  final PinchCoordinatorOnCount onPinchPointerCount;
  final PinchCoordinatorClearCancel onPinchClearCancel;

  /// Fired exactly once per successful commit, with `+1` for a
  /// left swipe (next day) and `-1` for a right swipe (previous
  /// day). The parent wires this to
  /// `PlannerController.moveDays(delta)`.
  final FutureOr<void> Function(int) onDayChanged;

  /// Called once after a successful settlement reaches its destination and
  /// before progress is reset. The date strip uses this one synchronous hook
  /// to advance its cached scroll offset by one cell; cancellation never calls
  /// it.
  final FutureOr<void> Function(int)? onPagerCommitPrepared;

  /// The interactive current page (typically the existing
  /// `_TimedEventTimeline` widget). Receives pointer events
  /// for normal vertical scrolling and pinch when the pager is
  /// at rest or vertically-dominant.
  final Widget currentPage;

  /// Build a viewport snapshot for tests and the surrounding
  /// state. Reads from the planner's existing facts only — no
  /// derived controllers, no Drift writes.
  PlannerSharedViewport captureViewport({
    required ScrollController scrollController,
  }) {
    return PlannerSharedViewport.from(
      hourHeight: hourHeight,
      scrollController: scrollController,
      settings: settings,
      viewportHeight: timelineHeight,
    );
  }

  @override
  State<PlannerInteractiveDayPager> createState() =>
      _PlannerInteractiveDayPagerState();
}

/// Read-only preview column used for the previous and next day
/// pages. Renders a static hour grid and a representation of
/// the day's Calendar Events using the same vertical layout as
/// the centered timeline, without any recognizers that could
/// open Event details or commit a mutation.
/// Date-aware empty timeline used while the selected day's canonical data is
/// reconciling.
///
/// R4-05/R4-08 deliberately keep this as presentation state: no empty
/// [PlannerDay] is fabricated and the previous date's model is never painted
/// beneath the new header. The ordinary hour grid and today's current-time
/// indicator still recenter immediately while the repository read completes.
class PlannerLoadingDayTimeline extends StatelessWidget {
  const PlannerLoadingDayTimeline({
    super.key,
    required this.selectedDate,
    required this.today,
    required this.settings,
    required this.hourHeight,
    required this.viewportHeight,
    required this.currentTimeListenable,
  });

  final PlannerDate selectedDate;
  final PlannerDate today;
  final PlannerSettings settings;
  final double hourHeight;
  final double viewportHeight;
  final ValueListenable<DateTime> currentTimeListenable;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return _PagerPreviewColumn(
          key: Key('planner-loading-day-${selectedDate.iso8601}'),
          pageDate: selectedDate,
          pageDay: null,
          settings: settings,
          eventColorsByTypeId: const <String, EventColorPreference>{},
          hourHeight: hourHeight,
          viewportHeight: viewportHeight,
          width: constraints.maxWidth,
          isToday: selectedDate == today,
          currentTimeListenable: currentTimeListenable,
        );
      },
    );
  }
}

/// S2A: the offscreen preview columns are a StatefulWidget so their display
/// geometry is memoized. While an active pinch keeps [hourHeight] (the
/// committed preview height) and [pageDay]/[settings] unchanged, the cached
/// placements are reused and `PlannerDisplayGeometry.resolve` is not called
/// again on raw pinch frames — only the centered page follows the live scale.
/// The cache is recomputed whenever any resolve input changes (Event set,
/// settings, or hour height), so a swipe or a pinch-end commit always sees
/// current geometry before the page becomes visible.
class _PagerPreviewColumn extends StatefulWidget {
  const _PagerPreviewColumn({
    super.key,
    required this.pageDate,
    required this.pageDay,
    required this.settings,
    required this.eventColorsByTypeId,
    required this.hourHeight,
    this.viewportHeight = 0,
    required this.width,
    required this.isToday,
    required this.currentTimeListenable,
  });

  final PlannerDate pageDate;
  final PlannerDay? pageDay;
  final PlannerSettings settings;
  final Map<String, EventColorPreference> eventColorsByTypeId;
  final double hourHeight;
  final double viewportHeight;
  final double width;
  final bool isToday;

  /// Authoritative current-time source shared with the
  /// centered timeline. The preview column uses this
  /// listenable (not `DateTime.now()` directly) so the
  /// centered indicator and the preview indicators render
  /// from the same instant.
  final ValueListenable<DateTime> currentTimeListenable;

  @override
  State<_PagerPreviewColumn> createState() => _PagerPreviewColumnState();
}

class _PagerPreviewColumnState extends State<_PagerPreviewColumn> {
  List<PlannerDisplayPlacement>? _placements;
  double? _cachedHourHeight;
  double? _cachedViewportHeight;
  PlannerDay? _cachedPageDay;
  PlannerSettings? _cachedSettings;

  bool get _geometryInputsChanged {
    final widget = this.widget;
    return _placements == null ||
        _cachedHourHeight != widget.hourHeight ||
        _cachedViewportHeight != widget.viewportHeight ||
        !identical(_cachedPageDay, widget.pageDay) ||
        !identical(_cachedSettings, widget.settings);
  }

  /// Recompute display geometry only when a resolve input actually changed.
  /// During an active pinch the committed preview height and the day/settings
  /// identity are frozen, so this is a no-op on raw pinch frames.
  void _resolveIfNeeded() {
    if (!_geometryInputsChanged) {
      return;
    }
    final widget = this.widget;
    final events =
        (widget.pageDay?.timedEvents ?? const <PlannerCalendarItem>[])
            .where(
              (event) =>
                  event.startLocal != null &&
                  event.endLocal != null &&
                  (widget.settings.showCancelledItems ||
                      event.state != PlannerEventState.cancelled),
            )
            .toList(growable: false);
    final placements = PlannerDisplayGeometry.resolve(
      events: events,
      hourHeight: widget.hourHeight,
      viewportHeight: widget.viewportHeight,
      configuredHours:
          widget.settings.visibleEndHour - widget.settings.visibleStartHour,
    );
    _placements = placements;
    _cachedHourHeight = widget.hourHeight;
    _cachedViewportHeight = widget.viewportHeight;
    _cachedPageDay = widget.pageDay;
    _cachedSettings = widget.settings;
  }

  @override
  void initState() {
    super.initState();
    _resolveIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _PagerPreviewColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolveIfNeeded();
  }

  @override
  Widget build(BuildContext context) {
    _resolveIfNeeded();
    final hourHeight = widget.hourHeight;
    final placements = _placements ?? const <PlannerDisplayPlacement>[];
    // The preview grid mirrors the centered timeline: the canvas spans
    // the full civil day, and the configured planning window is a soft
    // window (PMG parity) that only gates the current-time indicator.
    final firstHour = kPlannerCivilDayStartHour;
    final lastHour = kPlannerCivilDayEndHour;
    final slotCount = lastHour - firstHour;
    final pixelsPerMinute = PlannerTimelineGeometry.pixelsPerMinute(hourHeight);
    final visibleStart = kPlannerCivilDayStartMinute;
    final visibleEnd = kPlannerCivilDayEndMinute;
    final width = widget.width;
    return SizedBox(
      width: width,
      height: slotCount * hourHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          // PMG hidden-midnight model: the 12 AM top and bottom boundaries
          // are hidden (no label, no line); 1 AM is the first visible label
          // and 11 PM the last. The 12 AM-1 AM and 11 PM-12 AM slots remain
          // fully usable because the canvas still spans 0..1440 minutes.
          for (var index = 1; index < slotCount; index++) ...<Widget>[
            Positioned(
              // Match the centered timeline: the boundary line comes first
              // and its label sits immediately below it inside the hour cell.
              top: index * hourHeight + 2,
              left: 0,
              width: kPlannerPagerTimeColumnWidth,
              child: Text(
                _hourLabel(index, widget.settings.use24HourTime),
                // Hour labels must never wrap (the test fallback font
                // renders every glyph at fontSize width, which would wrap
                // short labels and push them below the final line).
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  // Preview/settled parity (audit 2026-08-16): the preview
                  // column must render the EXACT same hour labels as the
                  // settled timeline — the old 0xB3/0xFF (white70) made the
                  // preview labels visibly stronger than the settled 0.54
                  // (white54) and the labels changed opacity at commit.
                  color: AppTheme.onFillTextOf(context, 0.54),
                ),
              ),
            ),
            Positioned(
              key: Key('planner-pager-full-hour-line-$index'),
              top: index * hourHeight,
              left: kPlannerPagerTimeColumnWidth,
              right: 0,
              child: Divider(height: 1, color: AppTheme.outlineOf(context)),
            ),
          ],
          // Current-time indicator: painted BEFORE the Event blocks so the
          // final z-order (hour grid -> current-time indicator -> Event
          // blocks) matches the centered timeline and cards cover the line
          // at intersections. Read from the same authoritative source as the
          // centered timeline so a focused test can drive minute, hour, and
          // date transitions deterministically. The ValueListenableBuilder
          // rebuilds only this subtree on a minute tick.
          if (widget.settings.showCurrentTime && widget.isToday)
            ValueListenableBuilder<DateTime>(
              valueListenable: widget.currentTimeListenable,
              builder: (context, now, _) {
                return _positionedCurrentTime(
                  now: now,
                  pixelsPerMinute: pixelsPerMinute,
                  visibleStart: visibleStart,
                  visibleEnd: visibleEnd,
                );
              },
            ),
          for (final placement in placements)
            _positionedPreviewEvent(
              context: context,
              placement: placement,
              width: width,
            ),
        ],
      ),
    );
  }

  Widget _positionedPreviewEvent({
    required BuildContext context,
    required PlannerDisplayPlacement placement,
    required double width,
  }) {
    final event = placement.event;
    final start = event.startLocal!;
    final end = event.endLocal!;
    final startMinute = start.hour * 60 + start.minute;
    final endMinute = plannerEndMinuteOfDay(start, end);
    // The preview uses the same exact canonical placement as the centered
    // timeline.
    final displayHeight = placement.height;
    final content = PlannerEventBlockContent.forHeight(
      displayHeight,
      interactive: false,
    );
    final resolvedAccent = PlannerEventColorResolver.accentColor(
      context,
      event,
      widget.eventColorsByTypeId,
    );
    final resolvedSurface = PlannerEventColorResolver.surfaceColor(
      context,
      event,
      widget.eventColorsByTypeId,
    );
    final accent = resolvedAccent;
    final surface = resolvedSurface;
    final eventContent = PlannerEventBlockContentView(
      event: event,
      accentColor: accent,
      surfaceColor: surface,
      use24HourTime: widget.settings.use24HourTime,
      displayStartMinute: startMinute,
      displayEndMinute: endMinute,
      awaitingReport: event.isAwaitingReport(
        widget.currentTimeListenable.value,
      ),
      content: content,
      titleKey: Key('planner-pager-preview-event-title-${event.id}'),
      timeKey: Key('planner-pager-preview-event-time-${event.id}'),
      recurrenceKey: Key('planner-pager-preview-event-recurrence-${event.id}'),
      statusKey: Key('planner-pager-preview-event-status-${event.id}'),
    );
    final eventBody = event.isBackupAppointment
        ? eventContent
        : DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: accent,
                  width: PlannerEventBlockLayoutPolicy.eventAccentWidth,
                ),
              ),
            ),
            child: eventContent,
          );
    final horizontal = PlannerPagerEventHorizontalGeometry.resolve(
      placement: placement,
      width: width,
      timeColumnWidth: kPlannerPagerTimeColumnWidth,
      laneGap: PlannerEventBlockLayoutPolicy.eventLaneGap,
    );
    final left = horizontal.left;
    final blockWidth = horizontal.width;
    return Positioned(
      key: Key('planner-pager-preview-event-${event.id}'),
      top: placement.top,
      left: left,
      width: blockWidth,
      height: displayHeight,
      child: IgnorePointer(
        child: Material(
          color: surface,
          shape: RoundedRectangleBorder(
            // Delta 4.2R R12: contiguous blocks square the shared edge so no
            // decorative rounded-corner notch fakes a vertical gap.
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(
                placement.squareTop
                    ? 0
                    : PlannerEventBlockLayoutPolicy.effectiveRadiusFor(
                        displayHeight,
                      ),
              ),
              topRight: Radius.circular(
                placement.squareTop
                    ? 0
                    : PlannerEventBlockLayoutPolicy.effectiveRadiusFor(
                        displayHeight,
                      ),
              ),
              bottomLeft: Radius.circular(
                placement.squareBottom
                    ? 0
                    : PlannerEventBlockLayoutPolicy.effectiveRadiusFor(
                        displayHeight,
                      ),
              ),
              bottomRight: Radius.circular(
                placement.squareBottom
                    ? 0
                    : PlannerEventBlockLayoutPolicy.effectiveRadiusFor(
                        displayHeight,
                      ),
              ),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: event.isBackupAppointment
              ? PlannerBackupStripeBackground(
                  accent: resolvedAccent,
                  surfaceColor: surface,
                  accentKey: Key(
                    'planner-pager-backup-accent-strip-${event.id}',
                  ),
                  surfaceKey: Key(
                    'planner-pager-backup-event-surface-${event.id}',
                  ),
                  child: eventBody,
                )
              : eventBody,
        ),
      ),
    );
  }

  Widget _positionedCurrentTime({
    required DateTime now,
    required double pixelsPerMinute,
    required int visibleStart,
    required int visibleEnd,
  }) {
    if (widget.settings.showCurrentTime != true) {
      return const SizedBox.shrink();
    }
    final current = PlannerDate.fromDateTime(now);
    if (current != widget.pageDate) {
      return const SizedBox.shrink();
    }
    final minuteOfDay = now.hour * 60 + now.minute;
    // M6 closure: the bound is the CANVAS minute range the caller passes
    // in (the full 00:00-1440 civil day), never the soft planning window.
    // The planning window only seeds the initial scroll position and the
    // max-zoom-out fit target, so gating visibility on it blanked the
    // indicator during the boundary hours of any narrower window.
    if (minuteOfDay < visibleStart || minuteOfDay >= visibleEnd) {
      return const SizedBox.shrink();
    }
    final resolvedMinuteY = minuteOfDay * pixelsPerMinute;
    final resolvedIndicatorTop =
        resolvedMinuteY - kPlannerPagerCurrentTimeIndicatorHeight / 2;
    return Positioned(
      key: const Key('planner-current-time-indicator'),
      top: resolvedIndicatorTop,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: SizedBox(
          height: kPlannerPagerCurrentTimeIndicatorHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                // CT-03: the label area widens LEFTWARD (62dp) so its right
                // edge stays tangent to the unchanged anchor boundary; the
                // anchor/line are not moved to make room.
                left: PlannerCurrentTimeHorizontalGeometry.labelLeft,
                top: 0,
                bottom: 0,
                width: PlannerCurrentTimeHorizontalGeometry.labelWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Container(
                      // CT-02/CT-03: NO fill/background behind the time.  The
                      // time text itself is the highlighted element — semantic
                      // primary, larger (fontSize 15) in a 62dp leftward-
                      // widened area with 4dp padding.
                      height: PlannerCurrentTimeHorizontalGeometry
                          .capsuleHeight,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        _formatCurrentTimeLabel(now),
                        key: const Key('planner-current-time-label'),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                key: const Key('planner-current-time-dot'),
                left: PlannerCurrentTimeHorizontalGeometry.dotLeft,
                top:
                    (kPlannerPagerCurrentTimeIndicatorHeight -
                        kPlannerPagerCurrentTimeDotSize) /
                    2,
                width: kPlannerPagerCurrentTimeDotSize,
                height: kPlannerPagerCurrentTimeDotSize,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                key: const Key('planner-current-time-line'),
                // CT-01: the thin line begins at the anchor's right edge and
                // continues across the Event canvas.
                left: PlannerCurrentTimeHorizontalGeometry.lineStartX,
                right: 0,
                top: (kPlannerPagerCurrentTimeIndicatorHeight - 2) / 2,
                height: 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reference the [PlannerSharedViewport.empty] constant so the
/// shared-viewport file is reachable from anywhere that imports
/// this pager; useful for focused tests that build both widgets
/// in the same harness.
// ignore: unused_element
const PlannerSharedViewport _kEmpty = PlannerSharedViewport.empty;
