import 'package:drift/drift.dart' show Value;
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';

/// VS16 M7 corrective persistence repair — the five per-field Detailed
/// notification content options, persisted as TYPED columns on the existing
/// `notification_preferences` table (schema v47).
///
/// WHY THIS MOVED: these five booleans were briefly stored as a namespaced key
/// (`notificationDetailedContent`) inside the SHARED
/// `PlannerPreferences.eventColorPreferencesJson` document, because a schema
/// migration was not yet authorized. That design was UNSAFE and was reproduced
/// as an actual data-loss defect: the planner document writers rebuild that
/// JSON from only the keys they understand
/// (`EventColorPreferenceCodec.encodeDocument`), so an ordinary Event Color,
/// Contact Group colour, restore-colors or Planner Settings save silently
/// dropped the notification key. The five switches then reverted to their
/// all-TRUE default with no user-visible error.
///
/// Notification-specific preferences belong to `NotificationPreferences`, and
/// that is where they now live. Nothing here reads or writes the planner JSON
/// document, so cross-feature isolation is structural rather than defensive.
///
/// DEFAULT LAW: all five options default to TRUE. A profile that has never
/// touched these settings keeps the richest Detailed behaviour, and an
/// upgrading profile keeps the exact pre-options behaviour. A profile with no
/// `notification_preferences` row reads as the all-TRUE default WITHOUT
/// creating a row — reading must never write.
///
/// PRIVACY LAW (M2 OWNER CORRECTION Issue 1): Privacy Lock does NOT force
/// Generic notification content.  Content follows ONLY the saved preview
/// preference and these per-field toggles.  Privacy Lock stays authoritative
/// for app-entry authentication, pending-OPEN handling and relock.  This store
/// never clears the saved toggles under any lock state.

/// The five stored booleans as an immutable value object.
///
/// This is a thin persistence wrapper around [ReminderDetailOptions]; the
/// renderer's own type stays the single presentation contract.
final class DetailedContentPreferences {
  const DetailedContentPreferences({
    this.enabled = true,
    this.showTitle = true,
    this.showDescription = true,
    this.showTime = true,
    this.showContacts = true,
    this.showLocation = true,
  });

  /// All five ON — the default and the pre-options behaviour.
  static const DetailedContentPreferences defaults =
      DetailedContentPreferences();

  /// The DETAILED CONTENT MASTER (schema v48).
  ///
  /// FALSE means "preview nothing detailed": the delivered copy is the neutral
  /// Generic one, and the Settings screen presents the five switches below as
  /// inactive.  It is deliberately SEPARATE from them: the field choices are
  /// stored exactly as the owner left them and return the moment this is turned
  /// back on.  Modelling OFF as five falses would silently destroy them.
  final bool enabled;

  final bool showTitle;
  final bool showDescription;
  final bool showTime;
  final bool showContacts;
  final bool showLocation;

  /// Adapts to the renderer's presentation options.
  ///
  /// A master that is OFF maps to "no field would be shown", which is what the
  /// canonical renderer already turns into the neutral Generic copy.  Doing it
  /// here rather than in each renderer keeps ONE content law: every consumer of
  /// these preferences (delivery, the Settings preview, the diagnostics) sees
  /// the suppression without having to remember the master exists, and NO caller
  /// can accidentally render detailed content while the master is off.
  ReminderDetailOptions toOptions() => enabled
      ? ReminderDetailOptions(
          showTitle: showTitle,
          showDescription: showDescription,
          showTime: showTime,
          showContacts: showContacts,
          showLocation: showLocation,
        )
      : const ReminderDetailOptions(
          showTitle: false,
          showDescription: false,
          showTime: false,
          showContacts: false,
          showLocation: false,
        );

  /// True when no field would be shown, which forces Generic copy at render
  /// time.  A disabled master makes this true whatever the children say.
  bool get isEmpty =>
      !enabled ||
      (!showTitle &&
          !showDescription &&
          !showTime &&
          !showContacts &&
          !showLocation);

