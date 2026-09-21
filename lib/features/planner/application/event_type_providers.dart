import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/planner/application/event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

/// Dedicated change signal for the profile's presentation document (event
/// colors, group colors, Goal name overrides). Emits after every committed
/// full-document write. This is a DATA stream over Planner Preferences
/// writes only — it introduces no notification refresh side effects.
final presentationDocumentChangesProvider = StreamProvider.family<void, String>(
  (ref, profileId) {
    return ref
        .watch(eventTypeRepositoryProvider)
        .watchPresentationDocument(profileId);
  },
);

/// Profile-scoped Goal Event Type presentation-name overrides, keyed by the
/// real Goal UUID (schema 46 Planner Preferences JSON metadata). Reactively
/// refreshed by the dedicated presentation-document change stream; errors
/// surface truthfully as AsyncError (callers fail closed, never fall back to
/// a raw canonical label for a valid live Goal).
final goalEventTypeNameOverridesProvider =
    FutureProvider.family<Map<String, GoalEventTypeNameOverride>, String>((
      ref,
      profileId,
    ) {
      // Watching the change stream keeps this provider reactive: it re-reads
      // after every committed presentation write (color, group, or override).
      ref.watch(presentationDocumentChangesProvider(profileId));
      return ref
          .watch(eventTypeRepositoryProvider)
          .readGoalEventTypeNameOverrides(profileId);
    });

final eventTypeRepositoryProvider = Provider<EventTypeRepository>((ref) {
  throw StateError('EventTypeRepository must be overridden at the app root');
});

final class EventTypeState {
  const EventTypeState({
    required this.isLoading,
    required this.eventTypes,
    required this.settings,
    required this.eventColors,
    required this.groupColors,
    this.message,
  });

  const EventTypeState.loading()
    : isLoading = true,
      eventTypes = const <EventType>[],
      settings = const PlannerSettings.defaults(),
      eventColors = const <String, EventColorPreference>{},
      groupColors = const <String, int>{},
      message = null;

  final bool isLoading;
  final List<EventType> eventTypes;
  final PlannerSettings settings;

  /// Explicit user choices keyed by Event Type stable key. Missing entries
  /// resolve through [PlannerEventColorDefaults] at the presentation edge.
  final Map<String, EventColorPreference> eventColors;
  final Map<String, int> groupColors;
  final String? message;

  EventTypeState copyWith({
    bool? isLoading,
    List<EventType>? eventTypes,
    PlannerSettings? settings,
    Map<String, EventColorPreference>? eventColors,
    Map<String, int>? groupColors,
    String? message,
    bool clearMessage = false,
  }) {
    return EventTypeState(
      isLoading: isLoading ?? this.isLoading,
      eventTypes: eventTypes ?? this.eventTypes,
      settings: settings ?? this.settings,
      eventColors: eventColors ?? this.eventColors,
      groupColors: groupColors ?? this.groupColors,
      message: clearMessage ? null : message ?? this.message,
    );
  }

  Map<String, EventColorPreference> get resolvedEventColorsByTypeId {
    return <String, EventColorPreference>{
      for (final type in eventTypes)
        type.id:
            eventColors[type.stableKey] ??
            PlannerEventColorDefaults.forEventType(type),
    };
  }
}

final eventTypeControllerProvider =
    NotifierProvider<EventTypeController, EventTypeState>(
      EventTypeController.new,
    );

final class EventTypeController extends Notifier<EventTypeState> {
  EventTypeRepository get _repository => ref.read(eventTypeRepositoryProvider);

  /// The profile that produced the CURRENT [state], or null while the state is
  /// only a pre-load placeholder.  Tracked so a warm entry can prove the data
  /// it would reuse belongs to the same Local Profile (O1/O10 provenance law).
  String? _loadedProfileId;

  /// The single in-flight load for [_inflightProfileId], shared by concurrent
  /// first callers so a warm/cold burst issues exactly one read set.
  Future<void>? _inflight;
  String? _inflightProfileId;
  bool _inflightIncludeArchived = false;

