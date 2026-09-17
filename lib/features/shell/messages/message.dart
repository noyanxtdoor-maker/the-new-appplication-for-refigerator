/// Bundled local Messages (closed-beta V2, owner decision AG-3/AG-4).
///
/// Messages are typed, locally bundled release notes and announcements that
/// ship WITH the application. There is no database table, no schema change,
/// no network fetch, no remote configuration and no push-content delivery:
/// a new message requires a future application update. That limitation is an
/// accepted, deliberate property of this beta.
///
/// The model is intentionally a small typed block list rather than HTML,
/// Markdown, or a rich-text document. A paragraph and a section heading cover
/// every approved shape; a plain bullet list is included only because it
/// materially improves the release notes and stays a simple typed list.
///
/// This file is UI-free: it never imports Flutter, so the catalog, the block
/// model and the date law are all directly unit-testable.
library;

/// One ordered content block inside a [Message].
sealed class MessageBlock {
  const MessageBlock();
}

/// Ordinary body copy. Long text wraps; it is never truncated in the model.
final class MessageParagraph extends MessageBlock {
  const MessageParagraph(this.text);

  final String text;
}

/// A bold section heading that introduces the paragraphs beneath it.
final class MessageSectionHeading extends MessageBlock {
  const MessageSectionHeading(this.text);

  final String text;
}

/// A short unordered list of plain strings.
final class MessageBulletList extends MessageBlock {
  const MessageBulletList(this.items);

  final List<String> items;
}

/// One bundled local message.
final class Message {
  const Message({
    required this.id,
    required this.title,
    required this.publishedAtLocal,
    required this.blocks,
  });

  /// Stable identity. It is the route parameter for the detail screen and
  /// must never be reused for different content.
  final String id;
  final String title;

  /// Local publication date. Stored local (not UTC) because these are
  /// static release artifacts, not recorded events.
  final DateTime publishedAtLocal;

  final List<MessageBlock> blocks;
}

/// Relative publication label: "Today", "Yesterday", "N days ago".
abstract final class MessageDateLabel {
  static String relative(DateTime publishedLocal, DateTime nowLocal) {
    final days = nowLocal.difference(publishedLocal).inDays;
    if (days <= 0) {
      return 'Today';
    }
    if (days == 1) {
      return 'Yesterday';
    }
    return '$days days ago';
  }
}

/// The bundled Next Transfer catalog, newest first.
///
/// Content describes only capabilities that actually ship in this beta. The
/// list is a compile-time constant of the application: nothing here is
/// fetched, and a new entry requires a new application build.
abstract final class BundledMessages {
  /// The launch release note for the current closed beta.
  static final Message versionZeroOneZero = Message(
    id: 'next-transfer-0-1-0-beta',
    title: 'Version 0.1.0 Beta release notes',
    publishedAtLocal: DateTime(2026, 9, 16, 9),
    blocks: const <MessageBlock>[
      MessageParagraph(
        'Version 0.1.0 is the first Next Transfer closed beta. Thank you for '
        'testing it. This build includes the following.',
      ),
      MessageSectionHeading('Planner and planning'),
      MessageParagraph(
        'Plan your day on a full timeline with timed events, tasks, weekly '
        'planning, and light or dark themes with the Blue and Rose accents.',
      ),
      MessageSectionHeading('Goals'),
      MessageParagraph(
        'Track progress toward the goals you choose, with daily, weekly, and '
        'monthly targets plus plan and activity history.',
      ),
      MessageSectionHeading('Contacts'),
      MessageParagraph(
        'Keep the people you care about organized with groups, filters, notes, '
        'and import from your device contacts.',
      ),
      MessageSectionHeading('Maps'),
      MessageParagraph(
        'Save the places that matter and use the location tools when you want '
        'to see where you are. The map itself works without sharing your '
        'location.',
      ),
      MessageSectionHeading('Notifications and reminders'),
      MessageParagraph(
        'Local reminders keep your events and tasks on time, and they return '
        'after your device restarts.',
      ),
      MessageSectionHeading('Additional improvements'),
      MessageBulletList(<String>[
        'Adaptive phone and tablet layouts, including landscape.',
        'Privacy Lock to keep the app private on a shared device.',
        'Call, message, email, and navigation actions open your own apps.',
        'No advertising and no behavioral analytics.',
      ]),
    ],
  );

  /// The welcome note that introduced the closed beta.
  static final Message welcome = Message(
    id: 'welcome-to-next-transfer-beta',
    title: 'Welcome to Next Transfer beta',
    publishedAtLocal: DateTime(2026, 9, 16, 8),
    blocks: const <MessageBlock>[
      MessageParagraph(
        'Next Transfer helps you plan your day, keep the goals that matter in '
        'view, and stay connected to the people you care about.',
      ),
      MessageParagraph(
        'Your data stays on this device. There is no cloud account, no sync, '
        'and no advertising in this beta.',
      ),
      MessageSectionHeading('How to send feedback'),
      MessageParagraph(
        'Please report bugs, crashes, missing data, or confusing workflows. '
        'Reports from this beta directly shape the next release.',
      ),
    ],
  );

  /// All bundled messages, newest first.
  static final List<Message> all = List<Message>.unmodifiable(
    <Message>[versionZeroOneZero, welcome]..sort(
      (left, right) => right.publishedAtLocal.compareTo(left.publishedAtLocal),
    ),
  );

  /// Resolves one bundled message by its stable [id], or null when the id is
  /// unknown (a stale or hand-typed deep link).
  static Message? byId(String id) {
    for (final message in all) {
      if (message.id == id) {
        return message;
      }
    }
    return null;
  }
}
