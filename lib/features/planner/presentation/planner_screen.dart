import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/shell/global_drawer_controller.dart';
import 'package:rmplanner/app/shell/planning_navigation.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/planner/application/calendar_event_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/planner_tap_marker_provider.dart';
import 'package:rmplanner/features/planner/application/planner_task_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_display_geometry.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/domain/planner_timeline_layout.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_creation.dart';
import 'package:rmplanner/features/planner/presentation/contextual_create_fab.dart';
import 'package:rmplanner/features/planner/presentation/planner_event_open.dart';
import 'package:rmplanner/features/planner/presentation/task_creation.dart';
import 'package:rmplanner/features/planner/presentation/task_preview_sheet.dart';
import 'package:rmplanner/features/planner/presentation/widgets/anchored_top_bar_popup.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_calendar_icon.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_date_strip.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_content.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_layout_policy.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_color_resolver.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_interactive_day_pager.dart'
    show
        PlannerCurrentTimeHorizontalGeometry,
        PlannerInteractiveDayPager,
        PlannerInteractiveDayPagerController,
        PlannerLoadingDayTimeline;
import 'package:rmplanner/features/planner/presentation/widgets/planner_shared_viewport.dart'
    show kPlannerTimelineBottomBoundaryExtent;
import 'package:rmplanner/features/planner/presentation/widgets/planner_slide_down_date_picker.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_top_bar_icons.dart';
import 'package:rmplanner/features/planner/presentation/widgets/repeating_event_scope_choices.dart';

final class PlannerScreen extends ConsumerStatefulWidget {
  const PlannerScreen({super.key, this.currentTimeListenable});

  /// Optional current-time source used by the exact current-time
  /// indicator. When omitted, the screen owns a [ValueNotifier] of
  /// [DateTime] seeded from `DateTime.now()` and refreshed by an
  /// internal minute-boundary [Timer] (production behavior).
  /// When provided, the screen reads this listenable directly and
  /// does not create its own notifier, timer, or ticker — the
  /// caller (typically a focused widget test) owns the listenable
  /// and is responsible for advancing it. Production code paths
  /// never pass this argument.
  final ValueListenable<DateTime>? currentTimeListenable;

  @override
  ConsumerState<PlannerScreen> createState() => _PlannerScreenState();
}

final class _PlannerScreenState extends ConsumerState<PlannerScreen> {
  // R7-03: symmetric in-viewport cross-date trigger strips inside the Event
  // canvas. Both the previous and next strips share the same width and
  // coordinate space; only the direction differs (previous = date - 1,
  // next = date + 1). The previous strip sits just inside the Event canvas
  // (after the time gutter) exactly mirroring the next strip at the right
  // edge, so left/past and right/future behave identically.
  static const double _crossDateTriggerWidth = 56;
  static const double _crossDatePreviousBoundary =
      PlannerCurrentTimeHorizontalGeometry.timeColumnWidth +
      _crossDateTriggerWidth;
  static const double _crossDateNextTriggerWidth = _crossDateTriggerWidth;
  static const Duration _crossDateEdgeDwell = Duration(milliseconds: 200);

  late final PlannerEventCreationDraftController _eventCreationDraftController;
  final ScrollController _dayScrollController = ScrollController();
  final GlobalKey _dayScrollKey = GlobalKey();
  final GlobalKey _timelineKey = GlobalKey();
  // Live hour height during a two-finger pinch. The timeline reports
  // every scale update here so the parent can rebuild the pager strip
  // with the mid-gesture height; without it the strip stays at the
  // settings height, clips the growing canvas, and the scroll extent
  // (and thus the focal compensation) never expands.
  //
  // R7-05: published through a [ValueNotifier] consumed only by the pager
  // strip, so a pinch frame rebuilds the pager subtree instead of the
  // whole Planner (app bar, date strip, header, drag overlay). `null`
  // means "use the saved setting".
  final ValueNotifier<double?> _liveTimelineHourHeight = ValueNotifier<double?>(
    null,
  );
  final GlobalKey _filterButtonKey = GlobalKey();
  final GlobalKey _overflowButtonKey = GlobalKey();
  // External command surface owned by the screen for the
  // lifetime of the Planner route. The interactive day pager
  // attaches itself to this controller in its
  // [State.initState] and detaches itself in
  // [State.dispose]. The screen's `_DaySwipeCoordinator`
  // cancel listener invokes
  // [PlannerInteractiveDayPagerController.recenterFromExternalCancel]
  // so a competing recognizer (long-press move, vertical
  // drag, pinch scale) tears the pager back to the centered
  // resting position. The previous `GlobalKey<State>` design
  // is removed: this typed controller is the only public
  // command surface, and the pager's private State class is
  // not exposed across files.
  final PlannerInteractiveDayPagerController _pagerController =
      PlannerInteractiveDayPagerController();
  final PlannerDateStripController _dateStripController =
      PlannerDateStripController();
  String? _initialScrollSignature;
  bool _initialScrollPerformed = false;
  String? _taskDraftRevealSignature;
  bool _taskDraftRevealPending = false;
  PlannerPresentation? _presentation;
  final Set<PlannerSelectionId> _selectedItems = <PlannerSelectionId>{};
  Future<List<PlannerDay>>? _rangeLoad;
  String? _rangeSignature;
  // Cached three-day read-only preview future for the
  // interactive pager. The cached future is rebuilt only
  // when the preview signature changes. The signature is
  // composed of:
  //   * the selected ISO date;
  //   * a per-build data revision counter that bumps every
  //     time the planner state is rebuilt (so any path that
  //     re-reads `state.day` — including a normal
  //     `refresh()` call after an adjacent-day mutation —
  //     invalidates the cache);
  //   * the resolved previous/next PlannerDay content
  //     signatures, captured the most recent time the
  //     preview trio completed (so a subsequent adjacent
  //     mutation refetches the preview the very next build
  //     after the data revision bumped);
  //   * the relevant settings that affect preview
  //     rendering (visible hour window, hour height,
  //     use-24-hour time, show-current-time, show-cancelled,
  //     content filters).
  //
  // The previous/next content signatures are captured at
  // the moment the preview future STARTS (not just when it
  // resolves) so a future started after a fresh data
  // revision uses the most recent known previous/next
  // signatures and refetches the trio on the next build.
  //
  // The generation captured at future-start is stored in
  // [_previewGeneration]. When the future resolves, the
  // result is adopted only if the generation still matches
  // the most recent build's generation — so an older
  // in-flight future cannot overwrite the active preview
  // when a more recent data revision has already started a
  // newer future.
  Future<_PlannerPreviewWindow>? _previewLoad;
  int? _previewGeneration;
  int _previewLoadSerial = 0;
  int? _activePreviewLoadSerial;
  String? _previewSignature;
  String? _previousDayContentSignature;
  String? _nextDayContentSignature;
  // Date-keyed preview cache: each successfully read adjacent day is stored
  // under its own `selectedDate`, and preview columns always resolve their day
  // BY DATE (never by list index). This makes a page unable to paint another
  // date's Events (no wrong-date flash during/after swipes) and lets a date
  // that was read once retain its correct snapshot while a newer window is
  // still loading (no empty-then-populate flicker).
  final Map<PlannerDate, PlannerDay> _previewDayCache =
      <PlannerDate, PlannerDay>{};
  // Bumped only when the authoritative selected date/day identity changes.
  // Unrelated parent rebuilds therefore keep the cached preview future
  // stable.
  int _dataRevision = 0;
  PlannerDate? _lastObservedSelectedDate;
  PlannerDay? _lastObservedDay;
  int? _lastObservedEventDeletionRevision;
  // Canonical day-cache revision last observed by this screen. The retained
  // [_previewDayCache] and [_previewSignature] belong to that canonical
  // generation, so they are invalidated whenever the controller invalidates
  // its own day cache — even when the selected day is semantically unchanged.
  int _lastObservedDayCacheRevision = -1;
  bool _selectionActive = false;
  bool _datePickerOpen = false;
  // Owns the day-swipe candidate lifetime across the Listener
  // wrapper and the timeline's pinch/long-press/resize recognizers.
  // The field is initialized on first build and reused for every
  // subsequent gesture so each pointer-down starts from a known
  // clean state.
  final _DaySwipeCoordinator _daySwipeCoordinator = _DaySwipeCoordinator();
  // Owns the pinch state for the Planner timeline. The
  // timeline's pointer Listener updates the active pointer
  // count; the parent reads the coordinator to decide whether
  // to swap the SingleChildScrollView's physics to
  // NeverScrollableScrollPhysics during a two-pointer pinch.
  // The coordinator lives on the parent state so its lifetime
  // spans the entire Planner route and its listeners (the
  // physics swap and the gesture suppressions) can be wired
  // up once on first build.
  final _PinchCoordinator _pinchCoordinator = _PinchCoordinator();
  // Delta 4.2E cross-date drag state lives above the day data so it survives
  // authoritative date reloads while the pointer remains down. The session is
  // transient only: hover transitions never write Calendar Event data.
  _CrossDateDragSession? _crossDateDrag;
  Future<void>? _crossDateNavigation;
  Timer? _crossDateDwellTimer;
  int? _crossDateDwellDirection;
  bool _savedDragPointerRouteRegistered = false;
  int _savedMoveCompletionRevision = 0;
  // R7-05: per-frame saved-drag candidate state (pointer + snapped minutes)
  // lives in a lightweight ValueNotifier consumed only by the screen-level
  // drag overlay. A pointer frame updates this notifier without rebuilding
  // the whole Planner (events, pager, strip, date header), so drag frames no
  // longer trigger a full-screen setState. The [ValueNotifier] is disposed in
  // [dispose].
  final ValueNotifier<_SavedDragFrameState?> _savedDragFrameNotifier =
      ValueNotifier<_SavedDragFrameState?>(null);
  // R7-04: optimistic pending-move projection shown immediately at drop,
  // before the canonical repository commit completes. Cleared on success
  // (when the refresh lands) or rolled back on failure.
  _PendingMoveProjection? _pendingMoveProjection;
  // Owns the current-time value for the planner's exact
  // current-time indicator. The timeline reads this via a
  // ValueListenableBuilder so only the indicator subtree rebuilds
  // when the minute changes — the pinch/long-press/resize
  // recognizers and the surrounding widget tree remain untouched
  // by minute ticks. Ownership semantics:
  //
  // - the notifier is constructed in [initState] (so its first
  //   value matches `DateTime.now()` when the widget mounts, not
  //   at field-init time);
  // - a single narrowly-scoped Timer schedules itself to fire at
  //   the next minute boundary and then continues once per minute,
  //   updating the notifier with the latest wall-clock minute;
  // - the timer is cancelled and the notifier is disposed in
  //   [dispose];
  // - tests drive the indicator deterministically by calling
  //   `currentTimeNotifier.value = newNow`, which notifies listeners
  //   without scheduling any real-time wait.
  //
  // When [PlannerScreen.currentTimeListenable] is supplied, the
  // screen-owned notifier and ticker are not constructed — the
  // injected listenable is used verbatim, and the screen does not
  // own its lifecycle. In that mode both [currentTimeNotifier] and
  // [_currentTimeTicker] remain `null` for the entire lifetime of
  // the state, so [dispose] is a no-op for current-time resources.
  ValueNotifier<DateTime>? currentTimeNotifier;
  Timer? _currentTimeTicker;

  /// The listenable the timeline actually reads. Equals the
  /// screen-owned notifier in production; equals the injected
  /// override in focused tests.
  ValueListenable<DateTime> get _activeCurrentTimeListenable =>
      widget.currentTimeListenable ?? currentTimeNotifier!;

  bool get _selectionMode => _selectionActive;

  @override
  void initState() {
    super.initState();
    _eventCreationDraftController = ref.read(
      plannerEventCreationDraftProvider.notifier,
    );
    if (widget.currentTimeListenable == null) {
      currentTimeNotifier = ValueNotifier<DateTime>(DateTime.now());
      _scheduleCurrentTimeTicker();
    }
    // Subscribe to pinch-state changes so the SingleChildScrollView
    // can be rebuilt with the appropriate physics on the same
    // frame a two-finger pinch begins or ends. The listener
    // uses setState; the timeline guarantees the callback only
    // fires on actual state transitions, so the rebuild cost is
    // bounded to one rebuild per gesture boundary.
    _pinchCoordinator.addListener(_onPinchCoordinatorChanged);
    // Register the day-swipe coordinator cancel listener so a
    // competing recognizer (long-press move, vertical drag,
    // pinch scale) tears the interactive day pager back to
    // the centered resting position. The listener is
    // unregistered in [dispose] to keep the lifecycle
    // symmetric; the typed controller exposed on
    // [_pagerController] is the only public command surface
    // used here, so there is no GlobalKey lookup or dynamic
    // invocation crossing module boundaries.
    _daySwipeCoordinator.addCancelListener(
      _pagerController.recenterFromExternalCancel,
    );
  }

  /// Schedule the next minute-boundary tick of [currentTimeNotifier].
  ///
  /// The timer fires once for the next minute boundary then
  /// reschedules itself every minute. Scheduling against the
  /// next boundary (rather than an arbitrary 60-second interval
  /// after construction) keeps the visible time text aligned
  /// with the actual wall-clock minute that crossed during the
  /// interval — a 60 s loop constructed at, say, 14:03:42 would
  /// otherwise tick at 14:04:42 and disagree with the wall clock.
  /// The scheduled duration is recomputed against the current
  /// moment so the ticker stays accurate even if the device's
  /// wall-clock changes mid-session.
  void _scheduleCurrentTimeTicker() {
    _currentTimeTicker?.cancel();
    final now = DateTime.now();
    final nextMinute = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    ).add(const Duration(minutes: 1));
    final initialDelay = nextMinute.difference(now);
    void onTick() {
      if (!mounted) {
        return;
      }
      currentTimeNotifier!.value = DateTime.now();
      _scheduleCurrentTimeTicker();
    }

