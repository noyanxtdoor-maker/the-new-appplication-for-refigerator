enum BackgroundNetworkConstraint { notRequired, connected, unmetered }

enum BackgroundExistingWorkPolicy { keep, replace }

enum BackgroundBackoffPolicy { exponential, linear }

/// Truthful platform work observation.  [scheduled] is retained as the
/// compatibility spelling for an ENQUEUED/BLOCKED request so existing fakes
/// stay valid; [unknown] is used when the platform cannot answer (e.g. a web
/// or iOS surface without a query API), never as a fabricated delay label.
enum BackgroundGatewayWorkState {
  absent,
  scheduled,
  running,
  succeeded,
  failed,
  cancelled,
  unknown;

  bool get isActive => this == scheduled || this == running;
}

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

  /// Bounded retry configuration.  M8 delivery work uses an exponential
  /// policy with a 30s initial delay so attempts 1-4 observe
  /// 30s/60s/120s/240s without any custom scheduler.
  final BackgroundBackoffPolicy? backoffPolicy;
  final Duration? backoffPolicyDelay;

  void validate() {
    if (tag != null && !_safeValue.hasMatch(tag!)) {
      throw ArgumentError('Invalid background tag.');
    }
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
