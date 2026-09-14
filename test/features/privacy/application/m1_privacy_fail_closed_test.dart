// M1 (T1 / A–G) — Privacy Lock fail-closed regression.
//
// LAW.  A privacy-settings read that FAILED or has not yet completed is
// UNKNOWN provenance.  Unknown never authorizes:
//   * the disabled shortcut must be refused while provenance is unknown;
//   * the recovery action (the existing Unlock button) retries the real read
//     once and then requires OS authentication;
//   * a trusted successful read — including a successful "no row" read, which
//     is legitimately disabled — still behaves exactly as accepted;
//   * a late load/auth/write completion can neither unlock nor overwrite
//     newer state.
//
// The ACTUAL `SessionPrivacyGate` is used throughout.  Only the controller's
// own repository is wrapped, so startup's independent canonical read stays
// healthy (a poisoned gate would test the fixture, not the vulnerability).
//
// NOTE ON THE HARNESS.  `TestPrivacyDependencies.createContainer` appends
// `extraOverrides` AFTER its own defaults and (unlike `buildApp`) does not
// de-duplicate them, so a provider it already overrides cannot be replaced
// through it.  These cases therefore build their own container from the same
// existing interfaces; no shared test helper is modified.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/security/privacy_gate.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

import '../../../support/test_dependencies.dart';

