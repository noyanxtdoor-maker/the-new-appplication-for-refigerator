/// Backup creation (FR-S-001…, OPD-4-014/016/017).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/backup/application/backup_container_codec.dart';
import 'package:rmplanner/features/backup/data/backup_document_gateway.dart';
import 'package:rmplanner/features/backup/data/backup_downloads_writer.dart';
import 'package:rmplanner/features/backup/data/backup_payload_codec.dart';
import 'package:rmplanner/features/backup/data/backup_table_codec.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_registry.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';
import 'package:rmplanner/features/backup/domain/restore_preview.dart';

final class BackupService {
  BackupService({
    required this.database,
    required this.gateway,
    required this.containerCodec,
    required this.clock,
    required this.appVersion,
    this.downloadsWriter,
    this.diagnostics,
  }) : tableCodec = BackupTableCodec(database);

  final AppDatabase database;
  final BackupDocumentGateway gateway;
  final BackupContainerCodec containerCodec;
  final DateTime Function() clock;
  final String appVersion;

  /// Writes straight to the user-visible Downloads folder where the platform
  /// allows it without a storage permission. Null falls back to a picker.
  final BackupDownloadsWriter? downloadsWriter;

  final SanitizedDiagnostics? diagnostics;
  final BackupTableCodec tableCodec;

  /// Exports every selected domain from canonical state.
  ///
  /// Seeded/derived identity rows are exported only where the registry says the
  /// user's customization lives on them; device-bound scheduling artifacts and
  /// credentials are never read at all.
  Future<BackupPayload> buildPayload({
    required String profileId,
    Set<BackupDomain>? domains,
  }) async {
    final selected = domains == null
        ? BackupDomainRegistry.populatedDomains
        : BackupDomainRegistry.resolveDependencies(domains);
    final exportedDomains = <BackupDomain, Map<String, BackupTableData>>{};
    final exports = <BackupDomain, String>{};
    final entries = <BackupDomain, BackupDomainEntry>{};

    for (final domain in BackupDomain.restoreOrder) {
      if (!selected.contains(domain)) {
        continue;
      }
      final specs = BackupDomainRegistry.tablesOf(domain);
      final tables = <String, BackupTableData>{};
      var rows = 0;
      for (final spec in specs) {
        final data = await tableCodec.exportTable(spec);
        tables[spec.table] = data;
        rows += data.rowCount;
      }
      exportedDomains[domain] = tables;
      exports[domain] = _csvFor(domain, tables);
      entries[domain] = BackupDomainEntry(
        domain: domain,
        formatVersion: domain.formatVersion,
        dependencies: domain.dependencies,
        rowCount: rows,
      );
    }

    final content = BackupPayloadCodec.canonicalContentJson(
      domains: exportedDomains,
      exports: exports,
    );

    return BackupPayload(
      manifest: BackupManifest(
        containerVersion: BackupFormat.containerVersion,
        appVersion: appVersion,
        schemaVersion: database.schemaVersion,
        createdAtUtc: clock().toUtc(),
        sourcePackage: BackupFormat.sourcePackage,
        profileId: profileId,
        domains: entries,
        payloadSha256: BackupPayloadCodec.sha256Hex(content),
      ),
      domains: exportedDomains,
      exports: exports,
    );
  }

  /// Encodes [payload] into portable container bytes.
  ///
  /// Portable backups carry no encryption: saving one is a single tap and must
  /// never demand a password, and no secure portable scheme exists without user
  /// credentials or account infrastructure. Integrity is unaffected — the
  /// manifest's payload hash still rejects an altered file.
  Uint8List encode({required BackupPayload payload}) {
    final plainText = BackupPayloadCodec.encode(payload);
    return containerCodec.sealPortable(plainText: plainText).toBytes();
  }

