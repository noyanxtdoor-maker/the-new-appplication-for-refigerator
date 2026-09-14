// M1 (T5 / L) — LocalAuthDeviceAuthenticator contract.
//
// The OS authentication adapter is deliberately NOT part of the M1 correction:
// the fail-closed model depends on it staying exactly as accepted.  This test
// pins that contract so a later refactor cannot quietly change the option set,
// the user-facing reason, or the plugin-result mapping the controller consumes.
//
// The pinned local_auth 3.0.2 `LocalAuthentication` class is not `final`, so a
// test-local subclass can capture the named options and return a controlled
// result (or throw a real `LocalAuthException`) with no mock dependency.
// `AuthMessages` is intentionally not referenced: the public `local_auth`
// library does not export it, and a transitive platform-interface import would
// violate the dependency contract.  A widened `Iterable<dynamic>` parameter is
// a valid override of `Iterable<AuthMessages>` and is never exercised here.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/data/local_auth_device_authenticator.dart';

final class _FakeLocalAuthentication extends LocalAuthentication {
  _FakeLocalAuthentication({
    this.supported = true,
    this.result = true,
    this.failure,
    this.supportFailure,
  });

  bool supported;
  bool result;
  Object? failure;
  Object? supportFailure;

  int authenticateCalls = 0;
  String? capturedReason;
  bool? capturedBiometricOnly;
  bool? capturedPersistAcrossBackgrounding;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const <dynamic>[],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    authenticateCalls += 1;
    capturedReason = localizedReason;
    capturedBiometricOnly = biometricOnly;
    capturedPersistAcrossBackgrounding = persistAcrossBackgrounding;
    final Object? thrown = failure;
    if (thrown != null) {
      throw thrown;
    }
    return result;
  }

  @override
  Future<bool> isDeviceSupported() async {
    final Object? thrown = supportFailure;
    if (thrown != null) {
      throw thrown;
    }
    return supported;
  }
}

void main() {
  group('M1 L: adapter options and reason are unchanged', () {
    test('L1 authenticate uses non-biometric fallback and persists across '
        'backgrounding, with the accepted reason', () async {
      final plugin = _FakeLocalAuthentication();
      final authenticator = LocalAuthDeviceAuthenticator(
        authentication: plugin,
      );

      expect(
        await authenticator.authenticate(),
        DeviceAuthenticationResult.authenticated,
      );
      expect(plugin.authenticateCalls, 1);
      expect(
        plugin.capturedBiometricOnly,
        isFalse,
        reason: 'a device credential must remain an accepted unlock path',
      );
      expect(
        plugin.capturedPersistAcrossBackgrounding,
        isTrue,
        reason: 'authentication survives the backgrounding privacy session',
      );
      expect(
        plugin.capturedReason,
        'Unlock your private Next Transfer planner',
        reason: 'the owner-facing reason string is part of the accepted UX',
      );
    });

    test('L2 a false plugin result maps to failed', () async {
      final plugin = _FakeLocalAuthentication(result: false);
      final authenticator = LocalAuthDeviceAuthenticator(
        authentication: plugin,
      );
      expect(
        await authenticator.authenticate(),
        DeviceAuthenticationResult.failed,
      );
    });

    test('L3 cancellation, lockout and missing-credential codes map exactly',
        () async {
      final expectations = <LocalAuthExceptionCode, DeviceAuthenticationResult>{
        LocalAuthExceptionCode.userCanceled: DeviceAuthenticationResult.canceled,
        LocalAuthExceptionCode.systemCanceled:
            DeviceAuthenticationResult.canceled,
        LocalAuthExceptionCode.timeout: DeviceAuthenticationResult.canceled,
        LocalAuthExceptionCode.temporaryLockout:
            DeviceAuthenticationResult.temporarilyLocked,
        LocalAuthExceptionCode.biometricLockout:
            DeviceAuthenticationResult.temporarilyLocked,
        LocalAuthExceptionCode.noCredentialsSet:
            DeviceAuthenticationResult.unavailable,
        LocalAuthExceptionCode.noBiometricsEnrolled:
            DeviceAuthenticationResult.unavailable,
        LocalAuthExceptionCode.noBiometricHardware:
            DeviceAuthenticationResult.unavailable,
        LocalAuthExceptionCode.deviceError: DeviceAuthenticationResult.failed,
      };

      for (final entry in expectations.entries) {
        final plugin = _FakeLocalAuthentication(
          failure: LocalAuthException(code: entry.key),
        );
        final authenticator = LocalAuthDeviceAuthenticator(
          authentication: plugin,
        );
        expect(
          await authenticator.authenticate(),
          entry.value,
          reason: 'unexpected mapping for ${entry.key.name}',
        );
      }
    });

    test('L4 an unexpected throw is a safe failed result, never a grant',
        () async {
      final plugin = _FakeLocalAuthentication(failure: StateError('boom'));
      final authenticator = LocalAuthDeviceAuthenticator(
        authentication: plugin,
      );
      expect(
        await authenticator.authenticate(),
        DeviceAuthenticationResult.failed,
      );
    });
  });

  group('M1 L: availability', () {
    test('L5 device support maps to availability and a throw is unavailable',
        () async {
      final supported = LocalAuthDeviceAuthenticator(
        authentication: _FakeLocalAuthentication(supported: true),
      );
      expect(
        await supported.availability(),
        DeviceAuthenticationAvailability.available,
      );

      final unsupported = LocalAuthDeviceAuthenticator(
        authentication: _FakeLocalAuthentication(supported: false),
      );
      expect(
        await unsupported.availability(),
        DeviceAuthenticationAvailability.unavailable,
      );

      final throwing = LocalAuthDeviceAuthenticator(
        authentication: _FakeLocalAuthentication(
          supportFailure: StateError('boom'),
        ),
      );
      expect(
        await throwing.availability(),
        DeviceAuthenticationAvailability.unavailable,
        reason: 'an unsupported query fails to the safe unavailable state',
      );
    });
  });
}