  DetailedContentPreferences copyWith({
    bool? enabled,
    bool? showTitle,
    bool? showDescription,
    bool? showTime,
    bool? showContacts,
    bool? showLocation,
  }) => DetailedContentPreferences(
    enabled: enabled ?? this.enabled,
    showTitle: showTitle ?? this.showTitle,
    showDescription: showDescription ?? this.showDescription,
    showTime: showTime ?? this.showTime,
    showContacts: showContacts ?? this.showContacts,
    showLocation: showLocation ?? this.showLocation,
  );

  @override
  bool operator ==(Object other) =>
      other is DetailedContentPreferences &&
      other.enabled == enabled &&
      other.showTitle == showTitle &&
      other.showDescription == showDescription &&
      other.showTime == showTime &&
      other.showContacts == showContacts &&
      other.showLocation == showLocation;

  @override
  int get hashCode => Object.hash(
    enabled,
    showTitle,
    showDescription,
    showTime,
    showContacts,
    showLocation,
  );

  @override
  String toString() =>
      'DetailedContentPreferences(enabled: $enabled, title: $showTitle, '
      'description: $showDescription, time: $showTime, '
      'contacts: $showContacts, location: $showLocation)';
}

/// Typed read/write for the five Detailed content options.
///
/// Every operation touches ONLY the five dedicated columns. There is no shared
/// document to merge and therefore no cross-feature key loss.
final class DetailedContentPreferencesStore {
  const DetailedContentPreferencesStore({
    required this.database,
    required this.clock,
  });

  final AppDatabase database;
  final AppClock clock;

  /// Read-only. A missing row or missing value reads as the all-TRUE default,
  /// and this never writes.
  Future<DetailedContentPreferences> read(String profileId) async {
    final row = await _readRow(profileId);
    return _decode(row);
  }

  /// Persists the five options. When a row already exists the write is a
  /// partial update of exactly these five columns plus `updatedAtUtc`, so no
  /// other notification preference can change.
  Future<DetailedContentPreferences> write(
    String profileId,
    DetailedContentPreferences next,
  ) async {
    return database.transaction(() async {
      final row = await _readRow(profileId);
      if (row == null) {
        await database
            .into(database.notificationPreferences)
            .insert(
              NotificationPreferencesCompanion.insert(
                profileId: profileId,
                detailedContentEnabled: Value(next.enabled),
                detailedShowTitle: Value(next.showTitle),
                detailedShowDescription: Value(next.showDescription),
                detailedShowTime: Value(next.showTime),
                detailedShowContacts: Value(next.showContacts),
                detailedShowLocation: Value(next.showLocation),
                updatedAtUtc: clock.nowUtc(),
              ),
            );
      } else {
        await (database.update(
          database.notificationPreferences,
        )..where((table) => table.profileId.equals(profileId))).write(
          NotificationPreferencesCompanion(
            detailedContentEnabled: Value(next.enabled),
            detailedShowTitle: Value(next.showTitle),
            detailedShowDescription: Value(next.showDescription),
            detailedShowTime: Value(next.showTime),
            detailedShowContacts: Value(next.showContacts),
            detailedShowLocation: Value(next.showLocation),
            updatedAtUtc: Value<DateTime>(clock.nowUtc()),
          ),
        );
      }
      return next;
    });
  }

  Future<NotificationPreferenceRow?> _readRow(String profileId) async {
    return (database.select(database.notificationPreferences)
          ..where((table) => table.profileId.equals(profileId))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Absent row or absent value resolves to the field's TRUE default, one field
  /// at a time, so a partially populated row never blanks a notification.
  static DetailedContentPreferences _decode(NotificationPreferenceRow? row) {
    if (row == null) return DetailedContentPreferences.defaults;
    return DetailedContentPreferences(
      enabled: row.detailedContentEnabled,
      showTitle: row.detailedShowTitle,
      showDescription: row.detailedShowDescription,
      showTime: row.detailedShowTime,
      showContacts: row.detailedShowContacts,
      showLocation: row.detailedShowLocation,
    );
  }
}
