import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_top_bar_icons.dart';

const double kContactGroupIdentitySlotSize = 40;

final class ContactGroupIdentityDot extends StatelessWidget {
  const ContactGroupIdentityDot({required this.colorValue, super.key});

  final ColorValue colorValue;

  @override
  Widget build(BuildContext context) {
    // The ungrouped state resolves through one domain constant so this dot can
    // never disagree with the Contact detail surfaces about "no group".
    final color = colorValue.isNeutral
        ? const Color(ContactUngroupedColor.argb)
        : Color(colorValue.value);
    return SizedBox(
      width: kContactGroupIdentitySlotSize,
      height: kContactGroupIdentitySlotSize,
      child: Center(
        child: Container(
          width: 19,
          height: 19,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
      ),
    );
  }
}

final class QuickFilterChip extends StatelessWidget {
  const QuickFilterChip({
    required this.label,
    required this.summary,
    required this.onPressed,
    this.active = false,
    super.key,
  });

  final String label;
  final String summary;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(7);
    return SizedBox(
      height: 48,
      child: IntrinsicWidth(
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: radius),
          child: InkWell(
            onTap: onPressed,
            borderRadius: radius,
            child: Center(
              child: Container(
                key: Key('quick-filter-chip-body-$label'),
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: active
                      ? scheme.primary.withValues(alpha: .12)
                      : Colors.transparent,
                  border: Border.all(
                    color: active
                        ? scheme.primary
                        : AppTheme.outlineOf(context),
                  ),
                  borderRadius: radius,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      active ? '$label: $summary' : label,
                      style: TextStyle(
                        color: active
                            ? scheme.primary
                            : AppTheme.onFillTextOf(context, 1),
                        fontSize: 13,
                        fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 16,
                      color: active
                          ? scheme.primary
                          : AppTheme.secondaryTextOf(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact quick-state reset affordance. It is intentionally distinct from
/// FilterPlusIcon, whose only job remains opening the full Filter Builder.
final class QuickFilterResetButton extends StatelessWidget {
  const QuickFilterResetButton({
    required this.active,
    required this.onPressed,
    super.key,
  });

  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurface;
    return IconButton(
      key: const Key('contacts-quick-filter-reset'),
      tooltip: 'Reset quick filters',
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: PlannerFilterIcon(color: color),
    );
  }
}

/// Contacts Filter action glyph supplied by the owner as an SVG asset.
/// The AppBar keeps its existing 48 dp action cell; the asset is optically
/// compact so Contacts retains a calm, accessible four-action top bar.
final class FilterPlusIcon extends StatelessWidget {
  const FilterPlusIcon({required this.color, this.size = 25, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.asset(
        'assets/icons/filter-svgrepo-com.svg',
        key: const Key('filter-plus-glyph'),
        fit: BoxFit.contain,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      ),
    );
  }
}

/// The accepted two-line Contacts/Maps header selector.  The selected view is
/// owned by the caller; this widget owns only the shared typography, spacing,
/// chevron, and semantics.
final class ContactViewSelectorButton extends StatelessWidget {
  const ContactViewSelectorButton({
    required this.onTap,
    required this.isFiltered,
    required this.expanded,
    this.standardView,
    this.appliedFilter,
    super.key,
  });

  final VoidCallback onTap;
  final bool isFiltered;
  final bool expanded;
  final ContactStandardView? standardView;
  final SavedContactFilter? appliedFilter;

  String get label => isFiltered
      ? 'Filtered'
      : standardView?.label ?? appliedFilter?.name ?? 'All Contacts';

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(top: 1, bottom: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.secondaryTextOf(context),
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 20,
              color: AppTheme.secondaryTextOf(context),
            ),
          ],
        ),
      ),
    );
  }
}

final class TriStateMasterCheckbox extends StatelessWidget {
  const TriStateMasterCheckbox({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: Checkbox(tristate: true, value: value, onChanged: onChanged),
      ),
    );
  }
}

final class FullWidthSectionDivider extends StatelessWidget {
  const FullWidthSectionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 8,
      width: double.infinity,
      color: AppTheme.sectionDividerOf(context),
    );
  }
}

/// Major edge-to-edge section band that separates the sort block from the
/// category table and the category table from the lower event toggles.
/// Slightly thicker than a row divider using the SAME neutral section-divider
/// family as the Filter's other structural dividers (never Theme Color).
final class MajorSectionBand extends StatelessWidget {
  const MajorSectionBand({super.key, this.height = 12});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      color: AppTheme.sectionDividerOf(context),
    );
  }
}

final class PmgStyleSortField extends StatelessWidget {
  const PmgStyleSortField({
    required this.value,
    required this.onTap,
    this.labelText = 'Contact List Sort',
    this.anchorKey,
    super.key,
  });

  final String value;
  final VoidCallback onTap;
  final String labelText;
  final GlobalKey? anchorKey;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(4),
      borderSide: BorderSide(color: AppTheme.outlineOf(context), width: 1),
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: SizedBox(
          key: anchorKey,
          height: 52,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: labelText,
              suffixIcon: const Icon(Icons.arrow_drop_down, size: 24),
              filled: true,
              fillColor: Colors.transparent,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              labelStyle: AppTypography.micro,
              floatingLabelStyle: AppTypography.micro,
              border: border,
              enabledBorder: border,
              focusedBorder: border,
            ),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.body.copyWith(
                color: AppTheme.onFillTextOf(context, 1.0),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showContactLongPressPreview({
  required BuildContext context,
  required ContactSummary summary,
  required VoidCallback onView,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) =>
        _ContactLongPressPreviewSheet(summary: summary, onView: onView),
  );
}

final class _ContactLongPressPreviewSheet extends StatelessWidget {
  const _ContactLongPressPreviewSheet({
    required this.summary,
    required this.onView,
  });

  final ContactSummary summary;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final address = summary.contact.addressText?.trim();
    final hasAddress = address != null && address.isNotEmpty;
    return Material(
      key: const Key('contact-long-press-preview'),
      color: AppTheme.surfaceOf(context),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 210),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  key: const Key('contact-preview-handle'),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.outlineOf(context),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      summary.contact.displayName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('contact-preview-view'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      onView();
                    },
                    child: const Text('View'),
                  ),
                ],
              ),
              const Divider(height: 24),
              if (hasAddress)
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Address',
                            style: TextStyle(
                              color: AppTheme.secondaryTextOf(context),
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(address),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('contact-preview-map'),
                      tooltip: 'Map',
                      onPressed: () => ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Open the contact profile to manage its map pin.',
                            ),
                          ),
                        ),
                      icon: const Icon(Icons.location_on_outlined),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
