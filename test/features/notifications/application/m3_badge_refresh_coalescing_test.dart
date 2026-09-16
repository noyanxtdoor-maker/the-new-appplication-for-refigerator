import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/notifications/launcher_badge_gateway.dart';
import 'package:rmplanner/features/notifications/application/launcher_badge_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

/// M3 badge refresh — one active full-universe refresh plus at most one
/// dirty-generation trailing refresh; stale completion can never publish.
void main() {
  // The production badge provider reads the REAL wall clock for `nowUtc`
  // (only `today` comes from the injectable date source), and
  // `LauncherBadgeCoordinator._isActionableEvent` excludes a timed Event whose
  // end is already in the past. Anchoring this fixture to a hard-coded instant
  // therefore made the assertion a time bomb: once that instant passed, the
  // coordinator CORRECTLY stopped counting the fixture Event and the expected
  // badge count flipped from 1 to 0. Anchor the fixture to the same real clock
  // production uses so the harness and the product agree at any run date.
  final now = DateTime.now().toUtc();
  final today = PlannerDate.fromDateTime(now);

  Future<ProviderContainer> boot() async {
    final events = _Events();
    final tasks = _Tasks();
    final gateway = _Badge();
    final container = ProviderContainer(
      overrides: <Override>[
        launcherBadgeGatewayProvider.overrideWithValue(gateway),
        calendarEventRepositoryProvider.overrideWithValue(events),
        plannerRepositoryProvider.overrideWithValue(tasks),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        startupRepositoryProvider.overrideWithValue(_FixedStartupRepository()),
        plannerDateSourceProvider.overrideWithValue(_FixedDateSource(today)),
      ],
    );
    container.read(startupControllerProvider);
    // Let the real startup controller settle into StartupReady.
    for (var attempt = 0; attempt < 200; attempt += 1) {
      if (container.read(startupControllerProvider) is StartupReady) break;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (container.read(startupControllerProvider) is! StartupReady) {
      fail('startup controller never reached StartupReady');
    }
    return container;
  }

  test('serial refreshes keep exact badge semantics', () async {
    final container = await boot();
    addTearDown(container.dispose);
    final events = container.read(calendarEventRepositoryProvider) as _Events;
    final gateway = container.read(launcherBadgeGatewayProvider) as _Badge;

    events.items = <PlannerCalendarItem>[
      _event('occ-1', now.add(const Duration(hours: 2))),
    ];
    await container.read(launcherBadgeRefreshProvider)();
    expect(gateway.counts, <int>[1]);

    events.items = const <PlannerCalendarItem>[];
    await container.read(launcherBadgeRefreshProvider)();
    expect(gateway.counts, <int>[1, 0]);
  });

  test(
    'concurrent burst coalesces: one active + at most one trailing read',
    () async {
      final container = await boot();
      addTearDown(container.dispose);
      final events = container.read(calendarEventRepositoryProvider) as _Events;
      final tasks = container.read(plannerRepositoryProvider) as _Tasks;
      final gateway = container.read(launcherBadgeGatewayProvider) as _Badge;
      var inFlight = 0;
      var maxConcurrent = 0;

      events.onRead = () async {
        inFlight += 1;
        if (inFlight > maxConcurrent) maxConcurrent = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        inFlight -= 1;
      };

      // A save burst: five overlapping badge refresh requests.
      final futures = <Future<void>>[
        for (var index = 0; index < 5; index += 1)
          container.read(launcherBadgeRefreshProvider)(),
      ];
      // Latest durable truth changed mid-read: the single trailing pass must
      // pick it up.
      tasks.ids = <String>{'task-trailing'};
      await Future.wait(futures);

      expect(maxConcurrent, 1, reason: 'no concurrent overlapping range reads');
      // Exactly ONE active + ONE trailing full-universe read (not five).
      expect(gateway.reads, 2, reason: 'measured reads: ${gateway.reads}');
      // The trailing pass published the latest durable truth.
      expect(gateway.counts.last, 1);
    },
  );

  test('stale completion cannot publish over newer truth', () async {
    final container = await boot();
    addTearDown(container.dispose);
    final events = container.read(calendarEventRepositoryProvider) as _Events;
    final gateway = container.read(launcherBadgeGatewayProvider) as _Badge;

    events.items = <PlannerCalendarItem>[
      _event('occ-1', now.add(const Duration(hours: 2))),
    ];
    await container.read(launcherBadgeRefreshProvider)();
    // Latest truth after the first pass: the event is gone.
    events.items = const <PlannerCalendarItem>[];
    await container.read(launcherBadgeRefreshProvider)();
    expect(gateway.counts, isNotEmpty);
    expect(gateway.counts.last, 0, reason: 'trailing pass publishes latest');
  });

  test(
    'platform failure never throws and never rolls back persistence',
    () async {
      final container = await boot();
      addTearDown(container.dispose);
      final gateway = container.read(launcherBadgeGatewayProvider) as _Badge;
      gateway.throwOnSet = true;
      await container.read(launcherBadgeRefreshProvider)();
      expect(gateway.counts, isEmpty);
    },
  );
}

final class _FixedStartupRepository implements StartupRepository {
  LocalProfile get _profile => LocalProfile(
    id: 'profile-badge',
    localName: 'Badge profile',
    createdAtUtc: DateTime.utc(2026, 9, 14, 9),
    updatedAtUtc: DateTime.utc(2026, 9, 14, 9),
  );

  @override
  Future<StartupSnapshot> resolveStartup() async {
    return StartupSnapshot(
      profile: _profile,
      accountSessionState: AccountSessionState.localOnly,
      syncState: LocalSyncState.notConfigured,
      unlockRequired: false,
    );
  }

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() async {
    throw UnimplementedError();
  }

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) async {
    throw UnimplementedError();
  }

  @override
  Future<LocalProfile> completeOnboarding() async => _profile;

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) async => _profile;
}

final class _FixedDateSource implements PlannerDateSource {
  const _FixedDateSource(this.date);

  final PlannerDate date;

  @override
  PlannerDate today() => date;
}

final class _Events
    implements CalendarEventRepository, CalendarEventRangeSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  List<PlannerCalendarItem> items = const <PlannerCalendarItem>[];
  Future<void> Function()? onRead;

  @override
  Future<List<PlannerCalendarItem>> readRange({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  }) async {
    await onRead?.call();
    return items;
  }
}

final class _Tasks implements PlannerRepository, PlannerBadgeTaskSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Set<String> ids = const <String>{};

  @override
  Future<List<String>> readActionableBadgeTasks({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  }) async => ids.toList(growable: false);
}

final class _Badge implements LauncherBadgeGateway {
  final counts = <int>[];
  int reads = 0;
  bool throwOnSet = false;

  @override
  Future<void> setCount(int count) async {
    reads += 1;
    if (throwOnSet) throw StateError('platform failure');
    counts.add(count);
  }
}

PlannerCalendarItem _event(String id, DateTime startUtc) {
  return PlannerCalendarItem(
    id: id,
    title: 'Event $id',
    date: PlannerDate.fromDateTime(startUtc),
    timing: PlannerEventTiming.timed,
    state: PlannerEventState.scheduled,
    requiresReport: false,
    hasOutcomeReport: false,
    startUtc: startUtc,
    endUtc: startUtc.add(const Duration(hours: 1)),
    eventId: 'event-$id',
    originalDate: PlannerDate.fromDateTime(startUtc),
  );
}
