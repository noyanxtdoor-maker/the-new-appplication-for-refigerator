/// The one bounded retry law for durable background work (contract section 31).
///
/// Section 31 allows a maximum of five persisted attempts per technical
/// revision, with exponential MINIMUM backoff of 30s, 60s, 120s and 240s for
/// attempts 1-4.  Attempt 5 is terminal `retry_exhausted`.
///
/// "Minimum" is deliberate: the OS decides when it actually runs the work, so
/// `nextEligibleAtUtc` is the earliest eligibility instant and never a promise
/// of execution.  The same arithmetic is shared by the targeted delivery worker
/// and by the durable reconciliation marker, so the budget cannot drift between
/// the two consumers.
abstract final class BackgroundRetryPolicy {
  /// Maximum persisted attempts for ONE technical revision / generation.
  static const int maxAttemptsPerRevision = 5;

  /// Minimum backoff before attempt [attempt] (1-based): 30/60/120/240 seconds.
  ///
  /// Attempts beyond the fourth keep the largest step; the terminal attempt is
  /// identified by [isTerminalAttempt] rather than by a longer delay.
  static Duration minimumBackoffFor(int attempt) {
    if (attempt < 1) {
      throw ArgumentError.value(attempt, 'attempt', 'Attempts are 1-based.');
    }
    return Duration(seconds: 30 * (1 << (attempt - 1).clamp(0, 3)));
  }

  /// True when [attempt] has reached the terminal `retry_exhausted` budget.
  static bool isTerminalAttempt(int attempt) =>
      attempt >= maxAttemptsPerRevision;
}