/// Yields to the event loop so a joined/gated future can resume.
Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// Builds a container over the same existing providers, allowing the
/// controller's own repository/gate/authenticator/refresh to be replaced
/// without duplicating an override.
ProviderContainer _open({
  required TestPrivacyDependencies dependencies,
  PrivacyRepository? repository,
  PrivacyGate? gate,
  DeviceAuthenticator? authenticator,
  NotificationPrivacyRefresh? refresh,
}) {
  final container = ProviderContainer(
    overrides: [
      privacyRepositoryProvider.overrideWithValue(
        repository ?? dependencies.repository,
      ),
      privacyGateProvider.overrideWithValue(gate ?? dependencies.gate),
      deviceAuthenticatorProvider.overrideWithValue(
        authenticator ?? dependencies.authenticator,
      ),
      permissionGatewayProvider.overrideWithValue(
        dependencies.permissionGateway,
      ),
      if (refresh != null)
        notificationPrivacyRefreshProvider.overrideWithValue(refresh),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Delegating [PrivacyRepository] that can inject a read failure, hold a read
/// open, force a read result, and hold durable writes open.  Every other call
/// forwards to the real Drift repository.
final class _ForwardingPrivacyRepository implements PrivacyRepository {
  _ForwardingPrivacyRepository(this._inner);

  final PrivacyRepository _inner;

  int readSettingsCalls = 0;
  int setLockEnabledCalls = 0;
  int previewWriteCalls = 0;

  Object? readFailure;
  Completer<void>? readGate;
  Completer<void>? lockWriteGate;
  Completer<void>? previewWriteGate;
  PrivacySettings? forcedReadResult;

  @override
  Future<PrivacySettings> readSettings() async {
    readSettingsCalls += 1;
    final gate = readGate;
    if (gate != null) {
      await gate.future;
    }
    final failure = readFailure;
    if (failure != null) {
      throw failure;
    }
    final forced = forcedReadResult;
    if (forced != null) {
      return forced;
    }
    return _inner.readSettings();
  }

  @override
  Future<PrivacySettings> setLockEnabled(bool enabled) async {
    setLockEnabledCalls += 1;
    final gate = lockWriteGate;
    if (gate != null) {
      await gate.future;
    }
    return _inner.setLockEnabled(enabled);
  }

  @override
  Future<PrivacySettings> setNotificationPreviewMode(
    NotificationPreviewMode mode,
  ) async {
    previewWriteCalls += 1;
    final gate = previewWriteGate;
    if (gate != null) {
      await gate.future;
    }
    return _inner.setNotificationPreviewMode(mode);
  }

  @override
  Future<PermissionAudit> readPermissionAudit(OptionalPermission permission) =>
      _inner.readPermissionAudit(permission);

  @override
  Future<void> recordPermissionGranted(OptionalPermission permission) =>
      _inner.recordPermissionGranted(permission);

  @override
  Future<void> recordPermissionRequested(OptionalPermission permission) =>
      _inner.recordPermissionRequested(permission);

  @override
  Future<bool> isPrivacyLockEnabled() => _inner.isPrivacyLockEnabled();
}

/// Counts gate side effects while delegating to the REAL session gate.
final class _CountingGate implements PrivacyGate {
  _CountingGate(this._inner);

  final PrivacyGate _inner;

  int markUnlockedCalls = 0;
  int markLockedCalls = 0;

  @override
  Future<bool> isUnlockRequired() => _inner.isUnlockRequired();

  @override
  void markLocked() {
    markLockedCalls += 1;
    _inner.markLocked();
  }

  @override
  void markUnlocked() {
    markUnlockedCalls += 1;
    _inner.markUnlocked();
  }
}

/// Device authenticator whose OS result is resolved explicitly by the test.
final class _GatedDeviceAuthenticator implements DeviceAuthenticator {
  int attempts = 0;
  Completer<DeviceAuthenticationResult>? _pending;

  @override
  Future<DeviceAuthenticationAvailability> availability() async =>
      DeviceAuthenticationAvailability.available;

  @override
  Future<DeviceAuthenticationResult> authenticate() {
    attempts += 1;
    final completer = Completer<DeviceAuthenticationResult>();
    _pending = completer;
    return completer.future;
  }

  void resolve(DeviceAuthenticationResult result) {
    final pending = _pending;
    _pending = null;
    pending!.complete(result);
  }
}

void main() {
  test('A1 a failed initial settings read is untrusted and writes nothing', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readFailure = StateError('injected privacy read failure');
    final container = _open(dependencies: dependencies, repository: repository);
    final controller = container.read(privacyControllerProvider.notifier);

    await controller.initialize();

    final state = container.read(privacyControllerProvider);
    expect(state.status, PrivacyLockStatus.unavailable);
    expect(
      state.settings.lockEnabled,
      isFalse,
      reason: 'only the untrusted fallback object is displayed',
    );
    expect(state.message, 'Privacy settings could not be opened.');
    expect(repository.setLockEnabledCalls, 0);
    expect(repository.previewWriteCalls, 0);
    expect(
      (await dependencies.repository.readSettings()).lockEnabled,
      isTrue,
      reason: 'the durable setting must be untouched',
    );
  });

  test('A2 a retry that also fails still denies access and never marks unlocked', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readFailure = StateError('injected privacy read failure');
    final gate = _CountingGate(dependencies.gate);
    final container = _open(
      dependencies: dependencies,
      repository: repository,
      gate: gate,
    );
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.unavailable,
    );

    expect(await controller.authenticate(), isFalse);
    expect(gate.markUnlockedCalls, 0);
    expect(
      await dependencies.gate.isUnlockRequired(),
      isTrue,
      reason: 'the real session gate must still refuse access',
    );
    expect(dependencies.authenticator.authenticationAttempts, 0);
  });

  test('A3 authenticate during an unresolved settings read cannot fast-path', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final pendingRead = Completer<void>();
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readGate = pendingRead
      ..readFailure = StateError('injected privacy read failure');
    final gate = _CountingGate(dependencies.gate);
    final container = _open(
      dependencies: dependencies,
      repository: repository,
      gate: gate,
    );
    final controller = container.read(privacyControllerProvider.notifier);
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.loading,
    );

    final authentication = controller.authenticate();
    pendingRead.complete();
    expect(
      await authentication,
      isFalse,
      reason: 'a not-yet-trusted read must not authorize',
    );
    expect(gate.markUnlockedCalls, 0);
    expect(dependencies.authenticator.authenticationAttempts, 0);
    expect(await dependencies.gate.isUnlockRequired(), isTrue);
  });

  test('E1 explicit retry re-reads settings, then requires OS authentication', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readFailure = StateError('injected privacy read failure');
    final gate = _CountingGate(dependencies.gate);
    final container = _open(
      dependencies: dependencies,
      repository: repository,
      gate: gate,
    );
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.unavailable,
    );

    repository.readFailure = null;
    dependencies.authenticator.authenticationResult =
        DeviceAuthenticationResult.canceled;
    expect(await controller.authenticate(), isFalse);
    expect(gate.markUnlockedCalls, 0);
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.authenticationFailed,
    );
    expect(await dependencies.gate.isUnlockRequired(), isTrue);

    dependencies.authenticator.authenticationResult =
        DeviceAuthenticationResult.authenticated;
    expect(await controller.authenticate(), isTrue);
    expect(gate.markUnlockedCalls, 1);
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.unlocked,
    );
    expect(await dependencies.gate.isUnlockRequired(), isFalse);
  });

  test('F1 a trusted disabled read permits local access with no OS prompt', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readFailure = StateError('injected privacy read failure');
    final container = _open(dependencies: dependencies, repository: repository);
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.unavailable,
    );

    repository.readFailure = null;
    final callsBefore = repository.readSettingsCalls;
    expect(await controller.authenticate(), isTrue);
    expect(
      repository.readSettingsCalls,
      greaterThan(callsBefore),
      reason: 'no authorization before a fresh successful read',
    );
    expect(dependencies.authenticator.authenticationAttempts, 0);
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.disabled,
    );
  });

  test('F2 a successful missing-row read is legitimately disabled and writes nothing', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    final refreshLog = <String>[];
    final container = _open(
      dependencies: dependencies,
      refresh: () async {
        refreshLog.add('refresh');
      },
    );
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();

    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.disabled,
    );
    expect(await controller.authenticate(), isTrue);
    expect(dependencies.authenticator.authenticationAttempts, 0);
    expect(
      await database.select(database.privacyPreferences).get(),
      isEmpty,
      reason: 'a successful absent-row read must never insert a row',
    );
    expect(refreshLog, isEmpty);
  });

  test('G1 duplicate load and Unlock calls collapse to one read and one prompt', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final pendingRead = Completer<void>();
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readGate = pendingRead;
    final container = _open(dependencies: dependencies, repository: repository);
    final controller = container.read(privacyControllerProvider.notifier);

    final first = controller.initialize();
    final second = controller.initialize();
    pendingRead.complete();
    await first;
    await second;
    expect(repository.readSettingsCalls, 1);

    final a = controller.authenticate();
    final b = controller.authenticate();
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(
      dependencies.authenticator.authenticationAttempts,
      1,
      reason: 'simultaneous Unlock taps share one OS prompt',
    );
  });

  test('G2 a stale failed load cannot overwrite a newer protected state', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final pendingRead = Completer<void>();
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readGate = pendingRead
      ..readFailure = StateError('injected privacy read failure');
    final gate = _CountingGate(dependencies.gate);
    final container = _open(
      dependencies: dependencies,
      repository: repository,
      gate: gate,
    );
    final controller = container.read(privacyControllerProvider.notifier);

    expect(
      controller.lockForBackground(),
      isTrue,
      reason: 'unknown settings must still require protection',
    );
    final lockedCalls = gate.markLockedCalls;
    repository.readGate = null;
    pendingRead.complete();
    await _flush();

    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.locked,
    );
    expect(
      gate.markLockedCalls,
      lockedCalls,
      reason: 'a discarded stale result must not re-run gate side effects',
    );
  });

  test('G2b a stale successful load cannot replace a newer protected state', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final pendingRead = Completer<void>();
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readGate = pendingRead
      ..forcedReadResult = const PrivacySettings(
        lockEnabled: false,
        notificationPreviewMode: NotificationPreviewMode.hidden,
      );
    final gate = _CountingGate(dependencies.gate);
    final container = _open(
      dependencies: dependencies,
      repository: repository,
      gate: gate,
    );
    final controller = container.read(privacyControllerProvider.notifier);

    expect(controller.lockForBackground(), isTrue);
    repository.readGate = null;
    pendingRead.complete();
    await _flush();

    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.locked,
      reason: 'the newer protection decision stands',
    );
    expect(gate.markUnlockedCalls, 0);
  });

  test('G3 a delayed OS failure after a newer relock cannot overwrite or unlock', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final authenticator = _GatedDeviceAuthenticator();
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final gate = _CountingGate(dependencies.gate);
    final container = _open(
      dependencies: dependencies,
      gate: gate,
      authenticator: authenticator,
    );
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.locked,
    );

    final authentication = controller.authenticate();
    expect(authenticator.attempts, 1);
    expect(controller.lockForBackground(), isTrue);
    authenticator.resolve(DeviceAuthenticationResult.canceled);
    expect(await authentication, isFalse);
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.locked,
      reason: 'a stale failure must not overwrite the newer lock',
    );
    expect(gate.markUnlockedCalls, 0);
  });

  test('G3b a delayed OS success after a newer relock cannot unlock', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final authenticator = _GatedDeviceAuthenticator();
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final gate = _CountingGate(dependencies.gate);
    final container = _open(
      dependencies: dependencies,
      gate: gate,
      authenticator: authenticator,
    );
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();

    final authentication = controller.authenticate();
    expect(controller.lockForBackground(), isTrue);
    authenticator.resolve(DeviceAuthenticationResult.authenticated);
    expect(await authentication, isFalse);
    expect(gate.markUnlockedCalls, 0);
    expect(await dependencies.gate.isUnlockRequired(), isTrue);
  });

  test('G4 unknown settings refuse a preview write and start no refresh', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readFailure = StateError('injected privacy read failure');
    final refreshLog = <String>[];
    final container = _open(
      dependencies: dependencies,
      repository: repository,
      refresh: () async {
        refreshLog.add('refresh');
      },
    );
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();

    await controller.setNotificationPreviewMode(
      NotificationPreviewMode.showContent,
    );

    expect(
      repository.previewWriteCalls,
      0,
      reason: 'unknown provenance must never be written as truth',
    );
    expect(refreshLog, isEmpty);
    expect(
      container.read(privacyControllerProvider).settings.notificationPreviewMode,
      NotificationPreviewMode.hidden,
    );
  });

  test('G4b a stale preview write cannot publish over newer state', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    await dependencies.repository.setLockEnabled(true);
    final writeGate = Completer<void>();
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..previewWriteGate = writeGate;
    final refreshLog = <String>[];
    final container = _open(
      dependencies: dependencies,
      repository: repository,
      refresh: () async {
        refreshLog.add('refresh');
      },
    );
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();

    final write = controller.setNotificationPreviewMode(
      NotificationPreviewMode.showContent,
    );
    await _flush();
    expect(repository.previewWriteCalls, 1);
    expect(controller.lockForBackground(), isFalse);
    writeGate.complete();
    await write;
    await _flush();

    expect(
      container.read(privacyControllerProvider).settings.notificationPreviewMode,
      NotificationPreviewMode.hidden,
      reason: 'a superseded write completion must not publish its settings',
    );
    expect(refreshLog, isEmpty);
  });

  test('G5 a successful initialization is cached and never re-reads', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    final repository = _ForwardingPrivacyRepository(dependencies.repository);
    final refreshLog = <String>[];
    final container = _open(
      dependencies: dependencies,
      repository: repository,
      refresh: () async {
        refreshLog.add('refresh');
      },
    );
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.disabled,
    );

    final callsAfterSuccess = repository.readSettingsCalls;
    await controller.initialize();
    await controller.initialize();
    expect(
      repository.readSettingsCalls,
      callsAfterSuccess,
      reason: 'a trusted successful load is cached, not polled',
    );
    expect(refreshLog, isEmpty);
  });

  test('G5b a failed load is retryable and is not cached as permanent truth', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    final repository = _ForwardingPrivacyRepository(dependencies.repository)
      ..readFailure = StateError('injected privacy read failure');
    final container = _open(dependencies: dependencies, repository: repository);
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.unavailable,
    );

    final callsAfterFailure = repository.readSettingsCalls;
    repository.readFailure = null;
    await controller.initialize();
    expect(
      repository.readSettingsCalls,
      callsAfterFailure + 1,
      reason: 'a failed load must not be retained as the permanent result',
    );
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.disabled,
    );
  });

  test('G6 only a real durable write refreshes notification privacy', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final dependencies = TestPrivacyDependencies(database: database);
    final refreshLog = <String>[];
    final container = _open(
      dependencies: dependencies,
      refresh: () async {
        refreshLog.add('refresh');
      },
    );
    final controller = container.read(privacyControllerProvider.notifier);
    await controller.initialize();
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.disabled,
    );

    expect(await controller.enableLock(), isTrue);
    expect(refreshLog, hasLength(1), reason: 'one refresh per real write');

    await controller.initialize();
    expect(controller.lockForBackground(), isTrue);
    await controller.authenticate();
    expect(
      refreshLog,
      hasLength(1),
      reason: 'reads, retries, relocks and plain auth never refresh',
    );
  });
}
