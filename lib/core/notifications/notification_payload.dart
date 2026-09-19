import 'dart:convert';

enum NotificationSourceKind {
  calendarEvent,
  task,
  weeklyReview,
  awaitingReport,
  goalAchievement,
  contactFollowUp,
  // Appended last (owner law, 2026-09-19): the persistent app-status/summary
  // notification opens the canonical Unreported hub.  Never reorder or reuse
  // an existing value — payloads persist across updates.
  unreportedSummary,
}

enum NotificationResponseAction { open, snooze }

final class NotificationResponseIntent {
  const NotificationResponseIntent({
    required this.profileId,
    required this.sourceKind,
    required this.sourceId,
    required this.action,
    this.occurrenceId,
    this.generation = 0,
  });

  static const int version = 1;

  final String profileId;
  final NotificationSourceKind sourceKind;
  final String sourceId;
  final String? occurrenceId;
  final int generation;
  final NotificationResponseAction action;

  @override
  bool operator ==(Object other) =>
      other is NotificationResponseIntent &&
      profileId == other.profileId &&
      sourceKind == other.sourceKind &&
      sourceId == other.sourceId &&
      occurrenceId == other.occurrenceId &&
      action == other.action &&
      generation == other.generation;

  @override
  int get hashCode => Object.hash(
    profileId,
    sourceKind,
    sourceId,
    occurrenceId,
    action,
    generation,
  );
}

abstract final class NotificationPayloadCodec {
  static final RegExp _safeIdentity = RegExp(r'^[A-Za-z0-9_.:-]{1,256}$');
  static const Set<String> _keys = <String>{
    'version',
    'generation',
    'profileId',
    'sourceKind',
    'sourceId',
    'occurrenceId',
    'action',
  };

  static String encode(NotificationResponseIntent intent) {
    _validate(intent);
    return jsonEncode(<String, Object?>{
      'version': NotificationResponseIntent.version,
      if (intent.generation != 0) 'generation': intent.generation,
      'profileId': intent.profileId,
      'sourceKind': intent.sourceKind.name,
      'sourceId': intent.sourceId,
      if (intent.occurrenceId != null) 'occurrenceId': intent.occurrenceId,
      'action': intent.action.name,
    });
  }

  static NotificationResponseIntent? tryDecode(
    String? payload, {
    String? actionId,
  }) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final value = jsonDecode(payload);
      if (value is! Map<String, dynamic> ||
          value.keys.any((key) => !_keys.contains(key)) ||
          value['version'] != NotificationResponseIntent.version) {
        return null;
      }
      final profileId = value['profileId'];
      final sourceId = value['sourceId'];
      final occurrenceId = value['occurrenceId'];
      final sourceKind = NotificationSourceKind.values
          .asNameMap()[value['sourceKind']];
      final storedAction = NotificationResponseAction.values
          .asNameMap()[value['action']];
      final action = switch (actionId) {
        'snooze' => NotificationResponseAction.snooze,
        'open' => NotificationResponseAction.open,
        null || '' => storedAction,
        _ => null,
      };
      if (profileId is! String ||
          sourceId is! String ||
          sourceKind == null ||
          action == null ||
          (occurrenceId != null && occurrenceId is! String)) {
        return null;
      }
      final generation = value['generation'] ?? 0;
      if (generation is! int || generation < 0) return null;
      final intent = NotificationResponseIntent(
        profileId: profileId,
        sourceKind: sourceKind,
        sourceId: sourceId,
        occurrenceId: occurrenceId as String?,
        action: action,
        generation: generation,
      );
      _validate(intent);
      return intent;
    } on Object {
      return null;
    }
  }

  static void _validate(NotificationResponseIntent intent) {
    if (intent.generation < 0) {
      throw ArgumentError('Invalid notification generation.');
    }
    for (final value in <String?>[
      intent.profileId,
      intent.sourceId,
      intent.occurrenceId,
    ]) {
      if (value != null && !_safeIdentity.hasMatch(value)) {
        throw ArgumentError('Notification payload identity is invalid.');
      }
    }
  }
}
