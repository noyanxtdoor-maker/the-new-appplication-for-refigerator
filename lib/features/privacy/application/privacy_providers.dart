import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/security/auth_token_store.dart';
import 'package:rmplanner/core/security/privacy_gate.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/privacy/application/privacy_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

final privacyRepositoryProvider = Provider<PrivacyRepository>((ref) {
  throw StateError('PrivacyRepository must be overridden at the app root');
});

final privacyGateProvider = Provider<PrivacyGate>((ref) {
  throw StateError('PrivacyGate must be overridden at the app root');
});

final deviceAuthenticatorProvider = Provider<DeviceAuthenticator>((ref) {
  throw StateError('DeviceAuthenticator must be overridden at the app root');
});

final monotonicClockProvider = Provider<MonotonicClock>((ref) {
  return StopwatchMonotonicClock();
});

final permissionGatewayProvider = Provider<PermissionGateway>((ref) {
  throw StateError('PermissionGateway must be overridden at the app root');
});

final authTokenStoreProvider = Provider<AuthTokenStore>((ref) {
  throw StateError('AuthTokenStore must be overridden at the app root');
});

enum PrivacyLockStatus {
  loading,
  disabled,
  locked,
  authenticating,
  unlocked,
  authenticationFailed,
  unavailable,
}

final class PrivacyState {
  const PrivacyState({
    required this.status,
    required this.settings,
    this.message,
    this.settingsTrusted = false,
  });

  const PrivacyState.loading()
    : status = PrivacyLockStatus.loading,
      settings = const PrivacySettings.defaults(),
      message = null,
      settingsTrusted = false;

  final PrivacyLockStatus status;
  final PrivacySettings settings;
  final String? message;

  /// True ONLY when [settings] came from a successful canonical read.
  ///
  /// A fallback/default object (initial load, failed read or an invalidated
  /// configuration) is never a trustworthy description of the persisted
  /// setting, so it must never authorize the "lock disabled" shortcut.
  final bool settingsTrusted;

  bool get isBusy =>
      status == PrivacyLockStatus.loading ||
      status == PrivacyLockStatus.authenticating;

  /// True when background access must be protected.  Unknown provenance
  /// protects even when the displayed fallback says the lock is disabled.
  bool get requiresProtection => !settingsTrusted || settings.lockEnabled;

  PrivacyState copyWith({
    PrivacyLockStatus? status,
    PrivacySettings? settings,
    String? message,
    bool? settingsTrusted,
    bool clearMessage = false,
  }) {
    return PrivacyState(
      status: status ?? this.status,
      settings: settings ?? this.settings,
      message: clearMessage ? null : message ?? this.message,
      settingsTrusted: settingsTrusted ?? this.settingsTrusted,
    );
  }
}

final privacyControllerProvider =
    NotifierProvider<PrivacyController, PrivacyState>(PrivacyController.new);

final class PrivacyController extends Notifier<PrivacyState> {
  Future<void>? _initialization;
  Future<bool>? _authentication;
  int _lockGeneration = 0;
  bool _settingsTrusted = false;

  PrivacyRepository get _repository => ref.read(privacyRepositoryProvider);
  PrivacyGate get _gate => ref.read(privacyGateProvider);
  DeviceAuthenticator get _authenticator =>
      ref.read(deviceAuthenticatorProvider);

  @override
  PrivacyState build() {
    unawaited(initialize());
    return const PrivacyState.loading();
  }

  /// Runs at most one settings load at a time and caches only a SUCCESSFUL
  /// result.  A failed or superseded load is never cached, so the existing
  /// Unlock action can retry the real read; simultaneous callers join the
  /// single in-flight load instead of starting parallel reads.
  Future<void> initialize() async {
    if (_settingsTrusted) {
      return;
    }
    final existing = _initialization;
    if (existing != null) {
      await existing;
      return;
    }
    state = const PrivacyState.loading();
    final future = _loadSettings(_lockGeneration);
    _initialization = future;
    try {
      await future;
    } finally {
      if (identical(_initialization, future)) {
        _initialization = null;
      }
    }
  }

  Future<void> _loadSettings(int generation) async {
    try {
      final settings = await _repository.readSettings();
      if (generation != _lockGeneration || !ref.mounted) {
        return;
      }
      if (settings.lockEnabled) {
        _gate.markLocked();
      }
      final availability = await _authenticator.availability();
      if (generation != _lockGeneration || !ref.mounted) {
        return;
      }
      _settingsTrusted = true;
      state = PrivacyState(
        status: settings.lockEnabled
            ? PrivacyLockStatus.locked
            : PrivacyLockStatus.disabled,
        settings: settings,
        settingsTrusted: true,
        message:
            settings.lockEnabled &&
                availability == DeviceAuthenticationAvailability.unavailable
            ? 'Device authentication is unavailable. Configure a screen lock '
                  'in Android Settings, then try again.'
            : null,
      );
    } on Object {
      if (generation != _lockGeneration || !ref.mounted) {
        return;
      }
      // A failed read is UNKNOWN provenance: lock the session, publish a
      // recoverable state, and never use the fallback object as authority.
      _settingsTrusted = false;
      _gate.markLocked();
      state = const PrivacyState(
        status: PrivacyLockStatus.unavailable,
        settings: PrivacySettings.defaults(),
        message: 'Privacy settings could not be opened.',
      );
    }
  }

