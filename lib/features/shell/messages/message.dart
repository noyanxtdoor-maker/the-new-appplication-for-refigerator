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
    this.actionLabel,
  });

  /// Stable identity. It is the route parameter for the detail screen and
  /// must never be reused for different content.
  final String id;
  final String title;

  /// Local publication date. Stored local (not UTC) because these are
  /// static release artifacts, not recorded events.
  final DateTime publishedAtLocal;

  final List<MessageBlock> blocks;

  /// Optional primary action rendered at the end of the detail body.
  ///
  /// A release note that asks for an explicit acknowledgement carries one
  /// (`'Got it'`). A message without an action stays read-only, exactly as it
  /// was before this field existed. The label is presentation only: it never
  /// grants notification permission and never opens Android settings.
  final String? actionLabel;
}

/// Version-scoped unread law (owner requirement, 2026-09-18).
///
/// A bundled message is UNREAD until its own [Message.id] has been
/// acknowledged on this device. Because the id carries the release version
/// (`next-transfer-0-1-1-beta`), a later release ships a NEW id and is
/// therefore unread again, while an already-acknowledged message can never
/// become unread a second time by simply relaunching the app.
abstract final class MessageUnreadLaw {
  /// True when [message] has not been acknowledged yet.
  static bool isUnread(Message message, Set<String> acknowledgedIds) =>
      !acknowledgedIds.contains(message.id);

  /// The bundled messages that are still unread, newest first.
  static List<Message> unread(
    Iterable<Message> messages,
    Set<String> acknowledgedIds,
  ) => List<Message>.unmodifiable(
    messages.where((message) => isUnread(message, acknowledgedIds)),
  );
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

  /// The closed-beta 0.1.1 update notice.
  ///
  /// OWNER REQUIREMENT (2026-09-18): a tester-facing in-app update message.
  /// Every claim below is verified against what actually shipped in 0.1.1:
  /// Backup & Restore and the bundled Messages catalog are absent from the
  /// released 0.1.0 bundle (proven by inspecting both signed AABs), the
  /// 10-minute Event/Task defaults and the Event Type selector fix are in
  /// `checkpoint(owner): preserve 10-minute reminder default regression proof`
  /// and `…preserve event type picker refresh glitch fix`, and the Create Goal
  /// flicker is reported but NOT root-caused, so it is stated as such.
  static final Message versionZeroOneOne = Message(
    id: 'next-transfer-0-1-1-beta',
    title: "What's New in Next Transfer",
    publishedAtLocal: DateTime(2026, 9, 18, 20),
    actionLabel: 'Got it',
    blocks: const <MessageBlock>[
      MessageParagraph('Beta 0.1.1'),
      MessageParagraph('Thanks for continuing to test Next Transfer. 💙'),
      MessageSectionHeading("What's new"),
      MessageBulletList(<String>[
        'Backup & Restore is now available to help you save and restore your '
            'Next Transfer data.',
        'Improved Manage Groups, including No Group filtering and Restore '
            'Default Groups behavior.',
        'Improved notification setup and reminder behavior.',
        'Event and Task reminders now use the intended 10-minute default.',
        'Fixed a flicker in the Planner Event Type selector.',
        'Improved reliability across Planner, Maps, Restore, Contacts, and '
            'Settings.',
        'Additional stability improvements based on beta feedback.',
      ]),
      MessageSectionHeading('Still being investigated'),
      MessageBulletList(<String>[
        'A visual flicker reported on the Create Goal screen on one beta '
            'device.',
      ]),
      MessageParagraph(
        'Thanks for helping us improve Next Transfer before launch.',
      ),
      MessageParagraph('The mission has ended. The next transfer begins.'),
    ],
  );

