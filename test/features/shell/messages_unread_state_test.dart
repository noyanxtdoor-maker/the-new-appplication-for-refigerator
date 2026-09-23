// Closed-beta 0.1.1 — in-app update notice + Home bell unread indicator.
//
// OWNER REQUIREMENT (2026-09-18): the Home notification bell must show a small
// red dot while an unread release message exists, the dot must clear once that
// message is opened or acknowledged, the state must survive a restart, and the
// dot must never be an arbitrary timer, a fabricated counter, or a side effect
// of Android notification permission.
//
// These tests are written against the REAL catalog and the REAL controller. The
// persistence seam is injected, so nothing here touches a platform channel.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/shell/message_detail_screen.dart';
import 'package:rmplanner/features/shell/messages/application/message_providers.dart';
import 'package:rmplanner/features/shell/messages/data/message_read_state_store.dart';
import 'package:rmplanner/features/shell/messages/message.dart';
import 'package:rmplanner/features/shell/messages_screen.dart';
import 'package:rmplanner/features/startup/presentation/home_screen.dart';

import '../../support/test_dependencies.dart';

/// A test double with an explicit failure switch, so the "no false read" law is
/// testable rather than assumed.
final class _MemoryReadStateStore implements MessageReadStateStore {
  _MemoryReadStateStore([Iterable<String> initial = const <String>[]])
    : acknowledged = <String>{...initial};

  final Set<String> acknowledged;
  int writeCount = 0;
  bool failWrites = false;

  @override
  Future<Set<String>> readAcknowledgedIds() async => <String>{...acknowledged};

  @override
  Future<void> acknowledge(String id) async {
    if (failWrites) {
      throw StateError('receipt refused');
    }
    // Idempotent, exactly like the real store: a repeated acknowledgement of
    // the same id stores one receipt.
    if (acknowledged.contains(id)) return;
    writeCount += 1;
    acknowledged.add(id);
  }
}

