/// Backup payload model and codec.
///
/// The payload is *untrusted input*: decoding validates the container and
/// domain versions against the live registry, rejects unknown user-data
/// domains, and refuses anything that is not shaped exactly as declared.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rmplanner/features/backup/data/backup_table_codec.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_registry.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';

final class BackupPayload {
  BackupPayload({
    required this.manifest,
    required this.domains,
    required this.exports,
  });

  final BackupManifest manifest;
  final Map<BackupDomain, Map<String, BackupTableData>> domains;

  /// Human-readable CSV summaries (OPD-4-016). Export-only: never a restore
  /// input.
  final Map<BackupDomain, String> exports;

  int rowsOf(BackupDomain domain) {
    final tables = domains[domain];
    if (tables == null) {
      return 0;
    }
    return tables.values.fold<int>(0, (total, table) => total + table.rowCount);
  }
}

abstract final class BackupPayloadCodec {
  /// Canonical, deterministic serialization of the restorable content.
  ///
  /// Used both to compute the integrity hash at creation and to re-compute it
  /// on read. Domain order is the registry restore order, table order is the
  /// registry order and column order is the recorded column order, so the same
  /// content always produces the same bytes.
  static String canonicalContentJson({
    required Map<BackupDomain, Map<String, BackupTableData>> domains,
    required Map<BackupDomain, String> exports,
  }) {
    final orderedDomains = <String, Object?>{};
    for (final domain in BackupDomain.restoreOrder) {
      final tables = domains[domain];
      if (tables == null) {
        continue;
      }
      final orderedTables = <String, Object?>{};
      for (final spec in BackupDomainRegistry.tablesOf(domain)) {
        final table = tables[spec.table];
        if (table == null) {
          continue;
        }
        orderedTables[spec.table] = table.toJson();
      }
      orderedDomains[domain.manifestKey] = <String, Object?>{
        'tables': orderedTables,
      };
    }
    final orderedExports = <String, Object?>{};
    for (final domain in BackupDomain.restoreOrder) {
      final export = exports[domain];
      if (export != null) {
        orderedExports[domain.manifestKey] = export;
      }
    }
    return jsonEncode(<String, Object?>{
      'domains': orderedDomains,
      'exports': orderedExports,
    });
  }

  static String sha256Hex(String content) =>
      sha256.convert(utf8.encode(content)).toString();

