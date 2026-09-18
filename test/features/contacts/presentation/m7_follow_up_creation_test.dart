// VS16 M7 — explicit follow-up creation provenance (Appendix T, T-B).
//
// The typed intent may be produced ONLY by the existing Contact Detail
// "Create Follow-Up" chooser; no title/link/notes heuristic may infer it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/notifications/domain/contact_follow_up_creation_intent.dart';

void main() {
  test('T11 intent equality and blank rejection are exact', () {
    const a = ContactFollowUpCreationIntent('contact-1');
    const b = ContactFollowUpCreationIntent('contact-1');
    const c = ContactFollowUpCreationIntent('contact-2');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
    expect(a.isValid, isTrue);
    expect(const ContactFollowUpCreationIntent('  ').isValid, isFalse);
  });

  test('T9/T10 chooser is the only production intent producer', () {
    final producers = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll('\\', '/');
      if (path.endsWith('contact_follow_up_creation_intent.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains('ContactFollowUpCreationIntent(')) {
        producers.add(path);
      }
    }
    expect(producers, <String>[
      'lib/features/contacts/presentation/contact_detail_screen.dart',
    ]);
  });

  test('T10 forms receive provenance without inferring it from links', () {
    final eventForm = File(
      'lib/features/planner/presentation/calendar_event_form_screen.dart',
    ).readAsStringSync();
    final taskForm = File(
      'lib/features/planner/presentation/task_form_screen.dart',
    ).readAsStringSync();
    expect(eventForm, contains('followUpContactId'));
    expect(eventForm, contains('deferReminderReconciliation'));
    expect(eventForm, contains('finalizeContactFollowUp'));
    expect(taskForm, contains('initialFollowUpContactId'));
    expect(taskForm, contains('deferReminderReconciliation'));
    expect(taskForm, contains('finalizeContactFollowUp'));
    // No heuristic inference: the forms never derive the purpose from a
    // single linked Contact or from title keywords.
    expect(eventForm, isNot(contains('_peopleContactIds.length == 1')));
    expect(taskForm, isNot(contains('_contactIds.length == 1')));
  });
}