  /// Whether the last SUCCESSFUL load was read with archived types.
  bool _loadedIncludeArchived = false;

  String get _profileId {
    final startup = ref.read(startupControllerProvider);
    if (startup is! StartupReady) {
      throw StateError('Event Types require a ready Local Profile');
    }
    return startup.profile.id;
  }

  @override
  EventTypeState build() {
    unawaited(Future<void>.microtask(load));
    return const EventTypeState.loading();
  }

  /// True when the current state is a SUCCESSFUL load for [profileId] — i.e.
  /// it carries usable truth this profile may present as current creation
  /// eligibility.  Loading, errored, or wrong-profile data never qualifies.
  bool isReadyFor(String profileId) {
    if (state.isLoading || state.message != null) {
      return false;
    }
    return _loadedProfileId == profileId;
  }

  /// O1/O10 warm fast path: reuse the current successful same-profile load,
  /// otherwise await the in-flight one, otherwise start exactly one.
  ///
  /// This is deliberately NOT "skip the load when the list is nonempty": a
  /// cached list from another profile, a loading placeholder, or an errored
  /// state can never establish current creation eligibility.  Existing
  /// [load] callers keep their own explicit-reload behavior.
  Future<void> ensureLoaded({
    bool includeArchived = false,
    bool requireArchived = false,
  }) async {
    // A not-yet-ready Local Profile is not a warm state: fall through to
    // [load], whose existing error containment owns that outcome.
    final profileId = _currentProfileIdOrNull();
    if (profileId == null) {
      await load(includeArchived: includeArchived);
      return;
    }
    // A warm, trustworthy, same-profile state satisfies the caller.  An
    // archived-inclusive request is only satisfied by an archived-inclusive
    // load, since the narrow list may legitimately omit retired types.
    if (isReadyFor(profileId) && (!requireArchived || _loadedIncludeArchived)) {
      return;
    }
    final inflight = _inflight;
    if (inflight != null &&
        _inflightProfileId == profileId &&
        (!requireArchived || _inflightIncludeArchived)) {
      await inflight;
      return;
    }
    await load(includeArchived: includeArchived);
  }

  Future<void> load({bool includeArchived = false}) async {
    // Coalesce: while one load is in flight, a second caller for the SAME
    // profile (and the same archive scope) awaits that work instead of issuing
    // a duplicate read set.  A caller that needs a broader scope still starts
    // its own read, so `load(includeArchived: true)` keeps its own behavior.
    final inflight = _inflight;
    final inflightProfileId = _inflightProfileId;
    if (inflight != null &&
        inflightProfileId != null &&
        inflightProfileId == _currentProfileIdOrNull() &&
        (!includeArchived || _inflightIncludeArchived)) {
      await inflight;
      return;
    }
    state = state.copyWith(isLoading: true, clearMessage: true);
    final work = _performLoad(includeArchived: includeArchived);
    _inflight = work;
    try {
      await work;
    } finally {
      if (identical(_inflight, work)) {
        _inflight = null;
        _inflightProfileId = null;
        _inflightIncludeArchived = false;
      }
    }
  }

  Future<void> _performLoad({required bool includeArchived}) async {
    try {
      final profileId = _profileId;
      _inflightProfileId = profileId;
      _inflightIncludeArchived = includeArchived;
      final results = await Future.wait<Object>(<Future<Object>>[
        _repository.readEventTypes(
          profileId: profileId,
          includeArchived: includeArchived,
        ),
        _repository.readPlannerSettings(profileId: profileId),
        _repository.readEventColorPreferences(profileId: profileId),
        _repository.readContactGroupColors(profileId: profileId),
      ]);
      _loadedProfileId = profileId;
      _loadedIncludeArchived = includeArchived;
      state = EventTypeState(
        isLoading: false,
        eventTypes: results[0] as List<EventType>,
        settings: results[1] as PlannerSettings,
        eventColors: results[2] as Map<String, EventColorPreference>,
        groupColors: results[3] as Map<String, int>,
      );
    } on Object {
      // The errored state is explicitly NOT ready for any profile: a failed
      // read can never establish current creation eligibility.
      _loadedProfileId = null;
      state = state.copyWith(
        isLoading: false,
        message:
            'Planner settings could not be opened. Retry without data loss.',
      );
    }
  }