  Future<bool> authenticate() async {
    if (!state.settingsTrusted) {
      // Recovery entry point: retry the real read once.  Still unknown after
      // that is refused; a newly trusted ENABLED configuration requires OS
      // authentication within this same user action.
      await initialize();
      if (!state.settingsTrusted || state.isBusy) {
        return false;
      }
    }
    if (!state.settings.lockEnabled) {
      _gate.markUnlocked();
      state = state.copyWith(
        status: PrivacyLockStatus.disabled,
        clearMessage: true,
      );
      return true;
    }
    final existing = _authentication;
    if (existing != null) {
      return existing;
    }
    final future = _runAuthentication();
    _authentication = future;
    try {
      return await future;
    } finally {
      if (identical(_authentication, future)) {
        _authentication = null;
      }
    }
  }

  Future<bool> enableLock() async {
    if (!state.settingsTrusted) {
      await initialize();
      if (!state.settingsTrusted) {
        return false;
      }
    }
    if (state.settings.lockEnabled || state.isBusy) {
      return state.settings.lockEnabled;
    }
    final generation = _lockGeneration;
    final availability = await _authenticator.availability();
    if (generation != _lockGeneration || !ref.mounted) {
      return false;
    }
    if (availability == DeviceAuthenticationAvailability.unavailable) {
      state = state.copyWith(
        status: PrivacyLockStatus.unavailable,
        message: 'Set up an Android screen lock before enabling Privacy Lock.',
      );
      return false;
    }
    final authenticated = await _authenticateDevice(generation: generation);
    if (!authenticated || generation != _lockGeneration || !ref.mounted) {
      if (generation != _lockGeneration || !ref.mounted) {
        return false;
      }
      if (state.status != PrivacyLockStatus.unavailable) {
        state = state.copyWith(
          message:
              'Authentication did not complete. Privacy Lock was not '
              'enabled.',
        );
      }
      return false;
    }
    try {
      final settings = await _repository.setLockEnabled(true);
      if (generation != _lockGeneration || !ref.mounted) {
        return false;
      }
      _gate.markUnlocked();
      _settingsTrusted = true;
      state = PrivacyState(
        status: PrivacyLockStatus.unlocked,
        settings: settings,
        settingsTrusted: true,
      );
      await _refreshNotificationPrivacy();
      return true;
    } on Object {
      if (generation != _lockGeneration || !ref.mounted) {
        return false;
      }
      state = state.copyWith(
        status: PrivacyLockStatus.authenticationFailed,
        message:
            'Privacy Lock was not enabled because its setting could not '
            'be saved.',
      );
      return false;
    }
  }

  Future<bool> disableLock() async {
    if (!state.settingsTrusted) {
      await initialize();
      if (!state.settingsTrusted) {
        return false;
      }
    }
    if (!state.settings.lockEnabled || state.isBusy) {
      return !state.settings.lockEnabled;
    }
    final generation = _lockGeneration;
    final authenticated = await _authenticateDevice(generation: generation);
    if (!authenticated || generation != _lockGeneration || !ref.mounted) {
      return false;
    }
    try {
      final settings = await _repository.setLockEnabled(false);
      if (generation != _lockGeneration || !ref.mounted) {
        return false;
      }
      _gate.markUnlocked();
      _settingsTrusted = true;
      state = PrivacyState(
        status: PrivacyLockStatus.disabled,
        settings: settings,
        settingsTrusted: true,
      );
      await _refreshNotificationPrivacy();
      return true;
    } on Object {
      if (generation != _lockGeneration || !ref.mounted) {
        return false;
      }
      _gate.markLocked();
      state = state.copyWith(
        status: PrivacyLockStatus.authenticationFailed,
        message:
            'Privacy Lock remains enabled because its setting could not '
            'be changed.',
      );
      return false;
    }
  }

  Future<void> setNotificationPreviewMode(NotificationPreviewMode mode) async {
    if (!state.settingsTrusted) {
      await initialize();
      if (!state.settingsTrusted || state.isBusy) {
        state = state.copyWith(
          message: 'Notification privacy could not be updated.',
        );
        return;
      }
    }
    if (state.settings.notificationPreviewMode == mode) return;
    final generation = _lockGeneration;
    try {
      final settings = await _repository.setNotificationPreviewMode(mode);
      if (generation != _lockGeneration || !ref.mounted) {
        return;
      }
      state = state.copyWith(settings: settings, clearMessage: true);
      await _refreshNotificationPrivacy();
    } on Object {
      if (generation != _lockGeneration || !ref.mounted) {
        return;
      }
      state = state.copyWith(
        message: 'Notification privacy could not be updated.',
      );
    }
  }