  /// Full create flow: export everything → seal → save.
  ///
  /// Tries the user-visible Downloads folder first so the ordinary flow is one
  /// tap. Only when the platform cannot write there without a storage
  /// permission does the user get asked where to put the file.
  Future<BackupCreationResult?> createBackup({
    required String profileId,
    Set<BackupDomain>? domains,
    String? suggestedFileName,
    bool preferDownloads = true,
  }) async {
    diagnostics?.record(
      'backup_create_started',
      context: <String, Object?>{'domains': domains?.length ?? -1},
    );
    final payload = await buildPayload(
      profileId: profileId,
      domains: domains,
    );
    final bytes = encode(payload: payload);
    final fileName = suggestedFileName ?? defaultFileName(payload.manifest);

    SavedBackupDocument? saved;
    var savedToDownloads = false;
    if (preferDownloads && downloadsWriter != null) {
      saved = await downloadsWriter!.writeToDownloads(
        fileName: fileName,
        bytes: bytes,
      );
      savedToDownloads = saved != null;
    }
    saved ??= await gateway.saveDocument(
      suggestedFileName: fileName,
      bytes: bytes,
    );
    if (saved == null) {
      diagnostics?.record('backup_create_cancelled');
      return null;
    }
    if (saved.byteLength != bytes.length) {
      // The destination stored something other than what was written, so the
      // file would not restore. This is never reported as a backup.
      diagnostics?.record('backup_create_unverified');
      throw const BackupFailure(
        BackupFailureKind.storageError,
        detail: 'verification_failed',
      );
    }
    diagnostics?.record(
      'backup_create_completed',
      context: <String, Object?>{
        'bytes': saved.byteLength,
        'downloads': savedToDownloads,
      },
    );
    return BackupCreationResult(
      fileName: fileName,
      location: saved.location,
      byteLength: saved.byteLength,
      domains: payload.manifest.includedDomains,
      rowCounts: <BackupDomain, int>{
        for (final entry in payload.manifest.domains.entries)
          entry.key: entry.value.rowCount,
      },
      createdAtUtc: payload.manifest.createdAtUtc,
      savedToDownloads: savedToDownloads,
    );
  }

  /// Readable export (JSON + CSV summaries).
  ///
  /// Not a primary user action and explicitly **not** a restore source. It
  /// remains available as a capability so the ordinary screen can offer only
  /// the two actions a beta tester actually needs.
  Future<SavedBackupDocument?> createReadableExport({
    required String profileId,
    String? suggestedFileName,
  }) async {
    final payload = await buildPayload(profileId: profileId);
    final readable = <String, Object?>{
      'about': 'Readable Next Transfer export. This JSON and its CSV summaries '
          'are for reading and are not a restorable native backup. Restore '
          'requires a .ntbackup file created by Next Transfer.',
      'appVersion': payload.manifest.appVersion,
      'schemaVersion': payload.manifest.schemaVersion,
      'createdAtUtc': payload.manifest.createdAtUtc.toIso8601String(),
      'domains': <String, Object?>{
        for (final entry in payload.domains.entries)
          entry.key.manifestKey: entry.value.map(
            (table, data) => MapEntry<String, Object?>(table, data.toJson()),
          ),
      },
      'csv': payload.exports,
    };
    final bytes = Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert(readable),
      ),
    );
    return gateway.saveDocument(
      suggestedFileName: suggestedFileName ?? 'next_transfer_export.json',
      bytes: bytes,
    );
  }

  /// `NextTransfer_Backup_YYYY-MM-DD_HHmmss.ntbackup`
  ///
  /// Seconds are part of the name so two backups taken in the same minute stay
  /// two distinct, truthfully named files. A minute-only name collides, and the
  /// platform then stores the second one as a copy of the first.
  String defaultFileName(BackupManifest manifest) {
    final created = manifest.createdAtUtc.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'NextTransfer_Backup_'
        '${created.year}-${two(created.month)}-${two(created.day)}_'
        '${two(created.hour)}${two(created.minute)}${two(created.second)}'
        '.ntbackup';
  }

  String _csvFor(
    BackupDomain domain,
    Map<String, BackupTableData> tables,
  ) {
    final buffer = StringBuffer()
      ..writeln('# Next Transfer readable export')
      ..writeln('# domain: ${domain.manifestKey}')
      ..writeln('# This table is for reading. It is not a restore input.');
    for (final entry in tables.entries) {
      buffer
        ..writeln()
        ..writeln('## ${entry.key}')
        ..writeln(entry.value.columns.map(_csvCell).join(','));
      for (final row in entry.value.rows) {
        buffer.writeln(row.map(_csvCell).join(','));
      }
    }
    return buffer.toString();
  }

  static String _csvCell(Object? value) {
    if (value == null) {
      return '';
    }
    final text = value is Uint8List
        ? '<${value.length} bytes>'
        : value.toString();
    if (text.contains(',') || text.contains('"') || text.contains('\n')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  /// Captures the current local state for the pre-restore recovery checkpoint.
  Future<Uint8List> captureCurrentState({
    required String profileId,
    required Set<BackupDomain> domains,
  }) async {
    final payload = await buildPayload(
      profileId: profileId,
      domains: domains,
    );
    return BackupPayloadCodec.encode(payload);
  }
}
