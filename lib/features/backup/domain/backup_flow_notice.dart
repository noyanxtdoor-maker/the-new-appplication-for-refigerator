/// One transient acknowledgement shown inside the app when an operation
/// finishes.
///
/// [title] is the headline the user reads first; [body] carries the one thing
/// they may need to do next, and is present only when there is something
/// truthful to add. There is deliberately no action button: the acknowledgement
/// never navigates anywhere, so the user leaves Backup & Restore through
/// ordinary Back navigation.
final class BackupFlowNotice {
  const BackupFlowNotice(this.title, {this.body});

  final String title;

  /// Null when the headline says everything there is to say.
  final String? body;

  @override
  bool operator ==(Object other) =>
      other is BackupFlowNotice && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  /// So a notice logged in a failure message stays readable.
  @override
  String toString() => body == null ? title : '$title\n$body';
}

/// The one sentence that tells the user how a completed restore becomes
/// visible on screen.
///
/// Shared by the in-app acknowledgement and the Android operation card, so the
/// app and the notification shade cannot drift into telling the user two
/// different things about the same completed restore.
const String restoreRefreshGuidance =
    'Please close and reopen Next Transfer to refresh all restored data.';