  Future<void> _refreshNotificationPrivacy() async {
    try {
      await ref.read(notificationPrivacyRefreshProvider)();
    } on Object {
      // The privacy preference is already durable. A platform refresh failure
      // must not roll it back or overwrite the saved preview mode; the next
      // reconciliation remains safe and idempotent.
    }
  }

  bool lockForBackground() {
    // Only a TRUSTED disabled configuration may skip protection; unknown
    // provenance protects even though the displayed fallback says disabled.
    // Locking never turns unknown provenance into trusted settings.
    if (state.settingsTrusted && !state.settings.lockEnabled) {
      return false;
    }
    _lockGeneration += 1;
    _initialization = null;
    _gate.markLocked();
    if (state.status == PrivacyLockStatus.locked) {
      return false;
    }
    state = state.copyWith(
      status: PrivacyLockStatus.locked,
      clearMessage: true,
    );
    return true;
  }

  Future<bool> _runAuthentication() async {
    final generation = _lockGeneration;
    final authenticated = await _authenticateDevice(generation: generation);
    if (generation != _lockGeneration || !ref.mounted) {
      return false;
    }
    if (authenticated) {
      _gate.markUnlocked();
      state = state.copyWith(
        status: PrivacyLockStatus.unlocked,
        clearMessage: true,
      );
      return true;
    }
    _gate.markLocked();
    return false;
  }

  /// Prompts the OS adapter once and publishes the canonical result messages.
  ///
  /// [generation] is the operation currently being executed: a late result
  /// from a superseded load/auth/write is discarded BEFORE any state, message,
  /// trust or gate side effect, so it can never overwrite a newer outcome.
  Future<bool> _authenticateDevice({int? generation}) async {
    final token = generation ?? _lockGeneration;
    state = state.copyWith(
      status: PrivacyLockStatus.authenticating,
      clearMessage: true,
    );
    DeviceAuthenticationResult result;
    try {
      result = await _authenticator.authenticate();
    } on Object {
      // A dependency failure degrades to a safe failed result; it never
      // authorizes and never surfaces raw error text.
      result = DeviceAuthenticationResult.failed;
    }
    if (token != _lockGeneration || !ref.mounted) {
      return false;
    }
    switch (result) {
      case DeviceAuthenticationResult.authenticated:
        return true;
      case DeviceAuthenticationResult.canceled:
        state = state.copyWith(
          status: PrivacyLockStatus.authenticationFailed,
          message: 'Authentication was canceled. Your data remains locked.',
        );
        return false;
      case DeviceAuthenticationResult.temporarilyLocked:
        state = state.copyWith(
          status: PrivacyLockStatus.authenticationFailed,
          message:
              'Android temporarily blocked authentication. Wait or use '
              'your device credential, then try again.',
        );
        return false;
      case DeviceAuthenticationResult.unavailable:
        state = state.copyWith(
          status: PrivacyLockStatus.unavailable,
          message:
              'Device authentication is unavailable. Configure a screen '
              'lock in Android Settings, then try again.',
        );
        return false;
      case DeviceAuthenticationResult.failed:
        state = state.copyWith(
          status: PrivacyLockStatus.authenticationFailed,
          message: 'Authentication failed. Your data remains locked.',
        );
        return false;
    }
  }
}

final permissionSummariesProvider = FutureProvider<List<PermissionSummary>>((
  ref,
) async {
  final repository = ref.watch(privacyRepositoryProvider);
  final gateway = ref.watch(permissionGatewayProvider);
  final summaries = <PermissionSummary>[];

  for (final permission in OptionalPermissionCatalog.values) {
    final osState = await gateway.status(permission);
    final audit = await repository.readPermissionAudit(permission);
    if (osState == OperatingSystemPermissionState.granted) {
      await repository.recordPermissionGranted(permission);
    }
    summaries.add(
      PermissionSummary(
        permission: permission,
        title: OptionalPermissionCatalog.title(permission),
        purpose: OptionalPermissionCatalog.purpose(permission),
        state: _resolvePermissionState(osState, audit),
      ),
    );
  }
  return List<PermissionSummary>.unmodifiable(summaries);
});

PermissionState _resolvePermissionState(
  OperatingSystemPermissionState osState,
  PermissionAudit audit,
) {
  return switch (osState) {
    OperatingSystemPermissionState.granted => PermissionState.granted,
    OperatingSystemPermissionState.restricted ||
    OperatingSystemPermissionState.unavailable => PermissionState.unavailable,
    OperatingSystemPermissionState.denied ||
    OperatingSystemPermissionState.permanentlyDenied =>
      audit.everGranted
          ? PermissionState.revoked
          : audit.requestedByApp
          ? PermissionState.denied
          : PermissionState.notRequested,
  };
}
