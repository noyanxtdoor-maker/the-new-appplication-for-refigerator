import 'package:drift/drift.dart';
import 'package:rmplanner/core/colors/vs11_color_system.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';

/// One run of the canonical default-Group engine.
///
/// This is the ONLY place canonical built-in Contact Groups are written, so
/// every caller (new-profile onboarding, post-restore reconciliation, the
/// Settings "Restore Group Defaults" action and the Manage Groups migration)
/// obeys the same four laws:
///
///   1. IDENTITY, NOT NAME. A canonical row is recognised by its deterministic
///      UUIDv5 id. A different row that merely *shares the name* is never
///      overwritten, renamed, merged or deleted — it is reported as a
///      [ContactGroupNameCollision] instead.
///   2. NEVER THROW. A same-name collision used to abort the whole run — which
///      also broke the post-restore seeding path. It is now skipped, reported
///      as data, and the run continues.
///   3. ADDITIVE ONLY by default. A run creates missing canonical rows and
///      touches nothing else: no custom row, no colour, no membership, and no
///      legacy `Other` row is modified.
///   4. EXPLICIT RESTORE re-applies canonical name/order/colour to the canonical
///      ids only, and only when the user asked for it.
///
/// Nothing here is called from a read path: a Group the user permanently deletes
/// must stay deleted.
Future<ContactGroupDefaultsOutcome> seedCanonicalContactGroups(
  AppDatabase database, {
  required String profileId,
  required AppClock clock,
  bool restoreCanonicalValues = false,
}) async {
  // A database pinned to a schema version that predates `contact_groups` has no
  // such table. That is a real state: the historical-version migration harness
  // opens genuine old files and runs onboarding against them, and at that point
  // in history these groups did not exist. There is nothing to seed, so skip
  // instead of failing the whole onboarding/restore path.
  if (!await _contactGroupsTableExists(database)) {
    return const ContactGroupDefaultsOutcome();
  }

  final existing =
      await (database.select(database.contactGroups)
            ..where((table) => table.profileId.equals(profileId)))
          .get();
  final byId = <String, ContactGroupRow>{
    for (final row in existing) row.id: row,
  };
  final byNormalizedName = <String, List<ContactGroupRow>>{};
  for (final row in existing) {
    byNormalizedName
        .putIfAbsent(_normalizeName(row.name), () => <ContactGroupRow>[])
        .add(row);
  }
  // Legacy Store A colour overrides (dormant after C2 canonicalisation) are
  // imported ONLY when a missing canonical row is being created, so a saved
  // pre-C2 override is never lost and never re-applied to an existing row.
  final legacyOverrides = await _readLegacyStoreAGroupColors(
    database,
    profileId,
  );

  final now = clock.nowUtc();
  final added = <String>[];
  final collisions = <ContactGroupNameCollision>[];
  final reapplied = <String>[];
  final migratedColors = <String>[];

  for (final definition in ContactBuiltInGroupDefaults.ordered) {
    final expectedId = ContactBuiltInGroupIdentity.idForProfile(
      profileId,
      definition.key,
    );
    final existingRow = byId[expectedId];
    if (existingRow != null) {
      if (!restoreCanonicalValues) {
        continue;
      }
      // The user explicitly asked to restore defaults, so the canonical row's
      // name, order and colour are re-applied. This is the only path that
      // writes an already-existing canonical row.
      await (database.update(database.contactGroups)..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.id.equals(expectedId),
          ))
          .write(
            ContactGroupsCompanion(
              name: Value<String>(definition.name),
              colorValue: Value<int>(definition.colorArgb),
              sortOrder: Value<int>(definition.canonicalOrder),
              isArchived: const Value<bool>(false),
              updatedAtUtc: Value<DateTime>(now),
            ),
          );
      reapplied.add(definition.name);
      continue;
    }

    final owners = byNormalizedName[_normalizeName(definition.name)];
    if (owners != null && owners.isNotEmpty) {
      // A real row (custom, or an older built-in under a different identity)
      // already owns this name. Skip and report; never convert its identity.
      final owner = owners.first;
      collisions.add(
        ContactGroupNameCollision(
          definition: definition,
          groupId: owner.id,
          groupName: owner.name,
          currentColorArgb: owner.colorValue,
          isUnambiguous: owners.length == 1,
        ),
      );
      continue;
    }

    final companion = ContactGroupsCompanion.insert(
      id: expectedId,
      profileId: profileId,
      name: definition.name,
      colorValue: legacyOverrides[definition.key] ?? definition.colorArgb,
      isArchived: const Value<bool>(false),
      sortOrder: Value<int>(definition.canonicalOrder),
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await database
        .into(database.contactGroups)
        .insert(companion, mode: InsertMode.insertOrIgnore);
    added.add(definition.name);
    // No in-run bookkeeping is needed: the five canonical names are distinct,
    // so the collision gate cannot see a duplicate produced by this same run.
  }

  if (restoreCanonicalValues) {
    // The retired `Other` built-in keeps its id, its name and every membership.
    // Only its *palette* moved (owner-approved 2026-09-18), and only when the
    // stored value is provably still one of its documented historical seeded
    // defaults — i.e. the user never chose this colour. A customized row is
    // left exactly as the user left it.
    final legacyOtherId = ContactBuiltInGroupIdentity.idForProfile(
      profileId,
      ContactBuiltInGroupDefaults.other.key,
    );
    final legacyOther = byId[legacyOtherId];
    if (legacyOther != null &&
        ContactBuiltInGroupDefaults.otherHistoricalDefaultArgbs.any(
          (argb) => Vs11ColorSystem.sameOpaqueRgb(argb, legacyOther.colorValue),
        )) {
      await (database.update(database.contactGroups)..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.id.equals(legacyOtherId),
          ))
          .write(
            ContactGroupsCompanion(
              colorValue: Value<int>(ContactBuiltInGroupDefaults.otherArgb),
              updatedAtUtc: Value<DateTime>(now),
            ),
          );
      migratedColors.add(ContactBuiltInGroupDefaults.other.name);
    }
  }

  return ContactGroupDefaultsOutcome(
    addedNames: List<String>.unmodifiable(added),
    collisions: List<ContactGroupNameCollision>.unmodifiable(collisions),
    reappliedNames: List<String>.unmodifiable(reapplied),
    migratedColorNames: List<String>.unmodifiable(migratedColors),
  );
}

/// Group names are compared trimmed and case-insensitively so "members" and
/// "Members " collide truthfully instead of silently creating a near-duplicate.
String _normalizeName(String name) => name.trim().toLowerCase();

/// True when this database actually has the `contact_groups` table.
///
/// Asked of SQLite rather than inferred from a version number, so it stays
/// correct no matter which schema version introduced the table.
Future<bool> _contactGroupsTableExists(AppDatabase database) async {
  final rows = await database
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'contact_groups'",
      )
      .get();
  return rows.isNotEmpty;
}

/// Reads ONLY the legacy Settings group-colour map (Store A) without mutating
/// it. Returns an empty map when absent or malformed.
Future<Map<String, int>> _readLegacyStoreAGroupColors(
  AppDatabase database,
  String profileId,
) async {
  final row =
      await (database.select(database.plannerPreferences)..where(
            (table) => table.profileId.equals(profileId),
          ))
          .getSingleOrNull();
  if (row == null) {
    return const <String, int>{};
  }
  return EventColorPreferenceCodec.decodeDocument(
    row.eventColorPreferencesJson,
  ).groups;
}
