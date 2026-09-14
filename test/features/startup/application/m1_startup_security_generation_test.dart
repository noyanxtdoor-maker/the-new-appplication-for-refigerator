// M1 (T2 / H) — narrow startup security-generation guard.
//
// This is the S01 precondition the privacy controller alone cannot supply: an
// older startup resolution must not be able to publish `StartupReady` after a
// NEWER resolution has already published a protected or recovery state, and a
// pending onboarding/profile publication must not resurrect a stale Ready.
//
// The guard is deliberately narrow: when queries start, what they read, the
// route graph, the router identity and onboarding persistence are all
// unchanged.  Only the publication of an out-of-date result is discarded.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

import '../../../support/test_dependencies.dart';

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final LocalProfile _profile = LocalProfile(
  id: '11111111-1111-4111-8111-111111111111',
  localName: 'Local Profile 11111111',
  displayName: 'Offline user',
  createdAtUtc: DateTime.utc(2026, 7, 26, 12),
  updatedAtUtc: DateTime.utc(2026, 7, 26, 12),
);

StartupSnapshot _ready() => StartupSnapshot(
  profile: _profile,
  accountSessionState: AccountSessionState.localOnly,
  syncState: LocalSyncState.notConfigured,
  unlockRequired: false,
);

StartupSnapshot _protected() => StartupSnapshot(
  profile: _profile,
  accountSessionState: AccountSessionState.localOnly,
  syncState: LocalSyncState.notConfigured,
  unlockRequired: true,
);

/// Delegating startup repository whose resolve/persistence completions can be
/// held open so out-of-order resolutions are deterministic.
final class _ScriptedStartupRepository implements StartupRepository {
  _ScriptedStartupRepository(this._inner);

  final StartupRepository _inner;

  bool gateResolve = false;
  bool gateCheckpoint = false;
  bool gateCompleteOnboarding = false;
  bool gateUpdateDisplayName = false;

  final List<Completer<StartupSnapshot>> resolves =
      <Completer<StartupSnapshot>>[];
  final List<(LocalProfile, Completer<LocalProfile>)> profileCompletions =
      <(LocalProfile, Completer<LocalProfile>)>[];
  final List<(OnboardingCheckpoint, Completer<OnboardingCheckpoint>)>
  checkpointCompletions =
      <(OnboardingCheckpoint, Completer<OnboardingCheckpoint>)>[];

  @override
  Future<StartupSnapshot> resolveStartup() {
    if (!gateResolve) {
      return _inner.resolveStartup();
    }
    final completer = Completer<StartupSnapshot>();
    resolves.add(completer);
    return completer.future;
  }

  void completeResolve(int index, StartupSnapshot snapshot) {
    resolves[index].complete(snapshot);
  }

  void failResolve(int index, Object error) {
    resolves[index].completeError(error);
  }

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() async =>
      _holdCheckpoint(await _inner.beginOrResumeOnboarding());

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) async =>
      _holdCheckpoint(await _inner.saveOnboardingDraft(displayName));

  Future<OnboardingCheckpoint> _holdCheckpoint(
    OnboardingCheckpoint checkpoint,
  ) {
    if (!gateCheckpoint) {
      return Future<OnboardingCheckpoint>.value(checkpoint);
    }
    final completer = Completer<OnboardingCheckpoint>();
    checkpointCompletions.add((checkpoint, completer));
    return completer.future;
  }

  @override
  Future<LocalProfile> completeOnboarding() async {
    final profile = await _inner.completeOnboarding();
    if (!gateCompleteOnboarding) {
      return profile;
    }
    final completer = Completer<LocalProfile>();
    profileCompletions.add((profile, completer));
    return completer.future;
  }

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) async {
    final profile = await _inner.updateDisplayName(displayName);
    if (!gateUpdateDisplayName) {
      return profile;
    }
    final completer = Completer<LocalProfile>();
    profileCompletions.add((profile, completer));
    return completer.future;
  }

  void releaseProfileCompletion() {
    final entry = profileCompletions.removeAt(0);
    entry.$2.complete(entry.$1);
  }

  void releaseCheckpointCompletion() {
    final entry = checkpointCompletions.removeAt(0);
    entry.$2.complete(entry.$1);
  }
}

