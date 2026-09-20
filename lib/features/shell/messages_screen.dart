import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/shell/messages/application/message_providers.dart';
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
///
/// CLOSED-BETA 0.1.1 (owner requirement, 2026-09-18): OPENING a message records
/// its read receipt, which is what clears the Home bell dot. The receipt is
/// written from this real user gesture (never from a build or a post-frame
/// callback), and the message detail screen records it again from its own
/// primary action. The write is idempotent, so opening and then confirming
/// stores one receipt.
final class MessagesScreen extends ConsumerWidget {
  const MessagesScreen({super.key});

  void _openMessage(BuildContext context, WidgetRef ref, Message message) {
    unawaited(ref.read(messageAcknowledgementProvider).acknowledge(message.id));
    unawaited(context.push<void>(RoutePaths.messageDetail(message.id)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = BundledMessages.all;
    // Owner law (2026-09-19): the Messages surface marks EACH still-unread
    // bundled message with the same red dot, never a number, so a tester can
    // see exactly which release note is new after an update while every
    // previously read receipt stays read.
    final unreadIds = <String>{
      for (final message in ref.watch(unreadMessagesProvider)) message.id,
    };
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
                  isUnread: unreadIds.contains(messages[index].id),
                  nowLocal: DateTime.now(),
                  onOpen: () => _openMessage(context, ref, messages[index]),
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
  const _MessageListRow({
    required this.message,
    required this.isUnread,
    required this.nowLocal,
    required this.onOpen,
  });

  final Message message;

  /// Red-dot only: the row never renders a count.
  final bool isUnread;
  final DateTime nowLocal;

  /// Records the receipt and opens the detail. Supplied by the screen so the
  /// row itself stays free of application state.
  final VoidCallback onOpen;

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
          '${MessageDateLabel.relative(message.publishedAtLocal, nowLocal)}'
          '${isUnread ? ', unread' : ''}',
      child: InkWell(
        key: Key('message-row-${message.id}'),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      message.title,
                      key: Key('message-row-title-${message.id}'),
                      style: titleStyle,
                    ),
                  ),
                  if (isUnread) ...<Widget>[
                    const SizedBox(width: 8),
                    Container(
                      key: Key('message-unread-dot-${message.id}'),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
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
