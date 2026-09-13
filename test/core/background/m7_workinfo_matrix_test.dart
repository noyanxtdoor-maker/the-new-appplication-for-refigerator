import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_repair_decision.dart';

/// Section 65 WorkInfo decision matrix.
///
/// The matrix is exercised as a pure function so every adjudicated branch is
/// asserted without WorkManager, a device or wall-clock timing.  The point of
/// these tests is that the PLATFORM is never allowed to override durable truth,
/// and that an unreadable query is never silently treated as ABSENT.
void main() {
  group('section 65 WorkInfo matrix: durable terminal truth outranks platform', () {
    for (final platform in BackgroundRegistrationState.values) {
      for (final same in <bool>[true, false]) {
        test('terminal durable over $platform (same=$same) is never replayed', () {
          expect(
            BackgroundRepairDecision.decide(
              durable: BackgroundDurableEligibility.terminal,
              platform: platform,
              sameGeneration: same,
            ),
            BackgroundRepairAction.none,
            reason: 'a finished episode is never resurrected by WorkInfo',
          );
        });
      }
    }
  });

  group('section 65 unavailable platform truth is never ABSENT', () {
    for (final durable in BackgroundDurableEligibility.values) {
      test('$durable + unavailable reports unavailable, changes nothing', () {
        final action = BackgroundRepairDecision.decide(
          durable: durable,
          platform: BackgroundRegistrationState.unavailable,
          sameGeneration: true,
        );
        if (durable == BackgroundDurableEligibility.terminal) {
          expect(action, BackgroundRepairAction.none);
        } else {
          expect(
            action,
            BackgroundRepairAction.unavailable,
            reason: 'an unavailable query is not proof the work is absent',
          );
        }
      });
    }
  });

  group('section 65 identical current nonterminal generation', () {
    test('ABSENT repairs with KEEP (budget preserved by caller)', () {
      expect(
        BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.awaitingFirstRegistration,
          platform: BackgroundRegistrationState.absent,
          sameGeneration: true,
        ),
        BackgroundRepairAction.enqueueKeep,
      );
    });

    test('ENQUEUED/BLOCKED pending means KEEP, no duplicate, no reset', () {
      expect(
        BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.currentGenerationEligible,
          platform: BackgroundRegistrationState.pending,
          sameGeneration: true,
        ),
        BackgroundRepairAction.keep,
      );
    });

    test('SUCCEEDED is not pending and not proof of delivery — repair once', () {
      expect(
        BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.currentGenerationEligible,
          platform: BackgroundRegistrationState.terminal,
          sameGeneration: true,
        ),
        BackgroundRepairAction.enqueueKeep,
      );
    });

    test('FAILED on an unregistered eligible generation repairs with KEEP', () {
      expect(
        BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.awaitingFirstRegistration,
          platform: BackgroundRegistrationState.terminal,
          sameGeneration: true,
        ),
        BackgroundRepairAction.enqueueKeep,
      );
    });
  });

  group('section 65 changed generation uses G5 replace', () {
    for (final platform in <BackgroundRegistrationState>[
      BackgroundRegistrationState.pending,
      BackgroundRegistrationState.terminal,
    ]) {
      test('$platform cancels the old registration then replaces', () {
        expect(
          BackgroundRepairDecision.decide(
            durable: BackgroundDurableEligibility.eligibleReplacement,
            platform: platform,
            sameGeneration: false,
          ),
          BackgroundRepairAction.cancelThenReplace,
        );
      });
    }

    test('a changed generation with no registration enqueues with KEEP', () {
      expect(
        BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.eligibleReplacement,
          platform: BackgroundRegistrationState.absent,
          sameGeneration: false,
        ),
        BackgroundRepairAction.enqueueKeep,
      );
    });

    test('a changed generation never reaches a terminal durable row', () {
      expect(
        BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.terminal,
          platform: BackgroundRegistrationState.pending,
          sameGeneration: false,
        ),
        BackgroundRepairAction.none,
      );
    });
  });

  group('section 65 ineligible generations are withdrawn, never replayed', () {
    test('a stale PENDING registration for an ineligible source is cancelled', () {
      expect(
        BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.ineligible,
          platform: BackgroundRegistrationState.pending,
          sameGeneration: true,
        ),
        BackgroundRepairAction.cancelThenReplace,
      );
    });

    test('an ineligible source with no registration does nothing', () {
      expect(
        BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.ineligible,
          platform: BackgroundRegistrationState.absent,
          sameGeneration: true,
        ),
        BackgroundRepairAction.none,
      );
    });

    test('an ineligible source never enqueues from a terminal platform state', () {
      expect(
        BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.ineligible,
          platform: BackgroundRegistrationState.terminal,
          sameGeneration: true,
        ),
        BackgroundRepairAction.none,
      );
    });
  });

  test('the matrix is total: every combination returns an action', () {
    for (final durable in BackgroundDurableEligibility.values) {
      for (final platform in BackgroundRegistrationState.values) {
        for (final same in <bool>[true, false]) {
          expect(
            () => BackgroundRepairDecision.decide(
              durable: durable,
              platform: platform,
              sameGeneration: same,
            ),
            returnsNormally,
          );
        }
      }
    }
  });
}
