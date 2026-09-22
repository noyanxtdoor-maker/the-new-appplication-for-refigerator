// P2 owner-review corrections (2026-09-22) — Contact Type presentation mapping.
//
// The owner asked for visual cues on the Contact Type presentation, then revised
// the law the same day: there are exactly EIGHT user-facing Contact Types and
// "Not set" is not one of them. A Contact Event that never stored a channel
// presents as In Person, which is also the default for every new Contact Event.
//
// The audit found no emoji convention anywhere in `lib/`: contact/channel
// surfaces are drawn as theme-tinted SVGs with Material icons for ideas that
// have no asset (see `features/contacts/presentation/contact_method_visuals.dart`
// and the Contact Information action row in `contact_detail_screen.dart`). This
// mapper follows that accepted precedent rather than inventing a second visual
// language.
//
// These are the unit-level claims. The widget-level claims (the selector, the
// selected value, the detail row, the In Person default, the NULL convergence
// and the untouched stored key) live in
// `p2_owner_review_corrections_test.dart`; the Unreported marker claims live in
// `unreported_contact_type_icons_test.dart`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/presentation/widgets/event_contact_channel_visuals.dart';

void main() {
  test('the eight owner-approved stable keys and labels are unchanged', () {
    expect(
      <String, String>{
        for (final channel in EventContactChannel.values)
          channel.stableKey: channel.label,
      },
      <String, String>{
        'in_person': 'In Person',
        'phone_call': 'Phone Call',
        'text': 'Text',
        'email': 'Email',
        'whatsapp': 'WhatsApp',
        'social_media': 'Social Media',
        'video_call': 'Video Call',
        'other': 'Other',
      },
      reason:
          'adding a visual cue is presentation only: it must never rename a '
          'stable key or a label',
    );
  });

  test('there are exactly eight user-facing Contact Types and no "Not set"', () {
    expect(EventContactChannel.values, hasLength(8));
    for (final channel in EventContactChannel.values) {
      expect(
        eventContactChannelDisplayLabel(channel),
        channel.label,
        reason: 'the label must come from the channel itself',
      );
    }
    // The owner removed "Not set" completely: it is neither a stored value nor
    // a label any surface may render.
    const Set<String> allowedLabels = <String>{
      'In Person',
      'Phone Call',
      'Text',
      'Email',
      'WhatsApp',
      'Social Media',
      'Video Call',
      'Other',
    };
    for (final channel in EventContactChannel.values) {
      expect(allowedLabels, contains(eventContactChannelDisplayLabel(channel)));
    }
    expect(allowedLabels, isNot(contains('Not set')));
    expect(eventContactChannelDisplayLabel(null), 'In Person');
  });

  test('a never-stored channel is effectively In Person', () {
    expect(
      effectiveEventContactChannel(null),
      EventContactChannel.inPerson,
      reason:
          'a legacy schema-49 NULL row is In Person for every presentation '
          'purpose, and is never labelled "Not set"',
    );
    expect(
      effectiveEventContactChannel(EventContactChannel.videoCall),
      EventContactChannel.videoCall,
      reason: 'a stored channel is never overridden by the default',
    );
    for (final channel in EventContactChannel.values) {
      expect(effectiveEventContactChannel(channel), channel);
    }
  });

  test('every channel resolves to exactly one audited visual source', () {
    // Channels drawn from an asset: two reused Contact Information method
    // assets plus the three owner-supplied SVGs.
    const Map<EventContactChannel, String> withAsset =
        <EventContactChannel, String>{
          EventContactChannel.phoneCall:
              'assets/icons/contacts/social/phone-action.svg',
          EventContactChannel.whatsApp:
              'assets/icons/contacts/social/whatsapp.svg',
          EventContactChannel.socialMedia:
              'assets/icons/contacts/channels/social-media.svg',
          EventContactChannel.videoCall:
              'assets/icons/contacts/channels/video-call.svg',
          EventContactChannel.other: 'assets/icons/contacts/channels/other.svg',
        };

    // Channels drawn from the visual the app already uses for that idea:
    // the generic Contacts/People glyph, the Contact Information message
    // bubble, and the Contact Information envelope.
    const Map<EventContactChannel, IconData> withIcon =
        <EventContactChannel, IconData>{
          EventContactChannel.inPerson: Icons.people_outline,
          EventContactChannel.text: Icons.chat_bubble_outline,
          EventContactChannel.email: Icons.mail_outline,
        };

    expect(
      withAsset.length + withIcon.length,
      EventContactChannel.values.length,
      reason: 'all eight channels must be covered, so no option renders bare',
    );

    withAsset.forEach((channel, asset) {
      expect(eventContactChannelAsset(channel), asset, reason: channel.label);
      expect(
        eventContactChannelIcon(channel),
        isNull,
        reason: '${channel.label} is drawn from its asset, not an icon',
      );
    });
    withIcon.forEach((channel, icon) {
      expect(
        eventContactChannelAsset(channel),
        isNull,
        reason: '${channel.label} has no audited asset',
      );
      expect(eventContactChannelIcon(channel), icon, reason: channel.label);
    });
  });

  testWidgets('every declared channel asset is bundled and loadable', (
    tester,
  ) async {
    // Guards the two failure modes a visual pack can ship with: a mistyped path
    // and an asset directory that was never registered in pubspec.
    for (final channel in EventContactChannel.values) {
      final asset = eventContactChannelAsset(channel);
      if (asset == null) {
        continue;
      }
      final data = await rootBundle.load(asset);
      expect(data.lengthInBytes, greaterThan(0), reason: asset);
    }
  });
}
