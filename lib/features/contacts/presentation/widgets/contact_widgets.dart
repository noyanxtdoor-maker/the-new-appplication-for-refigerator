import 'package:flutter/material.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/c3_contact_primitives.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

Color colorFromValue(ColorValue value) {
  // The neutral branch IS the ungrouped-contact state, so it resolves through
  // the single canonical source rather than duplicating the literal.
  return value.isNeutral
      ? const Color(ContactUngroupedColor.argb)
      : Color(value.value);
}

/// Neutral circle with initials; the ring/background uses the primary group
/// color when present.
final class ContactAvatar extends StatelessWidget {
  const ContactAvatar({
    required this.summary,
    this.size = 40,
    this.showRing = true,
    super.key,
  });

  final ContactSummary summary;
  final double size;
  final bool showRing;

  @override
  Widget build(BuildContext context) {
    final accent = colorFromValue(summary.colorValue);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.surfaceRaisedOf(context),
        border: showRing
            ? Border.all(color: accent, width: 1.5)
            : Border.all(color: AppTheme.surfaceVariantOf(context), width: 1),
      ),
      alignment: Alignment.center,
      child: Text(
        summary.contact.initials,
        style: TextStyle(
          color: AppTheme.onFillTextOf(context, 1.0),
          fontSize: size * 0.38,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Contact-list identity marker. A favorite replaces its group-color dot with
/// the existing star marker. An ungrouped non-favorite uses the canonical
/// neutral-gray identity dot in the same slot.
final class ContactGroupDot extends StatelessWidget {
  const ContactGroupDot({
    required this.summary,
    this.showFavorite = true,
    super.key,
  });

  final ContactSummary summary;
  final bool showFavorite;

  @override
  Widget build(BuildContext context) {
    if (showFavorite && summary.contact.isFavorite) {
      return SizedBox(
        width: kContactGroupIdentitySlotSize,
        height: kContactGroupIdentitySlotSize,
        child: Center(
          child: Icon(
            Icons.star_rounded,
            size: 25,
            color: colorFromValue(summary.colorValue),
          ),
        ),
      );
    }
    return ContactGroupIdentityDot(colorValue: summary.colorValue);
  }
}

/// Standard list row: favorite star or group dot + name + subtitle + one
/// contextual line (Next Event / Last Event). Minimum 72 dp, up to 3 lines.
final class ContactListRow extends StatelessWidget {
  const ContactListRow({
    required this.summary,
    this.onTap,
    this.displayedFields = ContactDisplayedFieldCodec.defaults,
    this.trailing,
    this.leading,
    this.showContextLine = true,
    this.showTrailing = true,
    this.showFavorite = true,
    this.statusContextLine,
    super.key,
  });

  final ContactSummary summary;
  final VoidCallback? onTap;
  final List<ContactDisplayedField> displayedFields;
  final Widget? leading;
  final Widget? trailing;
  final bool showContextLine;
  final bool showTrailing;
  final bool showFavorite;
  final String? statusContextLine;

  @override
  Widget build(BuildContext context) {
    final subtitle =
        displayedFields.contains(ContactDisplayedField.currentGroup)
        ? summary.subtitle
        : '';
    final contextLines = statusContextLine == null
        ? _contextLines(summary, displayedFields)
        : <String>[statusContextLine!];
    final hasSubtitle = subtitle.isNotEmpty;
    final hasContext = showContextLine && contextLines.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('contact-row-${summary.contact.id}'),
        onTap: onTap,
        onLongPress: onTap == null
            ? null
            : () => showContactLongPressPreview(
                context: context,
                summary: summary,
                onView: onTap!,
              ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: 12),
              ],
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: ContactGroupDot(
                  summary: summary,
                  showFavorite: showFavorite,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      summary.contact.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Roboto',
                        fontSize: 18,
                        height: 22 / 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (hasSubtitle) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.secondaryTextOf(context),
                          fontSize: 14,
                          height: 18 / 14,
                        ),
                      ),
                    ],
                    if (hasContext)
                      for (final line in contextLines) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppTheme.secondaryTextOf(context),
                            fontSize: 14,
                            height: 18 / 14,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                  ],
                ),
              ),
              if (showTrailing && trailing != null) ...<Widget>[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }

  static List<String> _contextLines(
    ContactSummary summary,
    List<ContactDisplayedField> displayedFields,
  ) {
    final lines = <String>[];
    final context = summary.context;
    final next = context.nextEventDate;
    if (displayedFields.contains(ContactDisplayedField.nextEvent) &&
        context.nextEventTitle != null &&
        next != null) {
      lines.add('Next Event Date: ${friendlyContactDate(next)}');
    }
    final last = context.lastEventDate;
    if (displayedFields.contains(ContactDisplayedField.lastEvent) &&
        last != null) {
      lines.add('Last Event Date: ${friendlyContactDate(last)}');
    }
    final lastHappened = context.lastHappenedEventDate;
    if (displayedFields.contains(ContactDisplayedField.lastHappenedEvent) &&
        lastHappened != null) {
      lines.add(
        'Last Happened Event Date: ${friendlyContactDate(lastHappened)}',
      );
    }
    if (displayedFields.contains(ContactDisplayedField.contactMethod)) {
      lines.add(
        'Contact Method: ${_preferredMethodLabel(summary.contact.preferredContactMethod)}',
      );
    }
    if (displayedFields.contains(ContactDisplayedField.address) &&
        summary.contact.addressText?.trim().isNotEmpty == true) {
      lines.add('Address: ${summary.contact.addressText!.trim()}');
    }
    final interaction = summary.latestQualifyingInteractionDate;
    if (displayedFields.contains(ContactDisplayedField.lastInteraction) &&
        interaction != null) {
      lines.add('Last Interaction: ${_relativeDate(interaction)}');
    }
    final lastViewed = summary.contact.lastViewedAtUtc;
    if (displayedFields.contains(ContactDisplayedField.lastViewed) &&
        lastViewed != null) {
      lines.add(
        'Last Viewed: ${friendlyContactDate(PlannerDate.fromDateTime(lastViewed.toLocal()))}',
      );
    }
    if (displayedFields.contains(ContactDisplayedField.createdDate)) {
      lines.add(
        'Created Date: ${friendlyContactDate(PlannerDate.fromDateTime(summary.contact.createdAtUtc.toLocal()))}',
      );
    }
    return lines;
  }

  static String _relativeDate(DateTime value) {
    final days = DateTime.now().toLocal().difference(value.toLocal()).inDays;
    return days <= 0
        ? 'today'
        : days == 1
        ? '1 day ago'
        : '$days days ago';
  }

  static String _preferredMethodLabel(ContactPreferredMethod method) {
    return switch (method) {
      ContactPreferredMethod.message => 'Message',
      ContactPreferredMethod.call => 'Call',
      ContactPreferredMethod.email => 'Email',
    };
  }
}

/// "Today", "Tomorrow", "Yesterday", "Aug 3", "Aug 3, 2025".
String friendlyContactDate(PlannerDate date) {
  final now = DateTime.now();
  final today = PlannerDate.fromDateTime(now);
  if (date == today) {
    return 'Today';
  }
  if (date == today.addDays(1)) {
    return 'Tomorrow';
  }
  if (date == today.addDays(-1)) {
    return 'Yesterday';
  }
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final label = '${months[date.month - 1]} ${date.day}';
  return date.year == today.year ? label : '$label, ${date.year}';
}
