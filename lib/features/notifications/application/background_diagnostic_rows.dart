import 'package:rmplanner/core/background/background_repair_decision.dart';
import 'package:rmplanner/features/notifications/application/background_diagnostics_provider.dart';

/// The ONE privacy-safe text projection of a [BackgroundDiagnosticSnapshot]
/// (contract section 38).
///
/// The projection is derived from explicit typed fields only — never from
/// `toString()` of a work row or a `WorkInfo` — so it can be asserted directly
/// as the privacy boundary instead of being duplicated per surface.  It carries
/// enums, counts, booleans and UTC timestamps; it never carries an Event/Task/
/// Contact name, notes, description, report or reflection text, location,
/// coordinates, notification body, raw payload, source/Contact/profile
/// identifier, unique work name, revision, stack trace or exception string.
abstract final class BackgroundDiagnosticRows {
  /// Label/value pairs in a fixed, deterministic order.
  ///
  /// The order is stable so the review surface never reshuffles between reads,
  /// and the work-count row is omitted entirely when nothing is recorded rather
  /// than being rendered as an invented zero.
  static List<(String, String)> of(BackgroundDiagnosticSnapshot snapshot) => [
    ('Notification scheduler', _adapter(snapshot.notificationAdapter)),
    ('Background scheduler', _adapter(snapshot.backgroundAdapter)),
    (
      'Pending reminders',
      snapshot.pendingNativeReminderCount?.toString() ?? 'Unavailable',
    ),
    ('Recovery state', snapshot.recoveryState?.name ?? 'Not recorded'),
    ('Recovery registration', _registration(snapshot.recoveryWorkerRegistration)),
    ('Attempts', snapshot.recoveryAttemptCount?.toString() ?? 'Not recorded'),
    ('Last attempt', _instant(snapshot.recoveryLastAttemptAtUtc)),
    ('Next eligible', _instant(snapshot.recoveryNextEligibleAtUtc)),
    ('Completed', _instant(snapshot.recoveryCompletedAtUtc)),
    ('Failure category', snapshot.recoveryFailureCategory ?? 'Not recorded'),
    if (snapshot.workCountsByState.isNotEmpty)
      ('Recorded work', _counts(snapshot)),
    ('Captured', _instant(snapshot.capturedAtUtc)),
  ];

  /// `unknown` is a distinct factual value: a failed probe proves nothing, so it
  /// must never be reported as available OR as not installed.
  static String _adapter(BackgroundAdapterAvailability value) => switch (value) {
    BackgroundAdapterAvailability.available => 'Available',
    BackgroundAdapterAvailability.unknown => 'Unavailable',
    BackgroundAdapterAvailability.unavailable => 'Not installed',
  };

  static String _registration(BackgroundRegistrationState value) =>
      switch (value) {
        BackgroundRegistrationState.absent => 'Not registered',
        BackgroundRegistrationState.pending => 'Pending',
        BackgroundRegistrationState.terminal => 'Terminal',
        BackgroundRegistrationState.unavailable => 'Unavailable',
      };

  /// UTC technical timestamps only; no identifiers and no local-zone guessing.
  static String _instant(DateTime? value) {
    if (value == null) return 'Not recorded';
    final utc = value.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
        '${two(utc.hour)}:${two(utc.minute)} UTC';
  }

  /// Counts are sorted by state NAME so the line is deterministic and never
  /// leaks row identity through ordering.
  static String _counts(BackgroundDiagnosticSnapshot s) {
    final entries = s.workCountsByState.entries.toList()
      ..sort((a, b) => a.key.name.compareTo(b.key.name));
    return entries.map((e) => '${e.key.name} ${e.value}').join(' · ');
  }
}
