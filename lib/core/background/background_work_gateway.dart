enum BackgroundNetworkConstraint { notRequired, connected, unmetered }

enum BackgroundExistingWorkPolicy { keep, replace }

/// Mirrors the installed plugin's [BackoffPolicy] without leaking it into the
/// domain layer.  Contract section 31 requires exponential minimum backoff for
/// bounded delivery retries; the composition layer supplies the concrete
/// delays (30s/60s/120s/240s for attempts 1-4).
enum BackgroundBackoffPolicy { linear, exponential }

enum BackgroundGatewayWorkState { absent, scheduled }

final class BackgroundWorkConstraints {
  const BackgroundWorkConstraints({
    this.network = BackgroundNetworkConstraint.notRequired,
    this.requiresCharging = false,
    this.requiresBatteryNotLow = false,
    this.requiresStorageNotLow = false,
  });

  final BackgroundNetworkConstraint network;
  final bool requiresCharging;
  final bool requiresBatteryNotLow;
  final bool requiresStorageNotLow;
}

final class BackgroundWorkSpec {
  const BackgroundWorkSpec({
    required this.uniqueName,
    required this.taskName,
    this.inputData = const <String, Object?>{},
    this.initialDelay,
    this.tag,
    this.constraints = const BackgroundWorkConstraints(),
    this.existingPolicy = BackgroundExistingWorkPolicy.keep,
    this.backoffPolicy,
    this.backoffPolicyDelay,
  });

  static final RegExp _safeKey = RegExp(r'^[a-z0-9_]{1,64}$');
  static final RegExp _safeValue = RegExp(r'^[A-Za-z0-9_.:-]{1,256}$');

  final String uniqueName;
  final String taskName;
  final Map<String, Object?> inputData;
  final Duration? initialDelay;
  final String? tag;
  final BackgroundWorkConstraints constraints;
  final BackgroundExistingWorkPolicy existingPolicy;

  /// Optional bounded-retry configuration (contract section 31).  Absent means
  /// the platform default; delivery work that is allowed to retry sets both.
  final BackgroundBackoffPolicy? backoffPolicy;
  final Duration? backoffPolicyDelay;

  void validate() {
    if (tag != null && !_safeValue.hasMatch(tag!)) throw ArgumentError('Invalid background tag.');
    if (!_safeValue.hasMatch(uniqueName) || !_safeValue.hasMatch(taskName)) {
      throw ArgumentError('Background work identity must be a safe token.');
    }
    for (final entry in inputData.entries) {
      if (!_safeKey.hasMatch(entry.key)) {
        throw ArgumentError('Background input key is not allowlisted.');
      }
      final value = entry.value;
      if (value is String && !_safeValue.hasMatch(value)) {
        throw ArgumentError(
          'Background input strings must be identity tokens.',
        );
      }
      if (value != null &&
          value is! String &&
          value is! int &&
          value is! bool) {
        throw ArgumentError('Background input contains unsupported data.');
      }
    }
  }
}

abstract interface class BackgroundWorkGateway {
  Future<void> initialize();

  Future<void> enqueueUnique(BackgroundWorkSpec work);

  Future<void> cancelUnique(String uniqueName);

  Future<BackgroundGatewayWorkState> inspect(String uniqueName);
}
