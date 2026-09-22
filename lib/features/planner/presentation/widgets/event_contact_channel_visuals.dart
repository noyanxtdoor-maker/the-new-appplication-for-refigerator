import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';

/// The ONE presentation source for the Event Contact Type.
///
/// Owner law (2026-09-22 revision): there are exactly EIGHT user-facing Contact
/// Types and "Not set" is not one of them. A Contact Event that never stored a
/// channel (a legacy schema-49 NULL row) presents as **In Person**, which is also
/// the default for every new Contact Event.
///
/// This mapper owns only the two presentation concerns — the display LABEL and
/// the icon/asset — and is shared by the Contact Type selector, the selected
/// value in the Event form, the Event detail row and the Unreported > Contacts
/// marker, so one channel can never render two different ways. It owns no
/// persistence, no schema and no Event Type or reporting logic: every value it
/// renders is derived FROM the channel it is given.
///
/// Visual sources, audited against the existing app language (there is no emoji
/// convention anywhere in `lib/`; contact surfaces are tinted SVGs with
/// Material icons for the ideas that have no asset):
///   * In Person — the generic Contacts/People glyph the Contacts surfaces
///     already use;
///   * Phone Call / WhatsApp — the canonical Contact Information method assets
///     (`contact_method_visuals.dart`);
///   * Text / Email — the existing Contact Information action visuals
///     (`contact_detail_screen.dart`: a message bubble and an envelope);
///   * Social Media / Video Call / Other — the three owner-supplied SVGs.
const Map<EventContactChannel, String> _channelAssets =
    <EventContactChannel, String>{
      EventContactChannel.phoneCall:
          'assets/icons/contacts/social/phone-action.svg',
      EventContactChannel.whatsApp: 'assets/icons/contacts/social/whatsapp.svg',
      EventContactChannel.socialMedia:
          'assets/icons/contacts/channels/social-media.svg',
      EventContactChannel.videoCall:
          'assets/icons/contacts/channels/video-call.svg',
      EventContactChannel.other: 'assets/icons/contacts/channels/other.svg',
    };

/// The channels drawn from a Material icon instead of an asset.
const Map<EventContactChannel, IconData> _channelIcons =
    <EventContactChannel, IconData>{
      EventContactChannel.inPerson: Icons.people_outline,
      EventContactChannel.text: Icons.chat_bubble_outline,
      EventContactChannel.email: Icons.mail_outline,
    };

/// The EFFECTIVE channel: a channel that was never stored is In Person.
///
/// This is the only place the owner's "legacy NULL presents as In Person" rule
/// is expressed, so every surface inherits it rather than re-deriving it.
EventContactChannel effectiveEventContactChannel(
  EventContactChannel? channel,
) => channel ?? EventContactChannel.inPerson;

/// The one user-facing Contact Type label. It never returns "Not set", because
/// there is no such Contact Type.
String eventContactChannelDisplayLabel(EventContactChannel? channel) =>
    effectiveEventContactChannel(channel).label;

/// The SVG asset for [channel], or `null` when the channel uses the icon
/// fallback.
String? eventContactChannelAsset(EventContactChannel channel) =>
    _channelAssets[channel];

/// The icon for [channel], or `null` when the channel is drawn from its asset
/// instead.
IconData? eventContactChannelIcon(EventContactChannel channel) =>
    _channelIcons[channel];

/// The single rendering entry point for every Contact Type surface.
///
/// [key] is applied to whichever widget ends up being built, so a caller's
/// landmark identifies the marker regardless of which channel it is showing.
/// The visual is purely presentational: it never carries or infers a value.
Widget eventContactChannelVisual({
  Key? key,
  required EventContactChannel? channel,
  required Color color,
  double size = 20,
}) {
  final effective = effectiveEventContactChannel(channel);
  final asset = eventContactChannelAsset(effective);
  if (asset != null) {
    return SvgPicture.asset(
      asset,
      key: key,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
  return Icon(
    eventContactChannelIcon(effective),
    key: key,
    color: color,
    size: size,
  );
}
