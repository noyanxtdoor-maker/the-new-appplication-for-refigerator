// P1 (2026-09-21) — pinch zoom commit lifecycle contract.
//
// Astra's audit listed these as SOURCE-DEMONSTRABLE defects, not runtime
// guesses:
//   * `_persistZoom` awaited a save built from a WHOLE settings snapshot
//     captured at gesture time, so an unrelated setting changed during the
//     pinch could be reverted by the zoom commit.
//   * the same await unconditionally cleared the live zoom override with no
//     gesture-generation check, so a save that began during an earlier pinch
//     could discard a LATER pinch's live height.
//   * a FAILED save still cleared the override, snapping the timeline back to
//     the previously stored scale.
//
// These tests drive the production `EventTypeController` with a fully
// controlled repository so commit ORDER, staleness and failure are all
// deterministic. They lock the replacement law rather than the old behaviour.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';

final class _RaceStartupRepository implements StartupRepository {
  _RaceStartupRepository(this.profileId);

  final String profileId;

  LocalProfile _profile() => LocalProfile(
    id: profileId,
    localName: 'Local Profile',
    createdAtUtc: DateTime.utc(2026),
    updatedAtUtc: DateTime.utc(2026),
  );

  @override
  Future<StartupSnapshot> resolveStartup() async => StartupSnapshot(
    profile: _profile(),
    accountSessionState: AccountSessionState.localOnly,
    syncState: LocalSyncState.notConfigured,
    unlockRequired: false,
  );

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() async {
    throw UnimplementedError();
  }

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) async {
    throw UnimplementedError();
  }

  @override
  Future<LocalProfile> completeOnboarding() async => _profile();

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) async =>
      _profile();
}

/// Fully controlled Event Type / Planner settings source.
///
/// Every write is recorded in ORDER, an individual write can be HELD open so a
/// test decides when it completes, and every write can be made to FAIL.
final class _RaceEventTypeRepository implements EventTypeRepository {
  PlannerSettings baseline = const PlannerSettings.defaults();

  /// Every settings row this repository actually committed, in write order.
  final List<PlannerSettings> writes = <PlannerSettings>[];

  /// When true, every save throws before recording anything.
  bool failSaves = false;

  /// When true, `readPlannerSettings` throws (models an unreadable settings
  /// row so the failure path can be exercised at load time).
  bool failReads = false;

  int _saveCount = 0;
  final Map<int, Completer<void>> _gates = <int, Completer<void>>{};

  /// Hold the [index]-th save (0-based) open until [releaseSave].
  void holdSave(int index) => _gates[index] = Completer<void>();

