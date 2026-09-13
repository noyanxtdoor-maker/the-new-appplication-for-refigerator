/// What the platform currently reports about one unique work name.
///
/// The installed plugin collapses Android ENQUEUED and BLOCKED into a single
/// `scheduled` state and exposes no attempt count or finish timestamp on
/// Android, so this enum deliberately carries no more than the platform can
/// actually prove (contract section 65).
enum BackgroundRegistrationState {
  /// The platform has no record of this unique name.
  ///
  /// NOTE: an unavailable/erroring query is NOT absent.  Callers must not map a
  /// failed lookup here — see [BackgroundRepairDecision.unavailable].
  absent,

  /// Enqueued or blocked: still pending, reason and delay not knowable.
  pending,

  /// The platform reported a terminal outcome.  Terminal work is not pending,
  /// but it is also NOT proof that a notification was delivered.
  terminal,

  /// The query itself failed.  Truthful reporting only — never treated as
  /// absent, never used to mark a row running/completed.
  unavailable,
}

/// The durable truth the matrix consults BEFORE any platform state.
///
/// These facts are owned by the app, not the OS, so they outrank WorkInfo.
enum BackgroundDurableEligibility {
  /// Terminal (completed / cancelled-obsolete / failed-action-required): the
  /// episode is over and is never replayed or resurrected.
  terminal,

  /// Ineligible right now (source gone, category off, Event past its end).
  /// Nothing is repaired and nothing is replayed.
  ineligible,

  /// Eligible but never registered, and known not to have posted.
  awaitingFirstRegistration,

  /// Eligible, previously registered, and this exact generation is still live.
  currentGenerationEligible,

  /// A genuinely eligible replacement (new target or technical revision) for a
  /// generation that has not delivered.  Only a real mutation reaches this.
  eligibleReplacement,
}

/// The only permitted action for one repair pass (contract section 65 matrix).
enum BackgroundRepairAction {
  /// Leave the platform registration exactly as it is.
  keep,

  /// Idempotent KEEP enqueue: repair registration uncertainty for demonstrably
  /// unposted work without replacing an existing job.
  enqueueKeep,

  /// Replace the registration for a genuinely changed eligible generation.
  replace,

  /// Cancel the stale registration, then register the new generation.
  cancelThenReplace,

  /// Nothing to do, and nothing may be replayed.
  none,

  /// The platform truth could not be read; report it and change nothing.
  unavailable,
}

/// Pure §65 WorkInfo decision matrix.
///
/// It is a pure function of (durable truth, platform state, generation identity)
/// so the entire contract matrix is unit-testable without WorkManager, a phone
/// or timing.  Every branch encodes an explicit adjudicated rule rather than an
/// inference from the platform.
abstract final class BackgroundRepairDecision {
  /// [sameGeneration] means the durable row is the identical generation the
  /// caller is reconciling — exact key, normalised target AND source revision.
  static BackgroundRepairAction decide({
    required BackgroundDurableEligibility durable,
    required BackgroundRegistrationState platform,
    required bool sameGeneration,
  }) {
    // The OS is never allowed to override durable terminal truth.
    if (durable == BackgroundDurableEligibility.terminal) {
      return BackgroundRepairAction.none;
    }

    // A failed query proves nothing, so no registration decision can be made.
    if (platform == BackgroundRegistrationState.unavailable) {
      return BackgroundRepairAction.unavailable;
    }

    // An ineligible generation is never registered, repaired or replayed — but
    // a still-pending stale registration must be withdrawn.
    if (durable == BackgroundDurableEligibility.ineligible) {
      return platform == BackgroundRegistrationState.pending
          ? BackgroundRepairAction.cancelThenReplace
          : BackgroundRepairAction.none;
    }

    // From here the durable row is eligible in some way.
    if (!sameGeneration) {
      // G5: a changed eligible generation supersedes the old registration.
      return switch (platform) {
        BackgroundRegistrationState.pending ||
        BackgroundRegistrationState.terminal =>
          BackgroundRepairAction.cancelThenReplace,
        BackgroundRegistrationState.absent =>
          BackgroundRepairAction.enqueueKeep,
        BackgroundRegistrationState.unavailable => BackgroundRepairAction.unavailable,
      };
    }

    return switch (platform) {
      // ABSENT: repair with KEEP only when the work is demonstrably unposted and
      // eligible; budget is preserved by the caller.
      BackgroundRegistrationState.absent => BackgroundRepairAction.enqueueKeep,

      // ENQUEUED / BLOCKED: keep.  Never duplicate the enqueue, never reset the
      // budget, never invent a reason or a delay deadline.
      BackgroundRegistrationState.pending => BackgroundRepairAction.keep,

      // SUCCEEDED / FAILED / CANCELLED on the platform are all "not pending".
      // Terminal platform work is NOT proof of delivery, so an identical
      // eligible generation may still be repaired once — the durable row, not
      // WorkInfo, decides whether anything already posted.
      BackgroundRegistrationState.terminal => switch (durable) {
        BackgroundDurableEligibility.awaitingFirstRegistration =>
          BackgroundRepairAction.enqueueKeep,
        BackgroundDurableEligibility.currentGenerationEligible =>
          BackgroundRepairAction.enqueueKeep,
        _ => BackgroundRepairAction.none,
      },

      BackgroundRegistrationState.unavailable => BackgroundRepairAction.unavailable,
    };
  }
}
