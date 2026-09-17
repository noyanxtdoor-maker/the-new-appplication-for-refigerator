/// Versioned backup manifest (container version 2).
///
/// The manifest lives *inside* the payload. For a portable backup nothing is
/// encrypted — saving a backup is one tap and must never demand a password —
/// so the manifest is readable, and that is stated plainly to the user rather
/// than papered over. Integrity is still enforced: [BackupManifest.payloadSha256]
/// covers the payload body, so an altered or truncated file fails before any
/// restore parsing.
///
/// Domain packages carry their own format version so a future domain can be
/// added without invalidating older backups.
library;

import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';

abstract final class BackupFormat {
  /// Wire magic for the container header.
  static const String magic = 'NTBACKUP';

  /// The manifest magic (inside the payload).
  static const String manifestMagic = 'NEXTTRANSFER-BACKUP';

  /// This app writes container version 2.
  ///
  /// Version 1 was a development-only shape that carried a passphrase KDF and
  /// a salt field, and it never shipped. Version 2 drops the KDF entirely:
  /// portable backups are integrity-protected but not encrypted, and
  /// device-bound checkpoints are authenticated with a directly supplied key.
  /// The version was bumped rather than reused because the security semantics
  /// of the two shapes differ, and a restore must never have to guess which it
  /// is holding.
  static const int containerVersion = 2;

  /// Oldest container version this app can still read. Version 1 was never
  /// released, so keeping a reader for it would preserve a prerelease format
  /// for no user's benefit.
  static const int minimumReadableContainerVersion = 2;

  static const String sourcePackage = 'com.nexttransfer.rmplanner';

  /// Wire identifier for a container that carries no protection at all. This is
  /// the shape of every portable user backup.
  static const int noneProtectionId = 0;

  /// Wire identifier for a container authenticated with a directly supplied
  /// 32-byte device-bound key. Used only for the temporary local recovery
  /// checkpoint, which never leaves app-private storage.
  static const int deviceKeyProtectionId = 1;

  /// Wire identifier for "no cipher". Only ever paired with
  /// [noneProtectionId].
  static const int noneCipherId = 0;

  /// Wire identifier for AES-256-GCM.
  static const int cipherId = 1;

  static const int gcmNonceLength = 12;
  static const int gcmTagLengthBits = 128;
  static const int derivedKeyLength = 32;

  /// Smallest possible well-formed header: the unprotected form, which carries
  /// no nonce.
  static const int minimumHeaderBytes = 21;

  /// Refuse absurd documents before allocating: a Next Transfer backup is a
  /// text payload and this beta's realistic ceiling is far below this.
  static const int maxFileBytes = 256 * 1024 * 1024;

  /// True when [protectionId] describes a container with no encryption.
  static bool isUnprotected(int protectionId) =>
      protectionId == noneProtectionId;
}

final class BackupDomainEntry {
  const BackupDomainEntry({
    required this.domain,
    required this.formatVersion,
    required this.dependencies,
    required this.rowCount,
  });

  final BackupDomain domain;
  final int formatVersion;
  final Set<BackupDomain> dependencies;

  /// Canonical row/item count for truthful preview.
  final int rowCount;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': formatVersion,
        'dependencies': dependencies
            .map((domain) => domain.manifestKey)
            .toList(growable: false)
          ..sort(),
        'rows': rowCount,
      };
}

final class BackupManifest {
  const BackupManifest({
    required this.containerVersion,
    required this.appVersion,
    required this.schemaVersion,
    required this.createdAtUtc,
    required this.sourcePackage,
    required this.profileId,
    required this.domains,
    required this.payloadSha256,
  });

  final int containerVersion;
  final String appVersion;
  final int schemaVersion;
  final DateTime createdAtUtc;
  final String sourcePackage;
  final String profileId;
  final Map<BackupDomain, BackupDomainEntry> domains;
  final String payloadSha256;

  Set<BackupDomain> get includedDomains => domains.keys.toSet();

  int get totalRows => domains.values
      .fold<int>(0, (total, entry) => total + entry.rowCount);

  Map<String, Object?> toJson() => <String, Object?>{
        'magic': BackupFormat.manifestMagic,
        'containerVersion': containerVersion,
        'appVersion': appVersion,
        'schemaVersion': schemaVersion,
        'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
        'sourcePackage': sourcePackage,
        'profileId': profileId,
        'domains': <String, Object?>{
          for (final entry in domains.entries)
            entry.key.manifestKey: entry.value.toJson(),
        },
        'payloadSha256': payloadSha256,
      };
}
