import 'package:flutter/material.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/shell/messages/message.dart';

/// One bundled local message (closed-beta V2, AG-3/AG-4).
///
/// The app bar carries the message title with the ordinary back affordance and
/// the body is a vertically scrollable column of typed content blocks. A short
/// release is one paragraph; a richer release note is an intro paragraph
/// followed by bold section headings with paragraphs beneath them.
final class MessageDetailScreen extends StatelessWidget {
  const MessageDetailScreen({required this.messageId, super.key});

  /// Stable bundled message id, taken from the route path.
  final String messageId;

  @override
  Widget build(BuildContext context) {
    final message = BundledMessages.byId(messageId);
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
                ],
              ),
      ),
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
