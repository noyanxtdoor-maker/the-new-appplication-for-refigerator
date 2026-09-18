import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/notification_preview_policy.dart';
import 'package:rmplanner/features/notifications/application/launcher_badge_providers.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/notifications/domain/task_reminder_occurrence.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

final plannerRepositoryProvider = Provider<PlannerRepository>((ref) {
  throw StateError('PlannerRepository must be overridden at the app root');
});

final plannerDateSourceProvider = Provider<PlannerDateSource>((ref) {
  return const SystemPlannerDateSource();
});

final plannerIdentifierSourceProvider = Provider<IdentifierSource>((ref) {
  return const UuidIdentifierSource();
});

typedef TaskReminderHorizonOverride =
    Future<void> Function(bool refreshContent);

final taskReminderHorizonOverrideProvider =
    Provider<TaskReminderHorizonOverride?>((ref) => null);

enum PlannerLoadStatus { loading, ready, failure }

/// Transient identities hidden while one or more Calendar Event deletions are
/// being reconciled with canonical Planner reads.
///
/// Occurrence deletion is keyed by the deterministic occurrence ID used by
/// [PlannerCalendarItem.id]. Entire-series deletion is keyed by the canonical
/// Calendar Event ID carried by [PlannerCalendarItem.eventId]. This value is
/// intentionally application-memory only; it is never persisted.
///
/// Confirmation scope is carried as EXPLICIT transient metadata, never
/// inferred from the hide identities: ThisAndFuture hides one occurrence but
/// must confirm BROAD because its durable mutation affects future dates.
final class PlannerEventDeletionTargetSet {
  PlannerEventDeletionTargetSet({
    Iterable<String> occurrenceIds = const <String>[],
    Iterable<String> seriesIds = const <String>[],
    Iterable<PlannerDate> confirmationDates = const <PlannerDate>[],
    this.confirmAllCachedDays = true,
  }) : occurrenceIds = Set<String>.unmodifiable(
         occurrenceIds.where((id) => id.trim().isNotEmpty),
       ),
       seriesIds = Set<String>.unmodifiable(
         seriesIds.where((id) => id.trim().isNotEmpty),
       ),
       confirmationDates = Set<PlannerDate>.unmodifiable(confirmationDates);

  /// A clicked occurrence can only exist on its own original date, so its
  /// canonical confirmation re-reads exactly that one date. Legacy/manual
  /// constructors default to [confirmAllCachedDays] = true, preserving the
  /// OLD broad confirmation behavior.
  factory PlannerEventDeletionTargetSet.occurrence({
    required String eventId,
    required PlannerDate originalDate,
  }) {
    return PlannerEventDeletionTargetSet(
      occurrenceIds: <String>{
        CalendarEventOccurrenceIdentity.forDate(
          eventId: eventId,
          originalDate: originalDate,
        ),
      },
      confirmationDates: <PlannerDate>{originalDate},
      confirmAllCachedDays: false,
    );
  }

  factory PlannerEventDeletionTargetSet.series(String eventId) {
    return PlannerEventDeletionTargetSet(
      seriesIds: <String>{eventId},
      confirmAllCachedDays: true,
    );
  }

  /// ThisAndFuture hides ONLY the clicked occurrence but confirms broad: its
  /// durable mutation affects multiple future dates, whose cached days must
  /// be re-read so no stale copy survives.
  factory PlannerEventDeletionTargetSet.thisAndFuture({
    required String eventId,
    required PlannerDate originalDate,
  }) {
    return PlannerEventDeletionTargetSet(
      occurrenceIds: <String>{
        CalendarEventOccurrenceIdentity.forDate(
          eventId: eventId,
          originalDate: originalDate,
        ),
      },
      confirmAllCachedDays: true,
    );
  }

  final Set<String> occurrenceIds;
  final Set<String> seriesIds;

  /// Explicit dates the canonical confirmation may re-read. Empty means
  /// "no narrow scope" and the broad set applies.
  final Set<PlannerDate> confirmationDates;

  /// True when confirmation must re-read the selected day and every cached
  /// day (series and thisAndFuture, plus every legacy/manual target).
  final bool confirmAllCachedDays;

  bool get isEmpty => occurrenceIds.isEmpty && seriesIds.isEmpty;

  bool hides(PlannerCalendarItem event) {
    return occurrenceIds.contains(event.id) ||
        (event.eventId != null && seriesIds.contains(event.eventId));
  }
}

final class PlannerState {
  const PlannerState({
    required this.status,
    required this.selectedDate,
    required this.historicalItemsExpanded,
    this.eventDeletionRevision = 0,
    this.day,
    this.message,
  });

  final PlannerLoadStatus status;
  final PlannerDate selectedDate;
  final PlannerDay? day;
  final bool historicalItemsExpanded;
  final int eventDeletionRevision;
  final String? message;

