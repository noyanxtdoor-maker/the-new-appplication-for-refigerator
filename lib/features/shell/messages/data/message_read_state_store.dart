import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Acknowledgement persistence for the bundled local Messages catalog.
///
/// WHY THIS IS NOT A DATABASE TABLE: the Messages catalog is a compile-time
/// constant of the application, and schema 47 is frozen by
/// `tool/verify_authority.dart`. A read receipt is device-scoped UI state, not
/// profile data, so it lives in one small document in app-private storage
/// instead of in a new table. That keeps schema 47, keeps the backup domain
/// registry unchanged, and cannot collide with any feature-owned Drift row.
///
/// READ LAW (deliberately fail-soft): an absent file, unreadable JSON, or an
/// unavailable platform directory reads as "nothing acknowledged". That is the
/// SAFE direction — the worst outcome is one extra unread indicator for an
/// update notice, never a silently swallowed message.
///
/// WRITE LAW (deliberately fail-loud): [acknowledge] throws when the receipt
/// could not be stored. The caller must not claim a message was read until the
/// acknowledgement is durable, otherwise the indicator could return on the
/// next launch and the UI would have lied.
abstract interface class MessageReadStateStore {
  /// The stable message ids acknowledged on this device.
  Future<Set<String>> readAcknowledgedIds();

  /// Records [id] as acknowledged. Idempotent. Throws when it cannot persist.
  Future<void> acknowledge(String id);
}

/// JSON document store in app-private storage (one file, one key).
final class FileMessageReadStateStore implements MessageReadStateStore {
  FileMessageReadStateStore({
    Future<Directory> Function()? directory,
    this.fileName = 'message_read_state.json',
  }) : _directory = directory ?? getApplicationSupportDirectory;

  /// Injected so tests can point at a temporary directory instead of the
  /// platform channel. Production uses the application support directory.
  final Future<Directory> Function() _directory;

  final String fileName;

  static const String _acknowledgedKey = 'acknowledged';

  @override
  Future<Set<String>> readAcknowledgedIds() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const <String>{};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return const <String>{};
      final raw = decoded[_acknowledgedKey];
      if (raw is! List) return const <String>{};
      return <String>{
        for (final entry in raw)
          if (entry is String && entry.isNotEmpty) entry,
      };
    } catch (_) {
      // Includes a missing/unavailable platform directory, a partially written
      // document, and a revoked file. All of them read as "unknown", and
      // "unknown" is rendered as unread rather than as a false "read".
      return const <String>{};
    }
  }

  @override
  Future<void> acknowledge(String id) async {
    if (id.isEmpty) return;
    final acknowledged = await readAcknowledgedIds();
    if (acknowledged.contains(id)) return;
    final next = <String>{...acknowledged, id}.toList()..sort();
    final file = await _file();
    await file.parent.create(recursive: true);
    // Write-then-rename so an interrupted write cannot leave a half document
    // that would silently read back as "nothing acknowledged".
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{_acknowledgedKey: next}),
      flush: true,
    );
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      // Android (POSIX) renames over an existing document atomically. A
      // platform that refuses an existing target still gets the same result,
      // just without the atomic swap.
      if (await file.exists()) {
        await file.delete();
      }
      await temporary.rename(file.path);
    }
  }

  Future<File> _file() async {
    final directory = await _directory();
    return File(
      '${directory.path}${Platform.pathSeparator}$fileName',
    );
  }
}
