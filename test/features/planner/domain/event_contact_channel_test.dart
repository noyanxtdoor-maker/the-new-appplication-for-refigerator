// P2-A (owner decision 2026-09-21, design D1) — the independent Event contact
// channel contract.
//
// The owner fixed the list to exactly eight choices with exact stable keys and
// exact display labels, and required that a stored value which is absent or not
// one of those keys reads back as UNSET rather than becoming an invented
// channel. This suite pins all three: the eight keys, the eight labels, and the
// honest-unknown behaviour.
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';

void main() {
  group('the eight owner-fixed channels', () {
    test('exactly eight values exist', () {
      expect(EventContactChannel.values, hasLength(8));
    });

    test('stable keys are exactly the owner-listed keys', () {
      expect(
        EventContactChannel.values.map((channel) => channel.stableKey).toList(),
        <String>[
          'in_person',
          'phone_call',
          'text',
          'email',
          'whatsapp',
          'social_media',
          'video_call',
          'other',
        ],
      );
    });

    test('display labels are exactly the owner-listed labels', () {
      expect(
        EventContactChannel.values.map((channel) => channel.label).toList(),
        <String>[
          'In Person',
          'Phone Call',
          'Text',
          'Email',
          'WhatsApp',
          'Social Media',
          'Video Call',
          'Other',
        ],
      );
    });

    test('every key round-trips to its own value', () {
      for (final channel in EventContactChannel.values) {
        expect(
          EventContactChannel.fromStableKey(channel.stableKey),
          channel,
          reason: channel.stableKey,
        );
      }
    });
  });

  group('honest unset state', () {
    test('null and empty resolve to unset', () {
      expect(EventContactChannel.fromStableKey(null), isNull);
      expect(EventContactChannel.fromStableKey(''), isNull);
      expect(EventContactChannel.fromStableKey('   '), isNull);
    });

    test('an unrecognised stored key resolves to unset, never a channel', () {
      // A corrupt/legacy value must NEVER be presented as though the user chose
      // a Contact Type. It reads as "not set" instead of an invented default.
      expect(EventContactChannel.fromStableKey('phone'), isNull);
      expect(EventContactChannel.fromStableKey('PHONE_CALL'), isNull);
      expect(EventContactChannel.fromStableKey('in-person'), isNull);
      expect(EventContactChannel.fromStableKey('whatsApp'), isNull);
    });

    test('surrounding whitespace is tolerated for a real key', () {
      expect(
        EventContactChannel.fromStableKey('  video_call  '),
        EventContactChannel.videoCall,
      );
    });
  });

  test('the channel is not the contact Event Type', () {
    // The contact-flavoured EVENT TYPES are `contact` and
    // `meaningful_connection`. The independent Contact Type must never reuse
    // them: doing so would re-create exactly the mis-wiring P2-A removed, where
    // the Event Type WAS the Contact Type. (`other` exists in both namespaces
    // but lives in a different column, so it is not a conflict.)
    final keys = EventContactChannel.values
        .map((channel) => channel.stableKey)
        .toSet();
    expect(keys, isNot(contains('contact')));
    expect(keys, isNot(contains('meaningful_connection')));
  });
}