  String? _currentProfileIdOrNull() {
    final startup = ref.read(startupControllerProvider);
    return startup is StartupReady ? startup.profile.id : null;
  }

  Future<EventType?> exactTypeForIndicator(String indicatorKey) {
    return _repository.readExactTypeForIndicator(
      profileId: _profileId,
      indicatorKey: indicatorKey,
    );
  }

  Future<EventType?> readType(String eventTypeId) {
    return _repository.readEventType(
      profileId: _profileId,
      eventTypeId: eventTypeId,
    );
  }

  Future<bool> saveCustomType(EventTypeDraft draft) async {
    try {
      final saved = await _repository.saveCustomType(
        profileId: _profileId,
        draft: draft,
      );
      _replaceOrAppendType(saved);
      return true;
    } on Object {
      state = state.copyWith(
        message: 'Event Type was not changed. Your input is still available.',
      );
      return false;
    }
  }

  Future<bool> renameSystemType({
    required String eventTypeId,
    required String label,
  }) async {
    try {
      final current = state.eventTypes
          .where((type) => type.id == eventTypeId)
          .firstOrNull;
      await _repository.renameSystemType(
        profileId: _profileId,
        eventTypeId: eventTypeId,
        label: label,
      );
      if (current == null) {
        state = state.copyWith(clearMessage: true);
      } else {
        _replaceOrAppendType(_withLabel(current, label.trim()));
      }
      return true;
    } on Object {
      state = state.copyWith(
        message:
            'Event Type name was not changed. Your input is still available.',
      );
      return false;
    }
  }

  void _replaceOrAppendType(EventType saved) {
    final eventTypes = List<EventType>.of(state.eventTypes);
    final index = eventTypes.indexWhere((type) => type.id == saved.id);
    if (index == -1) {
      eventTypes.add(saved);
    } else {
      eventTypes[index] = saved;
    }
    state = state.copyWith(
      eventTypes: List<EventType>.unmodifiable(eventTypes),
      clearMessage: true,
    );
  }

  static EventType _withLabel(EventType type, String label) => EventType(
    id: type.id,
    stableKey: type.stableKey,
    label: label,
    icon: type.icon,
    colorValue: type.colorValue,
    isSystem: type.isSystem,
    isArchived: type.isArchived,
    reportRequiredDefault: type.reportRequiredDefault,
    defaultDurationMinutes: type.defaultDurationMinutes,
    defaultReminderMinutes: type.defaultReminderMinutes,
    position: type.position,
    mappingVersion: type.mappingVersion,
    indicatorKeys: type.indicatorKeys,
  );

  Future<bool> setArchived(EventType type, bool archived) async {
    try {
      await _repository.setCustomTypeArchived(
        profileId: _profileId,
        eventTypeId: type.id,
        archived: archived,
      );
      await load(includeArchived: true);
      return true;
    } on Object {
      state = state.copyWith(
        message: 'Event Type archive state was not changed.',
      );
      return false;
    }
  }

  Future<bool> restoreSystemDefaults() async {
    try {
      await _repository.restoreSystemDefaults(profileId: _profileId);
      await load(includeArchived: true);
      return true;
    } on Object {
      state = state.copyWith(message: 'System defaults were not changed.');
      return false;
    }
  }

  Future<bool> saveSettings(PlannerSettings settings) async {
    try {
      final saved = await _repository.savePlannerSettings(
        profileId: _profileId,
        settings: settings,
      );
      final reminderChanged =
          state.settings.defaultReminderMinutes != saved.defaultReminderMinutes;
      state = state.copyWith(settings: saved, clearMessage: true);
      if (reminderChanged) {
        try {
          await ref.read(reconcileRemindersProvider)();
        } on Object {
          // Saved settings remain canonical; recovery retries independently.
        }
      }
      return true;
    } on Object {
      state = state.copyWith(
        message: 'Planner settings were not changed. You can safely retry.',
      );
      return false;
    }
  }