    if (initialDelay <= Duration.zero) {
      onTick();
      return;
    }
    _currentTimeTicker = Timer(initialDelay, onTick);
  }

  @override
  void dispose() {
    _eventCreationDraftController.clearCurrentAfterLifecycle();
    _crossDateDwellTimer?.cancel();
    _removeSavedDragPointerRoute();
    _savedDragFrameNotifier.dispose();
    _liveTimelineHourHeight.dispose();
    _currentTimeTicker?.cancel();
    _currentTimeTicker = null;
    currentTimeNotifier?.dispose();
    currentTimeNotifier = null;
    _pinchCoordinator.removeListener(_onPinchCoordinatorChanged);
    _daySwipeCoordinator.removeCancelListener(
      _pagerController.recenterFromExternalCancel,
    );
    _dayScrollController.dispose();
    _pagerController.dispose();
    super.dispose();
  }

  /// Listener invoked by the [_PinchCoordinator] whenever the
  /// pinch state changes. The parent uses the resulting
  /// `isPinchActive` signal to decide whether the parent
  /// SingleChildScrollView's `physics` should be
  /// [NeverScrollableScrollPhysics] (during a two-finger
  /// pinch) or the default [ClampingScrollPhysics] (one
  /// finger or zero fingers). The setState is guarded by
  /// `mounted` to avoid touching a disposed widget, and it
  /// only fires on a real state transition, so the rebuild
  /// cost is bounded.
  void _onPinchCoordinatorChanged() {
    if (!mounted || !context.mounted) {
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(plannerControllerProvider);
    final controller = ref.read(plannerControllerProvider.notifier);
    final eventTypeState = ref.watch(eventTypeControllerProvider);
    final plannerSettings = eventTypeState.settings;
    // The Task color is an existing Color Settings preference keyed by the
    // canonical task identity.  Keep it in the presentation map so a timed
    // Task footprint resolves through the same Light/Dark color pipeline as
    // Event blocks without borrowing a linked Event Type's color.
    final eventColorsByTypeId = <String, EventColorPreference>{
      ...eventTypeState.resolvedEventColorsByTypeId,
      PlannerEventColorResolver.taskStableKey:
          eventTypeState.eventColors[PlannerEventColorResolver.taskStableKey] ??
          PlannerEventColorDefaults.task,
    };
    _presentation ??= plannerSettings.preferredPresentation;
    // Delta 4.1 D4.1-05: the "+" FAB is a normal-Planner affordance only.
    // It is hidden while a creation session is engaged (generic Event
    // placeholder, provisional draft, or the editor sheet) so it
    // never overlaps the Save button or the draft editor, and it returns
    // after Save/Cancel clears the session.
    final creationSessionActive =
        ref.watch(plannerTapMarkerProvider) != null ||
        ref.watch(plannerEventCreationDraftProvider) != null ||
        ref.watch(plannerTaskCreationDraftProvider) != null;

    final scaffold = Scaffold(
      appBar: _buildAppBar(context, ref, state, plannerSettings, controller),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: <Widget>[
            PlannerDateStrip(
              selectedDate: state.selectedDate,
              onSelected: controller.selectDate,
              pagerProgress: _pagerController.progress,
              controller: _dateStripController,
            ),
            Expanded(
              child: _buildContent(
                context,
                ref,
                state,
                plannerSettings,
                eventColorsByTypeId,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: creationSessionActive
          ? null
          : ContextualCreateFab(
              buttonKey: const Key('planner-create-button'),
              destination: CreateActionDestination.planner,
              onSelected: (action) =>
                  _handleCreateAction(context, ref, state.selectedDate, action),
            ),
    );
    return Stack(
      children: <Widget>[
        scaffold,
        if (_datePickerOpen)
          PlannerDatePickerOverlay(
            key: const Key('planner-date-picker-overlay'),
            initialDate: state.selectedDate.asLocalDate,
            firstDate: DateTime(1900),
            lastDate: DateTime(2200, 12, 31),
            helpText: 'Select Planner date',
            onCancel: _closeDatePicker,
            onConfirm: (date) => _confirmDatePicker(controller, date),
          ),
      ],
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    WidgetRef ref,
    PlannerState state,
    PlannerSettings settings,
    PlannerController controller,
  ) {
    // Today icon visual state: pink only when the selected Planner
    // date is the current local date. Date-only comparison via
    // [PlannerDate] equality so hours/minutes/seconds do not affect
    // the color. The clock source is the same deterministic
    // [PlannerDateSource] used by the current-time indicator, so
    // production and tests share the same anchor.
    final today = ref.read(plannerDateSourceProvider).today();
    final isViewingToday = state.selectedDate == today;
    // B2-CORRECTION: the today icon uses the semantic Theme Color primary
    // when viewing today (dark Rose baseline = canonical rose, identical
    // pixels) and onSurface otherwise.
    final todayIconColor = isViewingToday
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurface;
    // B2-CORRECTION: the Planner top app bar follows the active brightness.
    // Dark keeps the locked black bar + white foreground (byte-identical);
    // Light uses the app/nav surface + onSurface so the bar is light with
    // readable icons instead of a black bar in Light.
    final appBarBackground = Theme.of(context).brightness == Brightness.dark
        ? Colors.black
        : Theme.of(context).colorScheme.surfaceContainer;
    final appBarForeground = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    if (_selectionMode) {
      return AppBar(
        backgroundColor: appBarBackground,
        foregroundColor: appBarForeground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          key: const Key('planner-selection-cancel'),
          tooltip: 'Cancel selection',
          onPressed: () => setState(() {
            _selectionActive = false;
            _selectedItems.clear();
          }),
          icon: const Icon(Icons.close),
        ),
        title: Text('${_selectedItems.length} selected'),
        actions: <Widget>[
          IconButton(
            key: const Key('planner-selection-delete'),
            tooltip: 'Remove selected items',
            onPressed: _selectedItems.isEmpty
                ? null
                : () => _removeSelected(context, ref, state, settings),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      );
    }
    return AppBar(
      backgroundColor: appBarBackground,
      foregroundColor: appBarForeground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: Builder(
        builder: (innerContext) => PlannerTopBarIconButton(
          key: const Key('planner-hamburger'),
          tooltip: 'Open global navigation',
          onPressed: () => GlobalDrawerScope.of(innerContext).open(),
          icon: const Icon(Icons.menu, size: 26),
        ),
      ),
      titleSpacing: 0,
      title: KeyedSubtree(
        key: const Key('planner-date-picker-trigger'),
        child: InkWell(
          key: const Key('planner-date-label'),
          borderRadius: BorderRadius.circular(8),
          onTap: _openCalendar,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Row(
              key: const Key('planner-date-label-row'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  child: Text(
                    _dateLabel(state.selectedDate, _presentation!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  key: Key('planner-date-chevron'),
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        Semantics(
          label: 'Go to today',
          button: true,
          child: ExcludeSemantics(
            // Slice D reuses the same calendar icon that the Home
            // top bar used to expose. The component encapsulates the
            // glyph, size, and visual structure while the parent
            // owns the tap callback, the focused key, and the
            // Slice C color contract (pink when selected date is
            // today; on-surface otherwise).
            child: PlannerCalendarButtonSurface(
              onTap: () {
                // Delta 4.2R R5 + Delta 4.2R2 R2-09: Go-to-Today must feel
                // immediate. Cancel any transient cross-date drag/hover
                // session AND any live day-swipe candidate first so a
                // lingering hover navigation or half-finished swipe can
                // never fight the jump or oscillate through intermediate
                // dates, then select TODAY directly (the pager recenters the
                // new page instantly and the minute-ticking current-time
                // notifier already carries the wall clock, so the indicator
                // shows "now" at once).
                if (_crossDateDrag != null) {
                  _cancelCrossDateDrag();
                }
                _daySwipeCoordinator.cancel();
                final today = ref.read(plannerDateSourceProvider).today();
                if (state.selectedDate != today) {
                  _dateStripController.prepareForImmediateSelection();
                }
                unawaited(
                  ref
                      .read(plannerControllerProvider.notifier)
                      .selectDate(today),
                );
              },
              color: todayIconColor,
            ),
          ),
        ),
        KeyedSubtree(
          key: const Key('planner-filter-button'),
          child: PlannerTopBarIconButton(
            key: _filterButtonKey,
            tooltip: 'Filter Planner content',
            onPressed: () => _showFilters(context, ref, settings),
            icon: PlannerFilterIcon(color: appBarForeground),
          ),
        ),
        PlannerTopBarIconButton(
          key: const Key('planner-selection-button'),
          tooltip: 'Select Events or Tasks',
          onPressed: () => setState(() => _selectionActive = true),
          icon: PlannerSelectionIcon(color: appBarForeground),
        ),
        KeyedSubtree(
          key: const Key('planner-overflow-button'),
          child: PlannerTopBarIconButton(
            key: _overflowButtonKey,
            tooltip: 'Planner menu',
            onPressed: () => _showOverflowMenu(context, ref, state, settings),
            icon: const Icon(Icons.more_vert, size: 24),
          ),
        ),
      ],
    );
  }

  Future<void> _showOverflowMenu(
    BuildContext context,
    WidgetRef ref,
    PlannerState state,
    PlannerSettings settings,
  ) async {
    await showAnchoredTopBarPopup(
      context: context,
      triggerKey: _overflowButtonKey,
      width: 240,
      maxHeight: 320,
      builder: (popupContext) {
        return Column(
          key: const Key('planner-overflow-menu'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final entry in <_OverflowEntry>[
              _OverflowEntry(
                action: _PlannerOverflowAction.search,
                label: 'Search',
                icon: Icons.search,
              ),
              _OverflowEntry(
                action: _PlannerOverflowAction.schedule,
                label: 'Schedule',
                icon: Icons.view_agenda_outlined,
                selected: _presentation == PlannerPresentation.schedule,
              ),
              _OverflowEntry(
                action: _PlannerOverflowAction.day,
                label: 'Day',
                icon: Icons.calendar_view_day_outlined,
                selected: _presentation == PlannerPresentation.day,
              ),
              _OverflowEntry(
                action: _PlannerOverflowAction.week,
                label: 'Week',
                icon: Icons.calendar_view_week_outlined,
                selected: _presentation == PlannerPresentation.week,
              ),
              // Owner law (2026-09-20): Tasks has exactly ONE canonical home.
              // This row NAVIGATES to the canonical Tasks screen instead of
              // switching the Planner into a second Tasks list, so it is never
              // a selected presentation state.
              _OverflowEntry(
                action: _PlannerOverflowAction.tasks,
                label: 'Tasks',
                icon: Icons.task_alt_outlined,
              ),
            ])
              _OverflowPopupRow(
                entry: entry,
                onTap: () async {
                  anchoredTopBarPopupController.dismiss();
                  await _handleOverflow(
                    context,
                    ref,
                    state,
                    settings,
                    entry.action,
                  );
                },
              ),
          ],
        );
      },
    );
  }

  Future<void> _showFilters(
    BuildContext context,
    WidgetRef ref,
    PlannerSettings settings,
  ) async {
    var filters = settings.contentFilters;
    await showAnchoredTopBarPopup(
      context: context,
      triggerKey: _filterButtonKey,
      width: 300,
      maxHeight: 380,
      builder: (popupContext) {
        return StatefulBuilder(
          builder: (innerContext, setSheetState) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                key: const Key('planner-filter-menu'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: Text(
                      'Show in Planner',
                      style: Theme.of(innerContext).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  CheckboxListTile(
                    key: const Key('planner-filter-events'),
                    title: const Text('Events'),
                    value: filters.events,
                    onChanged: (value) => setSheetState(
                      () => filters = filters.copyWith(events: value),
                    ),
                  ),
                  CheckboxListTile(
                    key: const Key('planner-filter-backup-events'),
                    title: const Text('Backup Events'),
                    value: filters.backupEvents,
                    onChanged: (value) => setSheetState(
                      () => filters = filters.copyWith(backupEvents: value),
                    ),
                  ),
                  CheckboxListTile(
                    key: const Key('planner-filter-tasks'),
                    title: const Text('Tasks'),
                    value: filters.tasks,
                    onChanged: (value) => setSheetState(
                      () => filters = filters.copyWith(tasks: value),
                    ),
                  ),
                  CheckboxListTile(
                    key: const Key('planner-filter-completed-tasks'),
                    title: const Text('Completed Tasks'),
                    value: filters.completedTasks,
                    onChanged: filters.tasks
                        ? (value) => setSheetState(
                            () => filters = filters.copyWith(
                              completedTasks: value,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: TextButton(
                            onPressed: () => setSheetState(
                              () => filters =
                                  const PlannerContentFilters.defaults(),
                            ),
                            child: const Text(
                              'Restore defaults',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const Key('planner-filter-apply'),
                          onPressed: () async {
                            anchoredTopBarPopupController.dismiss();
                            if (!mounted ||
                                filters == settings.contentFilters) {
                              return;
                            }
                            await ref
                                .read(eventTypeControllerProvider.notifier)
                                .saveSettings(
                                  settings.copyWith(contentFilters: filters),
                                );
                          },
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (!mounted) {
      return;
    }
  }

  Future<void> _handleOverflow(
    BuildContext context,
    WidgetRef ref,
    PlannerState state,
    PlannerSettings settings,
    _PlannerOverflowAction action,
  ) async {
    if (action == _PlannerOverflowAction.search) {
      final day = state.day;
      if (day != null) {
        await showSearch<void>(
          context: context,
          delegate: _PlannerSearchDelegate(day: day),
        );
      }
      return;
    }
    if (action == _PlannerOverflowAction.tasks) {
      // Canonical Tasks screen (owner law, 2026-09-20).  The Planner is
      // recorded as the back origin, so the screen's own back arrow returns
      // here rather than anywhere else.  Nothing about the Planner's
      // presentation is written: this row no longer has one.
      openPlanningDestination(context, RoutePaths.tasks);
      return;
    }
    final presentation = switch (action) {
      _PlannerOverflowAction.schedule => PlannerPresentation.schedule,
      _PlannerOverflowAction.day => PlannerPresentation.day,
      _PlannerOverflowAction.week => PlannerPresentation.week,
      _PlannerOverflowAction.tasks ||
      _PlannerOverflowAction.search => settings.preferredPresentation,
    };
    await _setPresentation(ref, settings, presentation);
  }

  Future<void> _setPresentation(
    WidgetRef ref,
    PlannerSettings settings,
    PlannerPresentation presentation,
  ) async {
    setState(() {
      _presentation = presentation;
      _selectionActive = false;
      _selectedItems.clear();
    });
    await ref
        .read(eventTypeControllerProvider.notifier)
        .saveSettings(settings.copyWith(preferredPresentation: presentation));
  }

  void _handleCreateAction(
    BuildContext context,
    WidgetRef ref,
    PlannerDate selectedDate,
    ContextualCreateAction action,
  ) {
    switch (action) {
      case ContextualCreateAction.event:
        unawaited(
          launchCalendarEventCreation<void>(
            context,
            ref,
            CalendarEventCreationContext(
              source: 'planner-fab',
              destinationPath: RoutePaths.calendarEventCreate,
              date: selectedDate,
            ),
          ),
        );
        return;
      case ContextualCreateAction.task:
        final now = DateTime.now();
        unawaited(
          launchTaskCreation(
            context,
            ref,
            TaskCreationContext(
              source: 'planner-fab',
              date: selectedDate,
              minute: now.hour * 60 + now.minute,
            ),
          ),
        );
        return;
    }
  }

  static String _dateLabel(PlannerDate date, PlannerPresentation presentation) {
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    if (presentation == PlannerPresentation.week) {
      final start = date.addDays(-(date.weekday - DateTime.monday));
      final end = start.addDays(6);
      return '${months[start.month - 1]} ${start.day}–'
          '${months[end.month - 1]} ${end.day}';
    }
    return '${months[date.month - 1]} ${date.day}';
  }

  /// R7-04: screen-level drag overlay that renders the saved-drag ghost and
  /// the candidate drag-time label ABOVE the pager strip. The ghost is
  /// positioned from the timeline's global rect and the per-frame
  /// [ValueNotifier] state, so it stays under the finger and is excluded
  /// from the page transform during a cross-date transition. Rebuilds only
  /// this overlay on pointer frames (R7-05 layer isolation).
  Widget _buildSavedDragOverlay({
    required double hourHeight,
    required double timelineHeight,
    required bool use24HourTime,
    required PlannerDate selectedDate,
    required Map<String, EventColorPreference> eventColorsByTypeId,
  }) {
    final session = _crossDateDrag;
    if (session == null ||
        !session.ghostActive ||
        session.targetDate != selectedDate) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<_SavedDragFrameState?>(
      valueListenable: _savedDragFrameNotifier,
      builder: (context, frame, _) {
        if (frame == null) {
          return const SizedBox.shrink();
        }
        final timeline = _parentTimelineRenderBox();
        // The overlay is a Positioned.fill sibling of the day scroll view
        // inside the same Stack, so it shares the day-scroll box's origin.
        // Using that already-mounted box (rather than the overlay's own
        // render object, which is not laid out on the very first build)
        // lets the ghost render on the first drag frame.
        final overlayBox = _dayScrollKey.currentContext?.findRenderObject();
        if (timeline == null ||
            !timeline.hasSize ||
            overlayBox is! RenderBox ||
            !overlayBox.hasSize) {
          return const SizedBox.shrink();
        }
        final timelineTopLeft = timeline.localToGlobal(Offset.zero);
        final overlayTopLeft = overlayBox.localToGlobal(Offset.zero);
        final origin = timelineTopLeft - overlayTopLeft;
        final pointerLocal = timeline.globalToLocal(frame.latestGlobalPointer);
        final candidateY = PlannerTimelineGeometry.yForMinute(
          minute: frame.currentStartMinute,
          visibleStartMinute: kPlannerCivilDayStartMinute,
          hourHeight: hourHeight,
        );
        final ghostWidth = math.min(
          session.ghostSize.width,
          math.max(
            1.0,
            timeline.size.width -
                PlannerCurrentTimeHorizontalGeometry.timeColumnWidth,
          ),
        );
        final desiredLeft = (pointerLocal.dx) - session.grabOffset.dx;
        final ghostTop = origin.dy + candidateY;
        final ghostHeight = math.min(
          session.ghostSize.height,
          math.max(1.0, timelineHeight - candidateY),
        );
        const indicatorHeight = 24.0;
        final indicatorTop = (candidateY - indicatorHeight / 2)
            .clamp(0.0, math.max(0.0, timelineHeight - indicatorHeight))
            .toDouble();
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // Candidate drag-time label (R7-01: time text only).
            Positioned(
              key: const Key('planner-drag-time-indicator'),
              left: origin.dx,
              top: origin.dy + indicatorTop,
              width: PlannerCurrentTimeHorizontalGeometry.timeColumnWidth - 4,
              height: indicatorHeight,
              child: IgnorePointer(
                child: Text(
                  formatPlannerEventMinute(
                    frame.currentStartMinute,
                    use24HourTime,
                  ),
                  key: const Key('planner-drag-time-label'),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            // Frozen drag-start snapshot ghost (R7-02).
            Positioned(
              key: const Key('planner-saved-event-drag-ghost'),
              left: origin.dx + desiredLeft,
              top: ghostTop,
              width: ghostWidth,
              height: ghostHeight,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: Opacity(
                    opacity: 0.8,
                    child: _TimelineEventBlock(
                      event: session.event,
                      provisional: false,
                      eventColorsByTypeId: eventColorsByTypeId,
                      use24HourTime: use24HourTime,
                      displayStartMinute: session.originalStartMinute,
                      displayEndMinute: session.originalEndMinute,
                      awaitingReport: session.event.isAwaitingReport(
                        DateTime.now(),
                      ),
                      selectionMode: false,
                      selected: false,
                      selectedForDirectManipulation: false,
                      onToggleSelection: () {},
                      interactive: false,
                      onTap: () {},
                      onDirectPointerDown: (_) {},
                      onMoveStart: (_) {},
                      onMoveUpdate: (_) {},
                      onLongPressMoveUpdate: (_) {},
                      onMoveEnd: () {},
                      onMoveCancel: () {},
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// R7-04: apply the optimistic pending-move projection to the selected
  /// day's timed Event list at render input. Replaces the moved occurrence
  /// by identity (never duplicates it) and renders it at the candidate
  /// minutes until the canonical refresh lands.
  List<PlannerCalendarItem> _applyPendingMoveProjection(
    List<PlannerCalendarItem> events,
    PlannerDate selectedDate,
  ) {
    final pending = _pendingMoveProjection;
    if (pending == null || pending.targetDate != selectedDate) {
      return events;
    }
    final others = events
        .where((event) => event.id != pending.event.id)
        .toList(growable: false);
    final projected = PlannerCalendarItem(
      id: pending.event.id,
      title: pending.event.title,
      date: pending.targetDate,
      timing: pending.event.timing,
      state: pending.event.state,
      requiresReport: pending.event.requiresReport,
      hasOutcomeReport: pending.event.hasOutcomeReport,
      startLocal: DateTime(
        selectedDate.year,
        selectedDate.month,
        selectedDate.day,
        pending.startMinute ~/ 60,
        pending.startMinute % 60,
      ),
      endLocal: DateTime(
        selectedDate.year,
        selectedDate.month,
        selectedDate.day,
        pending.endMinute ~/ 60,
        pending.endMinute % 60,
      ),
      startUtc: pending.event.startUtc,
      endUtc: pending.event.endUtc,
      locationText: pending.event.locationText,
      isRecurring: pending.event.isRecurring,
      replacementId: pending.event.replacementId,
      linkedTaskIds: pending.event.linkedTaskIds,
      eventId: pending.event.eventId,
      originalDate: pending.event.originalDate,
      timeZoneId: pending.event.timeZoneId,
      displayTimeZoneId: pending.event.displayTimeZoneId,
      activityTypeId: pending.event.activityTypeId,
      activityTypeLabel: pending.event.activityTypeLabel,
      activityTypeColorValue: pending.event.activityTypeColorValue,
      isBackupAppointment: pending.event.isBackupAppointment,
      backupForEventId: pending.event.backupForEventId,
    );
    return <PlannerCalendarItem>[...others, projected];
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    PlannerState state,
    PlannerSettings settings,
    Map<String, EventColorPreference> eventColorsByTypeId,
  ) {
    final day = state.day;
    final provisionalDraft = ref.watch(plannerEventCreationDraftProvider);
    final taskDraft = ref.watch(plannerTaskCreationDraftProvider);
    final tapMarker = ref.watch(plannerTapMarkerProvider);
    final canonicalDayCacheRevision = ref
        .read(plannerControllerProvider.notifier)
        .dayCacheRevision;
    if (_lastObservedDayCacheRevision != canonicalDayCacheRevision) {
      // The controller just invalidated its canonical day cache (refresh,
      // same-date reload, or confirmed pending deletion). The retained preview
      // signature belongs to that older canonical generation, so force the next
      // build to start a fresh preview window. The per-date snapshots are
      // deliberately NOT cleared: they keep the columns painted (no blank
      // pop-in, S1B-06) while the new window resolves and replaces each date
      // with its post-invalidation snapshot. Without this, a change confined to
      // an ADJACENT day is invisible to the pager — S1B-04 preserves the
      // selected day's object identity when its content is semantically
      // identical, so neither `_dataRevision` nor `_dayContentSignature(day)`
      // would move and the preview future is never re-created.
      _lastObservedDayCacheRevision = canonicalDayCacheRevision;
      _previewSignature = null;
      _dataRevision += 1;
    }
    if (_lastObservedEventDeletionRevision != state.eventDeletionRevision) {
      // R6-08: the screen owns an additional retained preview cache beyond the
      // PlannerController's bounded canonical cache. Drop it on every pending-
      // deletion transition so a previously completed FutureBuilder snapshot
      // can never repaint a deleted occurrence after its tombstone clears.
      _lastObservedEventDeletionRevision = state.eventDeletionRevision;
      _previewDayCache.clear();
      _previewSignature = null;
      _previousDayContentSignature = null;
      _nextDayContentSignature = null;
      _dataRevision += 1;
    }
    final dragSession = _crossDateDrag;
    if (state.status == PlannerLoadStatus.loading && day == null) {
      return _buildLoadingDayContent(context, ref, state, settings);
    }
    if (state.status == PlannerLoadStatus.failure && day == null) {
      return _PlannerFailure(
        message: state.message ?? 'Planner data could not be opened.',
        onRetry: () => ref
            .read(plannerControllerProvider.notifier)
            .selectDate(state.selectedDate),
      );
    }
    if (day == null) {
      return const SizedBox.shrink();
    }
    if (_presentation != PlannerPresentation.day) {
      return _buildAlternatePresentation(context, ref, state, settings, day);
    }
    _scheduleInitialScroll(
      selectedDate: state.selectedDate,
      settings: settings,
      timedEvents: day.timedEvents,
    );
    _scheduleTaskDraftReveal(
      draft: taskDraft,
      selectedDate: state.selectedDate,
      settings: settings,
    );

    // Invalidate the preview window only when the authoritative selected
    // date/day changes. Unrelated Planner rebuilds retain the same Future
    // instance and page keys.
    if (_lastObservedSelectedDate != state.selectedDate ||
        !identical(_lastObservedDay, day)) {
      _dataRevision += 1;
      _lastObservedSelectedDate = state.selectedDate;
      _lastObservedDay = day;
    }

    // Three-day read-only preview state for the interactive
    // day pager. The previous/next trio is loaded once per
    // relevant signature change (selected-date change OR a
    // relevant data refresh on the selected day) so a date
    // navigation does not double-fetch. `state.day` keeps
    // driving the centered current page; the preview columns
    // only consume the previous/next slots from the resolved
    // FutureBuilder snapshot for read-only painting. The
    // selected-day slot is intentionally never read from the
    // preview load: the centered current page continues to
    // render the authoritative current Planner state. This
    // avoids duplicate repository caches and bypasses any
    // future drift between the preview store and the
    // authoritative state.
    //
    // The `today` value is read once per build and is the
    // authoritative "is this page today" anchor for the
    // centered indicator and the preview columns. The
    // source is watched (not just read) so a midnight roll
    // — production's system source ticks at midnight,
    // tests inject a mutable source — propagates a single
    // rebuild that re-evaluates `today` and re-seats the
    // indicator ownership across the three pages.
    final today = ref.watch(plannerDateSourceProvider).today();
    final previousDate = state.selectedDate.addDays(-1);
    final nextDate = state.selectedDate.addDays(1);
    final previousSig = _previousDayContentSignature;
    final nextSig = _nextDayContentSignature;
    final previewSignature =
        'pager:'
        '${state.selectedDate.iso8601}:'
        'r$_dataRevision:'
        '${_dayContentSignature(day)}:'
        'p${previousSig ?? "_"}:'
        'n${nextSig ?? "_"}:'
        'h${settings.timelineHourHeight.toStringAsFixed(2)}:'
        'v${settings.visibleStartHour}-${settings.visibleEndHour}:'
        't${settings.use24HourTime ? 1 : 0}:'
        'c${settings.showCurrentTime ? 1 : 0}:'
        'x${settings.showCancelledItems ? 1 : 0}:'
        'f${settings.contentFilters.hashCode}';
    if (_previewSignature != previewSignature) {
      _previewSignature = previewSignature;
      // S1B-06: seed the presentation preview cache from the controller's
      // canonical cache BEFORE starting the new preview future, so a date
      // already available in the controller cache renders immediately
      // (no blank/pop-in for an already-known date while the future churns).
      // Dates still missing from the controller cache resolve normally from
      // the future and are folded in below.
      final controller = ref.read(plannerControllerProvider.notifier);
      final cachedPrevious = controller.cachedDay(previousDate);
      final cachedNext = controller.cachedDay(nextDate);
      if (cachedPrevious != null) {
        _previewDayCache[previousDate] = cachedPrevious;
      }
      if (cachedNext != null) {
        _previewDayCache[nextDate] = cachedNext;
      }
      // Capture the generation that THIS future was started
      // with. The FutureBuilder adopts the result only if the
      // generation still matches the most recent build's
      // generation at completion time. This is the
      // stale-future protection: an older in-flight future
      // cannot overwrite a newer window.
      final startGeneration = _dataRevision;
      _previewGeneration = startGeneration;
      final loadSerial = ++_previewLoadSerial;
      _activePreviewLoadSerial = loadSerial;
      _previewLoad = ref
          .read(plannerControllerProvider.notifier)
          .readDays(<PlannerDate>[previousDate, state.selectedDate, nextDate])
          .then((days) {
            // Validate the result against the active generation
            // before exposing it to the FutureBuilder. The capture
            // is a synchronous microtask after the future
            // resolves, so it never builds widget state mid-frame.
            if (_previewGeneration == startGeneration &&
                _activePreviewLoadSerial == loadSerial) {
              _previousDayContentSignature = _dayContentSignature(days[0]);
              _nextDayContentSignature = _dayContentSignature(days[2]);
              // Fold the freshly resolved days into the per-date
              // preview cache. Lookups are keyed by each day's own
              // `selectedDate`, so a stale or racing result can
              // never paint one date's Events under another date's
              // page key, and a date read once keeps its correct
              // snapshot while a newer window is in flight.
              for (final resolved in days) {
                _previewDayCache[resolved.selectedDate] = resolved;
              }
            }
            return _PlannerPreviewWindow(serial: loadSerial, days: days);
          });
    }

    final hourHeight =
        _liveTimelineHourHeight.value ?? settings.timelineHourHeight;
    // The timeline canvas always spans the full civil day so times
    // outside the configured planning window remain reachable (PMG
    // parity). The configured window is a soft planning window used
    // for the default initial scroll position and the maximum
    // zoom-out fit target; it no longer clips the canvas.
    final slotCount = kPlannerCivilDayEndHour - kPlannerCivilDayStartHour;
    final timelineHeight = slotCount * hourHeight;
    // The timeline content is exactly bounded: the final civil-day
    // 12 AM boundary (plus the small [kPlannerTimelineBottomBoundaryExtent]
    // spacer that follows it) is the last scrollable content. The shell
    // NavigationBar and the floating Add button live outside this
    // viewport, so no large bottom padding is needed and no black/dead
    // scroll region exists below the final boundary.

    // Refresh-indicator removed: the Planner does not support
    // pull-to-refresh. The previous RefreshIndicator intercepted
    // downward drags in the gesture arena and competed with the
    // two-finger pinch. Its onRefresh was a no-op
    // (selectDate(state.selectedDate)) and is no longer needed.
    // R7-04: the SingleChildScrollView is wrapped in a Stack so the
    // saved-drag ghost + candidate label overlay can render ABOVE the pager
    // strip (excluded from the page transform) while the day scrolls
    // underneath.
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        KeyedSubtree(
          key: _dayScrollKey,
          child: SingleChildScrollView(
            key: const Key('planner-day-scroll'),
            controller: _dayScrollController,
            // Two-pointer pinch owns the gesture; while a pinch
            // is active the timeline must not accumulate a
            // vertical scroll offset that would otherwise be
            // driven by the SingleChildScrollView's
            // VerticalDragGestureRecognizer. The dynamic swap
            // from ClampingScrollPhysics to
            // NeverScrollableScrollPhysics is driven by the
            // [_pinchCoordinator] listener installed in
            // [initState] and is the smallest coherent
            // architecture that satisfies the "two-pointer
            // pinch beats ordinary vertical scroll" contract
            // without introducing a second timeline wrapper.
            physics: _pinchCoordinator.isPinchActive
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
            child: Column(
              children: <Widget>[
                if (state.message != null) ...<Widget>[
                  _PlannerNotice(message: state.message!),
                  const SizedBox(height: 12),
                ],
                FutureBuilder<_PlannerPreviewWindow>(
                  future: _previewLoad,
                  builder: (context, snapshot) {
                    // The FutureBuilder is the single consumer of
                    // the cached preview future. While the future
                    // is in-flight the preview columns render
                    // with `null` data (an empty read-only grid);
                    // the centered current page is unaffected
                    // because it is driven by `state.day`.
                    // When the future resolves, the resolved list
                    // is fed straight into the previous/next
                    // preview columns. Stale results are dropped
                    // by the generation guard inside the future
                    // pipeline above — the FutureBuilder adopts
                    // the latest in-flight future via the
                    // signature key, and the resolution callback
                    // only updates the captured previous/next
                    // signatures when the in-flight generation
                    // still matches the active build's
                    // generation. Therefore an older in-flight
                    // future cannot overwrite the active preview
                    // when a more recent data revision has
                    // already started a newer future.
                    final previewWindow = snapshot.data;
                    final previewDays =
                        previewWindow?.serial == _activePreviewLoadSerial
                        ? previewWindow?.days
                        : null;
                    // Resolve each adjacent page's day strictly by date.
                    // Never trust list position: a page keyed for `previousDate`
                    // must receive a day whose `selectedDate` IS that date.
                    // While a new window is loading, fall back to the retained
                    // per-date cache so previously seen dates do not flash
                    // empty and no wrong-date Events ever paint.
                    PlannerDay? dayFor(PlannerDate date) {
                      if (previewDays != null) {
                        for (final resolved in previewDays) {
                          if (resolved.selectedDate == date) {
                            return ref
                                .read(plannerControllerProvider.notifier)
                                .filterPendingEventDeletions(resolved);
                          }
                        }
                      }
                      final cached = _previewDayCache[date];
                      return cached == null
                          ? null
                          : ref
                                .read(plannerControllerProvider.notifier)
                                .filterPendingEventDeletions(cached);
                    }

                    final previousDay = dayFor(previousDate);
                    final nextDay = dayFor(nextDate);
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final viewportWidth = constraints.maxWidth;
                        // R7-05: the pager strip is the only live consumer of
                        // the mid-pinch hour height. Scoping the notifier to
                        // the pager keeps pinch frames off the whole Planner
                        // screen build (app bar, date strip, header, drag
                        // overlay all stay untouched during the gesture).
                        return ValueListenableBuilder<double?>(
                          valueListenable: _liveTimelineHourHeight,
                          builder: (context, liveHourHeight, _) {
                            final stripHourHeight =
                                liveHourHeight ?? settings.timelineHourHeight;
                            final stripTimelineHeight =
                                slotCount * stripHourHeight;
                            return PlannerInteractiveDayPager(
                              key: const Key('planner-day-pager-viewport'),
                              controller: _pagerController,
                              selectedDate: state.selectedDate,
                              previousDate: previousDate,
                              nextDate: nextDate,
                              previousDay: previousDay,
                              currentDay: day,
                              nextDay: nextDay,
                              today: today,
                              settings: settings,
                              eventColorsByTypeId: eventColorsByTypeId,
                              hourHeight: stripHourHeight,
                              // S2A: offscreen prev/next previews keep the
                              // committed hour height while the pinch is live
                              // (the centered page alone follows the live
                              // scale). `_persistZoom` updates the committed
                              // value exactly once at pinch end, so the
                              // previews refresh to the final zoom before the
                              // next horizontal swipe can expose them.
                              previewHourHeight: settings.timelineHourHeight,
                              timelineHeight: stripTimelineHeight,
                              viewportWidth: viewportWidth,
                              viewportHeight: _dayViewportHeight(),
                              onSwipePointerDown:
                                  _daySwipeCoordinator.onPointerDown,
                              onSwipePointerUp:
                                  _daySwipeCoordinator.onPointerUp,
                              onSwipeCancel: _daySwipeCoordinator.claim,
                              isSwipeCancelled: () =>
                                  _daySwipeCoordinator.isExternallyCancelled,
                              preservedCurrentPageDate: dragSession?.sourceDate,
                              onPinchPointerCount: () =>
                                  _pinchCoordinator.pointerCount,
                              onPinchClearCancel: _pinchCoordinator.clearCancel,
                              onPagerCommitPrepared:
                                  _dateStripController.prepareForPagerCommit,
                              onDayChanged: (delta) async {
                                // Selection mode and overflow menus own their own
                                // gesture pipelines; day-swipe is a Day-view-only
                                // affordance and must not interfere with those
                                // interactions. The Day-view is the only context
                                // where this widget tree is built (the other
                                // presentations short-circuit above), so no extra
                                // presentation guard is required.
                                if (delta == 0) {
                                  return;
                                }
                                // S1B-03: cached pager commit handoff. When the
                                // adjacent destination is already in the
                                // controller's canonical day cache, the target
                                // date + matching day publish atomically and
                                // this future returns immediately so the pager
                                // recenters and unlocks without waiting for a
                                // canonical repository read (which continues in
                                // the background under the generation guard).
                                await ref
                                    .read(plannerControllerProvider.notifier)
                                    .moveDaysForPager(delta);
                              },
                              currentTimeListenable:
                                  _activeCurrentTimeListenable,
                              currentPage: KeyedSubtree(
                                key: const Key('timed-events-section'),
                                child: _TimedEventTimeline(
                                  events: <PlannerCalendarItem>[
                                    // R7-07 RENDER FILTER LAW: the final render
                                    // input re-filters active tombstones so a day
                                    // snapshot from before the deletion can never
                                    // paint a deleted Event, even for one frame.
                                    ..._visibleEvents(
                                      _applyPendingMoveProjection(
                                        day.timedEvents,
                                        state.selectedDate,
                                      ),
                                      settings,
                                    ).where(
                                      (event) =>
                                          (settings.showCancelledItems ||
                                              event.state !=
                                                  PlannerEventState
                                                      .cancelled) &&
                                          !ref
                                              .read(
                                                plannerControllerProvider
                                                    .notifier,
                                              )
                                              .isPendingEventDeletion(event),
                                    ),
                                    if (provisionalDraft?.date ==
                                        state.selectedDate)
                                      _provisionalPlannerItem(
                                        provisionalDraft!,
                                      ),
                                    if (taskDraft?.date == state.selectedDate)
                                      _provisionalTaskPlannerItem(taskDraft!),
                                  ],
                                  selectedDate: state.selectedDate,
                                  settings: settings,
                                  eventColorsByTypeId: eventColorsByTypeId,
                                  scrollController: _dayScrollController,
                                  onCreate: (minute) => _createTimedEvent(
                                    context,
                                    ref,
                                    state.selectedDate,
                                    minute,
                                    defaultDurationMinutes:
                                        settings.defaultDurationMinutes,
                                  ),
                                  onMove: (event, targetDate, startMinute) =>
                                      _moveEvent(
                                        ref,
                                        event,
                                        targetDate,
                                        startMinute,
                                      ),
                                  onResize: (event, startMinute, endMinute) =>
                                      _resizeEvent(
                                        ref,
                                        event,
                                        startMinute: startMinute,
                                        endMinute: endMinute,
                                      ),
                                  selectionMode: _selectionMode,
                                  selectedItems: _selectedItems,
                                  onToggleSelection: _toggleEventSelection,
                                  dragSession: dragSession,
                                  moveCompletionRevision:
                                      _savedMoveCompletionRevision,
                                  activeMoveEventId:
                                      dragSession?.ghostActive == true
                                      ? dragSession?.event.id
                                      : null,
                                  activeMoveSourceDate: dragSession?.sourceDate,
                                  activeMoveTargetDate: dragSession?.targetDate,
                                  activeMoveOriginalStartMinute:
                                      dragSession?.originalStartMinute,
                                  onMoveSessionStart: _beginCrossDateDrag,
                                  onMoveSessionCancel: _cancelCrossDateDrag,
                                  hourHeight: hourHeight,
                                  onZoomEnd: (value) =>
                                      _persistZoom(ref, settings, value),
                                  onZoomUpdate: _onZoomUpdateLive,
                                  daySwipeCoordinator: _daySwipeCoordinator,
                                  pinchCoordinator: _pinchCoordinator,
                                  currentTimeListenable:
                                      _activeCurrentTimeListenable,
                                  tapMarker: tapMarker,
                                  timelineKey: _timelineKey,
                                  tasks: _visibleTimelineTasks(day, settings),
                                  taskDraft:
                                      taskDraft?.date == state.selectedDate
                                      ? taskDraft
                                      : null,
                                  onTaskTap: (task) => showTaskPreview<void>(
                                    context: context,
                                    taskId: task.id,
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
                const SizedBox(
                  key: Key('planner-timeline-bottom-boundary'),
                  height: kPlannerTimelineBottomBoundaryExtent,
                ),
                // The form is an overlay, not a replacement Planner route.
                // While its one B7 Task draft exists, reserve only enough
                // trailing scroll extent to reveal a late fixed-height draft
                // above that form. The reserve is cleared with the draft and
                // never changes the civil-day geometry, saved Tasks, or Event
                // resize behavior.
                if (taskDraft?.date == state.selectedDate)
                  const SizedBox(
                    key: Key('planner-task-draft-visibility-reserve'),
                    height: 96,
                  ),
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: _buildSavedDragOverlay(
            hourHeight: hourHeight,
            timelineHeight: timelineHeight,
            use24HourTime: settings.use24HourTime,
            selectedDate: state.selectedDate,
            eventColorsByTypeId: eventColorsByTypeId,
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingDayContent(
    BuildContext context,
    WidgetRef ref,
    PlannerState state,
    PlannerSettings settings,
  ) {
    final hourHeight =
        _liveTimelineHourHeight.value ?? settings.timelineHourHeight;
    final timelineHeight =
        (kPlannerCivilDayEndHour - kPlannerCivilDayStartHour) * hourHeight;
    final today = ref.watch(plannerDateSourceProvider).today();
    _scheduleInitialScroll(
      selectedDate: state.selectedDate,
      settings: settings,
      timedEvents: const <PlannerCalendarItem>[],
    );

    return KeyedSubtree(
      key: _dayScrollKey,
      child: SingleChildScrollView(
        key: const Key('planner-day-scroll'),
        controller: _dayScrollController,
        physics: _pinchCoordinator.isPinchActive
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
        child: Column(
          children: <Widget>[
            SizedBox(
              key: const Key('planner-day-pager-viewport'),
              height: timelineHeight,
              child: PlannerLoadingDayTimeline(
                selectedDate: state.selectedDate,
                today: today,
                settings: settings,
                hourHeight: hourHeight,
                viewportHeight: _dayViewportHeight(),
                currentTimeListenable: _activeCurrentTimeListenable,
              ),
            ),
            const SizedBox(
              key: Key('planner-timeline-bottom-boundary'),
              height: kPlannerTimelineBottomBoundaryExtent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlternatePresentation(
    BuildContext context,
    WidgetRef ref,
    PlannerState state,
    PlannerSettings settings,
    PlannerDay selectedDay,
  ) {
    final presentation = _presentation!;
    final dates = _weekDates(state.selectedDate, settings.weekStartDay);
    final signature =
        '${dates.first.iso8601}:${settings.contentFilters.hashCode}:'
        '${_dayContentSignature(selectedDay)}';
    if (_rangeSignature != signature) {
      _rangeSignature = signature;
      _rangeLoad = ref.read(plannerControllerProvider.notifier).readDays(dates);
    }
    return FutureBuilder<List<PlannerDay>>(
      future: _rangeLoad,
      builder: (context, snapshot) {
        final days = snapshot.data ?? <PlannerDay>[selectedDay];
        if (!snapshot.hasData &&
            snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return switch (presentation) {
          PlannerPresentation.schedule => _SchedulePresentation(
            days: days,
            settings: settings,
            selectionMode: _selectionMode,
            selectedItems: _selectedItems,
            onToggleEvent: _toggleEventSelection,
            onToggleTask: _toggleTaskSelection,
          ),
          PlannerPresentation.week => _WeekPresentation(
            days: days,
            settings: settings,
            onSelected: (date) =>
                ref.read(plannerControllerProvider.notifier).selectDate(date),
          ),
          PlannerPresentation.awaitingReports => _AwaitingPresentation(
            days: days,
            settings: settings,
            selectionMode: _selectionMode,
            selectedItems: _selectedItems,
            onToggleEvent: _toggleEventSelection,
          ),
          PlannerPresentation.day => const SizedBox.shrink(),
        };
      },
    );
  }

  List<PlannerCalendarItem> _visibleEvents(
    List<PlannerCalendarItem> events,
    PlannerSettings settings,
  ) {
    final filters = settings.contentFilters;
    return events
        .where(
          (event) =>
              event.isBackupAppointment ? filters.backupEvents : filters.events,
        )
        .toList(growable: false);
  }

  /// Timed Tasks have one scheduled minute rather than an Event duration.
  /// This returns only the factual, filter-eligible Task rows that may be
  /// represented by a presentation-only 15-minute footprint in Day mode.
  /// No Task record, recurrence projection, or Contact link is changed here.
  List<PlannerTask> _visibleTimelineTasks(
    PlannerDay day,
    PlannerSettings settings,
  ) {
    final filters = settings.contentFilters;
    if (!filters.tasks) {
      return const <PlannerTask>[];
    }
    final tasks = <PlannerTask>[
      ...day.tasks.where(
        (task) =>
            task.status == PlannerTaskStatus.incomplete &&
            task.dueMinute != null,
      ),
      if (filters.completedTasks)
        ...day.completedTasks.where(
          (task) =>
              task.status == PlannerTaskStatus.completed &&
              task.dueMinute != null,
        ),
    ];
    return <String, PlannerTask>{
      for (final task in tasks) task.id: task,
    }.values.toList(growable: false);
  }

  static List<PlannerDate> _weekDates(PlannerDate date, int weekStartDay) {
    final offset = (date.weekday - weekStartDay + 7) % 7;
    final start = date.addDays(-offset);
    return List<PlannerDate>.generate(7, start.addDays);
  }

  static String _dayContentSignature(PlannerDay day) {
    return <String>[
      for (final event in <PlannerCalendarItem>[
        ...day.allDayEvents,
        ...day.timedEvents,
      ])
        '${event.id}:${event.state.name}:${event.hasOutcomeReport}',
      for (final task in <PlannerTask>[
        ...day.overdueTasks,
        ...day.tasks,
        ...day.completedTasks,
      ])
        '${task.id}:${task.status.name}',
    ].join('|');
  }

  void _toggleEventSelection(PlannerCalendarItem event) {
    setState(() {
      final selection = PlannerSelectionId(
        kind: PlannerSelectionKind.event,
        id: event.id,
      );
      _selectedItems.contains(selection)
          ? _selectedItems.remove(selection)
          : _selectedItems.add(selection);
    });
  }

  void _toggleTaskSelection(PlannerTask task) {
    setState(() {
      final selection = PlannerSelectionId(
        kind: PlannerSelectionKind.task,
        id: task.id,
      );
      _selectedItems.contains(selection)
          ? _selectedItems.remove(selection)
          : _selectedItems.add(selection);
    });
  }

  /// Forward the mid-gesture hour height to the pager strip so the
  /// scrollable extent grows in step with the timeline canvas. The
  /// override is cleared once the settings save (started by
  /// [_persistZoom]) lands, at which point the settings value equals
  /// the live height and no snap can occur.
  void _onZoomUpdateLive(double value) {
    if (_liveTimelineHourHeight.value == value) {
      return;
    }
    // R7-05: publish through the notifier so only the pager strip rebuilds
    // on pinch frames; the whole Planner no longer rebuilds per frame.
    _liveTimelineHourHeight.value = value;
  }

  Future<void> _persistZoom(
    WidgetRef ref,
    PlannerSettings settings,
    double hourHeight,
  ) async {
    await ref
        .read(eventTypeControllerProvider.notifier)
        .saveSettings(
          settings.copyWith(
            timelineHourHeight: PlannerZoomPolicy.clampAbsolute(hourHeight),
          ),
        );
    if (mounted) {
      _liveTimelineHourHeight.value = null;
    }
  }

  Future<void> _removeSelected(
    BuildContext context,
    WidgetRef ref,
    PlannerState state,
    PlannerSettings settings,
  ) async {
    final selectedItems = _selectedItems.toList(growable: false);
    final count = selectedItems.length;
    // Resolve every selected identity before the destructive confirmation is
    // shown. Once the user confirms, the complete Event tombstone set can be
    // published immediately in one coherent state update without waiting for
    // another week read.
    final days = await ref
        .read(plannerControllerProvider.notifier)
        .readDays(_weekDates(state.selectedDate, settings.weekStartDay));
    if (!mounted || !context.mounted) {
      return;
    }
    final events = <String, PlannerCalendarItem>{
      for (final day in days)
        for (final event in <PlannerCalendarItem>[
          ...day.allDayEvents,
          ...day.timedEvents,
        ])
          event.id: event,
    };
    final tasks = <String, PlannerTask>{
      for (final day in days)
        for (final task in <PlannerTask>[
          ...day.tasks,
          ...day.overdueTasks,
          ...day.completedTasks,
        ])
          task.id: task,
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove $count selected item${count == 1 ? '' : 's'}?'),
        content: const Text(
          'Events are cancelled and Tasks are cancelled independently. '
          'Links, reports, provenance, and the related record are preserved.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep items'),
          ),
          FilledButton(
            key: const Key('planner-confirm-selection-delete'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    var failed = 0;
    final selectedEvents = <PlannerCalendarItem>[];
    for (final selected in selectedItems.where(
      (selection) => selection.kind == PlannerSelectionKind.event,
    )) {
      final event = events[selected.id];
      if (event?.eventId == null || event?.originalDate == null) {
        failed += 1;
      } else {
        selectedEvents.add(event!);
      }
    }
    final planner = ref.read(plannerControllerProvider.notifier);
    final allEventTargets = PlannerEventDeletionTargetSet(
      occurrenceIds: selectedEvents.map((event) => event.id),
    );
    planner.beginPendingEventDeletion(allEventTargets);

    final successfulOccurrenceIds = <String>{};
    final failedOccurrenceIds = <String>{};
    for (final event in selectedEvents) {
      final success = await ref
          .read(calendarEventControllerProvider.notifier)
          .cancelEvent(
            eventId: event.eventId!,
            originalDate: event.originalDate!,
            scope: CalendarEventEditScope.occurrence,
            operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
            refreshPlanner: false,
            managePendingDeletion: false,
          );
      (success.closesDetail ? successfulOccurrenceIds : failedOccurrenceIds)
          .add(event.id);
      if (!success.closesDetail) {
        failed += 1;
      }
    }
    if (failedOccurrenceIds.isNotEmpty) {
      planner.rollbackPendingEventDeletion(
        PlannerEventDeletionTargetSet(occurrenceIds: failedOccurrenceIds),
      );
    }
    if (successfulOccurrenceIds.isNotEmpty) {
      final canonicallyAbsent = await planner.confirmPendingEventDeletion(
        PlannerEventDeletionTargetSet(occurrenceIds: successfulOccurrenceIds),
      );
      if (!canonicallyAbsent) {
        failed += successfulOccurrenceIds.length;
      }
    }

    for (final selected in selectedItems.where(
      (selection) => selection.kind == PlannerSelectionKind.task,
    )) {
      final task = tasks[selected.id];
      if (task == null) {
        failed += 1;
        continue;
      }
      final outcome = await ref
          .read(plannerControllerProvider.notifier)
          .changeStatus(
            taskId: task.id,
            target: PlannerTaskStatus.cancelled,
            operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
            reason: 'Removed from Planner selection mode',
          );
      if (outcome != TaskStatusChangeOutcome.changed &&
          outcome != TaskStatusChangeOutcome.unchanged) {
        failed += 1;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _selectionActive = false;
      _selectedItems.clear();
      _rangeSignature = null;
    });
    await ref
        .read(plannerControllerProvider.notifier)
        .selectDate(state.selectedDate);
    if (failed > 0 && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$failed item${failed == 1 ? '' : 's'} could not be removed. '
            'Protected history was left unchanged.',
          ),
        ),
      );
    }
  }

  void _scheduleInitialScroll({
    required PlannerDate selectedDate,
    required PlannerSettings settings,
    required List<PlannerCalendarItem> timedEvents,
  }) {
    // Phase 5 — Slice D removed automatic scroll-to-current-time
    // triggered by date changes. The initial scroll only runs on
    // first mount per session; subsequent date navigation
    // (horizontal swipe, week-strip tap, Go to today, picker
    // selection) preserves the existing vertical viewport.
    //
    // The signature dedup matches every input that would justify a
    // re-scroll so we never compute the same target twice; the
    // separate one-shot [_initialScrollPerformed] flag is the
    // true gate and stays true for the lifetime of this state,
    // so date changes can never re-fire the post-frame jumpTo.
    final signature =
        '${selectedDate.iso8601}:${settings.visibleStartHour}:'
        '${settings.visibleEndHour}:${settings.initialScrollBehavior.name}';
    if (_initialScrollSignature == signature) {
      return;
    }
    _initialScrollSignature = signature;
    if (_initialScrollPerformed) {
      // Subsequent calls debounce via the signature; the
      // one-shot gate short-circuits before scheduling the
      // post-frame jumpTo that would otherwise move the
      // viewport to current-time on every date change.
      return;
    }
    _initialScrollPerformed = true;
    final starts =
        timedEvents
            .map((event) => event.startLocal)
            .whereType<DateTime>()
            .map((value) => value.hour * 60 + value.minute)
            .toList(growable: false)
          ..sort();
    final targetMinute = plannerInitialScrollMinute(
      settings: settings,
      selectedDate: selectedDate,
      now: DateTime.now(),
      firstRelevantEventMinute: starts.firstOrNull,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Slice D writes the explicit frame-deferred scroll only
      // on the very first signature occurrence. The signature
      // gate above catches every subsequent invocation, and the
      // one-shot [_initialScrollPerformed] flag covers the case
      // where the same date is re-selected later without a
      // signature change. The additional mount-time guards
      // keep the planner from jumping to current-time after
      // date navigation even if the state is briefly torn down
      // and rebuilt without a different signature.
      if (!mounted || !_initialScrollPerformed) {
        return;
      }
      if (!mounted || !_dayScrollController.hasClients) {
        return;
      }
      final timelineBox =
          _timelineKey.currentContext?.findRenderObject() as RenderBox?;
      final scrollBox =
          _dayScrollKey.currentContext?.findRenderObject() as RenderBox?;
      if (timelineBox == null || scrollBox == null) {
        return;
      }
      final timelineTop =
          timelineBox.localToGlobal(Offset.zero).dy -
          scrollBox.localToGlobal(Offset.zero).dy +
          _dayScrollController.offset;
      // The canvas starts at 00:00, so the target minute-of-day maps
      // to pixels through the current pixels-per-minute and the
      // configured start is placed near the top of the viewport.
      final pixelsPerMinute = PlannerTimelineGeometry.pixelsPerMinute(
        settings.timelineHourHeight,
      );
      final desired = (timelineTop + targetMinute * pixelsPerMinute - 120)
          .clamp(0.0, _dayScrollController.position.maxScrollExtent);
      // jumpTo() is a synchronous scroll hint that does not block
      // the gesture pipeline; call it directly. The earlier
      // unawaited() wrapper was rejected by the analyzer because
      // the bound signature returns void in this Flutter SDK.
      _dayScrollController.jumpTo(desired);
    });
  }

  /// B7 owner-physical restoration: the draft was inserted into the real
  /// timeline but a late due time sat behind the open Task form. Reveal that
  /// same canvas position without creating a second overlay, changing the
  /// fixed 15-minute geometry, or touching saved/Event viewport rules.
  void _scheduleTaskDraftReveal({
    required PlannerTaskCreationDraft? draft,
    required PlannerDate selectedDate,
    required PlannerSettings settings,
  }) {
    if (draft == null || draft.date != selectedDate) {
      _taskDraftRevealSignature = null;
      return;
    }
    final hourHeight =
        _liveTimelineHourHeight.value ?? settings.timelineHourHeight;
    final signature =
        '${draft.id}:${draft.date.iso8601}:${draft.minute}:'
        '$hourHeight';
    if (_taskDraftRevealPending || _taskDraftRevealSignature == signature) {
      return;
    }
    _taskDraftRevealSignature = signature;
    _taskDraftRevealPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _taskDraftRevealPending = false;
      if (!mounted || !_dayScrollController.hasClients) {
        return;
      }
      final current = ref.read(plannerTaskCreationDraftProvider);
      if (current == null ||
          current.id != draft.id ||
          current.date != selectedDate ||
          current.minute != draft.minute) {
        return;
      }
      final timelineBox =
          _timelineKey.currentContext?.findRenderObject() as RenderBox?;
      final scrollBox =
          _dayScrollKey.currentContext?.findRenderObject() as RenderBox?;
      if (timelineBox == null || scrollBox == null) {
        return;
      }
      final timelineTop =
          timelineBox.localToGlobal(Offset.zero).dy -
          scrollBox.localToGlobal(Offset.zero).dy +
          _dayScrollController.offset;
      final pixelsPerMinute = PlannerTimelineGeometry.pixelsPerMinute(
        hourHeight,
      );
      // Keep the small 15-minute card wholly above the open form, including
      // at high zoom where its visual center otherwise clips the sheet edge.
      final desired = (timelineTop + current.minute * pixelsPerMinute - 200)
          .clamp(0.0, _dayScrollController.position.maxScrollExtent);
      _dayScrollController.jumpTo(desired);
    });
  }

  void _createTimedEvent(
    BuildContext context,
    WidgetRef ref,
    PlannerDate selectedDate,
    int startMinute, {
    required int defaultDurationMinutes,
  }) {
    if (ref.read(plannerEventCreationDraftProvider) != null) {
      return;
    }
    // Delta 4.2D: show the generic, non-persisted Event placeholder at the
    // snapped Planner time BEFORE the Event Type selector opens. Its duration
    // follows the Planner default and clips at midnight. It is cleared when
    // the selector session ends; after type selection the type-specific
    // provisional draft has already taken over.
    final markerController = ref.read(plannerTapMarkerProvider.notifier);
    markerController.show(
      date: selectedDate,
      startMinute: startMinute,
      defaultDurationMinutes: defaultDurationMinutes,
    );
    unawaited(
      launchCalendarEventCreation<void>(
        context,
        ref,
        CalendarEventCreationContext(
          source: 'planner-timeline',
          destinationPath: RoutePaths.calendarEventCreate,
          date: selectedDate,
          startMinute: startMinute,
        ),
      ).whenComplete(markerController.clear),
    );
  }

  /// Reads the usable day-scroll viewport height safely (the position may be
  /// attached but not yet dimensioned during an early LayoutBuilder pass).
  double _dayViewportHeight() {
    if (!_dayScrollController.hasClients) {
      return 0;
    }
    try {
      return _dayScrollController.position.viewportDimension;
    } on Object {
      return 0;
    }
  }

  void _beginCrossDateDrag(
    PlannerCalendarItem event,
    int pointerId,
    Offset globalPosition,
    Offset grabOffset,
    Size ghostSize,
    int startMinute,
    int endMinute,
    int snapMinutes,
    double hourHeight,
  ) {
    // A Task footprint has no Calendar Event ID by design. It is nevertheless
    // a real saved Planner item for the shared drag session, so allow it
    // through while retaining the provisional-Event exclusion.
    if ((event.eventId == null && !event.id.startsWith('task-footprint:')) ||
        event.id.startsWith('provisional:')) {
      return;
    }
    final current = _crossDateDrag;
    if (current?.event.id == event.id && current?.pointerId == pointerId) {
      return;
    }
    _crossDateDwellTimer?.cancel();
    _crossDateDwellTimer = null;
    _crossDateDwellDirection = null;
    _removeSavedDragPointerRoute();
    _savedDragFrameNotifier.value = null;
    setState(() {
      _crossDateDrag = _CrossDateDragSession(
        pointerId: pointerId,
        event: event,
        sourceDate: event.date,
        targetDate: event.date,
        originalStartMinute: startMinute,
        originalEndMinute: endMinute,
        currentStartMinute: startMinute,
        currentEndMinute: endMinute,
        durationMinutes: endMinute - startMinute,
        grabOffset: grabOffset,
        startGlobalPointer: globalPosition,
        latestGlobalPointer: globalPosition,
        ghostSize: ghostSize,
        snapMinutes: snapMinutes,
        hourHeight: hourHeight,
        ghostActive: false,
      );
    });
    GestureBinding.instance.pointerRouter.addGlobalRoute(
      _handleSavedDragPointerEvent,
    );
    _savedDragPointerRouteRegistered = true;
  }

  void _handleSavedDragPointerEvent(PointerEvent event) {
    final session = _crossDateDrag;
    if (session == null || event.pointer != session.pointerId) {
      return;
    }
    if (event is PointerMoveEvent) {
      _updateSavedDragFromGlobal(event.position);
    } else if (event is PointerUpEvent) {
      unawaited(_finishSavedDrag());
    } else if (event is PointerCancelEvent) {
      _cancelCrossDateDrag();
    }
  }

  RenderBox? _parentTimelineRenderBox() {
    final renderObject = _timelineKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }
    return renderObject;
  }

  void _updateSavedDragFromGlobal(Offset globalPosition) {
    final session = _crossDateDrag;
    final timeline = _parentTimelineRenderBox();
    if (session == null || timeline == null) {
      return;
    }
    final ghostActive =
        session.ghostActive ||
        (globalPosition - session.startGlobalPointer).distance >= kTouchSlop;
    if (!ghostActive) {
      // Pre-slop pointer updates are invisible; retain only the pointer so
      // the drag can activate once it crosses slop.
      _savedDragFrameNotifier.value = _SavedDragFrameState(
        currentStartMinute: session.currentStartMinute,
        currentEndMinute: session.currentEndMinute,
        latestGlobalPointer: globalPosition,
      );
      return;
    }
    final pointerLocal = timeline.globalToLocal(globalPosition);
    final pixelsPerMinute = PlannerTimelineGeometry.pixelsPerMinute(
      session.hourHeight,
    );
    final rawStartMinute =
        ((pointerLocal.dy - session.grabOffset.dy) / pixelsPerMinute).round();
    // R7-02 body-drag law: candidateEnd = candidateStart + originalDuration,
    // always. No independent end calculation.
    final nextStart = snapPlannerMinute(rawStartMinute, session.snapMinutes)
        .clamp(
          kPlannerCivilDayStartMinute,
          kPlannerCivilDayEndMinute - session.durationMinutes,
        );
    // R7-05: per-frame candidate updates go to a lightweight ValueNotifier
    // consumed only by the screen-level drag overlay, so a pointer frame
    // never rebuilds the whole Planner (events, pager, lane solver, strip,
    // date header). The session's ghostActive flips once via setState.
    _savedDragFrameNotifier.value = _SavedDragFrameState(
      currentStartMinute: nextStart,
      currentEndMinute: nextStart + session.durationMinutes,
      latestGlobalPointer: globalPosition,
    );
    if (!session.ghostActive) {
      setState(() {
        _crossDateDrag = session.copyWith(ghostActive: true);
      });
    }
    _updateCrossDateIntent(globalPosition);
  }

  int? _crossDateDirectionAt(Offset globalPosition) {
    final timeline = _parentTimelineRenderBox();
    if (timeline == null) {
      return null;
    }
    final local = timeline.globalToLocal(globalPosition);
    // R7-03: the previous strip is the same-width in-viewport strip just
    // inside the Event canvas, structurally mirroring the next strip. The
    // left region spans from the physical screen edge (local x = 0, the
    // time gutter included) through the old boundary so "push the dragged
    // Event to the edge and hold" works on the left exactly like the right;
    // the RIGHT strip stays flush with the physical right edge.
    if (local.dx <= _crossDatePreviousBoundary) {
      return -1;
    }
    if (local.dx >= timeline.size.width - _crossDateNextTriggerWidth) {
      return 1;
    }
    return null;
  }

  void _updateCrossDateIntent(Offset globalPosition) {
    final session = _crossDateDrag;
    if (session == null || !session.ghostActive) {
      return;
    }
    final direction = _crossDateDirectionAt(globalPosition);
    if (session.latchedDirection != null) {
      _cancelCrossDateDwell();
      if (direction == null) {
        // Center return rearms both directions.
        setState(() {
          _crossDateDrag = session.copyWith(clearLatchedDirection: true);
        });
      } else if (direction != session.latchedDirection) {
        // R7-03: entering the OPPOSITE trigger while latched starts a fresh
        // dwell for that direction (future->current and past->current
        // reversal), removing the directional asymmetry.
        _startCrossDateDwell(direction);
      }
      return;
    }
    if (direction == null) {
      _cancelCrossDateDwell();
      return;
    }
    if (_crossDateDwellTimer != null && _crossDateDwellDirection == direction) {
      return;
    }
    _startCrossDateDwell(direction);
  }

  void _startCrossDateDwell(int direction) {
    _cancelCrossDateDwell();
    _crossDateDwellDirection = direction;
    _crossDateDwellTimer = Timer(_crossDateEdgeDwell, () {
      _crossDateDwellTimer = null;
      _crossDateDwellDirection = null;
      final active = _crossDateDrag;
      final latestPointer =
          _savedDragFrameNotifier.value?.latestGlobalPointer ??
          active?.latestGlobalPointer;
      if (!mounted ||
          active == null ||
          !active.ghostActive ||
          latestPointer == null ||
          _crossDateDirectionAt(latestPointer) != direction) {
        return;
      }
      unawaited(_advanceSavedDragDate(direction));
    });
  }

  Future<void> _advanceSavedDragDate(int dayDelta) async {
    final session = _crossDateDrag;
    if (session == null ||
        !session.ghostActive ||
        dayDelta == 0 ||
        _crossDateNavigation != null) {
      return;
    }
    final nextTarget = session.targetDate.addDays(dayDelta);
    // R7-04: a cross-date advance routes through the pager's commit path so
    // the Planner page layer animates under the finger-held ghost. The ghost
    // lives in the screen-level drag overlay and is excluded from the page
    // transform. If the pager is unavailable, fall back to a direct
    // navigation.
    final navigation =
        _pagerController.commitDayChange(dayDelta) ??
        ref.read(plannerControllerProvider.notifier).moveDays(dayDelta);
    _crossDateNavigation = navigation;
    try {
      await navigation;
    } on Object {
      // PlannerController already publishes its retry-safe failure state.
    }
    final reachedTarget =
        mounted &&
        ref.read(plannerControllerProvider).selectedDate == nextTarget &&
        ref.read(plannerControllerProvider).day?.selectedDate == nextTarget;
    final active = _crossDateDrag;
    if (reachedTarget &&
        active != null &&
        active.pointerId == session.pointerId) {
      setState(() {
        _crossDateDrag = active.copyWith(
          targetDate: nextTarget,
          latchedDirection: dayDelta,
        );
      });
    }
    if (identical(_crossDateNavigation, navigation)) {
      _crossDateNavigation = null;
    }
  }

  Future<void> _finishSavedDrag() async {
    _cancelCrossDateDwell();
    _removeSavedDragPointerRoute();
    final pendingNavigation = _crossDateNavigation;
    if (pendingNavigation != null) {
      try {
        await pendingNavigation;
      } on Object {
        // The active session below remains authoritative after a failed read.
      }
    }
    final session = _crossDateDrag;
    if (!mounted || session == null) {
      return;
    }
    final frame = _savedDragFrameNotifier.value;
    final candidateStart =
        frame?.currentStartMinute ?? session.currentStartMinute;
    final changed =
        session.ghostActive &&
        (session.targetDate != session.sourceDate ||
            candidateStart != session.originalStartMinute);
    if (!changed) {
      _savedDragFrameNotifier.value = null;
      setState(() => _crossDateDrag = null);
      return;
    }
    final candidateEnd = candidateStart + session.durationMinutes;
    // R7-04: publish an optimistic pending-move projection immediately so the
    // moved Event appears at its candidate position before the repository
    // commit completes. The projection is removed once the canonical refresh
    // lands (success) or rolled back (failure).
    _savedDragFrameNotifier.value = null;
    final isTaskFootprint = session.event.id.startsWith('task-footprint:');
    setState(() {
      _crossDateDrag = null;
      _savedMoveCompletionRevision += 1;
      // The generic optimistic projection renderer is Event-only. A Task
      // waits for its canonical repository refresh instead of ever becoming
      // a transient Event-looking block during a drag commit.
      _pendingMoveProjection = isTaskFootprint
          ? null
          : _PendingMoveProjection(
              event: session.event,
              sourceDate: session.sourceDate,
              targetDate: session.targetDate,
              startMinute: candidateStart,
              endMinute: candidateEnd,
            );
    });
    final commit = await _moveEvent(
      ref,
      session.event,
      session.targetDate,
      candidateStart,
    );
    if (!mounted) {
      return;
    }
    if (commit == null) {
      setState(() => _pendingMoveProjection = null);
      if (session.targetDate != session.sourceDate) {
        await ref
            .read(plannerControllerProvider.notifier)
            .selectDate(session.sourceDate);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Event time was not changed. The original time is restored.',
            ),
          ),
        );
      }
      return;
    }
    setState(() => _pendingMoveProjection = null);
    if (mounted) {
      _showPlannerMoveUndoCard(
        context,
        startMinute: candidateStart,
        use24HourTime: ref
            .read(eventTypeControllerProvider)
            .settings
            .use24HourTime,
        commit: commit,
      );
    }
  }

  void _cancelCrossDateDwell() {
    _crossDateDwellTimer?.cancel();
    _crossDateDwellTimer = null;
    _crossDateDwellDirection = null;
  }

  void _removeSavedDragPointerRoute() {
    if (!_savedDragPointerRouteRegistered) {
      return;
    }
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handleSavedDragPointerEvent,
    );
    _savedDragPointerRouteRegistered = false;
  }

  void _cancelCrossDateDrag() {
    final session = _crossDateDrag;
    if (session == null) {
      return;
    }
    _cancelCrossDateDwell();
    _removeSavedDragPointerRoute();
    _savedDragFrameNotifier.value = null;
    setState(() {
      _crossDateDrag = null;
      _savedMoveCompletionRevision += 1;
    });
    if (session.targetDate != session.sourceDate ||
        ref.read(plannerControllerProvider).selectedDate !=
            session.sourceDate) {
      final restore = ref
          .read(plannerControllerProvider.notifier)
          .selectDate(session.sourceDate);
      _crossDateNavigation = restore;
      unawaited(
        restore.whenComplete(() {
          if (identical(_crossDateNavigation, restore)) {
            _crossDateNavigation = null;
          }
        }),
      );
    }
  }

  Future<_TimelineMoveCommit?> _moveEvent(
    WidgetRef ref,
    PlannerCalendarItem event,
    PlannerDate targetDate,
    int startMinute,
  ) async {
    if (event.id.startsWith('task-draft:')) {
      final draftId = event.id.substring('task-draft:'.length);
      final draft = ref.read(plannerTaskCreationDraftProvider);
      if (draft == null || draft.id != draftId) {
        return null;
      }
      final controller = ref.read(plannerTaskCreationDraftProvider.notifier);
      controller.updateDate(targetDate);
      controller.updateMinute(startMinute);
      return _TimelineMoveCommit(undo: () async => false);
    }
    // A Task footprint is a presentation-only item.  Re-read the real Task
    // before saving so the drag changes only its schedule and preserves the
    // current Task's stable identity, status, content, recurrence, and links.
    if (event.id.startsWith('task-footprint:')) {
      final taskId = event.id.substring('task-footprint:'.length);
      final controller = ref.read(plannerControllerProvider.notifier);
      final task = await controller.readTask(taskId);
      if (task == null || task.recurrence != PlannerTaskRecurrence.none) {
        return null;
      }
      final previousDate = task.dueDate;
      final previousMinute = task.dueMinute;
      final saved = await controller.saveTask(
        PlannerTaskDraft(
          id: task.id,
          title: task.title,
          notes: task.notes,
          dueDate: targetDate,
          dueMinute: startMinute,
          recurrence: task.recurrence,
          requiresReport: task.requiresReport,
          contributionRuleKey: task.contributionRuleKey,
          people: task.people,
          linkedActivityTypeId: task.linkedActivityTypeId,
          linkedActivityTypeStableKey: task.linkedActivityTypeStableKey,
          linkedActivityTypeLabelSnapshot: task.linkedActivityTypeLabelSnapshot,
          goalId: task.goalId,
        ),
      );
      if (!saved) {
        return null;
      }
      return _TimelineMoveCommit(
        undo: () async {
          if (previousDate == null) {
            return false;
          }
          return controller.saveTask(
            PlannerTaskDraft(
              id: task.id,
              title: task.title,
              notes: task.notes,
              dueDate: previousDate,
              dueMinute: previousMinute,
              recurrence: task.recurrence,
              requiresReport: task.requiresReport,
              contributionRuleKey: task.contributionRuleKey,
              people: task.people,
              linkedActivityTypeId: task.linkedActivityTypeId,
              linkedActivityTypeStableKey: task.linkedActivityTypeStableKey,
              linkedActivityTypeLabelSnapshot:
                  task.linkedActivityTypeLabelSnapshot,
              goalId: task.goalId,
            ),
          );
        },
      );
    }
    if (event.eventId == null && event.id.startsWith('provisional:')) {
      final draft = ref.read(plannerEventCreationDraftProvider);
      final start = event.startLocal;
      final end = event.endLocal;
      if (draft == null ||
          event.id != 'provisional:${draft.id}' ||
          start == null ||
          end == null) {
        return null;
      }
      final duration = end.difference(start).inMinutes;
      ref
          .read(plannerEventCreationDraftProvider.notifier)
          .updateTimes(
            startMinute: startMinute,
            endMinute: startMinute + duration,
          );
      return _TimelineMoveCommit(undo: () async => false);
    }
    final pendingNavigation = _crossDateNavigation;
    if (pendingNavigation != null) {
      await pendingNavigation;
    }
    final session = _crossDateDrag?.event.id == event.id
        ? _crossDateDrag
        : null;
    final sourceEvent = session?.event ?? event;
    final start = sourceEvent.startLocal;
    final end = sourceEvent.endLocal;
    if (start == null || end == null) {
      _cancelCrossDateDrag();
      return null;
    }
    final sourceDate = session?.sourceDate ?? sourceEvent.date;
    final resolvedTargetDate = session?.targetDate ?? targetDate;
    final originalStartMinute =
        session?.originalStartMinute ?? start.hour * 60 + start.minute;
    final originalEndMinute =
        session?.originalEndMinute ?? plannerEndMinuteOfDay(start, end);
    final duration = originalEndMinute - originalStartMinute;
    if (resolvedTargetDate == sourceDate && !sourceEvent.isRecurring) {
      final saved = await _persistTimelineEdit(
        ref,
        sourceEvent,
        startMinute: startMinute,
        endMinute: (startMinute + duration).clamp(1, 1440),
      );
      if (!saved) {
        _cancelCrossDateDrag();
        return null;
      }
      if (mounted && _crossDateDrag != null) {
        setState(() => _crossDateDrag = null);
      }
      return _TimelineMoveCommit(
        undo: () => _persistTimelineEdit(
          ref,
          sourceEvent,
          startMinute: originalStartMinute,
          endMinute: originalEndMinute,
        ),
      );
    }
    final commit = await _persistTimelineMove(
      ref,
      sourceEvent,
      sourceDate: sourceDate,
      targetDate: resolvedTargetDate,
      originalStartMinute: originalStartMinute,
      originalEndMinute: originalEndMinute,
      startMinute: startMinute,
      endMinute: (startMinute + duration).clamp(1, 1440),
    );
    if (commit == null) {
      _cancelCrossDateDrag();
    } else {
      if (mounted && _crossDateDrag != null) {
        setState(() => _crossDateDrag = null);
      }
      if (mounted && commit.plannerRefreshPending) {
        await ref.read(plannerControllerProvider.notifier).refresh();
      }
    }
    return commit;
  }

  Future<_TimelineMoveCommit?> _persistTimelineMove(
    WidgetRef ref,
    PlannerCalendarItem event, {
    required PlannerDate sourceDate,
    required PlannerDate targetDate,
    required int originalStartMinute,
    required int originalEndMinute,
    required int startMinute,
    required int endMinute,
  }) async {
    final eventId = event.eventId;
    final originalDate = event.originalDate;
    if (eventId == null ||
        originalDate == null ||
        endMinute <= startMinute ||
        endMinute > kPlannerCivilDayEndMinute) {
      return null;
    }
    final controller = ref.read(calendarEventControllerProvider.notifier);
    final existing = await controller.readEventDraft(eventId);
    if (existing == null) {
      return null;
    }
    final scope = event.isRecurring
        ? await _selectTimelineEditScope(originalDate)
        : CalendarEventEditScope.occurrence;
    if (!mounted || scope == null) {
      return null;
    }
    if (targetDate == sourceDate) {
      final saved = await controller.editEvent(
        eventId: eventId,
        originalDate: originalDate,
        scope: scope,
        draft: _timelineEditDraft(
          existing: existing,
          event: event,
          scope: scope,
          startMinute: startMinute,
          endMinute: endMinute,
        ),
        operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
      );
      if (!saved) {
        return null;
      }
      return _TimelineMoveCommit(
        undo: () => controller.editEvent(
          eventId: eventId,
          originalDate: originalDate,
          scope: scope,
          draft: _timelineEditDraft(
            existing: existing,
            event: event,
            scope: scope,
            startMinute: originalStartMinute,
            endMinute: originalEndMinute,
          ),
          operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
        ),
      );
    }

    if (!event.isRecurring) {
      final moved = existing.copyWith(
        id: eventId,
        title: event.title,
        startDate: targetDate,
        startMinute: startMinute,
        endMinute: endMinute,
        isBackupAppointment: event.isBackupAppointment,
        backupForEventId: event.backupForEventId,
      );
      final saved = await controller.editEvent(
        eventId: eventId,
        originalDate: originalDate,
        scope: CalendarEventEditScope.occurrence,
        draft: moved,
        operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
        refreshPlanner: false,
      );
      if (!saved) {
        return null;
      }
      return _TimelineMoveCommit(
        plannerRefreshPending: true,
        undo: () => controller.editEvent(
          eventId: eventId,
          originalDate: targetDate,
          scope: CalendarEventEditScope.occurrence,
          draft: existing.copyWith(
            id: eventId,
            startDate: sourceDate,
            startMinute: originalStartMinute,
            endMinute: originalEndMinute,
          ),
          operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
        ),
      );
    }

    final replacementId = ref.read(plannerIdentifierSourceProvider).nextUuid();
    final replacement = _crossDateMoveDraft(
      existing: existing,
      event: event,
      scope: scope,
      replacementId: replacementId,
      sourceDate: sourceDate,
      targetDate: targetDate,
      startMinute: startMinute,
      endMinute: endMinute,
    );
    final saved = await controller.rescheduleEvent(
      eventId: eventId,
      originalDate: originalDate,
      scope: scope,
      replacement: replacement,
      operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
      refreshPlanner: false,
    );
    if (!saved) {
      return null;
    }

    return _TimelineMoveCommit(
      plannerRefreshPending: true,
      undo: () {
        final undoReplacementId = ref
            .read(plannerIdentifierSourceProvider)
            .nextUuid();
        if (event.isRecurring && scope == CalendarEventEditScope.occurrence) {
          return controller.rescheduleEvent(
            eventId: eventId,
            originalDate: originalDate,
            scope: scope,
            replacement: existing.copyWith(
              id: undoReplacementId,
              title: event.title,
              startDate: sourceDate,
              startMinute: originalStartMinute,
              endMinute: originalEndMinute,
              isBackupAppointment: event.isBackupAppointment,
              backupForEventId: event.backupForEventId,
            ),
            operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
          );
        }
        final inverse = switch (scope) {
          CalendarEventEditScope.occurrence => existing.copyWith(
            id: undoReplacementId,
            startDate: sourceDate,
            startMinute: originalStartMinute,
            endMinute: originalEndMinute,
          ),
          CalendarEventEditScope.thisAndFuture => existing.copyWith(
            id: undoReplacementId,
            startDate: sourceDate,
            startMinute: originalStartMinute,
            endMinute: originalEndMinute,
          ),
          CalendarEventEditScope.series => existing.copyWith(
            id: undoReplacementId,
          ),
        };
        return controller.rescheduleEvent(
          eventId: replacementId,
          originalDate: targetDate,
          scope: scope,
          replacement: inverse,
          operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
        );
      },
    );
  }

  CalendarEventDraft _timelineEditDraft({
    required CalendarEventDraft existing,
    required PlannerCalendarItem event,
    required CalendarEventEditScope scope,
    required int startMinute,
    required int endMinute,
  }) {
    final originalDate = event.originalDate!;
    return switch (scope) {
      CalendarEventEditScope.occurrence => existing.copyWith(
        startDate: originalDate,
        startMinute: startMinute,
        endMinute: endMinute,
        title: event.title,
        isBackupAppointment: event.isBackupAppointment,
        backupForEventId: event.backupForEventId,
      ),
      CalendarEventEditScope.series => _seriesTimelineDraft(
        existing: existing,
        event: event,
        startMinute: startMinute,
        endMinute: endMinute,
      ),
      CalendarEventEditScope.thisAndFuture => existing.copyWith(
        startDate: originalDate,
        startMinute: startMinute,
        endMinute: endMinute,
      ),
    };
  }

  CalendarEventDraft _crossDateMoveDraft({
    required CalendarEventDraft existing,
    required PlannerCalendarItem event,
    required CalendarEventEditScope scope,
    required String replacementId,
    required PlannerDate sourceDate,
    required PlannerDate targetDate,
    required int startMinute,
    required int endMinute,
  }) {
    return switch (scope) {
      CalendarEventEditScope.occurrence => existing.copyWith(
        id: replacementId,
        title: event.title,
        startDate: targetDate,
        startMinute: startMinute,
        endMinute: endMinute,
        isBackupAppointment: event.isBackupAppointment,
        backupForEventId: event.backupForEventId,
      ),
      CalendarEventEditScope.thisAndFuture => existing.copyWith(
        id: replacementId,
        startDate: targetDate,
        startMinute: startMinute,
        endMinute: endMinute,
      ),
      CalendarEventEditScope.series =>
        _seriesTimelineDraft(
          existing: existing,
          event: event,
          startMinute: startMinute,
          endMinute: endMinute,
        ).copyWith(
          id: replacementId,
          startDate: existing.startDate.addDays(
            targetDate.asLocalDate.difference(sourceDate.asLocalDate).inDays,
          ),
        ),
    };
  }

  Future<_TimelineMoveCommit?> _resizeEvent(
    WidgetRef ref,
    PlannerCalendarItem event, {
    required int startMinute,
    required int endMinute,
  }) async {
    if (event.eventId == null && event.id.startsWith('provisional:')) {
      final draft = ref.read(plannerEventCreationDraftProvider);
      if (draft == null || event.id != 'provisional:${draft.id}') {
        return null;
      }
      ref
          .read(plannerEventCreationDraftProvider.notifier)
          .updateTimes(startMinute: startMinute, endMinute: endMinute);
      return const _TimelineMoveCommit(undo: _noopTimelineUndo);
    }
    return _persistTimelineResize(
      ref,
      event,
      startMinute: startMinute,
      endMinute: endMinute,
    );
  }

  /// Delta 4.2R2 R2-04: persists a saved Event resize and returns a commit
  /// whose Undo restores the exact original start/end through the SAME
  /// scope-captured save path (no second recurrence-scope dialog on Undo).
  Future<_TimelineMoveCommit?> _persistTimelineResize(
    WidgetRef ref,
    PlannerCalendarItem event, {
    required int startMinute,
    required int endMinute,
  }) async {
    final eventId = event.eventId;
    final originalDate = event.originalDate;
    if (eventId == null ||
        originalDate == null ||
        endMinute <= startMinute ||
        endMinute > 1440) {
      return null;
    }
    final controller = ref.read(calendarEventControllerProvider.notifier);
    final existing = await controller.readEventDraft(eventId);
    if (existing == null) {
      return null;
    }
    final scope = event.isRecurring
        ? await _selectTimelineEditScope(originalDate)
        : CalendarEventEditScope.occurrence;
    if (!mounted || scope == null) {
      return null;
    }
    final originalStartMinute =
        event.startLocal!.hour * 60 + event.startLocal!.minute;
    final originalEndMinute = plannerEndMinuteOfDay(
      event.startLocal!,
      event.endLocal!,
    );
    final saved = await controller.editEvent(
      eventId: eventId,
      originalDate: originalDate,
      scope: scope,
      draft: _timelineEditDraft(
        existing: existing,
        event: event,
        scope: scope,
        startMinute: startMinute,
        endMinute: endMinute,
      ),
      operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
    );
    if (!saved) {
      return null;
    }
    return _TimelineMoveCommit(
      undo: () => controller.editEvent(
        eventId: eventId,
        originalDate: originalDate,
        scope: scope,
        draft: _timelineEditDraft(
          existing: existing,
          event: event,
          scope: scope,
          startMinute: originalStartMinute,
          endMinute: originalEndMinute,
        ),
        operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
      ),
    );
  }

  Future<bool> _persistTimelineEdit(
    WidgetRef ref,
    PlannerCalendarItem event, {
    required int startMinute,
    required int endMinute,
  }) async {
    final eventId = event.eventId;
    final originalDate = event.originalDate;
    if (eventId == null ||
        originalDate == null ||
        endMinute <= startMinute ||
        endMinute > 1440) {
      return false;
    }
    final controller = ref.read(calendarEventControllerProvider.notifier);
    final existing = await controller.readEventDraft(eventId);
    if (existing == null) {
      return false;
    }
    final scope = event.isRecurring
        ? await _selectTimelineEditScope(originalDate)
        : CalendarEventEditScope.occurrence;
    if (!mounted || scope == null) {
      return false;
    }
    final draft = switch (scope) {
      CalendarEventEditScope.occurrence => existing.copyWith(
        startDate: originalDate,
        startMinute: startMinute,
        endMinute: endMinute,
        // Owner fix: a move/resize must not drop an occurrence-scoped
        // override.  The rendered occurrence (which merges any exception
        // overrides) is the source of truth for the effective Backup state
        // and title; drafting from the master row alone would silently
        // revert a Backup toggled via "This event only" (or by an earlier
        // edit) back to normal, and would erase an occurrence title.
        title: event.title,
        isBackupAppointment: event.isBackupAppointment,
        backupForEventId: event.backupForEventId,
      ),
      CalendarEventEditScope.series => _seriesTimelineDraft(
        existing: existing,
        event: event,
        startMinute: startMinute,
        endMinute: endMinute,
      ),
      CalendarEventEditScope.thisAndFuture => existing.copyWith(
        startDate: originalDate,
        startMinute: startMinute,
        endMinute: endMinute,
      ),
    };
    final operationId = ref.read(plannerIdentifierSourceProvider).nextUuid();
    return controller.editEvent(
      eventId: eventId,
      originalDate: originalDate,
      scope: scope,
      draft: draft,
      operationId: operationId,
    );
  }

  CalendarEventDraft _seriesTimelineDraft({
    required CalendarEventDraft existing,
    required PlannerCalendarItem event,
    required int startMinute,
    required int endMinute,
  }) {
    final occurrenceStart =
        event.startLocal!.hour * 60 + event.startLocal!.minute;
    final delta = startMinute - occurrenceStart;
    final duration = endMinute - startMinute;
    final baseStart = existing.startMinute ?? startMinute;
    final nextStart = (baseStart + delta).clamp(0, 1440 - duration);
    return existing.copyWith(
      startDate: existing.startDate,
      startMinute: nextStart,
      endMinute: nextStart + duration,
    );
  }

  Future<CalendarEventEditScope?> _selectTimelineEditScope(
    PlannerDate originalDate,
  ) {
    return showDialog<CalendarEventEditScope>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('recurring-timeline-scope-dialog'),
        title: const Text('Change repeating event'),
        content: RepeatingEventScopeChoices(
          originalDate: originalDate,
          keyPrefix: 'recurring-timeline-scope',
          onSelected: (scope) => Navigator.of(dialogContext).pop(scope),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('recurring-timeline-scope-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _openCalendar() {
    if (_datePickerOpen) {
      return;
    }
    setState(() => _datePickerOpen = true);
  }

  void _closeDatePicker() {
    if (mounted && _datePickerOpen) {
      setState(() => _datePickerOpen = false);
    }
  }

  Future<void> _confirmDatePicker(
    PlannerController controller,
    DateTime date,
  ) async {
    if (!_datePickerOpen) {
      return;
    }
    setState(() => _datePickerOpen = false);
    await controller.selectDate(PlannerDate.fromDateTime(date));
  }
}

final class _PlannerPreviewWindow {
  const _PlannerPreviewWindow({required this.serial, required this.days});

  final int serial;
  final List<PlannerDay> days;
}

/// R7-05: per-frame saved-drag candidate values consumed only by the
/// screen-level drag overlay. Updated on every pointer frame via a
/// [ValueNotifier] without rebuilding the whole Planner.
final class _SavedDragFrameState {
  const _SavedDragFrameState({
    required this.currentStartMinute,
    required this.currentEndMinute,
    required this.latestGlobalPointer,
  });

  final int currentStartMinute;
  final int currentEndMinute;
  final Offset latestGlobalPointer;
}

/// R7-04: optimistic pending-move projection shown immediately at drop,
/// before the canonical repository commit completes. Same Event identity
/// (occurrence ID), same candidate date/time, no duplicate persisted Event;
/// rolled back on failure.
final class _PendingMoveProjection {
  const _PendingMoveProjection({
    required this.event,
    required this.sourceDate,
    required this.targetDate,
    required this.startMinute,
    required this.endMinute,
  });

  final PlannerCalendarItem event;
  final PlannerDate sourceDate;
  final PlannerDate targetDate;
  final int startMinute;
  final int endMinute;
}

final class _CrossDateDragSession {
  const _CrossDateDragSession({
    required this.pointerId,
    required this.event,
    required this.sourceDate,
    required this.targetDate,
    required this.originalStartMinute,
    required this.originalEndMinute,
    required this.currentStartMinute,
    required this.currentEndMinute,
    required this.durationMinutes,
    required this.grabOffset,
    required this.startGlobalPointer,
    required this.latestGlobalPointer,
    required this.ghostSize,
    required this.snapMinutes,
    required this.hourHeight,
    required this.ghostActive,
    this.latchedDirection,
  });

  final int pointerId;
  final PlannerCalendarItem event;
  final PlannerDate sourceDate;
  final PlannerDate targetDate;
  final int originalStartMinute;
  final int originalEndMinute;
  final int currentStartMinute;
  final int currentEndMinute;
  final int durationMinutes;
  final Offset grabOffset;
  final Offset startGlobalPointer;
  final Offset latestGlobalPointer;
  final Size ghostSize;
  final int snapMinutes;
  final double hourHeight;
  final bool ghostActive;
  final int? latchedDirection;

  _CrossDateDragSession copyWith({
    PlannerDate? targetDate,
    int? currentStartMinute,
    int? currentEndMinute,
    Offset? latestGlobalPointer,
    bool? ghostActive,
    int? latchedDirection,
    bool clearLatchedDirection = false,
  }) {
    return _CrossDateDragSession(
      pointerId: pointerId,
      event: event,
      sourceDate: sourceDate,
      targetDate: targetDate ?? this.targetDate,
      originalStartMinute: originalStartMinute,
      originalEndMinute: originalEndMinute,
      currentStartMinute: currentStartMinute ?? this.currentStartMinute,
      currentEndMinute: currentEndMinute ?? this.currentEndMinute,
      durationMinutes: durationMinutes,
      grabOffset: grabOffset,
      startGlobalPointer: startGlobalPointer,
      latestGlobalPointer: latestGlobalPointer ?? this.latestGlobalPointer,
      ghostSize: ghostSize,
      snapMinutes: snapMinutes,
      hourHeight: hourHeight,
      ghostActive: ghostActive ?? this.ghostActive,
      latchedDirection: clearLatchedDirection
          ? null
          : latchedDirection ?? this.latchedDirection,
    );
  }
}

final class _TimelineMoveCommit {
  const _TimelineMoveCommit({
    required this.undo,
    this.plannerRefreshPending = false,
  });

  final Future<bool> Function() undo;
  final bool plannerRefreshPending;
}

/// No-op undo used by non-persisted (provisional draft) commits: the draft
/// provider update is not a persisted transaction, so there is nothing to
/// undo at the data layer (Cancel discards the draft entirely).
Future<bool> _noopTimelineUndo() async => false;

void _showPlannerMoveUndoCard(
  BuildContext context, {
  required int startMinute,
  required bool use24HourTime,
  required _TimelineMoveCommit commit,
}) {
  final movedTo = formatPlannerEventMinute(startMinute, use24HourTime);
  final messenger = ScaffoldMessenger.of(context);
  final undoTokens = _PlannerUndoCardTokens.resolve(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const Key('planner-move-undo-card'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: undoTokens.surface,
        elevation: 8,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: BorderSide(color: undoTokens.border),
        ),
        duration: const Duration(seconds: 10),
        content: _MoveUndoSnackBarContent(
          message: 'Moved to $movedTo',
          durationSeconds: 10,
          onUndo: commit.undo,
        ),
      ),
    );
}

PlannerCalendarItem _provisionalPlannerItem(PlannerEventCreationDraft draft) {
  final midnight = DateTime(draft.date.year, draft.date.month, draft.date.day);
  return PlannerCalendarItem(
    id: 'provisional:${draft.id}',
    title: draft.title,
    date: draft.date,
    timing: PlannerEventTiming.timed,
    state: PlannerEventState.scheduled,
    requiresReport: false,
    hasOutcomeReport: false,
    startLocal: midnight.add(Duration(minutes: draft.startMinute)),
    endLocal: midnight.add(Duration(minutes: draft.endMinute)),
    originalDate: draft.date,
    activityTypeId: draft.eventTypeId,
    activityTypeLabel: draft.eventTypeLabel,
    activityTypeColorValue: draft.eventTypeColorValue,
  );
}

PlannerCalendarItem _provisionalTaskPlannerItem(
  PlannerTaskCreationDraft draft,
) {
  final midnight = DateTime(draft.date.year, draft.date.month, draft.date.day);
  return PlannerCalendarItem(
    id: 'task-draft:${draft.id}',
    title: draft.title,
    date: draft.date,
    timing: PlannerEventTiming.timed,
    state: PlannerEventState.scheduled,
    requiresReport: false,
    hasOutcomeReport: false,
    startLocal: midnight.add(Duration(minutes: draft.minute)),
    endLocal: midnight.add(
      Duration(
        minutes:
            draft.minute +
            _TimedEventTimelineState._taskDisplayFootprintMinutes,
      ),
    ),
    originalDate: draft.date,
    activityTypeId: PlannerEventColorResolver.taskStableKey,
    activityTypeColorValue: PlannerEventColorDefaults.task.accentArgb,
  );
}

enum _PlannerOverflowAction { search, schedule, day, week, tasks }

enum _TimelineResizeEdge { top, bottom }

/// Delta 4.2C direct-manipulation endpoint handle. The 44 x 44 touch target
/// enters the ordinary vertical-drag arena immediately; Flutter's normal
/// touch slop is the only activation threshold.
///
/// Delta 4.2R R7 (owner review): the VISIBLE affordance is a small
/// BetterCalendar-style edge cap — a compact 14 dp mark straddling the exact
/// endpoint, instead of the previous oversized full circle. The 44 dp touch
/// target is unchanged (the visible cap must never be inflated to reach
/// accessibility), so the visual footprint shrinks while the practical
/// hitbox stays identical.
///
/// Delta 4.2R2 R2-03 (owner override): SAVED Events render a small
/// partial-circle edge cap that visually belongs to the Event edge — a
/// half-disc whose flat side lies on the Event's top edge (START, upper
/// right) or bottom edge (END, bottom left), colored with the Event accent.
///
/// MP-06 (owner lock): the PROVISIONAL DRAFT now uses the SAME integrated
/// corner treatment instead of the former full-circle floating dot — two
/// compact corner caps at upper-right START and bottom-left END, colored
/// with the selected APP THEME COLOR (Blue theme -> blue grips, Rose theme
/// -> rose grips, invariant across the draft's Event Type accent).
/// MP-06 FINAL POLISH (owner-approved 2026-08-16): each draft cap straddles
/// the block edge by half its 14 dp size so it stays VISIBLE on the filled
/// pink provisional surface in every appearance state (a flush-inside cap
/// colored like the fill is invisible).  The 44 dp invisible hit targets and
/// the straddling draft geometry are unchanged; saved-Event caps remain
/// flush-inside and accent-colored (unchanged).
final class _DirectEndpointHandle extends StatelessWidget {
  const _DirectEndpointHandle({
    required this.hitTargetKey,
    required this.dotKey,
    required this.edge,
    required this.provisional,
    required this.accentColor,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
  });

  /// Visible edge-cap diameter in logical pixels (owner-approved 12-16 dp).
  static const double visibleCapSize = 14;

  final Key hitTargetKey;
  final Key dotKey;
  final _TimelineResizeEdge edge;
  final bool provisional;
  final Color accentColor;
  final ValueChanged<_TimelineResizeEdge> onStart;
  final void Function(_TimelineResizeEdge edge, double deltaPixels) onUpdate;
  final ValueChanged<_TimelineResizeEdge> onEnd;
  final ValueChanged<_TimelineResizeEdge> onCancel;

  @override
  Widget build(BuildContext context) {
    // Draft targets straddle the endpoint by half their 44 dp height, so the
    // block edge crosses the target at y = 22 (the invisible 44 dp hit area
    // may extend beyond the block - unchanged).  MP-06B (owner correction
    // 2026-08-17, HIGHEST AUTHORITY): the VISIBLE 14 dp caps sit FULLY
    // INSIDE the filled draft block, reusing the saved-event Corner Tab Grip
    // shape:
    //   - START (upper-right): cap top = 22, right = 0 -> the cap's top
    //     edge is flush with the block's upper-right corner and the cap
    //     extends downward inside the block;
    //   - END (bottom-left): cap top = 22 - 14 = 8, left = 0 -> the cap's
    //     bottom edge is flush with the block's lower-left corner and the
    //     cap extends upward inside the block.
    // The grip is visible because it uses colorScheme.primary while the
    // filled surface uses colorScheme.primaryContainer (contrast contract),
    // so no straddle is needed. Saved targets stay flush with the block and
    // their caps sit at the target's own corner (top: 0 / bottom: 0) -
    // saved-Event grip geometry is unchanged.
    const double draftStraddle = 44 / 2; // 22
    final isStart = edge == _TimelineResizeEdge.top;
    final isEnd = edge == _TimelineResizeEdge.bottom;
    return SizedBox(
      key: hitTargetKey,
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onVerticalDragStart: (_) {
                unawaited(HapticFeedback.selectionClick());
                onStart(edge);
              },
              onVerticalDragUpdate: (details) =>
                  onUpdate(edge, details.primaryDelta ?? 0),
              onVerticalDragEnd: (_) => onEnd(edge),
              onVerticalDragCancel: () => onCancel(edge),
            ),
          ),
          Positioned(
            top: isStart
                ? (provisional ? draftStraddle : 0)
                : provisional
                ? draftStraddle - visibleCapSize
                : null,
            bottom: isEnd && !provisional ? 0 : null,
            left: isEnd ? 0 : null,
            right: isStart ? 0 : null,
            child: IgnorePointer(
              // MP-06: the draft uses the approved integrated Corner Tab
              // Grip (compact 14 dp, accent-colored) exactly like saved
              // Events - no more floating circle.
              child: CustomPaint(
                key: dotKey,
                size: const Size.square(visibleCapSize),
                painter: _SavedEndpointCornerTabPainter(
                  topRight: isStart,
                  color: accentColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// R4-01 approved Corner Tab Grip. The path occupies the saved Event corner
/// and uses two connected scallops, so the Event and grip read as one
/// silhouette instead of a circle pasted over the edge. Bottom-left is the
/// exact 180-degree counterpart of upper-right.
final class _SavedEndpointCornerTabPainter extends CustomPainter {
  const _SavedEndpointCornerTabPainter({
    required this.topRight,
    required this.color,
  });

  final bool topRight;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (!topRight) {
      canvas
        ..translate(size.width, size.height)
        ..rotate(math.pi);
    }
    final width = size.width;
    final height = size.height;
    final tab = Path()
      ..moveTo(0, 0)
      ..lineTo(width, 0)
      ..lineTo(width, height)
      ..lineTo(width * 0.82, height)
      ..cubicTo(
        width * 0.62,
        height,
        width * 0.78,
        height * 0.62,
        width * 0.50,
        height * 0.62,
      )
      ..cubicTo(
        width * 0.18,
        height * 0.62,
        width * 0.38,
        height * 0.18,
        0,
        height * 0.18,
      )
      ..close();
    canvas.drawPath(tab, Paint()..color = color.withValues(alpha: 0.96));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SavedEndpointCornerTabPainter oldDelegate) =>
      oldDelegate.topRight != topRight || oldDelegate.color != color;
}

/// Internal descriptor for a row inside the top-bar overflow popup.
final class _OverflowEntry {
  const _OverflowEntry({
    required this.action,
    required this.label,
    required this.icon,
    this.selected = false,
  });

  final _PlannerOverflowAction action;
  final String label;
  final IconData icon;
  final bool selected;
}

/// Single row in the anchored top-bar overflow popup.
class _OverflowPopupRow extends StatelessWidget {
  const _OverflowPopupRow({required this.entry, required this.onTap});

  final _OverflowEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSelected = entry.selected;
    return InkWell(
      key: Key('planner-overflow-${entry.action.name}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(
              isSelected ? Icons.check : entry.icon,
              size: 20,
              color: isSelected ? colorScheme.primary : colorScheme.onSurface,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                entry.label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vertical-dominance ratio: a gesture whose |dy| exceeds
/// |dx| * ratio is treated as a vertical drag (Event resize or
/// timeline scroll) and is not eligible for day navigation. The
/// 1.6 ratio is wide enough that a clean horizontal sweep
/// (dy ≈ 0) commits, while an angled drag that drifts more than
/// ~60% vertical is rejected. The horizontal/vertical
/// arbitration is owned by the [_DaySwipeCoordinator]; the
/// interactive day pager in [PlannerInteractiveDayPager]
/// applies its own direction-lock + horizontal-dominance
/// contract (see [kPlannerPagerDirectionLockDistance] and
/// [kPlannerPagerHorizontalDominanceRatio] in
/// planner_interactive_day_pager.dart).
const double _daySwipeVerticalDominanceRatio = 1.6;

/// Mutable coordinator shared between the swipe detector and the
/// other gesture sources (long-press move, vertical resize drag,
/// pinch zoom) so any of them can cancel an in-progress swipe
/// candidate before it commits a day change. The coordinator lives
/// on the parent state so its lifetime spans a single swipe gesture
/// and is reset on every pointer-down.
///
/// The [addCancelListener] / [removeCancelListener] hooks are an
/// extension hook for the live day pager added in Stage B3-R1
/// Slice D3-A: when a competing recognizer (long-press move,
/// vertical resize, or pinch) calls [cancel], the pager receives
/// a callback so it can drop its in-progress drag session and
/// animate back to the centered resting position. The hook keeps
/// the pager from competing with the existing recognizers in the
/// gesture arena — the recognizer that calls [cancel] still owns
/// the pointer, and the pager simply recenters without driving
/// the live transform further.
class _DaySwipeCoordinator {
  int _pointerCount = 0;
  bool _sawMultiPointer = false;
  bool _verticalDominant = false;
  bool _externalCancel = false;
  bool _pagerClaimed = false;
  bool _preclaimedPointerDown = false;
  final List<VoidCallback> _cancelListeners = <VoidCallback>[];

  void begin() {
    _pointerCount = 0;
    _sawMultiPointer = false;
    _verticalDominant = false;
    _externalCancel = false;
    _pagerClaimed = false;
    _preclaimedPointerDown = false;
  }

  void onPointerDown() {
    // Reset the gesture state on every fresh down so a
    // sticky `_externalCancel` from a previous gesture (set
    // by the previous gesture's last `cancel()` or `claim()`
    // call) cannot suppress a new swipe candidate. The
    // count itself is then incremented for this new pointer.
    final preclaimed = _preclaimedPointerDown;
    _preclaimedPointerDown = false;
    _sawMultiPointer = false;
    _verticalDominant = false;
    _externalCancel = preclaimed;
    _pagerClaimed = false;
    _pointerCount += 1;
    if (_pointerCount >= 2) {
      _sawMultiPointer = true;
    }
  }

  /// Returns true while the gesture is still eligible to commit a
  /// day change after observing the given accumulated deltas.
  /// `dx` and `dy` are the cumulative screen deltas for the active
  /// pointer since the gesture began.
  bool onPointerMove(double dx, double dy) {
    if (_pointerCount != 1 || _externalCancel) {
      return false;
    }
    if (dy.abs() > dx.abs() * _daySwipeVerticalDominanceRatio) {
      // Vertical-dominant motion (scroll / resize / long-press
      // move) means the swipe candidate has lost; remember the
      // fact so the commit check at pointer-up also rejects
      // the gesture even if the pointer comes back to a flat
      // horizontal track.
      _verticalDominant = true;
      return false;
    }
    return true;
  }

  void onPointerUp() {
    if (_pointerCount > 0) {
      _pointerCount -= 1;
    }
  }

  /// Called by the long-press move, vertical resize drag, and pinch
  /// scale recognizers when one of them claims the gesture. The
  /// pending swipe candidate is then dropped without committing.
  /// Notifies every registered cancel listener so any live-finger
  /// observer (the interactive day pager) can recenter.
  void cancel() {
    if (_externalCancel && !_pagerClaimed) {
      return;
    }
    _externalCancel = true;
    _pagerClaimed = false;
    for (final listener in List<VoidCallback>.of(_cancelListeners)) {
      listener();
    }
  }

  /// Marks a pointer that began on an already-selected Event before the
  /// outer pager observes that same down event. If hit-test dispatch reaches
  /// the pager first, [cancel] still drops its live session; if the Event
  /// sees the down first, [onPointerDown] preserves this claim instead of
  /// resetting it as stale state from an earlier gesture.
  void preclaimPointerDown() {
    _preclaimedPointerDown = true;
    cancel();
  }

  /// Called by the interactive day pager once it has claimed
  /// the gesture for horizontal paging. Sets the same
  /// [_externalCancel] flag as [cancel] so the timeline's
  /// long-press move, vertical resize drag, and pinch scale
  /// recognizers back off, but does NOT notify the cancel
  /// listener (the pager itself) so the self-trigger does
  /// not feed back into the pager's own recenter.
  void claim() {
    _externalCancel = true;
    _pagerClaimed = true;
  }

  /// Subscribe to [cancel] notifications. The listener fires once
  /// per external-cancel transition. Subscription is intentionally
  /// minimal so the coordinator remains dependency-free.
  void addCancelListener(VoidCallback listener) {
    _cancelListeners.add(listener);
  }

  void removeCancelListener(VoidCallback listener) {
    _cancelListeners.remove(listener);
  }

  bool get isActive =>
      _pointerCount == 0 && !_sawMultiPointer && !_verticalDominant;

  bool get isExternallyCancelled => _externalCancel && !_pagerClaimed;
}

/// Mutable coordinator that tracks the Planner timeline's
/// pinch state. The timeline's pointer Listener increments /
/// decrements the active pointer count; once the count reaches
/// two, the timeline reports the gesture as a pinch and the
/// parent state can use that signal to (a) swap the parent
/// SingleChildScrollView to NeverScrollableScrollPhysics so
/// ordinary vertical scrolling cannot accumulate, (b) suppress
/// Event tap / move / resize and empty-time create handlers
/// for the duration of the pinch and one settle pump, and
/// (c) ensure the day-swipe detector has already been
/// cancelled.
///
/// The coordinator is intentionally decoupled from the
/// [_DaySwipeCoordinator]; the two share no state because
/// their lifetimes and responsibilities differ.
///
/// HOTFIX (2026-09-19) — this doc used to claim the coordinator "is reset on the
/// first pointer-down of each fresh gesture". It was not: the reset ([begin]) had
/// no call site anywhere, so a missed pointer-up/cancel left the count >= 2 for
/// good and pinned both planner scroll views to `NeverScrollableScrollPhysics`.
/// The timeline now resets the coordinator when the subtree that owns the raw
/// pointer tracking is disposed, which is the only point at which a missed event
/// is provably unrecoverable.
class _PinchCoordinator {
  int _pointerCount = 0;
  bool _externalCancel = false;
  bool _notifyScheduled = false;
  // Listeners are notified whenever the pinch state changes
  // (pointer count transitions across 2, or cancel is
  // invoked). The parent state subscribes to rebuild the
  // SingleChildScrollView with the right physics; tests can
  // also subscribe to read the live state.
  final List<VoidCallback> _listeners = <VoidCallback>[];

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  /// Drops every tracked pointer and restores ordinary scrolling.
  ///
  /// HOTFIX (2026-09-19) — this is the pinch equivalent of
  /// [_DaySwipeCoordinator]'s fresh-gesture reset, and it is what makes the
  /// suppression self-healing.
  ///
  /// `_pointerCount` is maintained ONLY by pointer-up/cancel events delivered to
  /// the timeline surface. Before this fix `begin()` existed but was never called
  /// anywhere, so a single missed up/cancel left the count >= 2 forever and pinned
  /// BOTH planner scroll views to `NeverScrollableScrollPhysics` — the reported
  /// "hanging of the app where I can't swipe it up or down" (the app stays alive;
  /// drags simply stop reaching the scrollable).
  ///
  /// The notification is deferred to the next frame so a reset can be requested
  /// from a dispose/build phase without calling back into the parent's build.
  void begin() {
    if (_pointerCount == 0 && !_externalCancel) return;
    _pointerCount = 0;
    _externalCancel = false;
    _notifyAfterFrame();
  }

  /// Notifies listeners once, on the next frame.
  void _notifyAfterFrame() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      _notify();
    });
  }

  /// Called by the timeline's pointer Listener on every
  /// pointer-down. Returns true when the pointer-down caused
  /// the gesture to transition into the pinch state, so the
  /// caller can perform one-time side effects (e.g. cancel
  /// the day-swipe, capture the pinch baseline) on the exact
  /// frame the second finger lands.
  bool onPointerDown() {
    _pointerCount += 1;
    if (_pointerCount == 2) {
      _notify();
      return true;
    }
    return false;
  }

  /// Called by the timeline's pointer Listener on every
  /// pointer-up. Returns true when the pointer-up caused the
  /// gesture to transition out of the pinch state (count
  /// drops below 2), so the caller can finalize pinch state
  /// and restore ordinary one-finger scrolling.
  bool onPointerUp() {
    if (_pointerCount > 0) {
      _pointerCount -= 1;
    }
    if (_pointerCount < 2) {
      _notify();
      return true;
    }
    return false;
  }

  /// Called by the long-press move, vertical resize drag, and
  /// pinch scale recognizers when one of them claims the
  /// gesture. The pending pinch candidate is then dropped
  /// without committing any further updates.
  void cancel() {
    if (_externalCancel) {
      return;
    }
    _externalCancel = true;
    _notify();
  }

  void clearCancel() {
    if (!_externalCancel) {
      return;
    }
    _externalCancel = false;
    _notify();
  }

  /// True while two or more pointers are on the timeline and
  /// no recognizer has claimed the gesture. The parent state
  /// uses this to swap the SingleChildScrollView to
  /// NeverScrollableScrollPhysics.
  bool get isPinchActive => _pointerCount >= 2 && !_externalCancel;

  int get pointerCount => _pointerCount;
}

final class _TimedEventTimeline extends StatefulWidget {
  const _TimedEventTimeline({
    required this.events,
    required this.selectedDate,
    required this.settings,
    required this.eventColorsByTypeId,
    required this.scrollController,
    required this.onCreate,
    required this.onMove,
    required this.onResize,
    required this.selectionMode,
    required this.selectedItems,
    required this.onToggleSelection,
    required this.dragSession,
    required this.moveCompletionRevision,
    required this.activeMoveEventId,
    required this.activeMoveSourceDate,
    required this.activeMoveTargetDate,
    required this.activeMoveOriginalStartMinute,
    required this.onMoveSessionStart,
    required this.onMoveSessionCancel,
    required this.hourHeight,
    required this.onZoomEnd,
    required this.onZoomUpdate,
    required this.daySwipeCoordinator,
    required this.pinchCoordinator,
    required this.currentTimeListenable,
    required this.tapMarker,
    required this.timelineKey,
    required this.tasks,
    required this.taskDraft,
    required this.onTaskTap,
  });

  final List<PlannerCalendarItem> events;
  final PlannerDate selectedDate;
  final PlannerSettings settings;
  final Map<String, EventColorPreference> eventColorsByTypeId;
  // Parent-owned GlobalKey attached to the timeline surface so the
  // initial-scroll routine can measure the timeline's position inside
  // the day scroll view.
  final GlobalKey timelineKey;
  // Parent-owned SingleChildScrollView controller used for focal-time
  // preservation while pinching. Held here by reference so pinch
  // updates can reposition the viewport without rebuilding the screen.
  final ScrollController scrollController;
  final void Function(int minute) onCreate;
  final Future<_TimelineMoveCommit?> Function(
    PlannerCalendarItem event,
    PlannerDate targetDate,
    int startMinute,
  )
  onMove;
  final Future<_TimelineMoveCommit?> Function(
    PlannerCalendarItem event,
    int startMinute,
    int endMinute,
  )
  onResize;
  final bool selectionMode;
  final Set<PlannerSelectionId> selectedItems;
  final ValueChanged<PlannerCalendarItem> onToggleSelection;
  final _CrossDateDragSession? dragSession;
  final int moveCompletionRevision;
  final String? activeMoveEventId;
  final PlannerDate? activeMoveSourceDate;
  final PlannerDate? activeMoveTargetDate;
  final int? activeMoveOriginalStartMinute;
  final void Function(
    PlannerCalendarItem event,
    int pointerId,
    Offset globalPosition,
    Offset grabOffset,
    Size ghostSize,
    int startMinute,
    int endMinute,
    int snapMinutes,
    double hourHeight,
  )
  onMoveSessionStart;
  final VoidCallback onMoveSessionCancel;
  final double hourHeight;
  final ValueChanged<double> onZoomEnd;
  // Live pinch hook: the parent rebuilds the pager strip with the
  // mid-gesture hour height so the scrollable extent grows in step
  // with the canvas (without it, the strip stays at the settings
  // height, clips the canvas, and the focal compensation is clamped
  // back on pointer-up).
  final ValueChanged<double> onZoomUpdate;
  // Shared coordinator that lets the timeline's pinch, long-press
  // move, and vertical resize recognizers cancel an in-progress
  // day-swipe candidate before it commits. The detector lives on
  // the parent state, so the timeline only invokes its cancel()
  // hook without owning its lifecycle.
  final _DaySwipeCoordinator daySwipeCoordinator;
  // Shared coordinator that lets the timeline surface report
  // its active pointer count to the parent so the parent can
  // swap the SingleChildScrollView to
  // NeverScrollableScrollPhysics while a two-pointer pinch is
  // in progress. The coordinator lives on the parent state so
  // its lifetime spans the entire Planner route; the timeline
  // only reports pointer-down / pointer-up events without
  // owning its lifecycle.
  final _PinchCoordinator pinchCoordinator;
  // Parent-owned current-time source. The indicator subtree
  // watches this listenable via ValueListenableBuilder so a minute
  // tick only rebuilds the indicator — not the pinch / long-press
  // / resize recognizers or the surrounding gesture surface.
  // The notifier is owned and disposed by [_PlannerScreenState];
  // tests advance it by writing to it directly.
  final ValueListenable<DateTime> currentTimeListenable;
  // Delta 4.2D: transient generic Event placeholder shown before Event Type
  // selection. Only rendered when it belongs to the selected day.
  final PlannerTapMarker? tapMarker;

  /// Filter-resolved Task rows rendered as presentation-only footprints.
  final List<PlannerTask> tasks;

  /// Planner-local unsaved Task draft. It is intentionally distinct from the
  /// accepted Event provisional provider and has no end-time/resize state.
  final PlannerTaskCreationDraft? taskDraft;
  final ValueChanged<PlannerTask> onTaskTap;

  @override
  State<_TimedEventTimeline> createState() => _TimedEventTimelineState();
}

final class _TimedEventTimelineState extends State<_TimedEventTimeline> {
  // R4-07 restores the ordinary hour-label gutter to its compact width. The
  // current-time composition is an independent full-width overlay below, so
  // long live-time labels never make every Event lane permanently narrower.
  static const double _timeColumnWidth =
      PlannerCurrentTimeHorizontalGeometry.timeColumnWidth;

  /// Minimum invisible touch height for an exact-duration Event block
  /// (combined delta): the visible block keeps its true duration-derived
  /// height while the Positioned hit area covers at least this much, so
  /// very short blocks at wide zoom-out remain tappable without any
  /// visible minimum-height inflation.
  static const double kPlannerEventMinimumTouchHeight = 24;

  /// A timed Task is a real [PlannerTask] projected into the Day canvas. Its
  /// 15-minute footprint is presentation-only: it never creates an Event row
  /// or a persisted Task-duration field.  Keeping the logical end here means
  /// the shared collision allocator and normal/high zoom geometry stay
  /// factual rather than being distorted by a Task-only visual height floor.
  static const int _taskDisplayFootprintMinutes = 15;
  // R7-06: the external free-space gap between touching Event rectangles is
  // zero; the R6-05 one-pixel inner border is the only separator. Keeping
  // this as a named constant preserves the R5 lane-width math structurally —
  // only the gap value changed from the ~2 dp lane gap.
  static const double _eventGap = 0;
  // Vertical extent of the current-time indicator Row. The Row is
  // centered on the exact current minute within the timeline, so
  // this value defines the band whose center marks the minute.
  // Tall enough to host the 11-px time label and the 8-px dot and
  // 2-px line, with crossAxisAlignment.center centering each on
  // the minute within normal logical-pixel rounding tolerance.
  static const double _currentTimeIndicatorHeight =
      PlannerCurrentTimeHorizontalGeometry.indicatorHeight;
  static const double _currentTimeDotSize =
      PlannerCurrentTimeHorizontalGeometry.dotSize;
  final Map<String, int> _previewStartMinutes = <String, int>{};
  final Map<String, int> _previewEndMinutes = <String, int>{};
  // One canonical pointer stream owns both axes. The local grab offset keeps
  // the same point of the Event under the finger across target-date rebuilds,
  // scroll movement, and lane-geometry changes.
  final Map<String, Offset> _movePointerGlobals = <String, Offset>{};
  final Map<String, Offset> _moveGrabOffsets = <String, Offset>{};
  final Map<String, int> _movePointerIds = <String, int>{};
  final Map<String, double> _resizeAccumulatedPixels = <String, double>{};
  final Set<String> _persisting = <String>{};
  String? _directManipulationEventId;
  late double _hourHeight;
  // Pinch focal-time preservation: captured at two-finger scale start
  // and reapplied on every onScaleUpdate so the time under the focal
  // point stays under the same screen-local position as hour height
  // changes. The local Y is measured from the GestureDetector origin,
  // which sits at the top of the timeline surface (inside the
  // scrollable; not the global screen). The focal content Y is the
  // pointer's position in the scrollable's content space (scroll
  // offset + local Y), so dividing by the start pixelsPerMinute gives
  // the focal minute-of-day relative to `_firstHour`.
  double? _zoomStartHeight;
  double? _zoomStartScrollOffset;
  double? _zoomFocalLocalY;
  double? _zoomFocalMinute;
  // Viewport-derived pinch clamp inputs, captured once at two-finger
  // scale start so the min/max hour-height bounds stay stable for the
  // whole gesture. The SingleChildScrollView viewport dimension is the
  // usable timeline viewport between the date strip and bottom nav;
  // the configured-hours span drives the maximum-zoom-out fit target.
  double _zoomStartViewportHeight = 0;
  int _zoomStartConfiguredHours = 24;
  // The scrollable's max extent at pinch start and the hour height it
  // was measured at. The canvas grows with the hour height, so the
  // extent used to clamp each update is derived from these two values
  // (extent grows by 24 * delta-hour-height) instead of the stale
  // live extent, which lags one layout behind the gesture and would
  // truncate the focal compensation mid-pinch.
  double _zoomStartMaxExtent = 0;
  double _zoomStartHourHeight = 0;
  // R6-04: raw pointer/scale callbacks may arrive faster than Flutter paints.
  // Retain only the latest requested zoom geometry and apply it once at the
  // start of the next frame. Pointer-up flushes the latest value before the
  // one canonical settings save, so coalescing never changes final zoom.
  double? _pendingPinchHourHeight;
  double? _pendingPinchScrollOffset;
  bool _pendingPinchHasScrollClient = false;
  bool _pinchFrameScheduled = false;

  // Pinch two-pointer priority (Stage B3-R1 Slice D2):
  //
  // The Planner timeline must give an authentic two-pointer
  // pinch authoritative priority over a one-finger vertical
  // scroll. This is achieved by tracking the active pointer
  // count from the moment the first finger lands on the
  // timeline. When the count reaches 2, the timeline switches
  // its SingleChildScrollView child to a
  // `NeverScrollableScrollPhysics()` so the vertical drag
  // recognizer cannot accumulate a scroll offset, and the
  // empty-time / Event-tap / Event-move / Event-resize
  // gesture handlers short-circuit (they observe
  // `_pinchActive` and return immediately). When the count
  // falls below 2, ordinary vertical scrolling and Event
  // interactions are restored, but only after a fresh
  // one-finger gesture begins — stale pinch state cannot
  // trigger a delayed tap or swipe.
  bool _pinchActive = false;
  final Map<int, Offset> _pinchPointerPositions = <int, Offset>{};
  double? _pinchStartDistance;
  // Settle-time buffer: after the second pointer lifts and
  // the count returns to 0 or 1, the timeline keeps the
  // suppressions active for a single pump cycle so the gesture
  // arena can fully retire the scale recognizer before a fresh
  // vertical drag or tap is honored. This prevents the
  // observed race where lifting the second finger would allow
  // the remaining finger to immediately commit a vertical
  // scroll or a tap. The buffer is one pump, not a wall-clock
  // delay, so it cannot be classified as an artificial timer.
  bool _postPinchSuppress = false;

  @override
  void initState() {
    super.initState();
    _hourHeight = PlannerZoomPolicy.clampAbsolute(widget.hourHeight);
  }

  @override
  void didUpdateWidget(covariant _TimedEventTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_zoomStartHeight == null && oldWidget.hourHeight != widget.hourHeight) {
      _hourHeight = PlannerZoomPolicy.clampAbsolute(widget.hourHeight);
    }
    final activeMoveContinues =
        widget.activeMoveEventId != null &&
        _directManipulationEventId == widget.activeMoveEventId &&
        widget.events.any((event) => event.id == widget.activeMoveEventId);
    if (oldWidget.moveCompletionRevision != widget.moveCompletionRevision ||
        widget.selectionMode ||
        (oldWidget.selectedDate != widget.selectedDate &&
            !activeMoveContinues)) {
      _directManipulationEventId = null;
      _movePointerGlobals.clear();
      _moveGrabOffsets.clear();
      _movePointerIds.clear();
      _resizeAccumulatedPixels.clear();
      _previewStartMinutes.clear();
      _previewEndMinutes.clear();
    } else if (_directManipulationEventId case final selectedId?
        when !_hasTimelineItem(selectedId)) {
      _directManipulationEventId = null;
      _movePointerGlobals.remove(selectedId);
      _moveGrabOffsets.remove(selectedId);
      _movePointerIds.remove(selectedId);
      _resizeAccumulatedPixels.remove(selectedId);
      _previewStartMinutes.remove(selectedId);
      _previewEndMinutes.remove(selectedId);
    }
  }

  @override
  void dispose() {
    _pendingPinchHourHeight = null;
    _pendingPinchScrollOffset = null;
    // HOTFIX (2026-09-19): this subtree is the ONLY owner of the raw pointer
    // tracking that feeds [_PinchCoordinator]. Once it is gone — planner refresh,
    // loading/loaded branch swap, day-pager swap, route change — any pointer-up or
    // cancel it never received is unrecoverable here, and the stale count would
    // otherwise keep the whole Planner unscrollable forever. Drop it so the parent
    // re-reads the scroll physics on the next frame.
    widget.pinchCoordinator.begin();
    super.dispose();
  }

  bool _isProvisionalEvent(PlannerCalendarItem event) =>
      (event.eventId == null && event.id.startsWith('provisional:')) ||
      _isTaskDraft(event);

  bool _isTaskFootprint(PlannerCalendarItem event) =>
      event.id.startsWith('task-footprint:');

  bool _isTaskDraft(PlannerCalendarItem event) =>
      event.id.startsWith('task-draft:');

  bool _hasTimelineItem(String id) =>
      widget.events.any((event) => event.id == id) ||
      widget.tasks.any((task) => id == 'task-footprint:${task.id}') ||
      id == 'task-draft:${widget.taskDraft?.id}';

  List<PlannerCalendarItem> _taskFootprints() {
    final midnight = DateTime(
      widget.selectedDate.year,
      widget.selectedDate.month,
      widget.selectedDate.day,
    );
    return widget.tasks
        .where((task) => task.dueMinute != null)
        .map((task) {
          final minute = task.dueMinute!;
          return PlannerCalendarItem(
            id: 'task-footprint:${task.id}',
            title: task.title,
            date: widget.selectedDate,
            timing: PlannerEventTiming.timed,
            state: PlannerEventState.scheduled,
            requiresReport: false,
            hasOutcomeReport: false,
            startLocal: midnight.add(Duration(minutes: minute)),
            // The allocator retains the locked presentation-only interval.
            // The shared allocator receives the owner-locked 15-minute Task
            // footprint. It is independent of the persisted due minute.
            endLocal: midnight.add(
              Duration(minutes: minute + _taskDisplayFootprintMinutes),
            ),
            // This stable key is deliberately not a linked Event Type.
            activityTypeId: PlannerEventColorResolver.taskStableKey,
            activityTypeColorValue: PlannerEventColorDefaults.task.accentArgb,
          );
        })
        .toList(growable: false);
  }

  bool _isDirectlySelected(PlannerCalendarItem event) =>
      _isProvisionalEvent(event) || _directManipulationEventId == event.id;

  bool _deselectDirectManipulation() {
    if (_directManipulationEventId == null) {
      return false;
    }
    setState(() {
      _directManipulationEventId = null;
      _movePointerGlobals.clear();
      _moveGrabOffsets.clear();
      _movePointerIds.clear();
      _resizeAccumulatedPixels.clear();
      _previewStartMinutes.clear();
      _previewEndMinutes.clear();
    });
    if (widget.activeMoveEventId != null) {
      widget.onMoveSessionCancel();
    }
    return true;
  }

  void _handleEmptyTimeTap(int minute) {
    if (_suppressOneFingerInteractions) {
      return;
    }
    if (_deselectDirectManipulation()) {
      return;
    }
    widget.onCreate(minute);
  }

  void _handleEventTap(PlannerCalendarItem event) {
    if (_suppressOneFingerInteractions || _isProvisionalEvent(event)) {
      return;
    }
    if (_isTaskFootprint(event)) {
      final taskId = event.id.substring('task-footprint:'.length);
      final task = widget.tasks.where((task) => task.id == taskId).firstOrNull;
      if (task != null) {
        widget.onTaskTap(task);
      }
      return;
    }
    if (widget.selectionMode) {
      widget.onToggleSelection(event);
      return;
    }
    if (_directManipulationEventId != null &&
        _directManipulationEventId != event.id) {
      _deselectDirectManipulation();
    }
    _openCalendarEvent(context, event);
  }

  void _cancelManipulationPreviewForPinch() {
    if (_previewStartMinutes.isEmpty &&
        _previewEndMinutes.isEmpty &&
        _movePointerGlobals.isEmpty &&
        _moveGrabOffsets.isEmpty &&
        _resizeAccumulatedPixels.isEmpty &&
        widget.activeMoveEventId == null) {
      return;
    }
    setState(() {
      _previewStartMinutes.clear();
      _previewEndMinutes.clear();
      _movePointerGlobals.clear();
      _moveGrabOffsets.clear();
      _movePointerIds.clear();
      _resizeAccumulatedPixels.clear();
    });
    widget.onMoveSessionCancel();
  }

  // The timeline canvas always spans the full civil day so times
  // outside the configured planning window remain reachable (PMG
  // parity). The configured window remains the current-time
  // visibility window and the default initial-scroll anchor.
  int get _canvasFirstHour => kPlannerCivilDayStartHour;
  int get _canvasLastHour => kPlannerCivilDayEndHour;
  int get _planWindowFirstHour => widget.settings.visibleStartHour;
  int get _planWindowLastHour => widget.settings.visibleEndHour;

  /// True while the timeline must refuse to act on a one-finger
  /// gesture because a two-finger pinch is in progress (or the
  /// pinch just ended within the current pump cycle). Event
  /// tap / move / resize and the empty-time create handler all
  /// read this flag at the top of their callback and short-
  /// circuit when it is true.
  bool get _suppressOneFingerInteractions => _pinchActive || _postPinchSuppress;

  void _beginRawPinch() {
    if (_pinchPointerPositions.length < 2) {
      return;
    }
    final points = _pinchPointerPositions.values.take(2).toList();
    final distance = (points[0] - points[1]).distance;
    if (distance <= 0) {
      return;
    }
    widget.daySwipeCoordinator.cancel();
    _pinchStartDistance = distance;
    _zoomStartHeight = _hourHeight;
    _zoomStartViewportHeight = widget.scrollController.hasClients
        ? widget.scrollController.position.viewportDimension
        : 0;
    _zoomStartConfiguredHours = _planWindowLastHour - _planWindowFirstHour;
    _zoomStartScrollOffset = widget.scrollController.hasClients
        ? widget.scrollController.offset
        : 0;
    _zoomStartMaxExtent = widget.scrollController.hasClients
        ? widget.scrollController.position.maxScrollExtent
        : 0;
    _zoomStartHourHeight = _hourHeight;
    _zoomFocalLocalY = (points[0].dy + points[1].dy) / 2;
    final startPixelsPerMinute = _hourHeight / 60;
    _zoomFocalMinute = startPixelsPerMinute > 0
        ? (_zoomFocalLocalY ?? 0) / startPixelsPerMinute
        : 0;
    _pendingPinchHourHeight = null;
    _pendingPinchScrollOffset = null;
    _postPinchSuppress = false;
  }

  void _queuePinchFrame({
    required double hourHeight,
    required double scrollOffset,
    required bool hasScrollClient,
  }) {
    _pendingPinchHourHeight = hourHeight;
    _pendingPinchScrollOffset = scrollOffset;
    _pendingPinchHasScrollClient = hasScrollClient;
    if (_pinchFrameScheduled) {
      return;
    }
    _pinchFrameScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _pinchFrameScheduled = false;
      if (!mounted) {
        return;
      }
      _applyPendingPinchFrame();
    });
  }

  void _applyPendingPinchFrame() {
    final hourHeight = _pendingPinchHourHeight;
    final scrollOffset = _pendingPinchScrollOffset;
    final hasScrollClient = _pendingPinchHasScrollClient;
    _pendingPinchHourHeight = null;
    _pendingPinchScrollOffset = null;
    if (hourHeight == null || scrollOffset == null) {
      return;
    }
    setState(() {
      _hourHeight = hourHeight;
      if (hasScrollClient && widget.scrollController.hasClients) {
        widget.scrollController.jumpTo(scrollOffset);
      }
    });
    widget.onZoomUpdate(hourHeight);
  }

  void _updateRawPinch() {
    final startDistance = _pinchStartDistance;
    final start = _zoomStartHeight;
    final focalMinute = _zoomFocalMinute;
    final focalLocalY = _zoomFocalLocalY;
    if (!_pinchActive ||
        startDistance == null ||
        start == null ||
        focalMinute == null ||
        focalLocalY == null ||
        _pinchPointerPositions.length < 2) {
      return;
    }
    final points = _pinchPointerPositions.values.take(2).toList();
    final distance = (points[0] - points[1]).distance;
    final adjustedScale = PlannerZoomPolicy.applyDeadZone(
      distance / startDistance,
    );
    final newHourHeight = PlannerZoomPolicy.clampForViewport(
      start * adjustedScale,
      viewportHeight: _zoomStartViewportHeight,
      configuredHours: _zoomStartConfiguredHours,
    );
    final newPixelsPerMinute = newHourHeight / 60;
    final controller = widget.scrollController;
    final desiredFocalContentY = focalMinute * newPixelsPerMinute;
    final desiredOffset =
        (desiredFocalContentY - focalLocalY + (_zoomStartScrollOffset ?? 0))
            .toDouble();
    final newMaxExtent =
        _zoomStartMaxExtent + 24 * (newHourHeight - _zoomStartHourHeight);
    final hasClients = controller.hasClients;
    final clampedOffset = desiredOffset
        .clamp(0.0, newMaxExtent.clamp(0, double.infinity))
        .toDouble();
    _queuePinchFrame(
      hourHeight: newHourHeight,
      scrollOffset: clampedOffset,
      hasScrollClient: hasClients,
    );
  }

  void _endRawPinch() {
    if (_zoomStartHeight != null) {
      _applyPendingPinchFrame();
      _zoomStartHeight = null;
      _zoomStartScrollOffset = null;
      _zoomFocalLocalY = null;
      _zoomFocalMinute = null;
      _pinchStartDistance = null;
      widget.onZoomEnd(_hourHeight);
    }
    _postPinchSuppress = true;
    _pinchActive = false;
    widget.pinchCoordinator.clearCancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _postPinchSuppress = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final slotCount = _canvasLastHour - _canvasFirstHour;
    final timelineHeight = slotCount * _hourHeight;
    // Delta 4.2A: one canonical minute grid owns both logical and painted
    // geometry. Zoom changes pixels-per-minute only; it never adds a visual
    // height floor or a second set of display-only overlap lanes.
    final viewportHeight = _safeViewportHeight();
    final taskFootprints = _taskFootprints();
    final placements = PlannerDisplayGeometry.resolve(
      events: <PlannerCalendarItem>[...widget.events, ...taskFootprints],
      hourHeight: _hourHeight,
      viewportHeight: viewportHeight,
      configuredHours: _planWindowLastHour - _planWindowFirstHour,
      previewStartMinutes: _previewStartMinutes,
      previewEndMinutes: _previewEndMinutes,
    );
    // The current-time read happens inside the
    // ValueListenableBuilder so the indicator's visibility,
    // label, and vertical position all refresh together on every
    // minute tick without rebuilding the pinch / long-press /
    // resize recognizers on this surface.
    return Listener(
      // Pointer-level Listener wraps the entire timeline
      // surface so the active pointer count is tracked from
      // the very first finger-down, not only from the moment
      // the gesture arena promotes a ScaleGestureRecognizer.
      // The Listener does not consume the events; the inner
      // GestureDetector still receives every pointer event for
      // its scale / tap / long-press recognizers. The Listener
      // only feeds [_PinchCoordinator] so the parent state can
      // decide whether to swap the SingleChildScrollView
      // physics to NeverScrollableScrollPhysics.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _pinchPointerPositions[event.pointer] = event.localPosition;
        final transitioned = widget.pinchCoordinator.onPointerDown();
        if (transitioned) {
          // The second pointer just landed; the pinch now owns
          // the gesture. Cancel the day-swipe candidate (in
          // case the second finger is moving horizontally) and
          // arm the suppressions so a stale one-finger tap or
          // drag cannot commit after the pinch ends. The
          // _PinchCoordinator remains "active" (its
          // _externalCancel flag stays false) so the parent
          // state swaps the SingleChildScrollView physics to
          // NeverScrollableScrollPhysics for the duration of
          // the pinch; the explicit `clearCancel()` call
          // ensures no prior cancel state is lingering.
          widget.daySwipeCoordinator.cancel();
          widget.pinchCoordinator.clearCancel();
          _pinchActive = true;
          _postPinchSuppress = true;
          // Lock 1: the moment a second pointer lands, pinch owns the
          // interaction. Discard any in-flight one-finger move/resize
          // preview so its eventual recognizer end cannot commit it.
          _cancelManipulationPreviewForPinch();
          // Raw pointer tracking is deliberately outside the gesture arena:
          // selected-body and endpoint drag recognizers cannot prevent pinch
          // from establishing its two-pointer baseline.
          _beginRawPinch();
        }
      },
      onPointerMove: (event) {
        if (_pinchPointerPositions.containsKey(event.pointer)) {
          _pinchPointerPositions[event.pointer] = event.localPosition;
          _updateRawPinch();
        }
      },
      onPointerUp: (event) {
        final endingPinch = _pinchActive || _pinchStartDistance != null;
        final transitioned = widget.pinchCoordinator.onPointerUp();
        _pinchPointerPositions.remove(event.pointer);
        if (transitioned && endingPinch) {
          _endRawPinch();
        }
      },
      onPointerCancel: (event) {
        final endingPinch = _pinchActive || _pinchStartDistance != null;
        final transitioned = widget.pinchCoordinator.onPointerUp();
        _pinchPointerPositions.remove(event.pointer);
        if (transitioned && endingPinch) {
          _endRawPinch();
        }
      },
      child: GestureDetector(
        key: const Key('planner-zoom-surface'),
        behavior: HitTestBehavior.translucent,
        onScaleStart: (details) {
          if (_pinchStartDistance != null) {
            return;
          }
          // Pinch (two-pointer scale) owns the gesture. The
          // pinch baseline is captured as soon as the
          // recognizer fires with two pointers; Flutter's
          // ScaleGestureRecognizer resets `details.scale` to
          // 1.0 on the first onScaleStart of a multi-pointer
          // gesture, so the captured start height is the
          // pre-pinch effective hour height. The
          // _PinchCoordinator has already ensured the parent
          // SingleChildScrollView is in
          // NeverScrollableScrollPhysics for the duration of
          // the gesture.
          if (details.pointerCount >= 2) {
            widget.daySwipeCoordinator.cancel();
            _zoomStartHeight = _hourHeight;
            // Capture the usable timeline viewport and the configured
            // planning-window span so the gesture's min/max hour-height
            // clamps stay stable for the whole pinch.
            _zoomStartViewportHeight = widget.scrollController.hasClients
                ? widget.scrollController.position.viewportDimension
                : 0;
            _zoomStartConfiguredHours =
                _planWindowLastHour - _planWindowFirstHour;
            // Capture focal-time anchors: the local Y from this
            // GestureDetector's coordinate space and the scroll
            // offset of the parent SingleChildScrollView. The
            // local coordinate is the pointer's position inside
            // the timeline surface (origin at the top of the
            // SizedBox). The scroll offset is read defensively
            // (the controller has clients while mounted inside
            // the scroll view).
            _zoomStartScrollOffset = widget.scrollController.hasClients
                ? widget.scrollController.offset
                : 0;
            _zoomStartMaxExtent = widget.scrollController.hasClients
                ? widget.scrollController.position.maxScrollExtent
                : 0;
            _zoomStartHourHeight = _hourHeight;
            _zoomFocalLocalY = details.localFocalPoint.dy;
            // The GestureDetector wraps the timeline canvas directly,
            // so the local focal Y is already a canvas coordinate: it is
            // the minute-of-day under the pinch midpoint expressed in
            // pixels at the current scale. The scroll offset must NOT be
            // added here — adding it double-counts the scroll and the
            // compensation overshoots by `offset * (scale - 1)` at any
            // non-zero scroll position (the initial-scroll jump made this
            // visible on the physical planner).
            final startPixelsPerMinute = _hourHeight / 60;
            _zoomFocalMinute = startPixelsPerMinute > 0
                ? (_zoomFocalLocalY ?? 0) / startPixelsPerMinute
                : 0;
            // Clear the one-pump settle flag from any previous
            // pinch: a fresh two-pointer pinch has just begun
            // and its suppressions are explicit (_pinchActive
            // is now true), so the post-pinch buffer is no
            // longer required.
            _postPinchSuppress = false;
          }
        },
        onScaleUpdate: (details) {
          if (_pinchStartDistance != null) {
            return;
          }
          final start = _zoomStartHeight;
          final focalMinute = _zoomFocalMinute;
          final focalLocalY = _zoomFocalLocalY;
          if (start == null ||
              focalMinute == null ||
              focalLocalY == null ||
              details.pointerCount < 2) {
            return;
          }
          // Apply the dead zone around 1.0 and re-anchor the
          // scale baseline to the captured start hour height
          // (not the current hour height) so the response is
          // monotonic and stable across the gesture lifetime.
          final adjustedScale = PlannerZoomPolicy.applyDeadZone(details.scale);
          final newHourHeight = PlannerZoomPolicy.clampForViewport(
            start * adjustedScale,
            viewportHeight: _zoomStartViewportHeight,
            configuredHours: _zoomStartConfiguredHours,
          );
          final newPixelsPerMinute = newHourHeight / 60;
          final controller = widget.scrollController;
          // Compute the scroll offset that keeps the captured focal
          // minute directly beneath the same local Y on the timeline
          // surface. The desired offset equals the new canvas position
          // of the focal minute minus its viewport-relative position;
          // because the scrollable's content includes the current
          // offset, the captured start offset is re-added (this term
          // cancels at offset zero, which is why the original
          // implementation appeared correct before the initial-scroll
          // jump existed). Clamp to the controller's valid extent so
          // we cannot overshoot the start or end of the scrollable.
          final desiredFocalContentY = focalMinute * newPixelsPerMinute;
          final desiredOffset =
              (desiredFocalContentY -
                      focalLocalY +
                      (_zoomStartScrollOffset ?? 0))
                  .toDouble();
          // The canvas height is 24 slots, so the scrollable extent
          // grows by exactly 24 * delta-hour-height as the pinch
          // progresses. Clamping against this derived extent (rather
          // than the live `maxScrollExtent`, which lags one layout
          // behind the gesture) keeps the focal compensation intact
          // even when a pinch-out runs past the pre-pinch extent.
          final newMaxExtent =
              _zoomStartMaxExtent + 24 * (newHourHeight - _zoomStartHourHeight);
          final hasClients = controller.hasClients;
          final clampedOffset = desiredOffset
              .clamp(0.0, newMaxExtent.clamp(0, double.infinity))
              .toDouble();
          _queuePinchFrame(
            hourHeight: newHourHeight,
            scrollOffset: clampedOffset,
            hasScrollClient: hasClients,
          );
        },
        onScaleEnd: (_) {
          if (_pinchStartDistance != null || _postPinchSuppress) {
            return;
          }
          if (_zoomStartHeight != null) {
            _applyPendingPinchFrame();
            _zoomStartHeight = null;
            _zoomStartScrollOffset = null;
            _zoomFocalLocalY = null;
            _zoomFocalMinute = null;
            widget.onZoomEnd(_hourHeight);
          }
          // Keep the one-pump settle suppression active until
          // the next frame so a stale single-pointer drag that
          // was already in flight cannot immediately commit a
          // vertical scroll or a tap.
          _postPinchSuppress = true;
          _pinchActive = false;
          // Clear the cancel flag so a subsequent fresh
          // two-pointer pinch can claim the gesture again.
          widget.pinchCoordinator.clearCancel();
          // Schedule a single post-frame tick to clear the
          // settle flag once the gesture arena has retired the
          // scale recognizer. Using WidgetsBinding's transient
          // callback keeps this off any wall-clock timer and
          // avoids the artificial-delay anti-pattern.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            _postPinchSuppress = false;
          });
        },
        child: KeyedSubtree(
          key: widget.timelineKey,
          child: SizedBox(
            key: const Key('planner-time-grid'),
            height: timelineHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned.fill(
                      child: GestureDetector(
                        key: const Key('planner-timeline-create-surface'),
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) {
                          // Empty-time create: suppressed while a
                          // pinch is in progress or during the
                          // one-pump settle window so a stale
                          // finger landing does not open the
                          // Event Type picker after the pinch
                          // ends.
                          final minute =
                              snapPlannerMinute(
                                (details.localPosition.dy / _hourHeight * 60)
                                    .round(),
                                widget.settings.snapMinutes,
                              ).clamp(
                                kPlannerCivilDayStartMinute,
                                kPlannerCivilDayEndMinute - 15,
                              );
                          _handleEmptyTimeTap(minute);
                        },
                      ),
                    ),
                    // PMG hidden-midnight model: the 12 AM top and bottom
                    // boundaries are hidden (no label, no line). The first
                    // visible hour line is 1 AM and the last visible hour
                    // line is 11 PM; the 12 AM-1 AM and 11 PM-12 AM slots
                    // remain fully usable because the canvas still spans the
                    // full 0..1440 civil-day minutes and no fake 1 AM row
                    // follows the final boundary.
                    for (var index = 1; index < slotCount; index++) ...<Widget>[
                      Positioned(
                        // BetterCalendar / Delta 4.2A discipline: the boundary
                        // line comes first and its label sits inside the hour
                        // cell immediately below it at every zoom level.
                        top: index * _hourHeight + 2,
                        left: 0,
                        width: _timeColumnWidth,
                        child: GestureDetector(
                          key: Key('planner-time-label-$index'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            _handleEmptyTimeTap(index * 60);
                          },
                          child: Text(
                            _hourLabel(index),
                            // Hour labels must never wrap (the test fallback
                            // font renders every glyph at fontSize width, which
                            // would wrap short labels and push them below the
                            // final line).
                            maxLines: 1,
                            softWrap: false,
                            textAlign: TextAlign.right,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: AppTheme.onFillTextOf(context, 0.54),
                                ),
                          ),
                        ),
                      ),
                      Positioned(
                        key: Key('planner-full-hour-line-$index'),
                        top: index * _hourHeight,
                        left: _timeColumnWidth,
                        right: 0,
                        child: Divider(
                          height: 1,
                          color: AppTheme.outlineOf(context),
                        ),
                      ),
                    ],
                    if (widget.events.isEmpty &&
                        widget.tasks.isEmpty &&
                        widget.tapMarker == null)
                      const Positioned(
                        top: 18,
                        left: _timeColumnWidth + 14,
                        right: 8,
                        child: _EmptySectionMessage(
                          'No timed Calendar Events. Tap the timeline to add one.',
                        ),
                      ),
                    // Delta 4.2D generic pre-type Event placeholder. It uses
                    // the same canonical minute-to-pixel geometry as saved
                    // Events, stays non-interactive, and never enters the
                    // persistence or saved-event overlap paths.
                    if (widget.tapMarker != null &&
                        widget.tapMarker!.date == widget.selectedDate)
                      Builder(
                        builder: (context) {
                          // Phase B mixed correction: the pre-type marker
                          // shares the one explicit far-compact floor with
                          // saved Events and Task footprints. Intermediate
                          // zooms keep its truthful minute geometry.
                          final placeholderStart =
                              widget.tapMarker!.startMinute;
                          final placeholderEnd = widget.tapMarker!.endMinute;
                          final floorActive =
                              _hourHeight <=
                                  PlannerZoomPolicy.compactHourHeight &&
                              placeholderEnd - placeholderStart <=
                                  kPlannerMaxZoomReadabilityDurationMinutes;
                          final displayStart = floorActive
                              ? (placeholderStart ~/ 60) * 60
                              : placeholderStart;
                          final displayEnd = floorActive
                              ? displayStart + 60
                              : placeholderEnd;
                          final placeholderGeometry =
                              PlannerTimelineGeometry.event(
                                startMinute: displayStart,
                                endMinute: displayEnd,
                                visibleStartMinute: kPlannerCivilDayStartMinute,
                                visibleEndMinute: kPlannerCivilDayEndMinute,
                                hourHeight: _hourHeight,
                              );
                          return Positioned(
                            key: const Key('planner-tap-placeholder'),
                            top: placeholderGeometry.top,
                            left: _timeColumnWidth,
                            right: 0,
                            height: placeholderGeometry.height,
                            child: IgnorePointer(
                              child: _TapEventPlaceholder(
                                height: placeholderGeometry.height,
                              ),
                            ),
                          );
                        },
                      ),
                    // Current-time overlay: painted BEFORE the Event blocks so
                    // the final z-order is hour grid -> current-time indicator
                    // -> Event blocks. Event cards paint over the line where
                    // they intersect and the indicator never crosses an Event
                    // face (Phase 5 FINAL layer order). The overlay stays
                    // non-interactive (IgnorePointer) so Event tap / drag /
                    // resize / pinch and timeline scroll are never blocked.
                    //
                    // Nested-Stack pattern so both ParentData relationships
                    // remain valid:
                    //
                    // * Outer [Positioned.fill] is a direct child of the main
                    //   timeline [Stack] (Positioned MUST be laid out by a
                    //   Stack).
                    // * Inner [Stack] is the builder's return value; the inner
                    //   [Positioned] for the indicator Row is a direct child of
                    //   that inner [Stack], keeping ParentData valid when the
                    //   indicator is visible.
                    // * When hidden, the inner [Stack] contains no Positioned
                    //   and is therefore safe to render.
                    //
                    // The ValueListenableBuilder rebuilds only this overlay
                    // subtree on minute ticks; the pinch, long-press, resize,
                    // day-swipe, and event-tap recognizers are not in the
                    // rebuild path.
                    Positioned.fill(
                      key: const Key('planner-current-time-overlay'),
                      child: IgnorePointer(
                        child: ValueListenableBuilder<DateTime>(
                          valueListenable: widget.currentTimeListenable,
                          builder: (context, currentNow, _) {
                            final minuteOfDay =
                                currentNow.hour * 60 + currentNow.minute;
                            final pixelsPerMinute =
                                PlannerTimelineGeometry.pixelsPerMinute(
                                  _hourHeight,
                                );
                            final resolvedMinuteY =
                                minuteOfDay * pixelsPerMinute;
                            final resolvedIndicatorTop =
                                resolvedMinuteY -
                                _currentTimeIndicatorHeight / 2;
                            // M6 closure: the visibility bound is the
                            // CANVAS (the full 00:00-24:00 civil day this
                            // timeline always spans), never the soft
                            // planning window. `visibleStartHour` /
                            // `visibleEndHour` only seed the initial scroll
                            // position and the max-zoom-out fit target, so
                            // gating visibility on them blanked the
                            // indicator during the boundary hours of any
                            // window narrower than the full day (e.g.
                            // 23:00-00:59 for a 01:00-23:00 window, and
                            // 22:00-05:59 for the 06:00-22:00 default).
                            final indicatorVisible =
                                widget.settings.showCurrentTime &&
                                widget.selectedDate ==
                                    PlannerDate.fromDateTime(currentNow) &&
                                currentNow.hour >= kPlannerCivilDayStartHour &&
                                currentNow.hour < kPlannerCivilDayEndHour;
                            return Stack(
                              clipBehavior: Clip.none,
                              children: <Widget>[
                                if (indicatorVisible)
                                  Positioned(
                                    key: const Key(
                                      'planner-current-time-indicator',
                                    ),
                                    top: resolvedIndicatorTop,
                                    left: 0,
                                    right: 0,
                                    child: SizedBox(
                                      height: _currentTimeIndicatorHeight,
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        children: <Widget>[
                                          Positioned(
                                            // CT-03: the label area widens
                                            // LEFTWARD (62dp) so its right
                                            // edge stays tangent to the
                                            // unchanged anchor boundary;
                                            // the anchor/line are not
                                            // moved to make room.
                                            left:
                                                PlannerCurrentTimeHorizontalGeometry
                                                    .labelLeft,
                                            top: 0,
                                            bottom: 0,
                                            width:
                                                PlannerCurrentTimeHorizontalGeometry
                                                    .labelWidth,
                                            child: Align(
                                              alignment: Alignment.centerRight,
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Container(
                                                  // CT-02/CT-03: NO fill/
                                                  // background behind the
                                                  // time.  The time text
                                                  // itself is the highlighted
                                                  // element — semantic
                                                  // primary, larger (fontSize
                                                  // 15) in a 62dp leftward-
                                                  // widened area with 4dp
                                                  // padding.
                                                  height:
                                                      PlannerCurrentTimeHorizontalGeometry
                                                          .capsuleHeight,
                                                  alignment: Alignment.center,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 4,
                                                      ),
                                                  child: Text(
                                                    formatPlannerCurrentTimeLabel(
                                                      currentNow,
                                                    ),
                                                    key: const Key(
                                                      'planner-current-time-label',
                                                    ),
                                                    textAlign: TextAlign.right,
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    style: TextStyle(
                                                      color: Theme.of(
                                                        context,
                                                      ).colorScheme.primary,
                                                      fontSize: 15,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      height: 1.0,
                                                      letterSpacing: 0.2,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            key: const Key(
                                              'planner-current-time-dot',
                                            ),
                                            left:
                                                PlannerCurrentTimeHorizontalGeometry
                                                    .dotLeft,
                                            top:
                                                (_currentTimeIndicatorHeight -
                                                    _currentTimeDotSize) /
                                                2,
                                            width: _currentTimeDotSize,
                                            height: _currentTimeDotSize,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            key: const Key(
                                              'planner-current-time-line',
                                            ),
                                            // CT-01: the thin line begins at
                                            // the anchor's right edge and
                                            // continues across the Event
                                            // canvas.
                                            left:
                                                PlannerCurrentTimeHorizontalGeometry
                                                    .lineStartX,
                                            right: 0,
                                            top:
                                                (_currentTimeIndicatorHeight -
                                                    2) /
                                                2,
                                            height: 2,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    // R7-04: the saved-drag ghost and drag-time label are
                    // rendered in the screen-level drag overlay (outside the
                    // pager strip) so they are excluded from the page
                    // transform and stay under the finger during a cross-date
                    // transition. Saved cards paint first; the provisional
                    // draft then paints above every saved card, and the
                    // selected/draft endpoint handles paint last above both
                    // layers.
                    for (final placement in placements.where(
                      (placement) =>
                          !_isProvisionalEvent(placement.event) &&
                          !_isTaskFootprint(placement.event) &&
                          !_isTaskDraft(placement.event),
                    ))
                      _positionedEvent(placement, constraints.maxWidth),
                    for (final placement in placements.where(
                      (placement) =>
                          _isProvisionalEvent(placement.event) &&
                          !_isTaskFootprint(placement.event),
                    ))
                      _positionedEvent(placement, constraints.maxWidth),
                    for (final task in widget.tasks)
                      for (final placement in placements.where(
                        (placement) =>
                            placement.event.id == 'task-footprint:${task.id}',
                      ))
                        _positionedTimelineTask(
                          task,
                          placement,
                          constraints.maxWidth,
                        ),
                    ...placements
                        .where(
                          (placement) =>
                              !_isTaskFootprint(placement.event) &&
                              !_isTaskDraft(placement.event) &&
                              _isDirectlySelected(placement.event) &&
                              widget.activeMoveEventId != placement.event.id &&
                              !widget.selectionMode &&
                              widget.settings.quickEditEnabled &&
                              !_persisting.contains(placement.event.id),
                        )
                        .expand(
                          (placement) => _positionedEndpointHandles(
                            placement,
                            constraints.maxWidth,
                          ),
                        ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _positionedEvent(
    PlannerDisplayPlacement placement,
    double totalWidth,
  ) {
    final event = placement.event;
    final isTaskDraft = _isTaskDraft(event);
    final originalStart = event.startLocal!;
    final originalEnd = event.endLocal!;
    final originalStartMinute = originalStart.hour * 60 + originalStart.minute;
    final originalEndMinute = plannerEndMinuteOfDay(originalStart, originalEnd);
    final startMinute = _previewStartMinutes[event.id] ?? originalStartMinute;
    final endMinute = _previewEndMinutes[event.id] ?? originalEndMinute;
    final horizontal = _horizontalGeometry(placement, totalWidth);
    final horizontalDragOffset = widget.activeMoveEventId == event.id
        ? _activeMoveHorizontalOffset(event.id, horizontal.left)
        : 0.0;
    // Touch targets are separate from visible geometry (combined delta):
    // the Positioned covers at least [kPlannerEventMinimumTouchHeight] so
    // very short display blocks stay tappable at wide zoom-out, while the
    // visible block keeps its display height. The transparent layer below
    // the block forwards the same tap action and never enlarges the visible
    // rectangle or affects overlap.
    final touchHeight = math.max(
      placement.height,
      kPlannerEventMinimumTouchHeight,
    );
    final provisional = _isProvisionalEvent(event);
    final sourceDrag = widget.dragSession;
    final isSavedDragOrigin =
        !provisional &&
        sourceDrag?.ghostActive == true &&
        sourceDrag?.sourceDate == widget.selectedDate &&
        sourceDrag?.event.id == event.id;
    final interactive =
        !widget.selectionMode &&
        widget.settings.quickEditEnabled &&
        !_persisting.contains(event.id);
    return Positioned(
      key: Key(
        isTaskDraft
            ? 'task-draft:${event.id.substring('task-draft:'.length)}'
            : provisional
            ? 'planner-provisional-event-block'
            : 'planner-timed-event-${event.id}',
      ),
      top: placement.top,
      left: horizontal.left + horizontalDragOffset,
      width: horizontal.width,
      height: touchHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: provisional ? null : () => _handleEventTap(event),
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            key: Key(
              provisional
                  ? 'planner-provisional-event-visible'
                  : 'planner-timed-event-visible-${event.id}',
            ),
            top: 0,
            left: 0,
            right: 0,
            height: placement.height,
            child: Opacity(
              opacity: isSavedDragOrigin ? 0.45 : 1,
              child: isTaskDraft
                  ? KeyedSubtree(
                      key: const Key('planner-task-draft-block'),
                      child: _TimelineEventBlock(
                        event: event,
                        provisional: provisional,
                        eventColorsByTypeId: widget.eventColorsByTypeId,
                        use24HourTime: widget.settings.use24HourTime,
                        displayStartMinute: startMinute,
                        displayEndMinute: endMinute,
                        awaitingReport: event.isAwaitingReport(DateTime.now()),
                        selectionMode: widget.selectionMode,
                        selected: widget.selectedItems.contains(
                          PlannerSelectionId(
                            kind: PlannerSelectionKind.event,
                            id: event.id,
                          ),
                        ),
                        selectedForDirectManipulation: _isDirectlySelected(
                          event,
                        ),
                        onToggleSelection: () =>
                            widget.onToggleSelection(event),
                        interactive: interactive,
                        onTap: () => _handleEventTap(event),
                        onDirectPointerDown: (pointer) {
                          _movePointerIds[event.id] = pointer.pointer;
                          if (_isDirectlySelected(event)) {
                            widget.daySwipeCoordinator.preclaimPointerDown();
                          }
                        },
                        onMoveStart: (globalPosition) => _beginMove(
                          event,
                          globalPosition,
                          eventLocalLeft:
                              horizontal.left + horizontalDragOffset,
                          eventLocalTop: placement.top,
                          ghostSize: Size(horizontal.width, placement.height),
                        ),
                        onMoveUpdate: (globalPosition) => _updateMoveFromGlobal(
                          event,
                          originalStartMinute,
                          originalEndMinute,
                          globalPosition,
                        ),
                        onLongPressMoveUpdate: (globalPosition) =>
                            _updateMoveFromGlobal(
                              event,
                              originalStartMinute,
                              originalEndMinute,
                              globalPosition,
                            ),
                        onMoveEnd: () {
                          if (_suppressOneFingerInteractions) {
                            _clearPreview(event.id);
                            widget.onMoveSessionCancel();
                            return;
                          }
                          if (provisional) {
                            unawaited(_finishMove(event, originalStartMinute));
                          }
                        },
                        onMoveCancel: () {
                          if (provisional) {
                            _clearPreview(event.id);
                          }
                        },
                        squareTop: placement.squareTop,
                        squareBottom: placement.squareBottom,
                      ),
                    )
                  : _TimelineEventBlock(
                      event: event,
                      provisional: provisional,
                      eventColorsByTypeId: widget.eventColorsByTypeId,
                      use24HourTime: widget.settings.use24HourTime,
                      displayStartMinute: startMinute,
                      displayEndMinute: endMinute,
                      awaitingReport: event.isAwaitingReport(DateTime.now()),
                      selectionMode: widget.selectionMode,
                      selected: widget.selectedItems.contains(
                        PlannerSelectionId(
                          kind: PlannerSelectionKind.event,
                          id: event.id,
                        ),
                      ),
                      selectedForDirectManipulation: _isDirectlySelected(event),
                      onToggleSelection: () => widget.onToggleSelection(event),
                      interactive: interactive,
                      onTap: () => _handleEventTap(event),
                      onDirectPointerDown: (pointer) {
                        _movePointerIds[event.id] = pointer.pointer;
                        if (_isDirectlySelected(event)) {
                          widget.daySwipeCoordinator.preclaimPointerDown();
                        }
                      },
                      onMoveStart: (globalPosition) => _beginMove(
                        event,
                        globalPosition,
                        eventLocalLeft: horizontal.left + horizontalDragOffset,
                        eventLocalTop: placement.top,
                        ghostSize: Size(horizontal.width, placement.height),
                      ),
                      onMoveUpdate: (globalPosition) => _updateMoveFromGlobal(
                        event,
                        originalStartMinute,
                        originalEndMinute,
                        globalPosition,
                      ),
                      onLongPressMoveUpdate: (globalPosition) =>
                          _updateMoveFromGlobal(
                            event,
                            originalStartMinute,
                            originalEndMinute,
                            globalPosition,
                          ),
                      onMoveEnd: () {
                        if (_suppressOneFingerInteractions) {
                          _clearPreview(event.id);
                          widget.onMoveSessionCancel();
                          return;
                        }
                        if (provisional) {
                          unawaited(_finishMove(event, originalStartMinute));
                        }
                      },
                      onMoveCancel: () {
                        if (provisional) {
                          _clearPreview(event.id);
                        }
                      },
                      squareTop: placement.squareTop,
                      squareBottom: placement.squareBottom,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Renders a real [PlannerTask] through a presentation-only timeline
  /// footprint.  The footprint participates in the shared Event collision
  /// allocator above, but this widget intentionally owns no Event resize path.
  Widget _positionedTimelineTask(
    PlannerTask task,
    PlannerDisplayPlacement placement,
    double totalWidth,
  ) {
    final footprint = placement.event;
    final horizontal = _horizontalGeometry(placement, totalWidth);
    final startMinute = task.dueMinute!;
    final endMinute = startMinute + _taskDisplayFootprintMinutes;
    final dragEnabled =
        task.recurrence == PlannerTaskRecurrence.none &&
        !widget.selectionMode &&
        widget.settings.quickEditEnabled &&
        !_persisting.contains(footprint.id);
    return Positioned(
      key: Key('task-footprint:${task.id}'),
      top: placement.top,
      left: horizontal.left,
      width: horizontal.width,
      // Event and Task blocks use the same temporal scale. The Event content
      // policy handles compact readability without falsifying Task overlap
      // geometry through a permanent Task-only minimum height.
      height: placement.height,
      child: _TimelineTaskBlock(
        key: Key('planner-task-block-${task.id}'),
        task: task,
        footprint: footprint,
        eventColorsByTypeId: widget.eventColorsByTypeId,
        use24HourTime: widget.settings.use24HourTime,
        startMinute: startMinute,
        endMinute: endMinute,
        dragEnabled: dragEnabled,
        onTap: () => _handleEventTap(footprint),
        onPointerDown: (event) {
          _movePointerIds[footprint.id] = event.pointer;
        },
        onMoveStart: (position) => _beginMove(
          footprint,
          position,
          eventLocalLeft: horizontal.left,
          eventLocalTop: placement.top,
          ghostSize: Size(horizontal.width, placement.height),
        ),
        onMoveCancel: () {
          _clearPreview(footprint.id);
          widget.onMoveSessionCancel();
        },
      ),
    );
  }

  ({double left, double width}) _horizontalGeometry(
    PlannerDisplayPlacement placement,
    double totalWidth,
  ) {
    // Delta 3 PMG-style free-space expansion: when the placement carries a
    // span (first lane + lane count) the rectangle uses the shared grid basis
    // and starts at `spanStart * (base lane width + gap)`, so an Event widens
    // into free lanes and keeps one clean rectangle. The primary/backup split
    // and the plain column/columnCount paths remain unchanged.
    final availableWidth = totalWidth - _timeColumnWidth;
    final splitWidth = placement.widthFactor != null;
    final spanWidth = placement.spanCount != null;
    final widthBasis = splitWidth && !spanWidth
        ? availableWidth - _eventGap
        : availableWidth - _eventGap * (placement.columnCount - 1);
    final baseColumnWidth = widthBasis / placement.columnCount;
    final width = spanWidth
        ? baseColumnWidth * placement.spanCount! +
              _eventGap * (placement.spanCount! - 1)
        : splitWidth
        ? widthBasis * placement.widthFactor!
        : baseColumnWidth;
    final left = spanWidth
        ? _timeColumnWidth +
              placement.spanStart! * (baseColumnWidth + _eventGap)
        : splitWidth
        ? _timeColumnWidth +
              (widthBasis * placement.offsetFactor!) +
              (placement.column > 0 ? _eventGap : 0)
        : _timeColumnWidth + placement.column * (width + _eventGap);
    return (left: left, width: width);
  }

  List<Widget> _positionedEndpointHandles(
    PlannerDisplayPlacement placement,
    double totalWidth,
  ) {
    final event = placement.event;
    final originalStart = event.startLocal!;
    final originalEnd = event.endLocal!;
    final originalStartMinute = originalStart.hour * 60 + originalStart.minute;
    final originalEndMinute = plannerEndMinuteOfDay(originalStart, originalEnd);
    final horizontal = _horizontalGeometry(placement, totalWidth);
    final provisional = _isProvisionalEvent(event);
    // MP-06 (owner 2026-08-16): the provisional draft grips are colored by
    // the selected APP THEME COLOR (Blue theme -> blue grips, Rose theme ->
    // rose grips) in both Light and Dark, invariant across the draft's Event
    // Type accent. Saved Event handles keep the Event accent (unchanged).
    final handleAccent = provisional
        ? Theme.of(context).colorScheme.primary
        : PlannerEventColorResolver.accentColor(
            context,
            event,
            widget.eventColorsByTypeId,
          );
    final horizontalDragOffset = widget.activeMoveEventId == event.id
        ? _activeMoveHorizontalOffset(event.id, horizontal.left)
        : 0.0;

    void finishResize(_TimelineResizeEdge edge) {
      if (_suppressOneFingerInteractions) {
        _clearPreview(event.id);
        return;
      }
      unawaited(_finishResize(event, originalStartMinute, originalEndMinute));
    }

    return <Widget>[
      Positioned(
        top: provisional ? placement.top - 22 : placement.top,
        // Keep the full 44 dp target inside the Event/page. Only the small
        // decorative edge cap straddles the exact upper-right endpoint.
        left: horizontal.left + horizontalDragOffset + horizontal.width - 44,
        width: 44,
        height: 44,
        child: _DirectEndpointHandle(
          hitTargetKey: Key(
            provisional
                ? 'planner-provisional-start-handle'
                : 'planner-top-resize-hit-${event.id}',
          ),
          dotKey: Key(
            provisional
                ? 'planner-provisional-start-handle-dot'
                : 'planner-selected-start-handle-dot-${event.id}',
          ),
          edge: _TimelineResizeEdge.top,
          provisional: provisional,
          accentColor: handleAccent,
          onStart: (_) {
            _beginResize(event);
          },
          onUpdate: (edge, deltaPixels) => _updateResizeByDelta(
            event,
            originalStartMinute,
            originalEndMinute,
            edge,
            deltaPixels,
          ),
          onEnd: (edge) {
            finishResize(edge);
          },
          onCancel: (_) {
            _clearPreview(event.id);
          },
        ),
      ),
      Positioned(
        top: provisional ? placement.bottom - 22 : placement.bottom - 44,
        // Symmetric END target: full target inside the Event, decorative
        // edge cap straddling the exact bottom-left endpoint.
        left: horizontal.left + horizontalDragOffset,
        width: 44,
        height: 44,
        child: _DirectEndpointHandle(
          hitTargetKey: Key(
            provisional
                ? 'planner-provisional-resize-hit'
                : 'planner-resize-hit-${event.id}',
          ),
          dotKey: Key(
            provisional
                ? 'planner-provisional-end-handle-dot'
                : 'planner-selected-end-handle-dot-${event.id}',
          ),
          edge: _TimelineResizeEdge.bottom,
          provisional: provisional,
          accentColor: handleAccent,
          onStart: (_) {
            _beginResize(event);
          },
          onUpdate: (edge, deltaPixels) => _updateResizeByDelta(
            event,
            originalStartMinute,
            originalEndMinute,
            edge,
            deltaPixels,
          ),
          onEnd: (edge) {
            finishResize(edge);
          },
          onCancel: (_) {
            _clearPreview(event.id);
          },
        ),
      ),
    ];
  }

  RenderBox? _timelineRenderBox() {
    final renderObject = widget.timelineKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }
    return renderObject;
  }

  double _activeMoveHorizontalOffset(String eventId, double naturalLeft) {
    final pointer = _movePointerGlobals[eventId];
    final grabOffset = _moveGrabOffsets[eventId];
    final timeline = _timelineRenderBox();
    if (pointer == null || grabOffset == null || timeline == null) {
      return 0;
    }
    final pointerLocal = timeline.globalToLocal(pointer);
    final desiredLeft = pointerLocal.dx - grabOffset.dx;
    return desiredLeft - naturalLeft;
  }

  void _beginMove(
    PlannerCalendarItem event,
    Offset globalPosition, {
    required double eventLocalLeft,
    required double eventLocalTop,
    required Size ghostSize,
  }) {
    if (_suppressOneFingerInteractions || widget.selectionMode) {
      return;
    }
    widget.daySwipeCoordinator.cancel();
    final start = event.startLocal;
    final end = event.endLocal;
    final timeline = _timelineRenderBox();
    if (start == null || end == null || timeline == null) {
      return;
    }
    final startMinute = start.hour * 60 + start.minute;
    final endMinute = plannerEndMinuteOfDay(start, end);
    final pointerLocal = timeline.globalToLocal(globalPosition);
    final grabOffset = pointerLocal - Offset(eventLocalLeft, eventLocalTop);
    if (!_isProvisionalEvent(event)) {
      final pointerId = _movePointerIds[event.id];
      if (pointerId == null) {
        return;
      }
      setState(() {
        _directManipulationEventId = event.id;
        _resizeAccumulatedPixels.remove(event.id);
      });
      widget.onMoveSessionStart(
        event,
        pointerId,
        globalPosition,
        grabOffset,
        ghostSize,
        startMinute,
        endMinute,
        widget.settings.snapMinutes,
        _hourHeight,
      );
      return;
    }
    setState(() {
      _previewStartMinutes.remove(event.id);
      _previewEndMinutes.remove(event.id);
      _movePointerGlobals[event.id] = globalPosition;
      _moveGrabOffsets[event.id] = grabOffset;
      _resizeAccumulatedPixels.remove(event.id);
    });
  }

  void _updateMoveFromGlobal(
    PlannerCalendarItem event,
    int originalStartMinute,
    int originalEndMinute,
    Offset globalPosition,
  ) {
    if (_suppressOneFingerInteractions || !_isProvisionalEvent(event)) {
      return;
    }
    final grabOffset = _moveGrabOffsets[event.id];
    final timeline = _timelineRenderBox();
    if (grabOffset == null || timeline == null) {
      return;
    }
    widget.daySwipeCoordinator.cancel();
    final pointerLocal = timeline.globalToLocal(globalPosition);
    final pixelsPerMinute = PlannerTimelineGeometry.pixelsPerMinute(
      _hourHeight,
    );
    final duration = originalEndMinute - originalStartMinute;
    final rawStartMinute = ((pointerLocal.dy - grabOffset.dy) / pixelsPerMinute)
        .round();
    final nextStart = snapPlannerMinute(
      rawStartMinute,
      widget.settings.snapMinutes,
    ).clamp(kPlannerCivilDayStartMinute, kPlannerCivilDayEndMinute - duration);
    setState(() {
      _movePointerGlobals[event.id] = globalPosition;
      _previewStartMinutes[event.id] = nextStart;
      _previewEndMinutes[event.id] = nextStart + duration;
    });
  }

  void _beginResize(PlannerCalendarItem event) {
    if (_suppressOneFingerInteractions || widget.selectionMode) {
      return;
    }
    widget.daySwipeCoordinator.cancel();
    setState(() {
      if (!_isProvisionalEvent(event)) {
        _directManipulationEventId = event.id;
      }
      _previewStartMinutes.remove(event.id);
      _previewEndMinutes.remove(event.id);
      _resizeAccumulatedPixels[event.id] = 0;
      _movePointerGlobals.remove(event.id);
      _moveGrabOffsets.remove(event.id);
      _movePointerIds.remove(event.id);
    });
  }

  void _updateResizeByDelta(
    PlannerCalendarItem event,
    int originalStartMinute,
    int originalEndMinute,
    _TimelineResizeEdge edge,
    double deltaPixels,
  ) {
    if (_suppressOneFingerInteractions) {
      return;
    }
    widget.daySwipeCoordinator.cancel();
    final accumulated = (_resizeAccumulatedPixels[event.id] ?? 0) + deltaPixels;
    final rawDelta = (accumulated / _hourHeight * 60).round();
    final deltaMinutes =
        (rawDelta / widget.settings.snapMinutes).round() *
        widget.settings.snapMinutes;
    setState(() {
      _resizeAccumulatedPixels[event.id] = accumulated;
      if (edge == _TimelineResizeEdge.top) {
        final nextStart = (originalStartMinute + deltaMinutes).clamp(
          kPlannerCivilDayStartMinute,
          originalEndMinute - widget.settings.snapMinutes,
        );
        _previewStartMinutes[event.id] = nextStart;
        _previewEndMinutes[event.id] = originalEndMinute;
      } else {
        final nextEnd = (originalEndMinute + deltaMinutes).clamp(
          originalStartMinute + widget.settings.snapMinutes,
          kPlannerCivilDayEndMinute,
        );
        _previewStartMinutes[event.id] = originalStartMinute;
        _previewEndMinutes[event.id] = nextEnd;
      }
    });
  }

  /// Reads the usable vertical viewport height of the parent day scroll view
  /// without ever throwing during an early layout pass: the scroll position
  /// may be attached but not yet dimensioned when a LayoutBuilder rebuild
  /// runs inside the first frame.
  double _safeViewportHeight() {
    if (!widget.scrollController.hasClients) {
      return 0;
    }
    try {
      return widget.scrollController.position.viewportDimension;
    } on Object {
      return 0;
    }
  }

  Future<void> _finishMove(
    PlannerCalendarItem event,
    int originalStartMinute,
  ) async {
    final nextStart = _previewStartMinutes[event.id] ?? originalStartMinute;
    final sourceDate = widget.activeMoveEventId == event.id
        ? widget.activeMoveSourceDate ?? event.date
        : event.date;
    final targetDate = widget.activeMoveEventId == event.id
        ? widget.activeMoveTargetDate ?? widget.selectedDate
        : widget.selectedDate;
    final canonicalOriginalStart = widget.activeMoveEventId == event.id
        ? widget.activeMoveOriginalStartMinute ?? originalStartMinute
        : originalStartMinute;
    if (nextStart == canonicalOriginalStart && targetDate == sourceDate) {
      _clearPreview(event.id);
      widget.onMoveSessionCancel();
      // Delta 4.2R2 R2-01: a release that moved nothing is NOT a commit, so
      // it must not end direct manipulation. Long-press selects the Event and
      // the next body press (no second hold) immediately moves it; exiting
      // here would drop the selection and break that flow. Manipulation ends
      // only on a successful commit, an explicit cancel, or an outside tap.
      return;
    }
    if (_isProvisionalEvent(event)) {
      await widget.onMove(event, targetDate, nextStart);
      if (mounted) {
        _clearPreview(event.id);
      }
      return;
    }
    setState(() => _persisting.add(event.id));
    final commit = await widget.onMove(event, targetDate, nextStart);
    if (mounted) {
      setState(() {
        _persisting.remove(event.id);
        _previewStartMinutes.remove(event.id);
        _previewEndMinutes.remove(event.id);
        _movePointerGlobals.remove(event.id);
        _moveGrabOffsets.remove(event.id);
        _movePointerIds.remove(event.id);
        // Delta 4.2R R3: after a successful move commit (including the
        // recurrence-scope flow inside [onMove]), release the direct-
        // manipulation selection and hide the endpoint handles.
        _directManipulationEventId = null;
      });
      if (commit == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Event time was not changed. The original time is restored.',
            ),
          ),
        );
      } else {
        // PMG-style move confirmation + Undo (Part 16).  Undo reverses the
        // canonical transaction by persisting the original start minute
        // through the EXACT same save path (`widget.onMove`), so stored
        // start/end/date, recurring occurrence identity, and outbox
        // idempotency are all restored — never a UI-only reversal.  The
        // captured `event` still carries the original times, so the undo
        // call reproduces the pre-move geometry exactly.
        final movedTo = formatPlannerEventMinute(
          nextStart,
          widget.settings.use24HourTime,
        );
        final messenger = ScaffoldMessenger.of(context);
        final undoTokens = _PlannerUndoCardTokens.resolve(context);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              key: const Key('planner-move-undo-card'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: undoTokens.surface,
              elevation: 8,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
                side: BorderSide(color: undoTokens.border),
              ),
              duration: const Duration(seconds: 10),
              content: _MoveUndoSnackBarContent(
                message: 'Moved to $movedTo',
                durationSeconds: 10,
                onUndo: commit.undo,
              ),
            ),
          );
      }
    }
  }

  Future<void> _finishResize(
    PlannerCalendarItem event,
    int originalStartMinute,
    int originalEndMinute,
  ) async {
    final nextStart = _previewStartMinutes[event.id] ?? originalStartMinute;
    final nextEnd = _previewEndMinutes[event.id] ?? originalEndMinute;
    if (nextStart == originalStartMinute && nextEnd == originalEndMinute) {
      _clearPreview(event.id);
      // Delta 4.2R2 R2-03: a resize release that changed nothing is not a
      // commit, so the selection (and its endpoint handles) stays. Only a
      // successful commit, an explicit cancel, or an outside tap exits
      // direct-manipulation mode.
      return;
    }
    if (_isProvisionalEvent(event)) {
      await widget.onResize(event, nextStart, nextEnd);
      if (mounted) {
        _clearPreview(event.id);
      }
      return;
    }
    setState(() => _persisting.add(event.id));
    final commit = await widget.onResize(event, nextStart, nextEnd);
    if (mounted) {
      setState(() {
        _persisting.remove(event.id);
        _previewStartMinutes.remove(event.id);
        _previewEndMinutes.remove(event.id);
        _resizeAccumulatedPixels.remove(event.id);
        // Delta 4.2R R3: after a successful resize commit (recurrence-scope
        // flow included), release the direct-manipulation selection.
        _directManipulationEventId = null;
      });
      if (commit == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Event duration was not changed. The original duration is '
              'restored.',
            ),
          ),
        );
      } else {
        // Delta 4.2R2 R2-04: a successful saved Event resize (START or END)
        // shows the same floating countdown Undo card as a move, with
        // concise current-range copy. Undo restores the exact original
        // start/end through the same scope-captured save path as the move.
        final resizedTo = formatPlannerEventRange(
          nextStart,
          nextEnd,
          widget.settings.use24HourTime,
        );
        final messenger = ScaffoldMessenger.of(context);
        final undoTokens = _PlannerUndoCardTokens.resolve(context);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              key: const Key('planner-resize-undo-card'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: undoTokens.surface,
              elevation: 8,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
                side: BorderSide(color: undoTokens.border),
              ),
              duration: const Duration(seconds: 10),
              content: _MoveUndoSnackBarContent(
                message: 'Resized to $resizedTo',
                durationSeconds: 10,
                onUndo: commit.undo,
              ),
            ),
          );
      }
    }
  }

  void _clearPreview(String eventId) {
    setState(() {
      _previewStartMinutes.remove(eventId);
      _previewEndMinutes.remove(eventId);
      _movePointerGlobals.remove(eventId);
      _moveGrabOffsets.remove(eventId);
      _movePointerIds.remove(eventId);
      _resizeAccumulatedPixels.remove(eventId);
    });
  }

  String _hourLabel(int hour24) {
    if (widget.settings.use24HourTime) {
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
}

/// Generic, non-persisted Event block shown before Event Type selection.
final class _TapEventPlaceholder extends StatelessWidget {
  const _TapEventPlaceholder({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('planner-tap-placeholder-surface'),
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          PlannerEventBlockLayoutPolicy.effectiveRadiusFor(height),
        ),
        side: const BorderSide(color: AppTheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(
            'Event',
            key: Key('planner-tap-placeholder-title'),
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 17 / 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Theme-derived R4-02 component tokens. The surface is the active accent at
/// five percent over the current neutral surface, so the same Undo card is
/// ready for light/dark appearance and future accent choices without literal
/// rose/blue card colors scattered through the widget.
final class _PlannerUndoCardTokens {
  const _PlannerUndoCardTokens({
    required this.surface,
    required this.primaryText,
    required this.secondaryText,
    required this.accent,
    required this.border,
    required this.iconContainer,
  });

  factory _PlannerUndoCardTokens.resolve(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _PlannerUndoCardTokens(
      surface: Color.alphaBlend(
        colors.primary.withValues(alpha: 0.05),
        colors.surface,
      ),
      primaryText: colors.onSurface,
      secondaryText: colors.onSurfaceVariant,
      accent: colors.primary,
      border: colors.outlineVariant.withValues(alpha: 0.55),
      iconContainer: colors.primary.withValues(alpha: 0.08),
    );
  }

  final Color surface;
  final Color primaryText;
  final Color secondaryText;
  final Color accent;
  final Color border;
  final Color iconContainer;
}

final class _MoveUndoSnackBarContent extends StatefulWidget {
  const _MoveUndoSnackBarContent({
    required this.message,
    required this.durationSeconds,
    required this.onUndo,
  });

  final String message;
  final int durationSeconds;
  final Future<bool> Function() onUndo;

  @override
  State<_MoveUndoSnackBarContent> createState() =>
      _MoveUndoSnackBarContentState();
}

final class _MoveUndoSnackBarContentState
    extends State<_MoveUndoSnackBarContent> {
  Timer? _timer;
  late int _secondsRemaining;
  bool _undoStarted = false;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = widget.durationSeconds;
    _scheduleNextTick();
  }

  void _scheduleNextTick() {
    if (_secondsRemaining <= 0) {
      return;
    }
    _timer = Timer(const Duration(seconds: 1), () {
      if (!mounted) {
        return;
      }
      setState(() => _secondsRemaining -= 1);
      _scheduleNextTick();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _undo() {
    if (_undoStarted) {
      return;
    }
    _undoStarted = true;
    _timer?.cancel();
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.action);
    unawaited(
      widget.onUndo().then((undone) {
        if (!undone) {
          messenger.showSnackBar(
            const SnackBar(content: Text('Event move could not be undone.')),
          );
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _PlannerUndoCardTokens.resolve(context);
    return SizedBox(
      key: const Key('planner-move-undo-content'),
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            key: const Key('planner-move-undo-icon-container'),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: tokens.iconContainer,
              shape: BoxShape.circle,
              border: Border.all(color: tokens.border),
            ),
            child: Icon(Icons.history, size: 21, color: tokens.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.message,
                  key: const Key('planner-move-undo-message'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.primaryText,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_secondsRemaining}s remaining',
                  key: const Key('planner-move-undo-countdown'),
                  maxLines: 1,
                  style: TextStyle(
                    color: tokens.secondaryText,
                    fontSize: 12.5,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const Key('planner-move-undo-action'),
            onPressed: _undo,
            style: TextButton.styleFrom(
              minimumSize: const Size(50, 44),
              padding: const EdgeInsets.symmetric(horizontal: 7),
              foregroundColor: tokens.accent,
              textStyle: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('Undo'),
          ),
        ],
      ),
    );
  }
}

/// Task-specific Day block.  It deliberately does not reuse Event report,
/// recurrence, selection, or resize affordances.  Its [footprint] exists only
/// in presentation so the shared timeline allocator can safely place it.
final class _TimelineTaskBlock extends StatefulWidget {
  const _TimelineTaskBlock({
    super.key,
    required this.task,
    required this.footprint,
    required this.eventColorsByTypeId,
    required this.use24HourTime,
    required this.startMinute,
    required this.endMinute,
    required this.dragEnabled,
    required this.onTap,
    required this.onPointerDown,
    required this.onMoveStart,
    required this.onMoveCancel,
  });

  final PlannerTask task;
  final PlannerCalendarItem footprint;
  final Map<String, EventColorPreference> eventColorsByTypeId;
  final bool use24HourTime;
  final int startMinute;
  final int endMinute;
  final bool dragEnabled;
  final VoidCallback onTap;
  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<Offset> onMoveStart;
  final VoidCallback onMoveCancel;

  @override
  State<_TimelineTaskBlock> createState() => _TimelineTaskBlockState();
}

final class _TimelineTaskBlockState extends State<_TimelineTaskBlock> {
  bool _holdActivated = false;

  void _activateHold(Offset globalPosition) {
    setState(() => _holdActivated = true);
    unawaited(HapticFeedback.mediumImpact());
    widget.onMoveStart(globalPosition);
  }

  void _clearHoldFeedback() {
    if (mounted && _holdActivated) {
      setState(() => _holdActivated = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final footprint = widget.footprint;
    final eventColorsByTypeId = widget.eventColorsByTypeId;
    final use24HourTime = widget.use24HourTime;
    final startMinute = widget.startMinute;
    final dragEnabled = widget.dragEnabled;
    final onTap = widget.onTap;
    final onPointerDown = widget.onPointerDown;
    final onMoveCancel = widget.onMoveCancel;
    final baseFill = PlannerEventColorResolver.surfaceColor(
      context,
      footprint,
      eventColorsByTypeId,
    );
    final accent = PlannerEventColorResolver.accentColor(
      context,
      footprint,
      eventColorsByTypeId,
    );
    final time = formatPlannerEventMinute(startMinute, use24HourTime);
    final reportStatus = switch (task.reportedOutcome) {
      null => PlannerReportStatusKind.unreported,
      OutcomeKind.didNotHappen => PlannerReportStatusKind.didNotAttempt,
      OutcomeKind.partiallyCompleted => PlannerReportStatusKind.missedAttempted,
      OutcomeKind.completedHappened => PlannerReportStatusKind.completed,
    };
    // Report state is expressed by the compact canonical badge only.  A Task
    // block retains its original Task/Event-family surface regardless of
    // outcome so type recognition and collision geometry never flicker.
    final fill = baseFill;
    final textColor = PlannerEventBlockColorPolicy.textColor(
      fill,
      Theme.of(context).brightness,
    );
    final hint = task.recurrence == PlannerTaskRecurrence.none
        ? 'Tap for details. Long-press and drag to reschedule.'
        : 'Tap for details. Recurring Tasks cannot be moved here.';
    return Semantics(
      button: true,
      label:
          '${task.title}, ${PlannerEventReportStatus.labelFor(reportStatus)}, $time',
      hint: hint,
      child: Listener(
        onPointerDown: onPointerDown,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          // Saved Tasks retain their established long-press route. Task
          // creation drafts are rendered through the Event provisional path.
          // Reuse the saved Event long-press activation state and haptic.
          // Tasks intentionally expose only its move activation--never Event
          // endpoint/resize affordances.
          onLongPressStart: dragEnabled
              ? (details) => _activateHold(details.globalPosition)
              : null,
          onLongPressEnd: dragEnabled ? (_) => _clearHoldFeedback() : null,
          onLongPressCancel: dragEnabled
              ? () {
                  _clearHoldFeedback();
                  onMoveCancel();
                }
              : null,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availableHeight = constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : PlannerEventBlockLayoutPolicy.mediumThreshold + 1;
              final content = PlannerEventBlockContent.forHeight(
                availableHeight,
                interactive: false,
              );
              return Material(
                key: Key('planner-task-block-hold-feedback-${task.id}'),
                color: fill,
                elevation: _holdActivated ? 6 : 0,
                shadowColor: accent.withValues(alpha: 0.65),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    PlannerEventBlockLayoutPolicy.effectiveRadiusFor(
                      availableHeight,
                    ),
                  ),
                  // Match the Event-family separation outline without
                  // changing Task geometry or hit area.
                  side: BorderSide(
                    color: AppTheme.background.withValues(alpha: 0.72),
                    width: 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: DecoratedBox(
                  key: Key('planner-task-block-accent-${task.id}'),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: accent,
                        width: PlannerEventBlockLayoutPolicy.eventAccentWidth,
                      ),
                    ),
                  ),
                  child: PlannerTaskEventFamilyBlockContentView(
                    title: task.title,
                    time: time,
                    textColor: textColor,
                    status: reportStatus,
                    content: content,
                    contentKey: Key('planner-task-block-content-${task.id}'),
                    titleKey: Key('planner-task-block-title-${task.id}'),
                    timeKey: Key('planner-task-block-time-${task.id}'),
                    statusKey: Key('planner-task-block-status-${task.id}'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

final class _TimelineEventBlock extends StatefulWidget {
  const _TimelineEventBlock({
    required this.event,
    required this.provisional,
    required this.eventColorsByTypeId,
    required this.use24HourTime,
    required this.displayStartMinute,
    required this.displayEndMinute,
    required this.awaitingReport,
    required this.selectionMode,
    required this.selected,
    required this.selectedForDirectManipulation,
    required this.onToggleSelection,
    required this.interactive,
    required this.onTap,
    required this.onDirectPointerDown,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onLongPressMoveUpdate,
    required this.onMoveEnd,
    required this.onMoveCancel,
    this.squareTop = false,
    this.squareBottom = false,
  });

  final PlannerCalendarItem event;
  final bool provisional;
  final Map<String, EventColorPreference> eventColorsByTypeId;
  final bool use24HourTime;
  final int displayStartMinute;
  final int displayEndMinute;
  final bool awaitingReport;
  final bool selectionMode;
  final bool selected;
  final bool selectedForDirectManipulation;
  final VoidCallback onToggleSelection;
  final bool interactive;
  final VoidCallback onTap;
  final ValueChanged<PointerDownEvent> onDirectPointerDown;
  final ValueChanged<Offset> onMoveStart;
  final ValueChanged<Offset> onMoveUpdate;
  final ValueChanged<Offset> onLongPressMoveUpdate;
  final VoidCallback onMoveEnd;
  final VoidCallback onMoveCancel;

  /// Delta 4.2R R12: square the corner on the edge that touches a truly
  /// contiguous block below/above, so the shared boundary has no decorative
  /// rounded-corner notch.
  final bool squareTop;
  final bool squareBottom;

  @override
  State<_TimelineEventBlock> createState() => _TimelineEventBlockState();
}

/// S2B-02: stable Event content subtrees. The heavy presentation subtree
/// ([PlannerEventBlockContentView]: title/time/status/recurrence/colors) is
/// responds to the exact live compact height during an ordinary pinch. This
/// State reuses the content widget only while a COMPLETE render fingerprint
/// (Event facts + content metrics + resolved colors) is unchanged.
/// The gesture/semantics wrapper still rebuilds each frame (its callbacks
/// capture per-frame geometry), and any fact change or density-tier crossing
/// rebuilds the content exactly once (pack 10/12).
final class _TimelineEventBlockState extends State<_TimelineEventBlock> {
  Object? _contentFingerprint;
  Widget? _cachedContent;

  /// Resolve the scale-invariant content subtree, reusing the exact cached
  /// widget instance while the COMPLETE render fingerprint is unchanged.
  /// [content] is derived from the exact live available height. Its compact
  /// metrics vary fractionally inside a density tier during the frozen Luna
  /// transition, so the live height is part of the fingerprint. Omitting it
  /// retained stale Event padding/line metrics after the card had shrunk and
  /// produced the owner-observed transient bottom overflow. All other inputs
  /// are stable Event facts (title/time/status/recurrence/colors).
  Widget _resolveContent({
    required PlannerEventBlockContent content,
    required Color accent,
    required Color fill,
    required Color? textColorOverride,
  }) {
    final fingerprint = (
      widget.event.id,
      widget.event.displayTitle,
      widget.event.activityTypeLabel,
      widget.event.activityTypeColorValue,
      widget.event.isBackupAppointment,
      widget.event.requiresReport,
      widget.event.state,
      widget.event.isRecurring,
      widget.event.linkedTaskIds.length,
      widget.provisional,
      widget.use24HourTime,
      widget.displayStartMinute,
      widget.displayEndMinute,
      widget.awaitingReport,
      content.density,
      content.titleMaxLines,
      content.showTitle,
      content.showTime,
      content.showTimeInline,
      content.showRecurrence,
      content.showStatusIcons,
      content.showResizeHandle,
      content.showTimeOnly,
      content.visibleHeight,
      accent,
      fill,
      textColorOverride,
    );
    if (_contentFingerprint != fingerprint || _cachedContent == null) {
      _contentFingerprint = fingerprint;
      _cachedContent = PlannerEventBlockContentView(
        event: widget.event,
        accentColor: accent,
        surfaceColor: fill,
        textColorOverride: textColorOverride,
        use24HourTime: widget.use24HourTime,
        displayStartMinute: widget.displayStartMinute,
        displayEndMinute: widget.displayEndMinute,
        awaitingReport: widget.awaitingReport,
        content: content,
        titleKey: const Key('planner-event-block-title'),
        timeKey: const Key('planner-event-block-time'),
        recurrenceKey: Key('planner-event-recurring-${widget.event.id}'),
        statusKey: Key('planner-event-block-status-${widget.event.id}'),
      );
    }
    return _cachedContent!;
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final provisional = widget.provisional;
    final eventColorsByTypeId = widget.eventColorsByTypeId;
    final use24HourTime = widget.use24HourTime;
    final displayStartMinute = widget.displayStartMinute;
    final displayEndMinute = widget.displayEndMinute;
    final awaitingReport = widget.awaitingReport;
    final selectionMode = widget.selectionMode;
    final selected = widget.selected;
    final selectedForDirectManipulation = widget.selectedForDirectManipulation;
    final interactive = widget.interactive;
    final squareTop = widget.squareTop;
    final squareBottom = widget.squareBottom;
    final onToggleSelection = widget.onToggleSelection;
    final onTap = widget.onTap;
    final onDirectPointerDown = widget.onDirectPointerDown;
    final onMoveStart = widget.onMoveStart;
    final onMoveUpdate = widget.onMoveUpdate;
    final onLongPressMoveUpdate = widget.onLongPressMoveUpdate;
    final onMoveEnd = widget.onMoveEnd;
    final onMoveCancel = widget.onMoveCancel;
    final resolvedAccent = PlannerEventColorResolver.accentColor(
      context,
      event,
      eventColorsByTypeId,
    );
    final resolvedFill = PlannerEventColorResolver.surfaceColor(
      context,
      event,
      eventColorsByTypeId,
    );
    // Delta 4.1 D4.1-04: the unsaved draft is a provisional TIME-ONLY
    // surface clearly different from a saved Event-Type-colored card.
    // Saved Events keep their resolved Event Type colors and the locked
    // white-text rule untouched.
    // MP-06B (owner correction 2026-08-17, HIGHEST AUTHORITY): the draft
    // surface follows the APP THEME FAMILY using existing semantic tokens
    // only - fill = colorScheme.primaryContainer (soft same-family
    // container), accent = colorScheme.primary (strong same-family token
    // for the left accent bar and the grips), text =
    // colorScheme.onPrimaryContainer. Blue appearance -> blue-family draft,
    // Rose appearance -> rose-family draft, in both Light and Dark; the
    // Event Type never recolors the draft. Grip vs fill stay distinguishable
    // in every appearance (contrast contract).
    final colorScheme = Theme.of(context).colorScheme;
    final accent = provisional ? colorScheme.primary : resolvedAccent;
    // Saved Event blocks retain their Event Type surface.  The status badge is
    // the sole outcome treatment; provisional drafts keep their established
    // theme-family surface.
    final fill = provisional ? colorScheme.primaryContainer : resolvedFill;
    final textColorOverride = provisional
        ? colorScheme.onPrimaryContainer
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : PlannerEventBlockLayoutPolicy.mediumThreshold + 1;
        final content = PlannerEventBlockContent.forHeight(
          availableHeight,
          interactive: interactive,
          // Delta 4.1 D4.1-04: the unsaved draft block shows TIME ONLY
          // (approved provisional surface) — never the Event Type title.
          showTimeOnly: provisional,
        );
        // S2B-02: reuse the exact content subtree while the render
        // fingerprint is unchanged (same tier + same facts).
        final eventContent = _resolveContent(
          content: content,
          accent: accent,
          fill: fill,
          textColorOverride: textColorOverride,
        );
        final eventBody = InkWell(
          // R6-06: bulk mode has one tap owner around the complete visible
          // card below. Keeping a second InkWell action here would let one
          // physical tap toggle twice or open Preview through a competing hit
          // layer. Normal mode retains the approved Preview action.
          onTap: provisional || selectionMode ? null : onTap,
          child: event.isBackupAppointment
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
                ),
        );
        return Semantics(
          button: true,
          label:
              '${event.displayTitle}, ${event.activityTypeLabel ?? 'Calendar Event'}, '
              '${formatPlannerEventRange(displayStartMinute, displayEndMinute, use24HourTime)}'
              '${event.isBackupAppointment ? ', Backup Appointment' : ''}'
              '${awaitingReport ? ', Unreported' : ''}'
              '${event.linkedTaskIds.isEmpty ? '' : ', ${event.linkedTaskIds.length} linked Task(s)'}',
          hint: interactive
              ? provisional
                    ? 'Unsaved Event. Drag the body to move it or drag an endpoint handle to resize it.'
                    : selectedForDirectManipulation
                    ? 'Tap for details. Drag the body to move it or drag an endpoint handle to resize it.'
                    : 'Tap for details. Long-press to select and move.'
              : 'Tap for details.',
          child: Builder(
            builder: (context) {
              final card = Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      // Delta 4.2R2 R2-01/R2-02: a finger pressing a directly-
                      // manipulable body pre-claims the day-swipe coordinator so
                      // the raw-pointer day pager drops its swipe candidate. The
                      // Event's own drag recognizers then win the gesture arena
                      // (they are deeper than the day-scroll's recognizer), so
                      // the body drag moves the Event and the timeline cannot
                      // steal it. No physics swap happens here: swapping the
                      // scrollable physics on pointer-down rebuilt the whole
                      // gesture subtree mid-gesture and cancelled the recognizers
                      // before the drag could start (owner-review regression).
                      onPointerDown: interactive && !selectionMode
                          ? onDirectPointerDown
                          : null,
                      child: RawGestureDetector(
                        behavior: HitTestBehavior.opaque,
                        gestures: interactive && !selectionMode
                            ? <Type, GestureRecognizerFactory>{
                                // Delta 4.2R2: the LongPress recognizer stays in
                                // the map for BOTH selection states. RawGesture-
                                // Detector reuses recognizers by type, so when a
                                // long-press selects the Event (a rebuild changes
                                // the map from {LongPress} to {LongPress, drags})
                                // the LongPress recognizer that already won the
                                // gesture arena survives with updated handlers and
                                // the in-flight drag keeps moving the Event. The
                                // previous code dropped LongPress on selection,
                                // disposing the winning recognizer mid-gesture and
                                // freezing the drag (owner-review R2-01/R2-02).
                                LongPressGestureRecognizer:
                                    GestureRecognizerFactoryWithHandlers<
                                      LongPressGestureRecognizer
                                    >(
                                      () => LongPressGestureRecognizer(
                                        duration: const Duration(
                                          milliseconds: 300,
                                        ),
                                      ),
                                      (recognizer) {
                                        recognizer
                                            .onLongPressStart = (details) {
                                          unawaited(
                                            HapticFeedback.mediumImpact(),
                                          );
                                          // Only begin a fresh manipulation
                                          // session for a not-yet-selected saved
                                          // Event (or the always-manipulable
                                          // draft). A long-press on an Event that
                                          // is already the active one must not
                                          // restart the session mid-gesture.
                                          if (provisional ||
                                              !selectedForDirectManipulation) {
                                            onMoveStart(details.globalPosition);
                                          }
                                        };
                                        recognizer.onLongPressMoveUpdate =
                                            (details) => onLongPressMoveUpdate(
                                              details.globalPosition,
                                            );
                                        recognizer.onLongPressEnd = (_) =>
                                            onMoveEnd();
                                        recognizer.onLongPressCancel =
                                            onMoveCancel;
                                      },
                                    ),
                                if (selectedForDirectManipulation)
                                  HorizontalDragGestureRecognizer:
                                      GestureRecognizerFactoryWithHandlers<
                                        HorizontalDragGestureRecognizer
                                      >(HorizontalDragGestureRecognizer.new, (
                                        recognizer,
                                      ) {
                                        recognizer.dragStartBehavior =
                                            DragStartBehavior.down;
                                        recognizer.onStart = (details) =>
                                            onMoveStart(details.globalPosition);
                                        recognizer.onUpdate = (details) =>
                                            onMoveUpdate(
                                              details.globalPosition,
                                            );
                                        recognizer.onEnd = (_) => onMoveEnd();
                                        recognizer.onCancel = onMoveCancel;
                                      }),
                                if (selectedForDirectManipulation)
                                  VerticalDragGestureRecognizer:
                                      GestureRecognizerFactoryWithHandlers<
                                        VerticalDragGestureRecognizer
                                      >(VerticalDragGestureRecognizer.new, (
                                        recognizer,
                                      ) {
                                        recognizer.dragStartBehavior =
                                            DragStartBehavior.down;
                                        recognizer.onStart = (details) =>
                                            onMoveStart(details.globalPosition);
                                        recognizer.onUpdate = (details) =>
                                            onMoveUpdate(
                                              details.globalPosition,
                                            );
                                        recognizer.onEnd = (_) => onMoveEnd();
                                        recognizer.onCancel = onMoveCancel;
                                      }),
                              }
                            : const <Type, GestureRecognizerFactory>{},
                        child: Material(
                          color: fill,
                          shape: RoundedRectangleBorder(
                            // Delta 4.2R R12: contiguous blocks square their
                            // corners on the shared edge only; every other corner
                            // keeps the approved small radius.
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(
                                squareTop
                                    ? 0
                                    : PlannerEventBlockLayoutPolicy.effectiveRadiusFor(
                                        availableHeight,
                                      ),
                              ),
                              topRight: Radius.circular(
                                squareTop
                                    ? 0
                                    : PlannerEventBlockLayoutPolicy.effectiveRadiusFor(
                                        availableHeight,
                                      ),
                              ),
                              bottomLeft: Radius.circular(
                                squareBottom
                                    ? 0
                                    : PlannerEventBlockLayoutPolicy.effectiveRadiusFor(
                                        availableHeight,
                                      ),
                              ),
                              bottomRight: Radius.circular(
                                squareBottom
                                    ? 0
                                    : PlannerEventBlockLayoutPolicy.effectiveRadiusFor(
                                        availableHeight,
                                      ),
                              ),
                            ),
                            // R6-05: a one-pixel inner outline makes touching
                            // neighbors read as separate cards without changing
                            // their canonical rectangles, minutes, or hit areas.
                            side: provisional
                                ? BorderSide.none
                                : BorderSide(
                                    color: AppTheme.background.withValues(
                                      alpha: 0.72,
                                    ),
                                    width: 1,
                                  ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: event.isBackupAppointment
                              ? PlannerBackupStripeBackground(
                                  accent: resolvedAccent,
                                  surfaceColor: fill,
                                  accentKey: Key(
                                    'planner-backup-accent-strip-${event.id}',
                                  ),
                                  surfaceKey: Key(
                                    'planner-backup-event-surface-${event.id}',
                                  ),
                                  child: eventBody,
                                )
                              : eventBody,
                        ),
                      ),
                    ),
                  ),
                  if (selectionMode)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Icon(
                        selected
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : AppTheme.onFillTextOf(context, 1.0),
                        size: 20,
                      ),
                    ),
                ],
              );
              if (!selectionMode || provisional) {
                return card;
              }
              return GestureDetector(
                key: Key('planner-event-selection-target-${event.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: onToggleSelection,
                child: card,
              );
            },
          ),
        );
      },
    );
  }
}

/// Format a [DateTime] (interpreted as a local wall-clock time) to
/// the planner's required 12-hour current-time label: `h:mm a`,
/// with no leading zero on the hour, two digits for minutes,
/// uppercase AM/PM, and no seconds or timezone suffix. Centralised
/// here so both the production widget and the focused current-time
/// tests can pin the exact format without duplicating arithmetic.
String formatPlannerCurrentTimeLabel(DateTime now) {
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

final class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelection,
  });

  final PlannerTask task;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelection;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        key: Key('planner-task-${task.id}'),
        leading: selectionMode
            ? Icon(
                selected ? Icons.check_box : Icons.check_box_outline_blank,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white70,
              )
            : Icon(
                Icons.task_alt_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
        title: Text(task.title),
        subtitle: Text(_taskSubtitle(task)),
        trailing: const Icon(Icons.chevron_right),
        onTap: selectionMode
            ? onToggleSelection
            : () => showTaskPreview<void>(context: context, taskId: task.id),
      ),
    );
  }

  static String _taskSubtitle(PlannerTask task) {
    final due = task.dueDate;
    return due == null ? 'No due date' : 'Due ${due.iso8601}';
  }
}

final class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.event,
    this.awaitingReport = false,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelection,
  });

  final PlannerCalendarItem event;
  final bool awaitingReport;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelection;

  @override
  Widget build(BuildContext context) {
    final detail = <String>[
      if (event.timing == PlannerEventTiming.allDay) 'All day',
      if (event.timing == PlannerEventTiming.timed)
        '${_time(event.startLocal)} – ${_time(event.endLocal)}',
      if (event.locationText != null) event.locationText!,
      if (event.linkedTaskIds.isNotEmpty)
        '${event.linkedTaskIds.length} linked Task(s)',
      if (awaitingReport) 'Unreported',
      if (event.isBackupAppointment) 'Backup Appointment',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: event.isBackupAppointment
              ? const Border(left: BorderSide(color: Colors.black, width: 7))
              : null,
        ),
        child: ListTile(
          key: Key('planner-event-${event.id}'),
          leading: selectionMode
              ? Icon(
                  selected ? Icons.check_box : Icons.check_box_outline_blank,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white70,
                )
              : Icon(
                  awaitingReport
                      ? Icons.assignment_late_outlined
                      : event.timing == PlannerEventTiming.allDay
                      ? Icons.event_available_outlined
                      : Icons.schedule,
                  color: awaitingReport
                      ? AppTheme.warning
                      : AppTheme.eventAccent,
                ),
          title: Row(
            children: <Widget>[
              Flexible(child: Text(event.title)),
              if (event.isRecurring) ...const <Widget>[
                SizedBox(width: 6),
                Icon(Icons.repeat, size: 16),
              ],
              if (event.isBackupAppointment) ...const <Widget>[
                SizedBox(width: 6),
                Icon(Icons.layers_outlined, size: 16),
              ],
            ],
          ),
          subtitle: Text(detail),
          trailing: selectionMode
              ? null
              : event.locationText == null
              ? const Icon(Icons.chevron_right)
              : IconButton(
                  tooltip: 'Open contextual map action',
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'The stored location remains visible. Map handoff is '
                        'not available in this authorized build.',
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.map_outlined),
                ),
          onTap: selectionMode
              ? onToggleSelection
              : () => _openCalendarEvent(context, event),
        ),
      ),
    );
  }

  static String _time(DateTime? value) {
    if (value == null) {
      return 'Time not set';
    }
    final hour = value.hour == 0
        ? 12
        : value.hour > 12
        ? value.hour - 12
        : value.hour;
    return '$hour:${value.minute.toString().padLeft(2, '0')} '
        '${value.hour >= 12 ? 'PM' : 'AM'}';
  }
}

final class _SchedulePresentation extends StatelessWidget {
  const _SchedulePresentation({
    required this.days,
    required this.settings,
    required this.selectionMode,
    required this.selectedItems,
    required this.onToggleEvent,
    required this.onToggleTask,
  });

  final List<PlannerDay> days;
  final PlannerSettings settings;
  final bool selectionMode;
  final Set<PlannerSelectionId> selectedItems;
  final ValueChanged<PlannerCalendarItem> onToggleEvent;
  final ValueChanged<PlannerTask> onToggleTask;

  @override
  Widget build(BuildContext context) {
    final filters = settings.contentFilters;
    return ListView(
      key: const Key('planner-schedule-view'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: <Widget>[
        for (final day in days) ...<Widget>[
          Text(
            day.selectedDate.iso8601,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          for (final event in <PlannerCalendarItem>[
            ...day.allDayEvents,
            ...day.timedEvents,
          ])
            if (event.isBackupAppointment
                ? filters.backupEvents
                : filters.events)
              _EventTile(
                event: event,
                awaitingReport: event.isAwaitingReport(DateTime.now()),
                selectionMode: selectionMode,
                selected: selectedItems.contains(
                  PlannerSelectionId(
                    kind: PlannerSelectionKind.event,
                    id: event.id,
                  ),
                ),
                onToggleSelection: () => onToggleEvent(event),
              ),
          if (filters.tasks)
            for (final task in <PlannerTask>[
              ...day.overdueTasks,
              ...day.tasks,
              if (filters.completedTasks) ...day.completedTasks,
            ])
              _TaskTile(
                task: task,
                selectionMode: selectionMode,
                selected: selectedItems.contains(
                  PlannerSelectionId(
                    kind: PlannerSelectionKind.task,
                    id: task.id,
                  ),
                ),
                onToggleSelection: () => onToggleTask(task),
              ),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

final class _WeekPresentation extends StatelessWidget {
  const _WeekPresentation({
    required this.days,
    required this.settings,
    required this.onSelected,
  });

  final List<PlannerDay> days;
  final PlannerSettings settings;
  final ValueChanged<PlannerDate> onSelected;

  @override
  Widget build(BuildContext context) {
    final filters = settings.contentFilters;
    return ListView(
      key: const Key('planner-week-view'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: <Widget>[
        for (final day in days)
          Card(
            child: InkWell(
              onTap: () => onSelected(day.selectedDate),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 76,
                      child: Text(
                        day.selectedDate.iso8601,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          for (final event in <PlannerCalendarItem>[
                            ...day.allDayEvents,
                            ...day.timedEvents,
                          ])
                            if (event.isBackupAppointment
                                ? filters.backupEvents
                                : filters.events)
                              Chip(
                                key: Key('planner-week-event-${event.id}'),
                                avatar: Icon(
                                  event.isBackupAppointment
                                      ? Icons.layers_outlined
                                      : event.isAwaitingReport(DateTime.now())
                                      ? Icons.assignment_late_outlined
                                      : Icons.event_outlined,
                                  size: 16,
                                ),
                                label: Text(
                                  event.title,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          if (filters.tasks)
                            for (final task in day.tasks)
                              Chip(
                                avatar: const Icon(
                                  Icons.task_alt_outlined,
                                  size: 16,
                                ),
                                label: Text(task.title),
                              ),
                          if (<Object>[
                            ...day.allDayEvents,
                            ...day.timedEvents,
                            ...day.tasks,
                          ].isEmpty)
                            const Text(
                              'No visible items',
                              style: TextStyle(color: Colors.white54),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// RETIRED (owner decision, 2026-09-20): `_TasksPresentation` — the in-Planner
// Tasks list (key `planner-tasks-view`) — is gone.  Tasks have exactly ONE
// canonical home, the Tasks screen, and the Planner's overflow `Tasks` row now
// opens it.  The Planner's own day/schedule/week presentations are untouched.

final class _AwaitingPresentation extends StatelessWidget {
  const _AwaitingPresentation({
    required this.days,
    required this.settings,
    required this.selectionMode,
    required this.selectedItems,
    required this.onToggleEvent,
  });

  final List<PlannerDay> days;
  final PlannerSettings settings;
  final bool selectionMode;
  final Set<PlannerSelectionId> selectedItems;
  final ValueChanged<PlannerCalendarItem> onToggleEvent;

  @override
  Widget build(BuildContext context) {
    final events =
        <String, PlannerCalendarItem>{
              for (final day in days)
                for (final event in day.awaitingReportEvents) event.id: event,
            }.values
            .where((event) {
              return event.isBackupAppointment
                  ? settings.contentFilters.backupEvents
                  : settings.contentFilters.events;
            })
            .toList(growable: false);
    return ListView(
      key: const Key('planner-awaiting-reports-view'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: <Widget>[
        const _ViewHeading('Unreported Events'),
        if (events.isEmpty)
          const _EmptySectionMessage('No qualifying reports are pending.')
        else
          for (final event in events)
            _EventTile(
              event: event,
              awaitingReport: true,
              selectionMode: selectionMode,
              selected: selectedItems.contains(
                PlannerSelectionId(
                  kind: PlannerSelectionKind.event,
                  id: event.id,
                ),
              ),
              onToggleSelection: () => onToggleEvent(event),
            ),
      ],
    );
  }
}

final class _ViewHeading extends StatelessWidget {
  const _ViewHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

final class _PlannerSearchDelegate extends SearchDelegate<void> {
  _PlannerSearchDelegate({required this.day});

  final PlannerDay day;

  @override
  String get searchFieldLabel => 'Search Planner';

  @override
  List<Widget> buildActions(BuildContext context) => <Widget>[
    if (query.isNotEmpty)
      IconButton(
        tooltip: 'Clear search',
        onPressed: () => query = '',
        icon: const Icon(Icons.clear),
      ),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    tooltip: 'Close search',
    onPressed: () => close(context, null),
    icon: const Icon(Icons.arrow_back),
  );

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final events =
        <PlannerCalendarItem>[...day.allDayEvents, ...day.timedEvents].where(
          (event) =>
              normalized.isEmpty ||
              <String?>[
                event.title,
                event.locationText,
                event.activityTypeLabel,
              ].whereType<String>().any(
                (value) => value.toLowerCase().contains(normalized),
              ),
        );
    final tasks =
        <PlannerTask>[
          ...day.overdueTasks,
          ...day.tasks,
          ...day.completedTasks,
        ].where(
          (task) =>
              normalized.isEmpty ||
              <String?>[task.title, task.notes].whereType<String>().any(
                (value) => value.toLowerCase().contains(normalized),
              ),
        );
    return ListView(
      children: <Widget>[
        for (final event in events) _EventTile(event: event),
        for (final task in tasks) _TaskTile(task: task),
      ],
    );
  }
}

/// The shared canonical Event-opening law lives in `planner_event_open.dart`
/// so the Unreported hub reaches the SAME detail/report flow.  Every existing
/// Planner call site keeps using this name.
void _openCalendarEvent(BuildContext context, PlannerCalendarItem event) =>
    openPlannerCalendarEvent(context, event);

final class _EmptySectionMessage extends StatelessWidget {
  const _EmptySectionMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardOf(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.outlineOf(context)),
      ),
      child: Text(message, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

final class _PlannerNotice extends StatelessWidget {
  const _PlannerNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
        border: Border.all(color: Theme.of(context).colorScheme.primary),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message),
    );
  }
}

final class _PlannerFailure extends StatelessWidget {
  const _PlannerFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