  /// The closed-beta Build 4 update notice.
  ///
  /// OWNER REQUIREMENT (2026-09-20): Build 4 ships as its OWN message with a
  /// NEW stable id. Reusing the 0.1.1 id would re-open an already-acknowledged
  /// notice, so the previous `next-transfer-0-1-1-beta` entry is left byte-for-
  /// byte untouched and every tester keeps its receipt.
  ///
  /// Every claim below describes something that actually shipped in Build 4:
  /// the Unreported hub and the Tasks home (`feat(unreported)`, `feat(tasks)`,
  /// `e9a1716`), the attention indicators (`e86ec7d`), the notification
  /// transport/privacy/Contact work (`ec5bddc`, `65798da`, `061464b`), the
  /// Event reminder override (`0cfa9f9`), the Planner scroll self-heal
  /// (`0cfa9f9`), the Task attached-Contact navigation (`ced3da3`) and the
  /// per-message read receipts (`0d6dca5`).
  static final Message versionZeroOneOneBuildFour = Message(
    id: 'next-transfer-0-1-1-build-4-beta',
    title: "What's New in Next Transfer",
    publishedAtLocal: DateTime(2026, 9, 20, 9),
    actionLabel: 'Got it',
    blocks: const <MessageBlock>[
      MessageParagraph('Beta 0.1.1 · Build 4'),
      MessageParagraph('Thanks for continuing to test Next Transfer. 💙'),
      MessageSectionHeading("What's new"),
      MessageBulletList(<String>[
        'Added Unreported — a dedicated place for Life Goal, Event, and '
            'Contact items that still need your attention.',
        'Added a cleaner Tasks experience with Incomplete and Completed '
            'views, sticky date sections, and easier navigation.',
        'Improved notification delivery and reminder reliability.',
        'Fixed custom Event reminder settings so specific reminder times '
            'remain intact when you reopen or edit an Event.',
        'Improved notification privacy and Detailed Content controls, '
            'including Contact names in supported Event and Task reminders.',
        'Added clearer attention indicators for Tasks and Unreported.',
        'Improved navigation between Tasks, Planner, Contacts, and '
            'report-required items.',
        'Fixed an issue that could leave Planner scrolling unresponsive.',
        'Improved Task and Event Contact navigation.',
        'Previously read update messages now stay read when a future update '
            'adds a new message.',
        'Additional stability and reliability improvements based on beta '
            'feedback.',
      ]),
      MessageParagraph(
        'Thank you for helping us improve Next Transfer before launch.',
      ),
      MessageParagraph('The mission has ended. The next transfer begins.'),
    ],
  );

  /// The approved closed-beta Build 5 update notice.
  ///
  /// Build 5 has its own stable acknowledgement identity so testers who read
  /// Build 4 see only this new notice as unread. The copy is the owner-approved
  /// Planner/Event/Contact/notification release summary for P1-P5/Post-P2.
  static final Message versionZeroOneOneBuildFive = Message(
    id: 'next-transfer-0-1-1-build-5-beta',
    title: "What's New in Next Transfer",
    publishedAtLocal: DateTime(2026, 9, 23, 9),
    actionLabel: 'Got it',
    blocks: const <MessageBlock>[
      MessageParagraph(
        'We’ve made a major round of Planner, Event, Contact, and notification '
        'improvements based on beta feedback.',
      ),
      MessageBulletList(<String>[
        'Smarter Planner experience — improved visible-hour controls, '
            'scrolling, zooming, timeline spacing, and easier access to the '
            'full day.',
        'Better Contact Events — Contact Type is now independent from Event '
            'Type, with options such as In Person, Phone Call, Text, Email, '
            'WhatsApp, Social Media, Video Call, and Other.',
        'Clearer Event statuses — Contact Events now use Contacted where '
            'appropriate, while regular Events continue to use Completed.',
        'Completed Events controls — choose whether completed Events appear '
            'in Planner, including quick access from Planner filters.',
        'Cleaner Settings & Permissions — improved Settings surfaces, '
            'permission explanations, and notification privacy controls.',
        'Improved notification privacy — simplified generic vs. detailed '
            'notification previews and settings.',
        'Set Time to Now — quickly set an Event to the current time, with '
            'one-level Undo.',
        'Schedule from Planner — adjust an existing Event directly on the '
            'Planner before saving it. Changes remain a draft until you save '
            'the Event.',
        'Better time handling — minute-level scheduling and support for '
            'Events that continue past midnight.',
        'Smarter Unreported notifications — tapping the summary notification '
            'now opens the Unreported category with the most current '
            'actionable items.',
        'Contact Type icons in Planner — Contact Events now show their '
            'communication type beside the Event title for quicker '
            'identification.',
        'Conflict awareness — when a timed Event overlaps another applicable '
            'Event, the form now shows “Conflicting event” without preventing '
            'you from saving.',
      ]),
      MessageParagraph(
        'Plus: additional reliability, performance, layout, and regression '
        'improvements throughout Planner and beta workflows.',
      ),
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
    <Message>[
      versionZeroOneOneBuildFive,
      versionZeroOneOneBuildFour,
      versionZeroOneOne,
      versionZeroOneZero,
      welcome,
    ]..sort(
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
