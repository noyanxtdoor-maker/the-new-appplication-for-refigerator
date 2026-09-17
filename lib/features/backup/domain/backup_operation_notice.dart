/// One transient Android notification-shade card for a backup or restore
/// operation.
///
/// [platformId] identifies the *operation*, not the event: every state of one
/// operation is published under the same id, so "Backing up your data…" is
/// rewritten in place as "Backup created" instead of sitting beside it. That is
/// what keeps one operation to exactly one card.
///
/// The reminder platform-id allocator only ever emits ids inside
/// `[1, 0x7fffffff]`, so the negative ids used here cannot collide with a
/// reminder, with a delivered reminder card, or with the launcher badge id —
/// and these cards can never be mistaken for scheduled reminder requests.
final class BackupOperationNotice {
  const BackupOperationNotice({
    required this.platformId,
    this.title,
    this.body,
  });

  /// Identity of the operation's single card.
  final int platformId;

  /// Null means "take the card down": the operation was abandoned before it did
  /// anything, so there is nothing truthful to report.
  final String? title;

  final String? body;

  bool get dismisses => title == null;
}