  /// Monotonic token for the latest requested timeline-zoom commit.
  ///
  /// P1 (2026-09-21): a pinch completion must never write back a whole CAPTURED
  /// settings snapshot, because that snapshot can predate an unrelated setting
  /// changed during the gesture, and a slow earlier save must never be allowed
  /// to overwrite a later one.
  int _zoomCommitGeneration = 0;

  /// Serialises zoom commits so the LAST gesture is also the LAST database
  /// write, even while an earlier save is still in flight.
  Future<void> _zoomCommitQueue = Future<void>.value();

  /// Persist ONLY the timeline zoom preference and report what actually landed.
  ///
  /// Returns the committed hour height on success, or `null` when the save
  /// failed. A null result must make the caller keep its own live override so
  /// the user is left on a coherent, usable view rather than being snapped back
  /// to the previously stored scale. This is the deliberate pre-P1 defect the
  /// audit called out: `_persistZoom` unconditionally cleared the live override
  /// after an awaited whole-settings save, with no gesture-generation check.
  ///
  /// The zoom preference is applied to the controller's CURRENT settings (re-read
  /// when this commit actually runs) rather than to a captured snapshot, so an
  /// unrelated setting changed mid-gesture is not reverted.
  Future<double?> saveTimelineHourHeight(double hourHeight) {
    final generation = ++_zoomCommitGeneration;
    final normalized = PlannerZoomPolicy.clampAbsolute(hourHeight);
    final queued = _zoomCommitQueue.then((_) async {
      final next = state.settings.copyWith(timelineHourHeight: normalized);
      try {
        final saved = await _repository.savePlannerSettings(
          profileId: _profileId,
          settings: next,
        );
        if (generation == _zoomCommitGeneration) {
          state = state.copyWith(settings: saved, clearMessage: true);
        }
        return saved.timelineHourHeight;
      } on Object {
        if (generation == _zoomCommitGeneration) {
          state = state.copyWith(
            message: 'Timeline zoom was not saved. You can safely pinch again.',
          );
        }
        return null;
      }
    });
    _zoomCommitQueue = queued.then((_) {}, onError: (Object _) {});
    return queued;
  }

  Future<bool> saveEventColor(
    EventType type,
    EventColorPreference preference,
  ) async {
    try {
      final saved = await _repository.saveEventColorPreference(
        profileId: _profileId,
        eventTypeStableKey: type.stableKey,
        preference: preference,
      );
      state = state.copyWith(eventColors: saved, clearMessage: true);
      return true;
    } on Object {
      state = state.copyWith(
        message: 'Event color was not changed. You can safely retry.',
      );
      return false;
    }
  }

  Future<bool> restoreEventColorDefaults() async {
    try {
      final restored = await _repository.restoreEventColorDefaults(
        profileId: _profileId,
      );
      state = state.copyWith(eventColors: restored, clearMessage: true);
      return true;
    } on Object {
      state = state.copyWith(
        message: 'Event colors were not restored. You can safely retry.',
      );
      return false;
    }
  }

  Future<bool> saveContactGroupColor({
    required String groupId,
    required int colorArgb,
  }) async {
    try {
      final saved = await _repository.saveContactGroupColor(
        profileId: _profileId,
        groupId: groupId,
        colorArgb: colorArgb,
      );
      state = state.copyWith(groupColors: saved, clearMessage: true);
      return true;
    } on Object {
      state = state.copyWith(
        message: 'Group color was not changed. You can safely retry.',
      );
      return false;
    }
  }

  Future<bool> restoreContactGroupColorDefaults() async {
    try {
      final restored = await _repository.restoreContactGroupColorDefaults(
        profileId: _profileId,
      );
      state = state.copyWith(groupColors: restored, clearMessage: true);
      return true;
    } on Object {
      state = state.copyWith(
        message: 'Group colors were not restored. You can safely retry.',
      );
      return false;
    }
  }

  void clearMessage() {
    state = state.copyWith(clearMessage: true);
  }
}
