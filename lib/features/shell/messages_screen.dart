import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/shell/messages/message.dart';

/// Bundled local Messages (Pack 3, locked policy 1; closed-beta V2 AG-3/AG-4).
///
/// Both the Home bell and the drawer Messages destination open this one
/// canonical screen. It renders the typed, locally bundled release notes and
/// announcements, newest first. It performs no remote fetch, creates no
/// backend, claims no unread count, and never routes to Android notification
/// permissions. When the bundled catalog is empty it shows a truthful empty
/// state and nothing more.
///
/// A message that ships in the bundle is always readable offline, because it
/// is part of the application itself.
final class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final messages = BundledMessages.all;
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Messages')),
      body: SafeArea(
        child: messages.isEmpty
            ? const _MessagesEmptyState()
            : ListView.builder(
                key: const Key('messages-list'),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                itemCount: messages.length,
                itemBuilder: (context, index) => _MessageListRow(
                  message: messages[index],
                  nowLocal: DateTime.now(),
                ),
              ),
      ),
    );
  }
}

/// One message in the list: a prominent title with a smaller secondary
/// relative date beneath it, separated by generous whitespace instead of heavy
/// card chrome.
final class _MessageListRow extends StatelessWidget {
  const _MessageListRow({required this.message, required this.nowLocal});

  final Message message;
  final DateTime nowLocal;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontSize: 17,
      height: 24 / 17,
      fontWeight: FontWeight.w700,
    );
    return Semantics(
      button: true,
      label:
          '${message.title}, '
          '${MessageDateLabel.relative(message.publishedAtLocal, nowLocal)}',
      child: InkWell(
        key: Key('message-row-${message.id}'),
        onTap: () => context.push(RoutePaths.messageDetail(message.id)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                message.title,
                key: Key('message-row-title-${message.id}'),
                style: titleStyle,
              ),
              const SizedBox(height: 4),
              Text(
                MessageDateLabel.relative(message.publishedAtLocal, nowLocal),
                key: Key('message-row-date-${message.id}'),
                style: InternalScreen.label.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _MessagesEmptyState extends StatelessWidget {
  const _MessagesEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.chat_bubble_outline, size: 44, color: Colors.white38),
            const SizedBox(height: 16),
            Text(
              'No messages yet.',
              key: const Key('messages-empty-title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Roboto',
                fontSize: 16,
                height: 22 / 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'There are no local messages.',
              key: const Key('messages-empty-body'),
              textAlign: TextAlign.center,
              style: InternalScreen.label.copyWith(color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }
}
