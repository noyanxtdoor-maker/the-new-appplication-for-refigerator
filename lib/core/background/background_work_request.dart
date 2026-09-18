enum BackgroundWorkCategory {
  reminderRecovery,
  notificationFoundation,
  contentCheck,
  syncOutbox,
}

enum BackgroundWorkOwnerKind {
  profile,
  event,
  task,
  occurrence,
  planning,
  device,
}

enum BackgroundWorkState {
  queued,
  waitingForConstraints,
  running,
  delayedBySystem,
  retryScheduled,
  scheduled,
  completed,
  cancelledObsolete,
  failedActionRequired,
}

final class BackgroundWorkRequest {
  const BackgroundWorkRequest({
    required this.stableKey,
    required this.category,
    required this.ownerKind,
    required this.state,
    required this.attemptCount,
    required this.snoozeCount,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.profileId,
    this.ownerId,
    this.occurrenceId,
    this.sourceRevision,
    this.scheduledForUtc,
    this.platformNotificationId,
    this.lastAttemptAtUtc,
    this.nextEligibleAtUtc,
    this.completedAtUtc,
    this.lastFailureCategory,
  });

  static final RegExp _safeToken = RegExp(r'^[A-Za-z0-9_.:-]{1,256}$');
  static final RegExp _safeCategory = RegExp(r'^[a-z0-9_]{1,64}$');

  final String stableKey;
  final String? profileId;
  final BackgroundWorkCategory category;
  final BackgroundWorkOwnerKind ownerKind;
  final String? ownerId;
  final String? occurrenceId;
  final String? sourceRevision;
  final DateTime? scheduledForUtc;
  final BackgroundWorkState state;
  final int? platformNotificationId;
  final int attemptCount;
  final int snoozeCount;
  final DateTime? lastAttemptAtUtc;
  final DateTime? nextEligibleAtUtc;

  /// V39 stores the Snooze target in the existing sanitized eligibility field.
  DateTime? get snoozedUntilUtc => snoozeCount > 0 ? nextEligibleAtUtc : null;
  final DateTime? completedAtUtc;
  final String? lastFailureCategory;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  void validate() {
    for (final value in <String?>[
      stableKey,
      profileId,
      ownerId,
      occurrenceId,
      sourceRevision,
    ]) {
      if (value != null && !_safeToken.hasMatch(value)) {
        throw ArgumentError(
          'Background identity metadata must be a safe token.',
        );
      }
    }
    final failure = lastFailureCategory;
    if (failure != null && !_safeCategory.hasMatch(failure)) {
      throw ArgumentError('Failure category must be a sanitized key.');
    }
    if (attemptCount < 0 || snoozeCount < 0) {
      throw ArgumentError('Background counters cannot be negative.');
    }
    if (platformNotificationId != null && platformNotificationId! < 1) {
      throw ArgumentError('Platform notification ID must be positive.');
    }
  }

  /// Nullable fields alone cannot express "clear": a null argument means
  /// PRESERVE.  [clearLastAttemptAtUtc], [clearNextEligibleAtUtc],
  /// [clearCompletedAtUtc] and [clearLastFailureCategory] are the explicit
  /// VS16 M8 clear semantics needed for a new repair episode or a fresh
  /// revision that must not inherit stale retry/failure/eligibility metadata.
  BackgroundWorkRequest copyWith({
    BackgroundWorkState? state,
    int? platformNotificationId,
    int? attemptCount,
    int? snoozeCount,
    DateTime? scheduledForUtc,
    DateTime? lastAttemptAtUtc,
    DateTime? nextEligibleAtUtc,
    DateTime? completedAtUtc,
    String? lastFailureCategory,
    DateTime? updatedAtUtc,
    bool clearLastAttemptAtUtc = false,
    bool clearNextEligibleAtUtc = false,
    bool clearCompletedAtUtc = false,
    bool clearLastFailureCategory = false,
  }) => BackgroundWorkRequest(
    stableKey: stableKey,
    profileId: profileId,
    category: category,
    ownerKind: ownerKind,
    ownerId: ownerId,
    occurrenceId: occurrenceId,
    sourceRevision: sourceRevision,
    scheduledForUtc: scheduledForUtc ?? this.scheduledForUtc,
    state: state ?? this.state,
    platformNotificationId:
        platformNotificationId ?? this.platformNotificationId,
    attemptCount: attemptCount ?? this.attemptCount,
    snoozeCount: snoozeCount ?? this.snoozeCount,
    lastAttemptAtUtc: clearLastAttemptAtUtc
        ? null
        : lastAttemptAtUtc ?? this.lastAttemptAtUtc,
    nextEligibleAtUtc: clearNextEligibleAtUtc
        ? null
        : nextEligibleAtUtc ?? this.nextEligibleAtUtc,
    completedAtUtc: clearCompletedAtUtc
        ? null
        : completedAtUtc ?? this.completedAtUtc,
    lastFailureCategory: clearLastFailureCategory
        ? null
        : lastFailureCategory ?? this.lastFailureCategory,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}