ProviderContainer _openContainer(_ScriptedStartupRepository repository) {
  final container = ProviderContainer(
    overrides: [
      startupRepositoryProvider.overrideWithValue(repository),
      diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

_ScriptedStartupRepository _scripted() {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  return _ScriptedStartupRepository(buildTestRepository(database: database));
}

/// Same scripted repository, but with a real canonical profile already
/// persisted so the first resolution lands on Ready.
Future<_ScriptedStartupRepository> _scriptedWithProfile() async {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final inner = buildTestRepository(database: database);
  await inner.completeOnboarding();
  return _ScriptedStartupRepository(inner);
}

void main() {
  test('H0 control: the current security resolution still publishes once', () async {
    final scripted = _scripted()..gateResolve = true;
    final container = _openContainer(scripted);
    final controller = container.read(startupControllerProvider.notifier);
    expect(scripted.resolves, hasLength(1));

    scripted.completeResolve(0, _ready());
    await _flush();
    expect(container.read(startupControllerProvider), isA<StartupReady>());

    final second = controller.initialize();
    expect(scripted.resolves, hasLength(2));
    scripted.completeResolve(1, _protected());
    await second;
    expect(container.read(startupControllerProvider), isA<StartupProtected>());
  });

  test('H1 a late Ready cannot be published after a newer Protected', () async {
    final scripted = _scripted()..gateResolve = true;
    final container = _openContainer(scripted);
    final states = <StartupState>[];
    container.listen<StartupState>(
      startupControllerProvider,
      (_, next) => states.add(next),
    );
    final controller = container.read(startupControllerProvider.notifier);
    final second = controller.initialize();
    expect(scripted.resolves, hasLength(2));

    scripted.completeResolve(1, _protected());
    await second;
    await _flush();
    expect(container.read(startupControllerProvider), isA<StartupProtected>());

    scripted.completeResolve(0, _ready());
    await _flush();
    expect(
      container.read(startupControllerProvider),
      isA<StartupProtected>(),
      reason: 'an older Ready must not overturn the newer Protected',
    );
    final protectedIndex = states.indexWhere((s) => s is StartupProtected);
    expect(protectedIndex, isNonNegative);
    expect(
      states.skip(protectedIndex + 1).whereType<StartupReady>(),
      isEmpty,
      reason: 'no Ready may be published after the newer Protected',
    );
  });

  test('H2 a late Ready cannot replace a newer Recovery', () async {
    final scripted = _scripted()..gateResolve = true;
    final container = _openContainer(scripted);
    final controller = container.read(startupControllerProvider.notifier);
    final second = controller.initialize();

    scripted.failResolve(1, StateError('database unavailable'));
    await second;
    await _flush();
    expect(container.read(startupControllerProvider), isA<StartupRecovery>());

    scripted.completeResolve(0, _ready());
    await _flush();
    expect(
      container.read(startupControllerProvider),
      isA<StartupRecovery>(),
      reason: 'a discarded older success must not clear the recovery state',
    );
  });

  test('H3 a late older failure cannot publish Recovery over a newer Ready', () async {
    final scripted = _scripted()..gateResolve = true;
    final container = _openContainer(scripted);
    final controller = container.read(startupControllerProvider.notifier);
    final second = controller.initialize();

    scripted.completeResolve(1, _ready());
    await second;
    await _flush();
    expect(container.read(startupControllerProvider), isA<StartupReady>());

    scripted.failResolve(0, StateError('database unavailable'));
    await _flush();
    expect(
      container.read(startupControllerProvider),
      isA<StartupReady>(),
      reason: 'a stale failure must never mark a resolved database as broken',
    );
  });

  test('H4 a disposal during resolve mutates nothing and throws nothing', () async {
    final scripted = _scripted()..gateResolve = true;
    final container = _openContainer(scripted);
    final controller = container.read(startupControllerProvider.notifier);
    final pending = controller.initialize();
    expect(scripted.resolves, hasLength(2));

    container.dispose();
    scripted.completeResolve(0, _ready());
    scripted.completeResolve(1, _ready());

    Object? thrown;
    try {
      await pending;
    } on Object catch (error) {
      thrown = error;
    }
    expect(thrown, isNull, reason: 'a disposed controller must not publish');
  });

  test('H5 a pending display-name write cannot publish Ready over a newer Protected', () async {
    final scripted = await _scriptedWithProfile();
    final container = _openContainer(scripted);
    final controller = container.read(startupControllerProvider.notifier);
    await controller.initialize();
    expect(container.read(startupControllerProvider), isA<StartupReady>());

    scripted.gateUpdateDisplayName = true;
    scripted.gateResolve = true;
    final update = controller.updateDisplayName('Renamed');
    await _flush();
    expect(scripted.profileCompletions, hasLength(1));

    final second = controller.initialize();
    scripted.completeResolve(0, _protected());
    await second;
    await _flush();
    expect(container.read(startupControllerProvider), isA<StartupProtected>());

    scripted.releaseProfileCompletion();
    await update;
    expect(
      container.read(startupControllerProvider),
      isA<StartupProtected>(),
      reason: 'the older profile publication must be discarded',
    );
  });

  test('H6 a pending onboarding completion cannot publish Ready over a newer security resolution', () async {
    final scripted = _scripted();
    final container = _openContainer(scripted);
    final controller = container.read(startupControllerProvider.notifier);
    await controller.initialize();
    expect(container.read(startupControllerProvider), isA<StartupWelcome>());

    scripted.gateCompleteOnboarding = true;
    scripted.gateResolve = true;
    final completion = controller.completeOnboarding();
    await _flush();
    expect(scripted.profileCompletions, hasLength(1));

    final second = controller.initialize();
    scripted.completeResolve(0, _protected());
    await second;
    await _flush();
    expect(container.read(startupControllerProvider), isA<StartupProtected>());

    scripted.releaseProfileCompletion();
    await completion;
    expect(
      container.read(startupControllerProvider),
      isA<StartupProtected>(),
      reason: 'the stale onboarding Ready must not be republished',
    );
  });

  test('H7 an old draft checkpoint publication cannot override a newer gate', () async {
    final scripted = _scripted();
    final container = _openContainer(scripted);
    final controller = container.read(startupControllerProvider.notifier);
    await controller.initialize();
    expect(container.read(startupControllerProvider), isA<StartupWelcome>());

    scripted.gateCheckpoint = true;
    scripted.gateResolve = true;
    final draft = controller.continueLocalOnly();
    await _flush();
    expect(scripted.checkpointCompletions, hasLength(1));

    final second = controller.initialize();
    scripted.completeResolve(0, _protected());
    await second;
    await _flush();
    expect(container.read(startupControllerProvider), isA<StartupProtected>());

    scripted.releaseCheckpointCompletion();
    await draft;
    expect(
      container.read(startupControllerProvider),
      isA<StartupProtected>(),
      reason: 'no draft write may publish over a newer security resolution',
    );
  });
}
