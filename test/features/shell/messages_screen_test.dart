// Pack 3 — honest local Messages shell.
// Closed-beta V2 (owner decisions AG-3/AG-4, 2026-09-17): the single canonical
// Messages destination now renders the typed, LOCALLY BUNDLED release notes and
// announcements, newest first, with a structured detail screen.
//
// OLD LAW: the screen was an empty shell showing only "No messages yet."
// NEW LAW: the bundled catalog is shown; a new message ships with the app.
// WHY RECONCILED: the old assertions encoded the empty-shell presentation.
// PRODUCTION DELTA: bundled typed messages + a detail route.
//
// The reconciled assertions keep the original intent: one canonical screen for
// both entry points, never the permissions surface, never a fabricated unread
// count, and never a remote/notification-permission route.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/privacy/presentation/permissions_screen.dart';
import 'package:rmplanner/features/shell/message_detail_screen.dart';
import 'package:rmplanner/features/shell/messages/message.dart';
import 'package:rmplanner/features/shell/messages_screen.dart';
import 'package:rmplanner/features/startup/presentation/home_screen.dart';

import '../../support/test_dependencies.dart';

void main() {
  const buildFiveId = 'next-transfer-0-1-1-build-5-beta';

  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(431, 912),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
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
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDrawer(WidgetTester tester, String entryId) async {
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(Key(entryId)),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('global-app-drawer-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(entryId)));
    await tester.pumpAndSettle();
  }

  Future<void> openNewestDetail(WidgetTester tester) async {
    final release = BundledMessages.all.first;
    await tester.tap(find.byKey(Key('message-row-${release.id}')));
    await tester.pumpAndSettle();
  }

  // ---------------------------------------------------------------------
  // Pure model / catalog / date law (no widget involved).
  // ---------------------------------------------------------------------
  group('bundled catalog', () {
    test('is non-empty and newest first', () {
      final messages = BundledMessages.all;
      expect(messages, isNotEmpty);
      for (var index = 1; index < messages.length; index += 1) {
        expect(
          messages[index - 1].publishedAtLocal.isAfter(
            messages[index].publishedAtLocal,
          ),
          isTrue,
          reason: 'the list must be strictly newest first.',
        );
      }
    });

    test('ids are unique and resolvable', () {
      final messages = BundledMessages.all;
      final ids = messages.map((message) => message.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      for (final message in messages) {
        expect(BundledMessages.byId(message.id), same(message));
      }
      expect(BundledMessages.byId('does-not-exist'), isNull);
    });

    test('the Build 5 release notice is the newest bundled message', () {
      final release = BundledMessages.byId(buildFiveId);
      expect(release, isNotNull);
      expect(release!.title, "What's New in Next Transfer");
      expect(release.id, 'next-transfer-0-1-1-build-5-beta');
      expect(BundledMessages.all.first, same(release));
    });

    test('every message is well formed', () {
      for (final message in BundledMessages.all) {
        expect(message.title.trim(), isNotEmpty);
        expect(message.blocks, isNotEmpty);
        for (final block in message.blocks) {
          switch (block) {
            case MessageParagraph(:final text):
              expect(text.trim(), isNotEmpty);
            case MessageSectionHeading(:final text):
              expect(text.trim(), isNotEmpty);
            case MessageBulletList(:final items):
              expect(items, isNotEmpty);
              for (final item in items) {
                expect(item.trim(), isNotEmpty);
              }
          }
        }
      }
    });

    test('content is plain typed text, never markup', () {
      for (final message in BundledMessages.all) {
        final text = <String>[
          message.title,
          for (final block in message.blocks)
            switch (block) {
              MessageParagraph(:final text) => text,
              MessageSectionHeading(:final text) => text,
              MessageBulletList(:final items) => items.join(' '),
            },
        ].join(' ');
        expect(text, isNot(contains('<')));
        expect(text, isNot(contains('##')));
        expect(text, isNot(contains('](')));
      }
    });

    test('the release note is sectioned and readable', () {
      final releaseNote = BundledMessages.byId('next-transfer-0-1-0-beta');
      expect(releaseNote, isNotNull);
      expect(
        releaseNote!.blocks.whereType<MessageSectionHeading>(),
        isNotEmpty,
        reason: 'a structured release note has bold section headings.',
      );
      expect(
        releaseNote.blocks.first,
        isA<MessageParagraph>(),
        reason: 'the release note opens with an intro paragraph.',
      );
    });

    test('an unknown id never fabricates content', () {
      expect(BundledMessages.byId(''), isNull);
      expect(BundledMessages.byId('WELCOME-TO-NEXT-TRANSFER-BETA'), isNull);
    });
  });

  group('relative publication label', () {
    final now = DateTime(2026, 9, 17, 12);

    test('today, yesterday and N days ago', () {
      expect(MessageDateLabel.relative(DateTime(2026, 9, 17, 8), now), 'Today');
      expect(
        MessageDateLabel.relative(DateTime(2026, 9, 16, 8), now),
        'Yesterday',
      );
      expect(
        MessageDateLabel.relative(DateTime(2026, 9, 12, 8), now),
        '5 days ago',
      );
    });

    test('a future or same-day timestamp never reads as a negative age', () {
      expect(MessageDateLabel.relative(DateTime(2026, 9, 18, 8), now), 'Today');
      expect(MessageDateLabel.relative(now, now), 'Today');
    });
  });

  testWidgets(
    'Home bell opens the canonical Messages list, never permissions',
    (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('home-messages')));
      await tester.pumpAndSettle();
      expect(find.byType(MessagesScreen), findsOneWidget);
      expect(find.byType(PermissionsScreen), findsNothing);

      // The bundled catalog is rendered, and the old empty shell is gone.
      expect(find.byKey(const Key('messages-list')), findsOneWidget);
      expect(find.byKey(const Key('messages-empty-title')), findsNothing);
      final releaseNote = BundledMessages.all.first;
      expect(
        find.byKey(Key('message-row-${releaseNote.id}')),
        findsOneWidget,
        reason: 'the newest bundled message is listed.',
      );
      // Build 4 ships a SECOND release notice that legitimately carries the
      // same canonical title, so the title is asserted inside its OWN row
      // rather than as a whole-screen text count.
      expect(
        find.descendant(
          of: find.byKey(Key('message-row-${releaseNote.id}')),
          matching: find.text(releaseNote.title),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('message-row-date-${releaseNote.id}')),
        findsOneWidget,
        reason: 'each row carries a secondary relative publication date.',
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    },
  );

  testWidgets('drawer Messages opens the same canonical screen', (
    tester,
  ) async {
    await pumpApp(tester);
    await openDrawer(tester, 'drawer-messages');
    expect(find.byType(MessagesScreen), findsOneWidget);
    expect(find.byType(PermissionsScreen), findsNothing);
    expect(find.byKey(const Key('messages-list')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the list is newest first and never fabricates an unread count', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('home-messages')));
    await tester.pumpAndSettle();

    final messages = BundledMessages.all;
    final tops = <double>[
      for (final message in messages)
        tester.getTopLeft(find.byKey(Key('message-row-${message.id}'))).dy,
    ];
    for (var index = 1; index < tops.length; index += 1) {
      expect(
        tops[index - 1],
        lessThan(tops[index]),
        reason: 'the newest message must be rendered above the older one.',
      );
    }
    // No fabricated unread badge and no Android permission routing.
    expect(find.text('Not requested'), findsNothing);
    expect(find.byType(Badge), findsNothing);
  });

  testWidgets('a message opens a structured detail with a back arrow', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('home-messages')));
    await tester.pumpAndSettle();
    // Build 5 uses the approved plain intro + bullet structure. Select the
    // newest message that has a section heading for this structured-block law.
    final release = BundledMessages.all.firstWhere(
      (message) => message.blocks.whereType<MessageSectionHeading>().isNotEmpty,
    );
    await tester.tap(find.byKey(Key('message-row-${release.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(MessageDetailScreen), findsOneWidget);
    expect(find.byKey(const Key('message-detail-scroll')), findsOneWidget);
    // The app bar title equals the message title.
    expect(find.text(release.title), findsOneWidget);
    // Structured blocks render: a section heading and its paragraphs.
    final heading = release.blocks.whereType<MessageSectionHeading>().first;
    expect(find.text(heading.text), findsOneWidget);
    expect(find.byKey(const Key('message-detail-not-found')), findsNothing);
    // The ordinary back affordance returns to the list.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MessagesScreen), findsOneWidget);
    expect(find.byKey(const Key('messages-list')), findsOneWidget);
  });

  testWidgets('an unknown message id shows a truthful not-found state', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MessageDetailScreen(messageId: 'unknown-message-id'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-detail-not-found')), findsOneWidget);
    expect(find.text('This message is no longer available.'), findsOneWidget);
    expect(find.byKey(const Key('message-detail-scroll')), findsNothing);
  });

  testWidgets('the list and detail survive text scale 1.5', (tester) async {
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    await pumpApp(tester, size: const Size(393, 874));
    await tester.tap(find.byKey(const Key('home-messages')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('messages-list')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await openNewestDetail(tester);
    expect(find.byKey(const Key('message-detail-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact-height landscape keeps both screens usable', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(874, 393));
    await tester.tap(find.byKey(const Key('home-messages')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('messages-list')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await openNewestDetail(tester);
    expect(find.byKey(const Key('message-detail-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the detail body stays scrollable and readable at tablet width', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1024, 640));
    await tester.tap(find.byKey(const Key('home-messages')));
    await tester.pumpAndSettle();
    await openNewestDetail(tester);
    expect(find.byKey(const Key('message-detail-scroll')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('message-detail-scroll')),
        matching: find.byType(Scrollable),
      ),
      findsOneWidget,
    );
    await tester.drag(
      find.byKey(const Key('message-detail-scroll')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