void main() {
  // The accepted 0.1.1 notice. It is deliberately NOT re-identified by Build 4:
  // reusing this id would re-open a notice every tester has already read.
  const releaseId = 'next-transfer-0-1-1-beta';
  // The Build 4 notice: a NEW message with its OWN stable id.
  const buildFourId = 'next-transfer-0-1-1-build-4-beta';
  // Build 5 also needs a distinct receipt identity.
  const buildFiveId = 'next-transfer-0-1-1-build-5-beta';
  const unreadDot = Key('home-messages-unread-dot');

  Future<void> pumpHome(
    WidgetTester tester, {
    required _MemoryReadStateStore store,
    FakePermissionGateway? permissionGateway,
    Size size = const Size(431, 912),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(
      database: database,
      permissionGateway: permissionGateway,
    );
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startup.completeOnboarding();
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        extraOverrides: <Override>[
          messageReadStateStoreProvider.overrideWithValue(store),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openReleaseDetail(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-messages')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message-row-$releaseId')));
    await tester.pumpAndSettle();
  }

  Future<void> backToHome(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  /// The detail body is a lazy list, so the primary action is only built once
  /// it is scrolled into view.
  Future<void> revealDetailAction(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('message-detail-action')),
      240,
      scrollable: find.descendant(
        of: find.byKey(const Key('message-detail-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ---------------------------------------------------------------------
  // Catalog law.
  // ---------------------------------------------------------------------
  group('0.1.1 update notice', () {
    test('ships and keeps the catalog ordered newest-first', () {
      final message = BundledMessages.byId(releaseId);
      expect(message, isNotNull, reason: 'the 0.1.1 notice must ship.');
      expect(message!.title, "What's New in Next Transfer");
      expect(message.actionLabel, 'Got it');
      // Every release build gets a distinct notice id. Build 5 is newest;
      // earlier receipts remain attached to the unchanged Build 4/0.1.1 ids.
      expect(
        BundledMessages.all.first.id,
        buildFiveId,
        reason: 'the Build 5 notice is the newest entry.',
      );
      final published = <DateTime>[
        for (final entry in BundledMessages.all) entry.publishedAtLocal,
      ];
      for (var index = 1; index < published.length; index += 1) {
        expect(
          published[index - 1].isAfter(published[index]),
          isTrue,
          reason: 'every entry is published after the one below it.',
        );
      }
      expect(
        BundledMessages.all.map((entry) => entry.id),
        contains(releaseId),
        reason: 'the accepted 0.1.1 notice is preserved verbatim.',
      );
    });

    test('claims only what actually shipped in 0.1.1', () {
      final message = BundledMessages.byId(releaseId)!;
      final text = <String>[
        for (final block in message.blocks)
          switch (block) {
            MessageParagraph(:final text) => text,
            MessageSectionHeading(:final text) => text,
            MessageBulletList(:final items) => items.join(' | '),
          },
      ].join('\n');
      expect(text, contains('Backup & Restore'));
      // Owner correction (2026-09-18): the release note must disclose the
      // accepted Manage Groups work shipped in this beta.
      expect(
        text,
        contains(
          'Improved Manage Groups, including No Group filtering and '
          'Restore Default Groups behavior.',
        ),
      );
      expect(text, contains('Contacts'));
      expect(text, contains('10-minute default'));
      expect(text, contains('Event Type selector'));
      // The Create Goal flicker is NOT root-caused, so it is disclosed as an
      // open investigation and never as a fix.
      expect(text, contains('Still being investigated'));
      expect(text.toLowerCase(), contains('flicker'));
    });

    test('carries section headings so the detail stays structured', () {
      final message = BundledMessages.byId(releaseId)!;
      expect(message.blocks.first, isA<MessageParagraph>());
      expect(
        message.blocks.whereType<MessageSectionHeading>(),
        hasLength(greaterThanOrEqualTo(2)),
      );
    });
  });

  // ---------------------------------------------------------------------
  // Version-scoped unread law (no fabricated counter, no timer).
  // ---------------------------------------------------------------------
  group('unread law', () {
    test('a bundled message is unread until its own id is acknowledged', () {
      final release = BundledMessages.byId(releaseId)!;
      expect(MessageUnreadLaw.isUnread(release, const <String>{}), isTrue);
      expect(MessageUnreadLaw.isUnread(release, <String>{releaseId}), isFalse);
    });

    test('acknowledging one version never marks a later release read', () {
      final older = BundledMessages.byId('next-transfer-0-1-0-beta')!;
      final acknowledged = <String>{older.id};
      expect(MessageUnreadLaw.isUnread(older, acknowledged), isFalse);
      // A future release ships a NEW id and is therefore unread again.
      const future = 'next-transfer-0-1-2-beta';
      expect(acknowledged.contains(future), isFalse);
      expect(
        MessageUnreadLaw.unread(
          BundledMessages.all,
          acknowledged,
        ).map((message) => message.id),
        isNot(contains(older.id)),
      );
    });
  });

  // ---------------------------------------------------------------------
  // Persistence.
  // ---------------------------------------------------------------------
  group('read receipts', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('nt-messages');
    });

    tearDown(() async {
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    });

    FileMessageReadStateStore store() =>
        FileMessageReadStateStore(directory: () async => directory);

    test('an absent document reads as nothing acknowledged', () async {
      expect(await store().readAcknowledgedIds(), isEmpty);
    });

    test(
      'an acknowledgement survives a restart (a fresh store instance)',
      () async {
        await store().acknowledge('next-transfer-0-1-1-beta');
        final afterRestart = await store().readAcknowledgedIds();
        expect(afterRestart, <String>{'next-transfer-0-1-1-beta'});
      },
    );

    test('acknowledging is idempotent and never un-reads a message', () async {
      final first = store();
      await first.acknowledge('next-transfer-0-1-1-beta');
      await first.acknowledge('next-transfer-0-1-1-beta');
      expect(await store().readAcknowledgedIds(), <String>{
        'next-transfer-0-1-1-beta',
      });
      // Reading again can never make it unread: the receipt is on disk.
      expect(await store().readAcknowledgedIds(), hasLength(1));
    });

    test('two receipts accumulate without losing either', () async {
      final target = store();
      await target.acknowledge('next-transfer-0-1-1-beta');
      await target.acknowledge('welcome-to-next-transfer-beta');
      expect(await store().readAcknowledgedIds(), <String>{
        'next-transfer-0-1-1-beta',
        'welcome-to-next-transfer-beta',
      });
    });

    test(
      'a corrupt document reads as nothing acknowledged, never as read',
      () async {
        final file = File(
          '${directory.path}${Platform.pathSeparator}'
          'message_read_state.json',
        );
        await file.writeAsString('{not json');
        expect(await store().readAcknowledgedIds(), isEmpty);
      },
    );

    test('an empty id is never stored', () async {
      await store().acknowledge('');
      expect(await store().readAcknowledgedIds(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------
  // Home bell indicator.
  // ---------------------------------------------------------------------
  group('Home bell unread dot', () {
    testWidgets('a never-acknowledged tester sees the dot', (tester) async {
      await pumpHome(tester, store: _MemoryReadStateStore());
      expect(find.byKey(unreadDot), findsOneWidget);
    });

    testWidgets('an already-acknowledged tester never sees the dot', (
      tester,
    ) async {
      await pumpHome(
        tester,
        store: _MemoryReadStateStore(<String>{
          for (final message in BundledMessages.all) message.id,
        }),
      );
      expect(find.byKey(unreadDot), findsNothing);
    });

    testWidgets('opening the notice clears the dot and stores the receipt', (
      tester,
    ) async {
      final store = _MemoryReadStateStore();
      await pumpHome(tester, store: store);
      expect(find.byKey(unreadDot), findsOneWidget);

      await openReleaseDetail(tester);
      expect(find.byType(MessageDetailScreen), findsOneWidget);
      expect(store.acknowledged, contains(releaseId));
      expect(store.writeCount, 1);

      await backToHome(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      // The remaining older bundled messages are still unread, so the dot is
      // driven by the REAL unread set rather than by one hard-coded message.
      expect(find.byKey(unreadDot), findsOneWidget);
    });

    testWidgets('the dot clears once the LAST unread message is opened', (
      tester,
    ) async {
      final store = _MemoryReadStateStore(<String>{
        for (final message in BundledMessages.all)
          if (message.id != releaseId) message.id,
      });
      await pumpHome(tester, store: store);
      expect(find.byKey(unreadDot), findsOneWidget);

      await openReleaseDetail(tester);
      expect(store.acknowledged, contains(releaseId));
      await backToHome(tester);
      expect(find.byKey(unreadDot), findsNothing);
    });

    testWidgets('the Got it action acknowledges and returns to the list', (
      tester,
    ) async {
      final store = _MemoryReadStateStore();
      await pumpHome(tester, store: store);
      await openReleaseDetail(tester);

      await revealDetailAction(tester);
      expect(find.byKey(const Key('message-detail-action')), findsOneWidget);
      await tester.tap(find.byKey(const Key('message-detail-action')));
      await tester.pumpAndSettle();

      expect(find.byType(MessagesScreen), findsOneWidget);
      expect(store.acknowledged, contains(releaseId));
    });

    testWidgets('a refused receipt leaves the notice unread (no false read)', (
      tester,
    ) async {
      final store = _MemoryReadStateStore()..failWrites = true;
      await pumpHome(tester, store: store);
      await openReleaseDetail(tester);
      expect(store.acknowledged, isEmpty);
      expect(store.writeCount, 0);

      await backToHome(tester);
      expect(find.byKey(unreadDot), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the bell still opens the canonical Messages screen', (
      tester,
    ) async {
      await pumpHome(tester, store: _MemoryReadStateStore());
      await tester.tap(find.byKey(const Key('home-messages')));
      await tester.pumpAndSettle();
      expect(find.byType(MessagesScreen), findsOneWidget);
      expect(find.byKey(const Key('messages-list')), findsOneWidget);
    });

    testWidgets('the update notice never asks for an OS permission', (
      tester,
    ) async {
      final permissions = FakePermissionGateway();
      await pumpHome(
        tester,
        store: _MemoryReadStateStore(),
        permissionGateway: permissions,
      );
      await openReleaseDetail(tester);
      await revealDetailAction(tester);
      await tester.tap(find.byKey(const Key('message-detail-action')));
      await tester.pumpAndSettle();
      expect(
        permissions.requestCount,
        0,
        reason: 'the in-app update notice is presentation only.',
      );
    });

    testWidgets('the dot and the notice survive text scale 1.5', (
      tester,
    ) async {
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      await pumpHome(
        tester,
        store: _MemoryReadStateStore(),
        size: const Size(393, 874),
      );
      expect(find.byKey(unreadDot), findsOneWidget);
      await openReleaseDetail(tester);
      expect(find.byKey(const Key('message-detail-scroll')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact landscape keeps the dot and the action usable', (
      tester,
    ) async {
      await pumpHome(
        tester,
        store: _MemoryReadStateStore(),
        size: const Size(874, 393),
      );
      expect(find.byKey(unreadDot), findsOneWidget);
      await openReleaseDetail(tester);
      await revealDetailAction(tester);
      expect(find.byKey(const Key('message-detail-action')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------
  // Provider law at the unit level.
  // ---------------------------------------------------------------------
  group('acknowledgement projection', () {
    ProviderContainer containerFor(_MemoryReadStateStore store) {
      final container = ProviderContainer(
        overrides: <Override>[
          messageReadStateStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('an unresolved read state never invents an unread notice', () {
      final container = containerFor(_MemoryReadStateStore());
      expect(container.read(hasUnreadMessagesProvider), isFalse);
      expect(container.read(unreadMessagesProvider), isEmpty);
    });

    test('stored receipts load and a new acknowledgement is durable', () async {
      final store = _MemoryReadStateStore(const <String>[
        'welcome-to-next-transfer-beta',
      ]);
      final container = containerFor(store);

      expect(
        await container.read(storedMessageAcknowledgementsProvider.future),
        <String>{'welcome-to-next-transfer-beta'},
      );
      final unreadBefore = container
          .read(unreadMessagesProvider)
          .map((message) => message.id);
      expect(unreadBefore, contains(releaseId));
      expect(unreadBefore, isNot(contains('welcome-to-next-transfer-beta')));

      expect(
        await container
            .read(messageAcknowledgementProvider)
            .acknowledge(releaseId),
        isTrue,
      );
      expect(store.acknowledged, contains(releaseId));
      expect(
        container.read(unreadMessagesProvider).map((message) => message.id),
        isNot(contains(releaseId)),
      );
    });

    test('a failed write reports false and keeps the message unread', () async {
      final store = _MemoryReadStateStore()..failWrites = true;
      final container = containerFor(store);

      expect(
        await container
            .read(messageAcknowledgementProvider)
            .acknowledge(releaseId),
        isFalse,
      );
      expect(store.acknowledged, isEmpty);
      expect(container.read(sessionMessageAcknowledgementsProvider), isEmpty);
    });

    test('a storage failure still surfaces the notice', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          storedMessageAcknowledgementsProvider.overrideWith(
            (ref) async => throw StateError('storage unavailable'),
          ),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(storedMessageAcknowledgementsProvider.future),
        throwsStateError,
      );
      expect(container.read(hasUnreadMessagesProvider), isTrue);
    });
  });

  // ---------------------------------------------------------------------
  // Owner law (2026-09-19): each bundled message shows the red DOT only, and
  // per-message receipts survive a catalog update — installing a build with one
  // new release note leaves exactly that note unread.
  // ---------------------------------------------------------------------
  group('per-message unread presentation', () {
    /// Everything except the newest notice was already read by this tester.
    _MemoryReadStateStore previouslyReadAllButTheNotice() {
      return _MemoryReadStateStore(
        BundledMessages.all
            .where((message) => message.id != releaseId)
            .map((message) => message.id),
      );
    }

    testWidgets('only the unread notice carries the red dot, never a number', (
      tester,
    ) async {
      await pumpHome(tester, store: previouslyReadAllButTheNotice());
      await tester.tap(find.byKey(const Key('home-messages')));
      await tester.pumpAndSettle();

      for (final message in BundledMessages.all) {
        final dot = find.byKey(Key('message-unread-dot-${message.id}'));
        if (message.id == releaseId) {
          expect(dot, findsOneWidget, reason: 'the new notice is unread');
        } else {
          expect(dot, findsNothing, reason: '${message.id} stays read');
        }
      }
      // Red DOT only: the row never renders a count.
      expect(
        find.descendant(
          of: find.byKey(Key('message-row-$releaseId')),
          matching: find.text('1'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'opening the new notice clears its dot and keeps old receipts',
      (tester) async {
        final store = previouslyReadAllButTheNotice();
        await pumpHome(tester, store: store);
        final previouslyRead = <String>{...store.acknowledged};

        await tester.tap(find.byKey(const Key('home-messages')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('message-row-$releaseId')));
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        for (final message in BundledMessages.all) {
          expect(
            find.byKey(Key('message-unread-dot-${message.id}')),
            findsNothing,
            reason: '${message.id} is read once every notice is open',
          );
        }
        expect(store.acknowledged, contains(releaseId));
        expect(store.acknowledged.containsAll(previouslyRead), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  });

  // ---------------------------------------------------------------------
  // Build 4 update notice (owner requirement, 2026-09-20).
  //
  // RELEASE LAW: Build 4 ships as its OWN message with its OWN stable id. The
  // already-acknowledged 0.1.1 notice must keep its receipt, and installing
  // Build 4 must leave EXACTLY the new notice unread.
  // ---------------------------------------------------------------------
  group('Build 4 update notice', () {
    /// Every id except the Build 4 notice: a tester who had read everything
    /// before Build 4 was installed over the top of their install.
    Set<String> readEverythingBeforeBuildFour() => <String>{
      for (final message in BundledMessages.all)
        if (message.id != buildFourId) message.id,
    };

    String bodyText(Message message) => <String>[
      for (final block in message.blocks)
        switch (block) {
          MessageParagraph(:final text) => text,
          MessageSectionHeading(:final text) => text,
          MessageBulletList(:final items) => items.join(' | '),
        },
    ].join('\n');

    ProviderContainer containerFor(_MemoryReadStateStore store) {
      final container = ProviderContainer(
        overrides: <Override>[
          messageReadStateStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('RMSG-1 ships as a bundled message', () {
      expect(BundledMessages.byId(buildFourId), isNotNull);
    });

    test('RMSG-2 uses an id unique across the whole bundled catalog', () {
      expect(buildFourId, isNot(releaseId));
      final ids = <String>[
        for (final message in BundledMessages.all) message.id,
      ];
      expect(
        ids.toSet(),
        hasLength(ids.length),
        reason: 'every bundled id is used exactly once.',
      );
      expect(ids.where((id) => id == buildFourId), hasLength(1));
    });

    test('RMSG-3 keeps the canonical release-note title', () {
      expect(
        BundledMessages.byId(buildFourId)!.title,
        "What's New in Next Transfer",
      );
    });

    test('RMSG-4 labels itself as Beta 0.1.1 · Build 4', () {
      final message = BundledMessages.byId(buildFourId)!;
      expect(bodyText(message), contains('Beta 0.1.1 · Build 4'));
      expect(message.actionLabel, 'Got it');
    });

    test('RMSG-5 announces Unreported', () {
      expect(
        bodyText(BundledMessages.byId(buildFourId)!),
        contains('Unreported'),
      );
    });

    test('RMSG-6 announces the Tasks experience', () {
      expect(bodyText(BundledMessages.byId(buildFourId)!), contains('Tasks'));
    });

    test('RMSG-7 announces notification and reminder improvements', () {
      final text = bodyText(BundledMessages.byId(buildFourId)!).toLowerCase();
      expect(text, contains('notification'));
      expect(text, contains('reminder'));
    });

    test('RMSG-8 announces that already-read messages stay read', () {
      expect(
        bodyText(BundledMessages.byId(buildFourId)!).toLowerCase(),
        contains('stay read'),
      );
    });

    test('RMSG-9 an existing receipt is untouched by the new notice', () async {
      final store = _MemoryReadStateStore(readEverythingBeforeBuildFour());
      final container = containerFor(store);
      await container.read(storedMessageAcknowledgementsProvider.future);

      final unread = <String>{
        for (final message in container.read(unreadMessagesProvider))
          message.id,
      };
      for (final message in BundledMessages.all) {
        if (message.id == buildFourId) continue;
        expect(
          unread,
          isNot(contains(message.id)),
          reason: '${message.id} was read before Build 4 and stays read.',
        );
      }
    });

    test('RMSG-10 only the newly-added Build 4 notice is unread', () async {
      final store = _MemoryReadStateStore(readEverythingBeforeBuildFour());
      final container = containerFor(store);
      await container.read(storedMessageAcknowledgementsProvider.future);

      expect(
        container.read(unreadMessagesProvider).map((message) => message.id),
        <String>[buildFourId],
      );
    });

    test('RMSG-11 the unread dot reads the shared unread truth', () async {
      final store = _MemoryReadStateStore(readEverythingBeforeBuildFour());
      final container = containerFor(store);
      await container.read(storedMessageAcknowledgementsProvider.future);
      // Only the new notice is unread, so the red dot is shown.
      expect(container.read(hasUnreadMessagesProvider), isTrue);

      expect(
        await container
            .read(messageAcknowledgementProvider)
            .acknowledge(buildFourId),
        isTrue,
      );
      // Nothing is unread any more, so the dot goes away.
      expect(container.read(hasUnreadMessagesProvider), isFalse);
    });

    test(
      'RMSG-12 acknowledging Build 4 never alters an older receipt',
      () async {
        final store = _MemoryReadStateStore(readEverythingBeforeBuildFour());
        final before = <String>{...store.acknowledged};
        final container = containerFor(store);
        await container.read(storedMessageAcknowledgementsProvider.future);

        expect(
          await container
              .read(messageAcknowledgementProvider)
              .acknowledge(buildFourId),
          isTrue,
        );
        expect(store.acknowledged, hasLength(before.length + 1));
        expect(store.acknowledged.containsAll(before), isTrue);
        expect(store.acknowledged, contains(releaseId));
      },
    );

    testWidgets('a Build 4 install leaves only the new notice unread', (
      tester,
    ) async {
      final store = _MemoryReadStateStore(readEverythingBeforeBuildFour());
      await pumpHome(tester, store: store);
      expect(find.byKey(unreadDot), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-messages')));
      await tester.pumpAndSettle();
      for (final message in BundledMessages.all) {
        final dot = find.byKey(Key('message-unread-dot-${message.id}'));
        if (message.id == buildFourId) {
          expect(dot, findsOneWidget, reason: 'the Build 4 notice is unread.');
        } else {
          expect(
            dot,
            findsNothing,
            reason: '${message.id} keeps its pre-existing receipt.',
          );
        }
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Home dot clears once Build 4 is the last unread notice', (
      tester,
    ) async {
      final store = _MemoryReadStateStore(readEverythingBeforeBuildFour());
      await pumpHome(tester, store: store);
      expect(find.byKey(unreadDot), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-messages')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('message-row-$buildFourId')));
      await tester.pumpAndSettle();
      expect(find.byType(MessageDetailScreen), findsOneWidget);
      expect(store.acknowledged, contains(buildFourId));

      await backToHome(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byKey(unreadDot), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the Build 4 detail renders its own Beta 0.1.1 · Build 4 label',
      (tester) async {
        final store = _MemoryReadStateStore(readEverythingBeforeBuildFour());
        await pumpHome(tester, store: store);
        await tester.tap(find.byKey(const Key('home-messages')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('message-row-$buildFourId')));
        await tester.pumpAndSettle();

        expect(find.byType(MessageDetailScreen), findsOneWidget);
        expect(find.text('Beta 0.1.1 · Build 4'), findsOneWidget);
        expect(find.byKey(const Key('message-detail-not-found')), findsNothing);
        await revealDetailAction(tester);
        expect(find.byKey(const Key('message-detail-action')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Build 5 update notice', () {
    Set<String> readEverythingBeforeBuildFive() => <String>{
      for (final message in BundledMessages.all)
        if (message.id != buildFiveId) message.id,
    };

    ProviderContainer containerFor(_MemoryReadStateStore store) {
      final container = ProviderContainer(
        overrides: <Override>[
          messageReadStateStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('RMSG-13 uses a new build-scoped id and approved title', () {
      final message = BundledMessages.byId(buildFiveId);
      expect(message, isNotNull);
      expect(message!.id, 'next-transfer-0-1-1-build-5-beta');
      expect(message.title, "What's New in Next Transfer");
      expect(BundledMessages.all.first, same(message));
      expect(message.publishedAtLocal, DateTime(2026, 9, 23, 9));
    });

    test('RMSG-14 contains the exact owner-approved body', () {
      final message = BundledMessages.byId(buildFiveId)!;
      expect(
        message.blocks.whereType<MessageParagraph>().map((block) => block.text),
        <String>[
          'We’ve made a major round of Planner, Event, Contact, and notification improvements based on beta feedback.',
          'Plus: additional reliability, performance, layout, and regression improvements throughout Planner and beta workflows.',
        ],
      );
      expect(message.blocks.whereType<MessageBulletList>().single.items, <
        String
      >[
        'Smarter Planner experience — improved visible-hour controls, scrolling, zooming, timeline spacing, and easier access to the full day.',
        'Better Contact Events — Contact Type is now independent from Event Type, with options such as In Person, Phone Call, Text, Email, WhatsApp, Social Media, Video Call, and Other.',
        'Clearer Event statuses — Contact Events now use Contacted where appropriate, while regular Events continue to use Completed.',
        'Completed Events controls — choose whether completed Events appear in Planner, including quick access from Planner filters.',
        'Cleaner Settings & Permissions — improved Settings surfaces, permission explanations, and notification privacy controls.',
        'Improved notification privacy — simplified generic vs. detailed notification previews and settings.',
        'Set Time to Now — quickly set an Event to the current time, with one-level Undo.',
        'Schedule from Planner — adjust an existing Event directly on the Planner before saving it. Changes remain a draft until you save the Event.',
        'Better time handling — minute-level scheduling and support for Events that continue past midnight.',
        'Smarter Unreported notifications — tapping the summary notification now opens the Unreported category with the most current actionable items.',
        'Contact Type icons in Planner — Contact Events now show their communication type beside the Event title for quicker identification.',
        'Conflict awareness — when a timed Event overlaps another applicable Event, the form now shows “Conflicting event” without preventing you from saving.',
      ]);
      expect(message.actionLabel, 'Got it');
    });

    test(
      'RMSG-15 only Build 5 is unread; acknowledging it preserves prior receipts',
      () async {
        final store = _MemoryReadStateStore(readEverythingBeforeBuildFive());
        final priorReceipts = <String>{...store.acknowledged};
        final container = containerFor(store);
        await container.read(storedMessageAcknowledgementsProvider.future);

        expect(
          container.read(unreadMessagesProvider).map((message) => message.id),
          <String>[buildFiveId],
        );
        final acknowledgements = container.read(messageAcknowledgementProvider);
        expect(await acknowledgements.acknowledge(buildFiveId), isTrue);
        expect(store.acknowledged, <String>{...priorReceipts, buildFiveId});
        expect(store.writeCount, 1);
        expect(container.read(unreadMessagesProvider), isEmpty);

        // Reopening or acknowledging again must not create another receipt.
        expect(await acknowledgements.acknowledge(buildFiveId), isTrue);
        expect(store.writeCount, 1);
        expect(container.read(unreadMessagesProvider), isEmpty);
      },
    );

    testWidgets(
      'RMSG-16 the canonical Messages screen acknowledges Build 5 once',
      (tester) async {
        final store = _MemoryReadStateStore(readEverythingBeforeBuildFive());
        await pumpHome(tester, store: store);
        expect(find.byKey(unreadDot), findsOneWidget);

        await tester.tap(find.byKey(const Key('home-messages')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('message-row-$buildFiveId')));
        await tester.pumpAndSettle();
        expect(find.byType(MessageDetailScreen), findsOneWidget);
        expect(find.byKey(const Key('message-detail-not-found')), findsNothing);
        await revealDetailAction(tester);
        await tester.tap(find.byKey(const Key('message-detail-action')));
        await tester.pumpAndSettle();
        expect(store.acknowledged, contains(buildFiveId));
        expect(store.writeCount, 1);

        await backToHome(tester);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.byKey(unreadDot), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