  static Uint8List encode(BackupPayload payload) => Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'manifest': payload.manifest.toJson(),
            'domains': <String, Object?>{
              for (final entry in payload.domains.entries)
                entry.key.manifestKey: <String, Object?>{
                  'tables': <String, Object?>{
                    for (final table in entry.value.entries)
                      table.key: table.value.toJson(),
                  },
                },
            },
            'exports': <String, Object?>{
              for (final entry in payload.exports.entries)
                entry.key.manifestKey: entry.value,
            },
          }),
        ),
      );

  /// Decodes and fully validates a decrypted payload against [currentSchema].
  static BackupPayload decode(
    Uint8List bytes, {
    required int currentSchema,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const BackupFailure(BackupFailureKind.corruptedPayload);
    }
    if (decoded is! Map) {
      throw const BackupFailure(BackupFailureKind.corruptedPayload);
    }
    final root = decoded.cast<String, Object?>();

    final manifestJson = root['manifest'];
    if (manifestJson is! Map) {
      throw const BackupFailure(BackupFailureKind.corruptedPayload);
    }
    final manifestMap = manifestJson.cast<String, Object?>();
    if (manifestMap['magic'] != BackupFormat.manifestMagic) {
      throw const BackupFailure(BackupFailureKind.notABackupFile);
    }

    final manifest = _decodeManifest(manifestMap, currentSchema: currentSchema);

    final domainsJson = root['domains'];
    if (domainsJson is! Map) {
      throw const BackupFailure(BackupFailureKind.corruptedPayload);
    }

    final domains = <BackupDomain, Map<String, BackupTableData>>{};
    for (final entry in domainsJson.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map) {
        throw const BackupFailure(BackupFailureKind.corruptedPayload);
      }
      final domain = _domainByKey(key);
      final entryManifest = manifest.domains[domain];
      if (entryManifest == null) {
        throw BackupFailure(
          BackupFailureKind.validationFailed,
          detail: 'domain "$key" has data but no manifest entry',
        );
      }
      final tablesJson = value['tables'];
      if (tablesJson is! Map) {
        throw BackupFailure(
          BackupFailureKind.validationFailed,
          detail: 'domain "$key" has no tables object',
        );
      }
      final tables = <String, BackupTableData>{};
      for (final tableEntry in tablesJson.entries) {
        final tableName = tableEntry.key;
        if (tableName is! String) {
          throw const BackupFailure(BackupFailureKind.validationFailed);
        }
        final spec = BackupDomainRegistry.forTable(tableName);
        if (spec == null || !spec.exported || spec.domain != domain) {
          throw BackupFailure(
            BackupFailureKind.validationFailed,
            detail: 'domain "$key" contains unregistered table "$tableName"',
          );
        }
        BackupTableCodec.validateIdentifier(tableName);
        tables[tableName] = BackupTableData.fromJson(
          tableName,
          tableEntry.value,
        );
      }
      domains[domain] = tables;
    }

    for (final entry in manifest.domains.keys) {
      if (!domains.containsKey(entry)) {
        throw BackupFailure(
          BackupFailureKind.corruptedPayload,
          detail: 'manifest declares "${entry.manifestKey}" but its data is '
              'missing',
        );
      }
    }

    final exports = <BackupDomain, String>{};
    final exportsJson = root['exports'];
    if (exportsJson is Map) {
      for (final entry in exportsJson.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String) {
          throw const BackupFailure(BackupFailureKind.validationFailed);
        }
        exports[_domainByKey(key)] = value;
      }
    }

    final recomputed = sha256Hex(
      canonicalContentJson(domains: domains, exports: exports),
    );
    if (recomputed != manifest.payloadSha256) {
      throw const BackupFailure(BackupFailureKind.corruptedPayload);
    }

    return BackupPayload(
      manifest: manifest,
      domains: domains,
      exports: exports,
    );
  }

  static BackupManifest _decodeManifest(
    Map<String, Object?> map, {
    required int currentSchema,
  }) {
    final containerVersion = map['containerVersion'];
    final appVersion = map['appVersion'];
    final schemaVersion = map['schemaVersion'];
    final createdAt = map['createdAtUtc'];
    final sourcePackage = map['sourcePackage'];
    final profileId = map['profileId'];
    final payloadSha256 = map['payloadSha256'];
    if (containerVersion is! int ||
        appVersion is! String ||
        schemaVersion is! int ||
        createdAt is! String ||
        sourcePackage is! String ||
        profileId is! String ||
        payloadSha256 is! String) {
      throw const BackupFailure(BackupFailureKind.validationFailed);
    }
    if (containerVersion > BackupFormat.containerVersion) {
      throw const BackupFailure(BackupFailureKind.unsupportedContainerVersion);
    }
    if (schemaVersion > currentSchema) {
      throw const BackupFailure(BackupFailureKind.unsupportedBackupVersion);
    }
    if (sourcePackage != BackupFormat.sourcePackage) {
      throw const BackupFailure(BackupFailureKind.notABackupFile);
    }
    final created = DateTime.tryParse(createdAt);
    if (created == null) {
      throw const BackupFailure(BackupFailureKind.validationFailed);
    }

    final domainsJson = map['domains'];
    if (domainsJson is! Map || domainsJson.isEmpty) {
      throw const BackupFailure(BackupFailureKind.validationFailed);
    }
    final domainEntries = <BackupDomain, BackupDomainEntry>{};
    for (final entry in domainsJson.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map) {
        throw const BackupFailure(BackupFailureKind.validationFailed);
      }
      final domain = _domainByKey(key);
      final domainMap = value.cast<String, Object?>();
      final version = domainMap['version'];
      final rows = domainMap['rows'];
      if (version is! int || rows is! int) {
        throw BackupFailure(
          BackupFailureKind.validationFailed,
          detail: 'domain "$key" manifest entry is malformed',
        );
      }
      if (version < 1) {
        throw const BackupFailure(BackupFailureKind.validationFailed);
      }
      if (version > domain.formatVersion) {
        // A newer user-data domain cannot be understood: reject rather than
        // silently dropping the user's records.
        throw BackupFailure(
          BackupFailureKind.unsupportedDomainVersion,
          detail: 'domain "$key" version $version',
        );
      }
      domainEntries[domain] = BackupDomainEntry(
        domain: domain,
        formatVersion: version,
        dependencies: domain.dependencies,
        rowCount: rows,
      );
    }

    return BackupManifest(
      containerVersion: containerVersion,
      appVersion: appVersion,
      schemaVersion: schemaVersion,
      createdAtUtc: created.toUtc(),
      sourcePackage: sourcePackage,
      profileId: profileId,
      domains: domainEntries,
      payloadSha256: payloadSha256,
    );
  }

  static BackupDomain _domainByKey(String key) {
    for (final domain in BackupDomain.values) {
      if (domain.manifestKey == key) {
        return domain;
      }
    }
    throw BackupFailure(
      BackupFailureKind.unknownDomain,
      detail: 'unknown domain "$key"',
    );
  }
}
