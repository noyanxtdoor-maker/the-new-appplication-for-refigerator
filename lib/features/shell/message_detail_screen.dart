import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/shell/messages/application/message_providers.dart';
import 'package:rmplanner/features/shell/messages/message.dart';

/// One bundled local message (closed-beta V2, AG-3/AG-4).
///
/// The app bar carries the message title with the ordinary back affordance and
/// the body is a vertically scrollable column of typed content blocks. A short
/// release is one paragraph; a richer release note is an intro paragraph
/// followed by bold section headings with paragraphs beneath them.
///
/// CLOSED-BETA 0.1.1 (owner requirement, 2026-09-18): the read receipt is
/// recorded by the Messages list when the user opens a message, and again by
/// this screen's own primary action. A message that declares a
/// [Message.actionLabel] renders that action at the end of the body.
///
/// This screen is deliberately NOT a stateful consumer: it performs no
/// subscription of its own, so navigating in and out of it cannot flush a
/// provider while the framework is building.
///
/// The not-found branch renders WITHOUT touching any provider, so a stale or
/// hand-typed deep link stays a pure presentation state.
final class MessageDetailScreen extends StatelessWidget {
  const MessageDetailScreen({required this.messageId, super.key});

  /// Stable bundled message id, taken from the route path.
  final String messageId;

  @override
  Widget build(BuildContext context) {
    final message = BundledMessages.byId(messageId);
    final actionLabel = message?.actionLabel;
    return Scaffold(
      appBar: InternalAppBar(
        title: Text(
          message?.title ?? 'Message',
          key: const Key('message-detail-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: message == null
            ? const _MessageNotFound()
            : ListView(
                key: const Key('message-detail-scroll'),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: <Widget>[
                  Text(
                    MessageDateLabel.relative(
                      message.publishedAtLocal,
                      DateTime.now(),
                    ),
                    key: const Key('message-detail-date'),
                    style: InternalScreen.label.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final block in message.blocks)
                    _MessageBlockView(block: block),
                  if (actionLabel != null) ...<Widget>[
                    const SizedBox(height: 12),
                    _MessageActionButton(
                      messageId: message.id,
                      label: actionLabel,
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// The message's own primary action: confirmation that also records the read
/// receipt and returns to the list. It subscribes to nothing, so it can never
/// invalidate a provider during a build.
final class _MessageActionButton extends ConsumerWidget {
  const _MessageActionButton({required this.messageId, required this.label});

  final String messageId;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      key: const Key('message-detail-action'),
      onPressed: () {
        unawaited(
          ref.read(messageAcknowledgementProvider).acknowledge(messageId),
        );
        if (context.canPop()) {
          context.pop();
        }
      },
      child: Text(label),
    );
  }
}

final class _MessageBlockView extends StatelessWidget {
  const _MessageBlockView({required this.block});

  final MessageBlock block;

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      MessageSectionHeading(:final text) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 6),
        child: Text(text, style: InternalScreen.sectionHeading),
      ),
      MessageParagraph(:final text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text, style: InternalScreen.body),
      ),
      MessageBulletList(:final items) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('•  ', style: InternalScreen.body),
                    Expanded(child: Text(item, style: InternalScreen.body)),
                  ],
                ),
              ),
          ],
        ),
      ),
    };
  }
}

/// A stale or hand-typed deep link resolves to a truthful not-found state
/// rather than to fabricated content.
final class _MessageNotFound extends StatelessWidget {
  const _MessageNotFound();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
        child: Text(
          'This message is no longer available.',
          key: const Key('message-detail-not-found'),
          textAlign: TextAlign.center,
          style: InternalScreen.body,
        ),
      ),
    );
  }
}