  void releaseSave(int index) {
    final gate = _gates.remove(index);
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  Future<PlannerSettings> readPlannerSettings({
    required String profileId,
  }) async {
    if (failReads) {
      throw StateError('Injected settings read failure');
    }
    return baseline;
  }

  @override
  Future<PlannerSettings> savePlannerSettings({
    required String profileId,
    required PlannerSettings settings,
  }) async {
    final index = _saveCount++;
    final gate = _gates[index];
    if (gate != null) {
      await gate.future;
    }
    if (failSaves) {
      throw StateError('Injected zoom save failure');
    }
    writes.add(settings);
    baseline = settings;
    return settings;
  }

  @override
  Future<List<EventType>> readEventTypes({
    required String profileId,
    bool includeArchived = false,
  }) async => const <EventType>[];

  @override
  Future<EventType?> readEventType({
    required String profileId,
    required String eventTypeId,
  }) async => null;

  @override
  Future<EventType?> readExactTypeForIndicator({
    required String profileId,
    required String indicatorKey,
  }) async => null;

  @override
  Future<EventType> saveCustomType({
    required String profileId,
    required EventTypeDraft draft,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> renameSystemType({
    required String profileId,
    required String eventTypeId,
    required String label,
  }) async {}

  @override
  Future<void> setCustomTypeArchived({
    required String profileId,
    required String eventTypeId,
    required bool archived,
  }) async {}

  @override
  Future<void> restoreSystemDefaults({required String profileId}) async {}

  @override
  Future<Map<String, EventColorPreference>> readEventColorPreferences({
    required String profileId,
  }) async => const <String, EventColorPreference>{};

  @override
  Future<Map<String, EventColorPreference>> saveEventColorPreference({
    required String profileId,
    required String eventTypeStableKey,
    required EventColorPreference preference,
  }) async => const <String, EventColorPreference>{};

  @override
  Future<Map<String, EventColorPreference>> restoreEventColorDefaults({
    required String profileId,
  }) async => const <String, EventColorPreference>{};

  @override
  Future<Map<String, int>> readContactGroupColors({
    required String profileId,
  }) async => const <String, int>{};

  @override
  Future<Map<String, int>> saveContactGroupColor({
    required String profileId,
    required String groupId,
    required int colorArgb,
  }) async => const <String, int>{};

  @override
  Future<Map<String, int>> restoreContactGroupColorDefaults({
    required String profileId,
  }) async => const <String, int>{};

  @override
  Stream<void> watchPresentationDocument(String profileId) =>
      const Stream<void>.empty();

  @override
  Future<Map<String, GoalEventTypeNameOverride>> readGoalEventTypeNameOverrides(
    String profileId,
  ) async => const <String, GoalEventTypeNameOverride>{};

  @override
  Future<LiveGoalPresentationResult> saveLiveGoalPresentation({
    required String profileId,
    required int expectedSlotIndex,
    required String expectedGoalId,
    required String expectedEventTypeId,
    required String expectedStableKey,
    required LiveGoalPresentationOriginals originalValues,
    required LiveGoalPresentationPatch patch,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  late _RaceEventTypeRepository repository;
  late ProviderContainer container;

  Future<void> pumpMicrotasks() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    repository = _RaceEventTypeRepository();
    container = ProviderContainer(
      overrides: [
        startupRepositoryProvider.overrideWithValue(
          _RaceStartupRepository('profile-p1'),
        ),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        eventTypeRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(startupControllerProvider.notifier)
        .completeOnboarding();
    // Resolve the initial load so `state.settings` is real before any commit.
    await container.read(eventTypeControllerProvider.notifier).load();
  });

  EventTypeController controller() =>
      container.read(eventTypeControllerProvider.notifier);

  EventTypeState state() => container.read(eventTypeControllerProvider);

  test(
    'a zoom commit persists only the zoom and returns what committed',
    () async {
      final committed = await controller().saveTimelineHourHeight(88);

      expect(committed, 88);
      expect(state().settings.timelineHourHeight, 88);
      expect(repository.writes, hasLength(1));
      expect(repository.writes.single.timelineHourHeight, 88);
    },
  );

  test('a zoom commit does not revert other settings', () async {
    // An unrelated setting changes first; the zoom commit must carry the
    // CURRENT settings forward rather than a stale captured snapshot.
    await controller().saveSettings(
      const PlannerSettings.defaults().copyWith(snapMinutes: 5),
    );
    repository.writes.clear();

    final committed = await controller().saveTimelineHourHeight(88);

    expect(committed, 88);
    expect(state().settings.timelineHourHeight, 88);
    expect(state().settings.snapMinutes, 5);
    expect(repository.writes.single.snapMinutes, 5);
    expect(repository.writes.single.timelineHourHeight, 88);
  });

  test(
    'a stale zoom completion cannot overwrite newer gesture state',
    () async {
      // Hold the FIRST gesture's write open, then start a second gesture before
      // the first resolves. This is the exact pre-P1 defect: the earlier
      // completion cleared the live override and reverted the newer pinch.
      repository.holdSave(0);
      final first = controller().saveTimelineHourHeight(44);
      final second = controller().saveTimelineHourHeight(88);
      await pumpMicrotasks();

      expect(
        state().settings.timelineHourHeight,
        60,
        reason: 'nothing may be published while the first write is held',
      );

      repository.releaseSave(0);
      await first;

      expect(
        state().settings.timelineHourHeight,
        isNot(44),
        reason: 'the superseded completion must not publish its older height',
      );

      await second;

      expect(state().settings.timelineHourHeight, 88);
      expect(
        repository.writes.last.timelineHourHeight,
        88,
        reason: 'the newest gesture must also be the last write',
      );
    },
  );

  test('commits are serialised so write order matches gesture order', () async {
    repository.holdSave(0);
    final first = controller().saveTimelineHourHeight(44);
    final second = controller().saveTimelineHourHeight(88);
    await pumpMicrotasks();

    // The second commit must not reach the repository while the first is held.
    expect(repository.writes, isEmpty);

    repository.releaseSave(0);
    await Future.wait(<Future<double?>>[first, second]);

    expect(
      repository.writes.map((s) => s.timelineHourHeight).toList(),
      <double>[44, 88],
    );
  });

  test(
    'a failed zoom save reports honestly and leaves state coherent',
    () async {
      repository.failSaves = true;

      final committed = await controller().saveTimelineHourHeight(88);

      expect(committed, isNull, reason: 'failure must be reported, not hidden');
      expect(state().message, isNotNull);
      expect(
        state().settings.timelineHourHeight,
        isNot(88),
        reason: 'a failed save must not publish the height',
      );
      expect(repository.writes, isEmpty);

      // Fresh interactions still work from the coherent state.
      repository.failSaves = false;
      final retried = await controller().saveTimelineHourHeight(88);

      expect(retried, 88);
      expect(state().settings.timelineHourHeight, 88);
      expect(state().message, isNull);
    },
  );

  test(
    'a superseded failure does not overwrite the newer message state',
    () async {
      // First commit fails while a newer commit is already in flight: the stale
      // failure must not clobber the newer commit's outcome.
      repository.failSaves = true;
      repository.holdSave(0);
      final failing = controller().saveTimelineHourHeight(44);
      await pumpMicrotasks();

      repository.failSaves = false;
      final succeeding = controller().saveTimelineHourHeight(88);

      repository.releaseSave(0);
      await failing;
      await succeeding;

      expect(state().settings.timelineHourHeight, 88);
      expect(repository.writes.last.timelineHourHeight, 88);
    },
  );

  test('an out-of-range zoom is normalised before it is stored', () async {
    final committed = await controller().saveTimelineHourHeight(9999);

    expect(
      committed,
      320,
      reason: 'absolute safety ceiling, not an arbitrary clamped default',
    );
    expect(state().settings.timelineHourHeight, 320);
    expect(repository.writes.single.timelineHourHeight, 320);
  });
}
