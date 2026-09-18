import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/shell/messages/data/message_read_state_store.dart';
import 'package:rmplanner/features/shell/messages/message.dart';

/// Unread state for the bundled local Messages catalog.
///
/// CLOSED-BETA 0.1.1 (owner requirement, 2026-09-18): the Home bell shows a
/// small red dot while a bundled message is still unread, and the dot clears
/// once that message has been opened or explicitly acknowledged. The earlier
/// "never a fabricated unread count" law is preserved in the only way that
/// matters: the indicator is derived from a REAL stored receipt for a REAL
/// bundled message — never a counter, a timer, Android permission state, or a
/// push payload.
///
/// TWO SOURCES, ONE ANSWER:
/// * [storedMessageAcknowledgementsProvider] is the durable receipt set read
///   once from app-private storage;
/// * [sessionMessageAcknowledgementsProvider] holds receipts written since the
///   app started, so the indicator clears immediately without a re-read.
/// The unread projection is the union of both.

/// The persistence seam. Overridden in tests with a temporary directory or an
/// in-memory double; production uses app-private storage.
final messageReadStateStoreProvider = Provider<MessageReadStateStore>(
  (ref) => FileMessageReadStateStore(),
);

/// Durable receipts. While unresolved the indicator stays hidden, so a tester
/// who has already read everything never sees a dot flash on cold start.
final storedMessageAcknowledgementsProvider = FutureProvider<Set<String>>(
  (ref) async => ref.watch(messageReadStateStoreProvider).readAcknowledgedIds(),
);

/// Receipts recorded since launch (append-only).
final sessionMessageAcknowledgementsProvider =
    NotifierProvider<
      SessionMessageAcknowledgementsController,
      Set<String>
    >(SessionMessageAcknowledgementsController.new);

final class SessionMessageAcknowledgementsController
    extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void add(String id) {
    if (id.isEmpty || state.contains(id)) return;
    state = <String>{...state, id};
  }
}

/// Bundled messages that still lack a receipt, newest first.
///
/// Storage that is unresolved (and has no session receipt yet) projects to
/// EMPTY rather than to "everything is unread": an unknown read state is never
/// rendered as a notification. A storage FAILURE is different — it projects the
/// full unread set, so an update notice is never silently swallowed because a
/// read failed.
final unreadMessagesProvider = Provider<List<Message>>((ref) {
  final stored = ref.watch(storedMessageAcknowledgementsProvider);
  final session = ref.watch(sessionMessageAcknowledgementsProvider);
  if (stored.hasError) {
    return MessageUnreadLaw.unread(BundledMessages.all, session);
  }
  if (!stored.hasValue && session.isEmpty) {
    return const <Message>[];
  }
  final acknowledged = <String>{...?stored.value, ...session};
  return MessageUnreadLaw.unread(BundledMessages.all, acknowledged);
});

/// The Home bell indicator input.
final hasUnreadMessagesProvider = Provider<bool>(
  (ref) => ref.watch(unreadMessagesProvider).isNotEmpty,
);

/// Records read receipts.
///
/// WRITE LAW: the receipt is persisted BEFORE the session state changes, and a
/// failed write reports false and changes nothing. The UI can therefore never
/// claim an acknowledgement that would be missing again after a restart.
final messageAcknowledgementProvider = Provider<MessageAcknowledgementController>(
  MessageAcknowledgementController.new,
);

final class MessageAcknowledgementController {
  MessageAcknowledgementController(this._ref);

  final Ref _ref;

  Future<bool> acknowledge(String id) async {
    if (id.isEmpty) return false;
    try {
      await _ref.read(messageReadStateStoreProvider).acknowledge(id);
    } catch (_) {
      return false;
    }
    _ref.read(sessionMessageAcknowledgementsProvider.notifier).add(id);
    // Resolve the unread projection NOW, outside any widget build.
    //
    // A message is opened while the Home route is offstage, so Home's consumer
    // subscriptions are paused when this state changes. Settling the projection
    // here means nothing is left pending when those subscriptions resume, and
    // the resume can never try to schedule a refresh from inside a build.
    _ref.read(unreadMessagesProvider);
    return true;
  }
}