  PlannerState copyWith({
    PlannerLoadStatus? status,
    PlannerDate? selectedDate,
    PlannerDay? day,
    bool clearDay = false,
    bool? historicalItemsExpanded,
    int? eventDeletionRevision,
    String? message,
    bool clearMessage = false,
  }) {
    return PlannerState(
      status: status ?? this.status,
      selectedDate: selectedDate ?? this.selectedDate,
      day: clearDay ? null : day ?? this.day,
      historicalItemsExpanded:
          historicalItemsExpanded ?? this.historicalItemsExpanded,
      eventDeletionRevision:
          eventDeletionRevision ?? this.eventDeletionRevision,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}

final plannerControllerProvider =
    NotifierProvider<PlannerController, PlannerState>(PlannerController.new);

final class PlannerController extends Notifier<PlannerState> {
  static const int _dayCacheLimit = 15;
  int _loadGeneration = 0;
  int _dayCacheRevision = 0;
  final Map<PlannerDate, PlannerDay> _dayCache = <PlannerDate, PlannerDay>{};

  /// [S1B-02] Bounded transient in-flight map: one canonical repository read
  /// per (date) within a cache revision, shared by every caller. Completed
  /// futures remove themselves; a cache invalidation clears the map so a
  /// stale future is never adopted under a newer revision.
  final Map<PlannerDate, Future<PlannerDay>> _inFlightDayReads =
      <PlannerDate, Future<PlannerDay>>{};
  final Map<String, int> _pendingOccurrenceDeletionCounts = <String, int>{};
  final Map<String, int> _pendingSeriesDeletionCounts = <String, int>{};
  PlannerDay? _selectedCanonicalDay;

  PlannerRepository get _repository => ref.read(plannerRepositoryProvider);
  PlannerDateSource get _dateSource => ref.read(plannerDateSourceProvider);

  String get _profileId {
    final runtimeProfile = ref.read(reminderRuntimeProfileIdProvider);
    if (runtimeProfile != null) return runtimeProfile;
    final startup = ref.read(startupControllerProvider);
    if (startup is! StartupReady) {
      throw StateError('Planner requires a ready Local Profile');
    }
    return startup.profile.id;
  }

  @override
  PlannerState build() {
    ref.onDispose(() => _loadGeneration++);
    final today = _dateSource.today();
    if (ref.read(reminderRuntimeProfileIdProvider) == null) {
      unawaited(Future<void>.microtask(() => _load(today)));
    }
    return PlannerState(
      status: PlannerLoadStatus.loading,
      selectedDate: today,
      historicalItemsExpanded: true,
    );
  }

  Future<void> selectDate(PlannerDate date) {
    if (date == state.selectedDate) {
      // Same-date refresh (Event save, report submit, Task link): reload in
      // place while keeping the visible schedule (no spinner flash).
      return _load(date, invalidateCache: true);
    }
    // R5-04/R5-06: direct selection publishes the target date immediately.
    // If that exact day was already read canonically in this controller
    // session, publish date + matching PlannerDay atomically on the first
    // frame, then refresh it from Drift. Otherwise clear the old day so an
    // old-date Event can never paint under the new date while the read runs.
    return _load(date, publishDateImmediately: true);
  }

  /// Loads the adjacent day before publishing the new selected-date state.
  ///
  /// The interactive pager keeps the destination page exposed until this
  /// future completes. Publishing `selectedDate` first would pair the new
  /// page key with the previous day's [PlannerDay] for one or more frames,
  /// which is the stale-schedule flash this route must avoid.
  Future<void> moveDays(int days) async {
    final date = state.selectedDate.addDays(days);
    await _load(date, rethrowOnFailure: true);
  }

  /// [S1B-03] Pager commit handoff for a committed day-swipe.
  ///
  /// When the adjacent destination is already in the canonical day cache the
  /// target `selectedDate` + matching cached [PlannerDay] are published
  /// ATOMICALLY and this future returns immediately, so the pager recenters
  /// and clears its settle lock without waiting for a canonical repository
  /// read. The canonical refresh runs in the background under the captured
  /// generation: a newer navigation bumps the generation and the stale
  /// refresh is dropped, so it can never restore an old date or schedule.
  ///
  /// An UNCACHED target keeps the existing await semantics (date-aware
  /// loading page; never the previous date's Events). This narrow path is
  /// used only by the interactive pager; direct date selection
  /// ([selectDate]) and mutation refresh keep their original behavior.
  Future<void> moveDaysForPager(int days) async {
    final date = state.selectedDate.addDays(days);
    final cached = _dayCache[date];
    if (cached == null) {
      await _load(date, rethrowOnFailure: true);
      return;
    }
    final generation = ++_loadGeneration;
    // Reinsert to make the bounded insertion-ordered map act as a tiny LRU.
    _dayCache.remove(date);
    _dayCache[date] = cached;
    _selectedCanonicalDay = cached;
    state = state.copyWith(
      status: PlannerLoadStatus.ready,
      selectedDate: date,
      day: filterPendingEventDeletions(cached),
      clearMessage: true,
    );
    unawaited(_refreshCanonicalInBackground(date, generation));
    _prefetchRollingRunway();
  }

  /// Background canonical refresh for the [moveDaysForPager] handoff.
  ///
  /// Reads the target day from the repository and republishes it ONLY if:
  ///   * the captured generation is still the newest (a newer navigation or
  ///     mutation bumped [PlannerController._loadGeneration]); and
  ///   * the fresh result is not semantically identical to the currently
  ///     visible day (S1B-04), which would otherwise cause a second visible
  ///     presentation correction.
  ///
  /// Failures are silent: the cached target already published and the pager
  /// already unlocked.
  Future<void> _refreshCanonicalInBackground(
    PlannerDate date,
    int generation,
  ) async {
    try {
      final day = await _readDayCanonical(date);
      if (generation != _loadGeneration) {
        return;
      }
      final visible = state.day;
      final filteredFresh = filterPendingEventDeletions(day);
      if (visible != null &&
          visible.selectedDate == date &&
          _daysSemanticallyEqual(visible, filteredFresh)) {
        // S1B-04: equivalent refresh — preserve the existing visible/cache
        // object identity; only touch LRU order.
        final existing = _dayCache[date] ?? visible;
        _dayCache.remove(date);
        _dayCache[date] = existing;
        _selectedCanonicalDay = existing;
        return;
      }
      _cacheDay(day);
      _selectedCanonicalDay = day;
      state = state.copyWith(
        status: PlannerLoadStatus.ready,
        selectedDate: date,
        day: filteredFresh,
        clearMessage: true,
      );
    } on Object {
      // Silent: the cached day remains authoritative.
    }
  }

  /// [S1B-05] Rolling bounded prefetch runway.
  ///
  /// After a committed navigation, asynchronously warm the dates within ±3 of
  /// the newly selected date. [readDays] is cache-first, so dates already in
  /// the canonical cache cost ZERO repository reads; only newly missing edge
  /// dates are fetched. The cache remains bounded at [_dayCacheLimit]. This
  /// is read-only and never changes [PlannerState.selectedDate]; failures are
  /// silent and never replace the current day.
  void _prefetchRollingRunway() {
    final center = state.selectedDate;
    final missing = <PlannerDate>[];
    for (var offset = -3; offset <= 3; offset++) {
      final date = center.addDays(offset);
      if (!_dayCache.containsKey(date)) {
        missing.add(date);
      }
    }
    if (missing.isEmpty) {
      return;
    }
    unawaited(readDays(missing).then<void>((_) {}).catchError((_) => <void>[]));
  }

  /// [S1B-06] Narrow read accessor for presentation.
  ///
  /// Returns the canonical cached [PlannerDay] for [date] (with active
  /// pending-deletion tombstones filtered) or `null` when the date is not
  /// cached. The screen uses this to seed its presentation preview cache so a
  /// date already available in the controller cache renders immediately
  /// without waiting for a new preview future. Only a value is exposed — the
  /// cache map itself stays private.
  PlannerDay? cachedDay(PlannerDate date) {
    final cached = _dayCache[date];
    return cached == null ? null : filterPendingEventDeletions(cached);
  }

  /// Refresh the currently selected Planner day without changing
  /// [PlannerState.selectedDate]. The same repository read used by
  /// date navigation runs in place, so the screen receives a fresh
  /// [PlannerState.day] and any signature derived from the
  /// selected-day content bumps naturally. Adjacent preview
  /// caches that compose their cache key from that signature will
  /// then refetch on the next build without a manual
  /// selected-date round trip.
  Future<void> refresh() => _load(state.selectedDate, invalidateCache: true);

  /// Cache-first day reads for preview windows and alternate presentations.
  ///
  /// [S1B-01] Requests are served in the exact input order. Dates already in
  /// the canonical day cache are returned immediately with ZERO repository
  /// reads; only true misses hit the repository. Every resolved miss is cached
  /// (bounded at [_dayCacheLimit]) and the pending-deletion filter is applied
  /// to each returned day.
  ///
  /// If the cache revision changes while a miss is in flight (a mutation or
  /// pending-deletion transition invalidated the cache), the whole request is
  /// retried under the newest revision. Cache hits are still free on the retry,
  /// so the recursion cannot re-read already-valid dates forever.
  Future<List<PlannerDay>> readDays(Iterable<PlannerDate> dates) async {
    final requestedDates = dates.toList(growable: false);
    if (requestedDates.isEmpty) {
      return <PlannerDay>[];
    }
    final cacheRevision = _dayCacheRevision;
    final misses = <PlannerDate>[];
    final resolved = <PlannerDay?>[];
    for (final date in requestedDates) {
      final cached = _dayCache[date];
      if (cached != null) {
        resolved.add(cached);
      } else {
        resolved.add(null);
        misses.add(date);
      }
    }
    if (misses.isNotEmpty) {
      final fetched = await Future.wait(misses.map(_readDayCanonical));
      // S1B-01 (revision contract): an Event/Task mutation may invalidate the
      // cache while this read is in flight. Never repopulate the cache from
      // that older result — discard it and retry under the newest revision.
      // Otherwise the retry below could resolve from the just-repopulated
      // stale entry and return stale rows to a pager FutureBuilder.
      if (cacheRevision != _dayCacheRevision) {
        return readDays(requestedDates);
      }
      var missIndex = 0;
      for (var index = 0; index < resolved.length; index++) {
        if (resolved[index] == null) {
          final day = fetched[missIndex++];
          resolved[index] = day;
          _cacheDay(day);
        }
      }
    } else {
      // S1B-01 (deletion-revision contract): an all-cache-hit request still
      // yields once so a pending-deletion revision bump that lands between
      // the call and the awaited result is honored below. Without this, a
      // cached date read before a tombstone transition could resolve
      // unfiltered after the deletion started.
      await Future<void>.value();
      if (cacheRevision != _dayCacheRevision) {
        return readDays(requestedDates);
      }
    }
    // Already-valid cache hits resolve with zero repository reads on any
    // retry, so the recursion above cannot re-read valid dates forever.
    return <PlannerDay>[
      for (final day in resolved)
        if (day != null) filterPendingEventDeletions(day),
    ];
  }

  /// Atomically publishes the complete Event target set as pending deletion.
  /// Every currently visible PlannerDay is immediately filtered in one state
  /// update; canonical repository work may then run serially without exposing
  /// intermediate Event-by-Event disappearance.
  void beginPendingEventDeletion(PlannerEventDeletionTargetSet targets) {
    if (targets.isEmpty) {
      return;
    }
    _incrementCounts(_pendingOccurrenceDeletionCounts, targets.occurrenceIds);
    _incrementCounts(_pendingSeriesDeletionCounts, targets.seriesIds);
    _publishEventDeletionRevision();
  }

  /// Rolls back only [targets], preserving any overlapping deletion owned by
  /// another active operation through reference counts.
  void rollbackPendingEventDeletion(PlannerEventDeletionTargetSet targets) {
    if (targets.isEmpty) {
      return;
    }
    _decrementCounts(_pendingOccurrenceDeletionCounts, targets.occurrenceIds);
    _decrementCounts(_pendingSeriesDeletionCounts, targets.seriesIds);
    _publishEventDeletionRevision();
  }

  /// Refreshes every currently selected/cached canonical day while [targets]
  /// remain filtered. The tombstones are removed only after those canonical
  /// reads confirm that no target is still a visible Calendar Event.
  ///
  /// A failed read or a still-present target is treated as a failed deletion:
  /// the tombstones are rolled back so data is never silently hidden.
  Future<bool> confirmPendingEventDeletion(
    PlannerEventDeletionTargetSet targets,
  ) async {
    if (targets.isEmpty) {
      return true;
    }
    final Set<PlannerDate> dates;
    if (!targets.confirmAllCachedDays && targets.confirmationDates.isNotEmpty) {
      // Explicit narrow occurrence scope: confirm only the original date. A
      // clicked occurrence can only ever exist on that one day.
      dates = targets.confirmationDates;
    } else {
      // Series, thisAndFuture, and every legacy/manual target keep the OLD
      // BROAD confirmation: selected day + every cached day.
      dates = <PlannerDate>{state.selectedDate, ..._dayCache.keys};
    }
    final refreshRevision = ++_dayCacheRevision;
    _loadGeneration += 1;
    try {
      final days = await Future.wait(
        dates.map(
          (date) => _repository.readDay(
            profileId: _profileId,
            selectedDate: date,
            today: _dateSource.today(),
          ),
        ),
      );
      if (refreshRevision != _dayCacheRevision) {
        // Another data transition won while these reads were in flight. Keep
        // the tombstones active and retry against the newest canonical view.
        return confirmPendingEventDeletion(targets);
      }
      final targetStillVisible = days.any(
        (day) => <PlannerCalendarItem>[
          ...day.allDayEvents,
          ...day.timedEvents,
          ...day.awaitingReportEvents,
        ].any(targets.hides),
      );
      if (targetStillVisible) {
        rollbackPendingEventDeletion(targets);
        return false;
      }
      for (final day in days) {
        _cacheDay(day);
        if (day.selectedDate == state.selectedDate) {
          _selectedCanonicalDay = day;
        }
      }
      _decrementCounts(_pendingOccurrenceDeletionCounts, targets.occurrenceIds);
      _decrementCounts(_pendingSeriesDeletionCounts, targets.seriesIds);
      _publishEventDeletionRevision();
      return true;
    } on Object {
      rollbackPendingEventDeletion(targets);
      return false;
    }
  }

  /// Applies the active transient deletion identities to every Event-bearing
  /// PlannerDay list. Task lists and historical change records are preserved.
  PlannerDay filterPendingEventDeletions(PlannerDay day) {
    if (_pendingOccurrenceDeletionCounts.isEmpty &&
        _pendingSeriesDeletionCounts.isEmpty) {
      return day;
    }
    final allDayEvents = day.allDayEvents
        .where((event) => !_isPendingEventDeletion(event))
        .toList(growable: false);
    final timedEvents = day.timedEvents
        .where((event) => !_isPendingEventDeletion(event))
        .toList(growable: false);
    final awaitingReportEvents = day.awaitingReportEvents
        .where((event) => !_isPendingEventDeletion(event))
        .toList(growable: false);
    if (allDayEvents.length == day.allDayEvents.length &&
        timedEvents.length == day.timedEvents.length &&
        awaitingReportEvents.length == day.awaitingReportEvents.length) {
      return day;
    }
    return PlannerDay(
      selectedDate: day.selectedDate,
      allDayEvents: allDayEvents,
      timedEvents: timedEvents,
      tasks: day.tasks,
      overdueTasks: day.overdueTasks,
      completedTasks: day.completedTasks,
      awaitingReportEvents: awaitingReportEvents,
      changes: day.changes,
    );
  }

  void toggleHistoricalItems() {
    state = state.copyWith(
      historicalItemsExpanded: !state.historicalItemsExpanded,
    );
  }

  Future<PlannerTask?> readTask(String taskId) {
    return _repository.readTask(profileId: _profileId, taskId: taskId);
  }

  Future<void> reconcileTaskReminderHorizon({
    bool refreshContent = false,
  }) async {
    final override = ref.read(taskReminderHorizonOverrideProvider);
    if (override != null) {
      await override(refreshContent);
      return;
    }
    if (_repository is! PlannerTaskReminderSource &&
        _repository is! PlannerTaskReminderOccurrenceSource) {
      return;
    }
    final today = _dateSource.today();
    final endDate = today.addDays(42);
    final pending = await ref
        .read(notificationFoundationRepositoryProvider)
        .readReminderWork(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.task,
          windowStartUtc: today.asLocalDate
              .subtract(const Duration(days: 7))
              .toUtc(),
          windowEndUtc: endDate.addDays(2).asLocalDate.toUtc(),
        );
    final List<TaskReminderOccurrence> occurrences;
    if (_repository is PlannerTaskReminderOccurrenceSource) {
      // M8: recurrence-aware bounded projection over today..today+42 using the
      // existing PlannerTask.projectsOn arithmetic.  No per-occurrence Task
      // persistence; whole-Task terminal state removes every projected key.
      occurrences = await (_repository as PlannerTaskReminderOccurrenceSource)
          .readReminderTaskOccurrences(
            profileId: _profileId,
            startDate: today,
            endDate: endDate,
          );
    } else {
      final tasks = await (_repository as PlannerTaskReminderSource)
          .readPendingReminderTasks(
            profileId: _profileId,
            startDate: today,
            endDate: endDate,
          );
      final projectedTasks = [...tasks];
      for (final work in pending) {
        if (work.ownerId == null ||
            projectedTasks.any((task) => task.id == work.ownerId)) {
          continue;
        }
        final task = await _repository.readTask(
          profileId: _profileId,
          taskId: work.ownerId!,
        );
        if (task != null && task.status == PlannerTaskStatus.incomplete) {
          projectedTasks.add(task);
        }
      }
      occurrences = <TaskReminderOccurrence>[
        for (final task in projectedTasks)
          if (task.dueDate != null)
            TaskReminderOccurrence(task: task, projectedDate: task.dueDate!),
      ];
    }
    final preferences = await ref
        .read(notificationFoundationRepositoryProvider)
        .readPreferences(profileId: _profileId);
    final permission = await ref
        .read(permissionGatewayProvider)
        .status(OptionalPermission.notifications);
    final privacy = await ref.read(privacyRepositoryProvider).readSettings();
    final showDetails =
        resolveNotificationPreviewMode(
          settings: privacy,
          privacyProtectionRequired: privacy.lockEnabled,
        ) ==
        EffectiveNotificationPreviewMode.detailed;
    final reconciler = ref.read(reminderReconcilerProvider);
    final expected = <String>{};
    for (final occurrence in occurrences) {
      final task = occurrence.task;
      final date = occurrence.projectedDate;
      final minute = task.dueMinute;
      if (minute == null) continue;
      final occurrenceId = occurrence.occurrenceId;
      final key = ReminderReconciler.stableKey(
        sourceKind: ReminderSourceKind.task,
        profileId: _profileId,
        occurrenceId: occurrenceId,
      );
      await reconciler.reconcile(
        sourceKind: ReminderSourceKind.task,
        profileId: _profileId,
        sourceId: task.id,
        sourceVersion: task.updatedAtUtc.microsecondsSinceEpoch,
        occurrenceId: occurrenceId,
        startsAtUtc: DateTime(
          date.year,
          date.month,
          date.day,
          minute ~/ 60,
          minute % 60,
        ).toUtc(),
        globalOffsetMinutes: preferences.defaultTaskReminderMinutes,
        categoryEnabled: preferences.taskRemindersEnabled,
        systemEnabled: preferences.effectiveSystemEnabled(
          androidPermissionGranted:
              permission == OperatingSystemPermissionState.granted,
        ),
        sourceActive: task.status == PlannerTaskStatus.incomplete,
        genericTitle: ReminderNotificationCopy.genericTitle,
        genericBody: ReminderNotificationCopy.genericBody,
        detailedTitle: ReminderNotificationCopy.taskDetailedTitle,
        detailedBody: _taskReminderBody(task, use24HourTime: false),
        showDetails: showDetails,
        refreshContent: refreshContent,
        renderRevision: showDetails
            ? 'task_detailed_${task.updatedAtUtc.microsecondsSinceEpoch}'
            : 'task_generic',
      );
      final work = await ref
          .read(notificationFoundationRepositoryProvider)
          .readWorkRequest(key);
      if (work != null &&
          switch (work.state) {
            BackgroundWorkState.completed ||
            BackgroundWorkState.queued ||
            BackgroundWorkState.waitingForConstraints ||
            BackgroundWorkState.delayedBySystem ||
            BackgroundWorkState.retryScheduled ||
            BackgroundWorkState.scheduled => true,
            _ => false,
          }) {
        expected.add(key);
      }
    }
    final durable = await ref
        .read(notificationFoundationRepositoryProvider)
        .readReminderWork(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.task,
          windowStartUtc: today.asLocalDate
              .subtract(const Duration(days: 7))
              .toUtc(),
          windowEndUtc: endDate.addDays(2).asLocalDate.toUtc(),
        );
    for (final work in durable) {
      if (expected.contains(work.stableKey) || work.occurrenceId == null) {
        continue;
      }
      await reconciler.cancel(
        sourceKind: ReminderSourceKind.task,
        profileId: _profileId,
        occurrenceId: work.occurrenceId!,
      );
    }
  }

  Future<bool> saveTask(
    PlannerTaskDraft draft, {
    bool confirmLinkedTypeTransfer = false,
    ReminderPolicyMode? reminderMode,
    int? reminderOffsetMinutes,
    bool deferReminderReconciliation = false,
  }) async {
    try {
      final saved = await _repository.saveTask(
        profileId: _profileId,
        draft: draft,
        confirmLinkedTypeTransfer: confirmLinkedTypeTransfer,
      );
      final preferences = await ref
          .read(notificationFoundationRepositoryProvider)
          .readPreferences(profileId: _profileId);
      final permission = await ref
          .read(permissionGatewayProvider)
          .status(OptionalPermission.notifications);
      final privacy = await ref.read(privacyRepositoryProvider).readSettings();
      final showDetails =
          resolveNotificationPreviewMode(
            settings: privacy,
            privacyProtectionRequired: privacy.lockEnabled,
          ) ==
          EffectiveNotificationPreviewMode.detailed;
      final due = saved.dueDate;
      final minute = saved.dueMinute;
      final occurrenceId = 'task:${saved.id}:${due?.iso8601 ?? 'none'}';
      final reconciler = ref.read(reminderReconcilerProvider);
      // A custom policy must become durable before this canonical Task is
      // reconciled.  Saving it afterward leaves the just-created reminder on
      // the global default until some unrelated later edit.
      if (reminderMode != null && due != null && minute != null) {
        await reconciler.savePolicy(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.task,
          sourceId: saved.id,
          occurrenceId: occurrenceId,
          mode: reminderMode,
          offsetMinutes: reminderOffsetMinutes,
        );
      }
      final startsAtUtc = due == null || minute == null
          ? null
          // A Task's due fields are device/profile-local wall time. Construct
          // that local instant first, then convert it; treating the fields as
          // UTC shifts every non-UTC reminder by the local offset.
          : DateTime(
              due.year,
              due.month,
              due.day,
              minute ~/ 60,
              minute % 60,
            ).toUtc();
      // M7 explicit follow-up finalization withholds the early reconcile until
      // the Contacts save and purpose write have committed.
      if (!deferReminderReconciliation) {
        await reconciler.reconcile(
          sourceKind: ReminderSourceKind.task,
          profileId: _profileId,
          sourceId: saved.id,
          occurrenceId: occurrenceId,
          startsAtUtc: startsAtUtc,
          sourceVersion: saved.updatedAtUtc.microsecondsSinceEpoch,
          renderRevision: showDetails
              ? 'task_detailed_${saved.updatedAtUtc.microsecondsSinceEpoch}'
              : 'task_generic',
          globalOffsetMinutes: preferences.defaultTaskReminderMinutes,
          categoryEnabled: preferences.taskRemindersEnabled,
          systemEnabled: preferences.effectiveSystemEnabled(
            androidPermissionGranted:
                permission == OperatingSystemPermissionState.granted,
          ),
          sourceActive: saved.status == PlannerTaskStatus.incomplete,
          genericTitle: ReminderNotificationCopy.genericTitle,
          genericBody: ReminderNotificationCopy.genericBody,
          detailedTitle: ReminderNotificationCopy.taskDetailedTitle,
          detailedBody: _taskReminderBody(saved, use24HourTime: false),
          showDetails: showDetails,
        );
      }
      await _load(state.selectedDate, invalidateCache: true);
      await _refreshLauncherBadge();
      return true;
    } on PlannerTaskValidationException catch (error) {
      state = state.copyWith(message: error.message);
      return false;
    } on Object {
      state = state.copyWith(
        message:
            'Task could not be saved. Your input remains available to retry.',
      );
      return false;
    }
  }

  static String _taskReminderBody(
    PlannerTask task, {
    required bool use24HourTime,
  }) {
    final minute = task.dueMinute;
    if (minute == null) return 'Upcoming task';
    if (use24HourTime) {
      final hour = minute ~/ 60;
      final minutePart = (minute % 60).toString().padLeft(2, '0');
      final time = '${hour.toString().padLeft(2, '0')}:$minutePart';
      final notes = task.notes?.trim();
      return notes == null || notes.isEmpty ? 'Due $time' : 'Due $time\n$notes';
    }
    return ReminderNotificationCopy.taskDetailedBody(
      dueMinute: minute,
      notes: task.notes,
    );
  }

  /// M7 explicit follow-up finalization for Tasks: purpose is applied only
  /// after the canonical Task save and Contacts commit succeeded.
  Future<void> finalizeContactFollowUp({
    required String taskId,
    required String contactId,
    String? occurrenceId,
  }) async {
    await ref
        .read(reminderReconcilerProvider)
        .applySourcePurpose(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.task,
          sourceId: taskId,
          purpose: ReminderPurpose.contactFollowUp,
          contactId: contactId,
          occurrenceId: occurrenceId ?? ReminderPolicy.seriesOccurrenceId,
        );
    await reconcileTaskReminderHorizon();
  }

  /// Clears follow-up provenance for Contacts removed by an ordinary Task
  /// Contacts commit and re-reconciles only when something actually changed.
  Future<void> clearUnlinkedFollowUp({
    required String taskId,
    required Set<String> currentContactIds,
  }) async {
    try {
      final cleared = await ref
          .read(reminderReconcilerProvider)
          .clearUnlinkedPurpose(
            profileId: _profileId,
            sourceKind: ReminderSourceKind.task,
            sourceId: taskId,
            currentContactIds: currentContactIds,
          );
      if (cleared) {
        await reconcileTaskReminderHorizon();
      }
    } on Object {
      // The canonical Task/Contacts save already committed; retry reconciles.
    }
  }

  Future<void> clearContactFollowUpPurpose({
    required String taskId,
    required String contactId,
    String? occurrenceId,
  }) async {
    await ref
        .read(reminderReconcilerProvider)
        .clearContactPurpose(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.task,
          sourceId: taskId,
          contactId: contactId,
          occurrenceId: occurrenceId,
        );
    await reconcileTaskReminderHorizon();
  }

  Future<TaskStatusChangeOutcome> changeStatus({
    required String taskId,
    required PlannerTaskStatus target,
    required String operationId,
    String? reason,
    bool confirmLinkedTypeTransfer = false,
  }) async {
    try {
      final before = await _repository.readTask(
        profileId: _profileId,
        taskId: taskId,
      );
      final outcome = await _repository.changeTaskStatus(
        profileId: _profileId,
        taskId: taskId,
        target: target,
        operationId: operationId,
        reason: reason,
        confirmLinkedTypeTransfer: confirmLinkedTypeTransfer,
      );
      if (outcome == TaskStatusChangeOutcome.changed &&
          target != PlannerTaskStatus.incomplete &&
          before?.dueDate != null) {
        final due = before!.dueDate!;
        await ref
            .read(reminderReconcilerProvider)
            .cancel(
              sourceKind: ReminderSourceKind.task,
              profileId: _profileId,
              occurrenceId: 'task:$taskId:${due.iso8601}',
            );
      }
      await _load(state.selectedDate, invalidateCache: true);
      if (outcome == TaskStatusChangeOutcome.changed) {
        await _refreshLauncherBadge();
      }
      state = state.copyWith(
        message: switch (outcome) {
          TaskStatusChangeOutcome.reportRequired =>
            'This Task stays Incomplete until its required report and '
                'completion can save together.',
          TaskStatusChangeOutcome.correctionRequired =>
            'This status has historical effects and must use a correction.',
          TaskStatusChangeOutcome.changed ||
          TaskStatusChangeOutcome.unchanged => null,
        },
        clearMessage:
            outcome == TaskStatusChangeOutcome.changed ||
            outcome == TaskStatusChangeOutcome.unchanged,
      );
      return outcome;
    } on Object {
      state = state.copyWith(
        message: 'Task status was not changed. You can safely retry.',
      );
      return TaskStatusChangeOutcome.unchanged;
    }
  }

  Future<TaskHardDeleteOutcome> hardDeleteTask(String taskId) async {
    try {
      final before = await _repository.readTask(
        profileId: _profileId,
        taskId: taskId,
      );
      final outcome = await _repository.hardDeleteTask(
        profileId: _profileId,
        taskId: taskId,
      );
      if (outcome == TaskHardDeleteOutcome.deleted) {
        if (before?.dueDate != null) {
          final due = before!.dueDate!;
          await ref
              .read(reminderReconcilerProvider)
              .cancel(
                sourceKind: ReminderSourceKind.task,
                profileId: _profileId,
                occurrenceId: 'task:$taskId:${due.iso8601}',
              );
        }
        await _load(state.selectedDate, invalidateCache: true);
        await _refreshLauncherBadge();
      }
      state = state.copyWith(
        message: outcome == TaskHardDeleteOutcome.integrityFailure
            ? 'Task deletion was rolled back because its ownership could not be proven.'
            : null,
        clearMessage: outcome != TaskHardDeleteOutcome.integrityFailure,
      );
      return outcome;
    } on TaskHardDeleteIntegrityException catch (error) {
      state = state.copyWith(message: error.message);
      return TaskHardDeleteOutcome.integrityFailure;
    } on Object {
      state = state.copyWith(
        message: 'Task could not be deleted. Your data was not changed.',
      );
      return TaskHardDeleteOutcome.integrityFailure;
    }
  }

  void clearMessage() {
    state = state.copyWith(clearMessage: true);
  }

  Future<void> _refreshLauncherBadge() async {
    try {
      await ref.read(launcherBadgeRefreshProvider)();
    } on Object {
      // Canonical Task persistence must not depend on OEM badge support.
    }
  }

  /// Read the requested day before publishing it as the selected page.
  ///
  /// Navigation can issue another read before this one completes. The
  /// generation guard makes the newest request authoritative, so a slower
  /// earlier result cannot restore an old date or schedule after a newer
  /// selection has already completed.
  Future<void> _load(
    PlannerDate date, {
    bool rethrowOnFailure = false,
    bool publishDateImmediately = false,
    bool invalidateCache = false,
  }) async {
    if (invalidateCache) {
      _invalidateDayCache();
    }
    final generation = ++_loadGeneration;
    final cached = _dayCache[date];
    if (cached != null) {
      // Reinsert to make the bounded insertion-ordered map act as a tiny LRU.
      _dayCache.remove(date);
      _dayCache[date] = cached;
      _selectedCanonicalDay = cached;
      state = state.copyWith(
        status: PlannerLoadStatus.ready,
        selectedDate: date,
        day: filterPendingEventDeletions(cached),
        clearMessage: true,
      );
    } else if (publishDateImmediately) {
      _selectedCanonicalDay = null;
      state = state.copyWith(
        status: PlannerLoadStatus.loading,
        selectedDate: date,
        clearDay: true,
        clearMessage: true,
      );
    } else {
      state = state.copyWith(
        status: PlannerLoadStatus.loading,
        clearMessage: true,
      );
    }
    await _loadDay(date, generation, rethrowOnFailure: rethrowOnFailure);
  }

  Future<void> _loadDay(
    PlannerDate date,
    int generation, {
    bool rethrowOnFailure = false,
  }) async {
    try {
      final day = await _readDayCanonical(date);
      if (generation != _loadGeneration) {
        return;
      }
      final visible = state.day;
      final filteredFresh = filterPendingEventDeletions(day);
      if (visible != null &&
          visible.selectedDate == date &&
          _daysSemanticallyEqual(visible, filteredFresh)) {
        // S1B-04: a canonical refresh that is semantically identical to the
        // currently visible day must not produce a second visible
        // presentation correction. Preserve the visible/cache object
        // identity; only touch LRU order.
        final existing = _dayCache[date] ?? visible;
        _dayCache.remove(date);
        _dayCache[date] = existing;
        _selectedCanonicalDay = existing;
        return;
      }
      _cacheDay(day);
      _selectedCanonicalDay = day;
      state = state.copyWith(
        status: PlannerLoadStatus.ready,
        selectedDate: date,
        day: filteredFresh,
        clearMessage: true,
      );
      _prefetchRollingRunway();
    } on Object {
      if (generation != _loadGeneration) {
        return;
      }
      state = state.copyWith(
        status: PlannerLoadStatus.failure,
        message: 'Planner data could not be opened. Retry without data loss.',
      );
      if (rethrowOnFailure) {
        rethrow;
      }
    }
  }

  void _invalidateDayCache() {
    _dayCacheRevision += 1;
    _dayCache.clear();
    _inFlightDayReads.clear();
  }

  /// [S1B-02] Canonical repository read with same-date in-flight coalescing.
  ///
  /// Two callers requesting the same missing date within one cache revision
  /// (e.g. a selected-date load racing the rolling prefetch, or the preview
  /// window asking for a date `_loadDay` is already reading) share a single
  /// repository future. The future removes itself on completion; callers are
  /// still responsible for their own generation/revision guards before
  /// adopting or caching the result.
  Future<PlannerDay> _readDayCanonical(PlannerDate date) {
    final existing = _inFlightDayReads[date];
    if (existing != null) {
      return existing;
    }
    final future = _repository.readDay(
      profileId: _profileId,
      selectedDate: date,
      today: _dateSource.today(),
    );
    _inFlightDayReads[date] = future;
    // Error-safe cleanup: a failing repository read must still remove the
    // in-flight entry, and the cleanup chain itself must never surface an
    // unhandled async error (a prefetch read failure is deliberately silent).
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_inFlightDayReads[date], future)) {
            // Discard the removed in-flight future value intentionally; the
            // completion of [future] already notified every awaiting caller.
            final removed = _inFlightDayReads.remove(date);
            assert(identical(removed, future));
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_inFlightDayReads[date], future)) {
            // Discard the removed in-flight future value intentionally; the
            // completion of [future] already notified every awaiting caller.
            final removed = _inFlightDayReads.remove(date);
            assert(identical(removed, future));
          }
        },
      ),
    );
    return future;
  }

  /// [S1B-04] Complete render-relevant semantic equality for two days.
  ///
  /// Compares every visible field (Event title/time/location/color/Backup/
  /// Task identity, task status/due/context labels, list membership AND
  /// order) rather than relying on object identity or the intentionally
  /// narrow `_dayContentSignature`. Two days that compare equal paint
  /// identically, so a fresh canonical object equal to the visible day must
  /// not restart presentation work.
  static bool _daysSemanticallyEqual(PlannerDay a, PlannerDay b) {
    if (a.selectedDate != b.selectedDate) {
      return false;
    }
    if (!_eventsEqual(a.allDayEvents, b.allDayEvents) ||
        !_eventsEqual(a.timedEvents, b.timedEvents) ||
        !_eventsEqual(a.awaitingReportEvents, b.awaitingReportEvents)) {
      return false;
    }
    if (!_tasksEqual(a.tasks, b.tasks) ||
        !_tasksEqual(a.overdueTasks, b.overdueTasks) ||
        !_tasksEqual(a.completedTasks, b.completedTasks)) {
      return false;
    }
    if (a.changes.length != b.changes.length) {
      return false;
    }
    for (var index = 0; index < a.changes.length; index++) {
      final x = a.changes[index];
      final y = b.changes[index];
      if (x.id != y.id ||
          x.title != y.title ||
          x.label != y.label ||
          x.isTask != y.isTask ||
          x.eventId != y.eventId ||
          x.originalDate != y.originalDate) {
        return false;
      }
    }
    return true;
  }

  static bool _eventsEqual(
    List<PlannerCalendarItem> a,
    List<PlannerCalendarItem> b,
  ) {
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index++) {
      final x = a[index];
      final y = b[index];
      if (x.id != y.id ||
          x.eventId != y.eventId ||
          x.title != y.title ||
          x.date != y.date ||
          x.originalDate != y.originalDate ||
          x.timing != y.timing ||
          x.state != y.state ||
          x.requiresReport != y.requiresReport ||
          x.hasOutcomeReport != y.hasOutcomeReport ||
          x.startLocal != y.startLocal ||
          x.endLocal != y.endLocal ||
          x.startUtc != y.startUtc ||
          x.endUtc != y.endUtc ||
          x.locationText != y.locationText ||
          x.isRecurring != y.isRecurring ||
          x.replacementId != y.replacementId ||
          x.timeZoneId != y.timeZoneId ||
          x.displayTimeZoneId != y.displayTimeZoneId ||
          x.activityTypeId != y.activityTypeId ||
          x.activityTypeLabel != y.activityTypeLabel ||
          x.activityTypeColorValue != y.activityTypeColorValue ||
          x.isBackupAppointment != y.isBackupAppointment ||
          x.backupForEventId != y.backupForEventId ||
          !_stringListsEqual(x.linkedTaskIds, y.linkedTaskIds)) {
        return false;
      }
    }
    return true;
  }

  static bool _tasksEqual(List<PlannerTask> a, List<PlannerTask> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index++) {
      final x = a[index];
      final y = b[index];
      if (x.id != y.id ||
          x.title != y.title ||
          x.notes != y.notes ||
          x.dueDate != y.dueDate ||
          x.status != y.status ||
          x.requiresReport != y.requiresReport ||
          x.contributionRuleKey != y.contributionRuleKey ||
          x.dueMinute != y.dueMinute ||
          x.recurrence != y.recurrence ||
          x.linkedActivityTypeId != y.linkedActivityTypeId ||
          x.linkedActivityTypeStableKey != y.linkedActivityTypeStableKey ||
          x.linkedActivityTypeLabelSnapshot !=
              y.linkedActivityTypeLabelSnapshot ||
          !_stringListsEqual(x.people, y.people) ||
          !_stringListsEqual(x.linkedEventIds, y.linkedEventIds) ||
          !_stringListsEqual(x.pathwayContextLabels, y.pathwayContextLabels)) {
        return false;
      }
    }
    return true;
  }

  static bool _stringListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) {
        return false;
      }
    }
    return true;
  }

  void _cacheDay(PlannerDay day) {
    _dayCache.remove(day.selectedDate);
    _dayCache[day.selectedDate] = day;
    final today = _dateSource.today();
    while (_dayCache.length > _dayCacheLimit) {
      final eviction = _dayCache.keys.firstWhere(
        (date) => date != today,
        orElse: () => _dayCache.keys.first,
      );
      _dayCache.remove(eviction);
    }
  }

  bool _isPendingEventDeletion(PlannerCalendarItem event) {
    return _pendingOccurrenceDeletionCounts.containsKey(event.id) ||
        (event.eventId != null &&
            _pendingSeriesDeletionCounts.containsKey(event.eventId));
  }

  /// R7-07 RENDER FILTER LAW: public render-time predicate. The final
  /// render input filters active tombstones even if a day snapshot produced
  /// before the deletion somehow survives in memory — defense in depth on
  /// top of the monotonic [PlannerState.eventDeletionRevision] gate.
  bool isPendingEventDeletion(PlannerCalendarItem event) {
    return _isPendingEventDeletion(event);
  }

  void _publishEventDeletionRevision() {
    _loadGeneration += 1;
    _dayCacheRevision += 1;
    _inFlightDayReads.clear();
    final canonical = _selectedCanonicalDay?.selectedDate == state.selectedDate
        ? _selectedCanonicalDay
        : _dayCache[state.selectedDate];
    state = state.copyWith(
      day: canonical == null ? null : filterPendingEventDeletions(canonical),
      clearDay: canonical == null && state.day == null,
      eventDeletionRevision: state.eventDeletionRevision + 1,
    );
  }

  static void _incrementCounts(Map<String, int> counts, Iterable<String> ids) {
    for (final id in ids) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
  }

  static void _decrementCounts(Map<String, int> counts, Iterable<String> ids) {
    for (final id in ids) {
      final next = (counts[id] ?? 0) - 1;
      if (next > 0) {
        counts[id] = next;
      } else {
        counts.remove(id);
      }
    }
  }
}
