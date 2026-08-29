import 'package:flutter/material.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/c3_contact_primitives.dart';
import 'package:rmplanner/features/contacts/presentation/widgets/contact_widgets.dart';

/// Keeps phone Preview sheets comfortable at tablet widths without creating a
/// separate desktop layout. The same constraint applies to Event and Task.
const double kPlannerPreviewSheetMaxWidth = 720;

/// The shared modal surface for Planner Event-family previews.
///
/// It owns the handle, header geometry, close affordance, divider, and scroll
/// boundary. Event and Task callers supply only their factual title, actions,
/// and body; neither domain may recreate a visually similar shell.
final class SharedPlannerPreviewSheet extends StatelessWidget {
  const SharedPlannerPreviewSheet({
    required this.title,
    required this.closeTooltip,
    required this.onClose,
    required this.actions,
    required this.child,
    this.closeKey = const Key('planner-preview-sheet-close'),
    super.key,
  });

  final String title;
  final String closeTooltip;
  final VoidCallback onClose;
  final List<Widget> actions;
  final Widget child;
  final Key closeKey;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          const SizedBox(height: 8),
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white30,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
            child: Row(
              children: <Widget>[
                IconButton(
                  key: closeKey,
                  tooltip: closeTooltip,
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: 20,
                      height: 26 / 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Domain-neutral Event-family detail row.
///
/// The row accepts only already-resolved presentation facts so Calendar Event
/// and Task Preview can share the approved visual language without coupling
/// their domains, persistence, reporting, or navigation ownership.
final class PlannerDetailRow extends StatelessWidget {
  const PlannerDetailRow({required this.icon, required this.label, super.key});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

/// Domain-neutral Event-family labelled detail field.
///
/// This is intentionally presentation-only. Callers decide which factual
/// Task or Event data are legitimate to show and must not fabricate a map,
/// contact, Event Type, or reporting relationship for another domain.
final class PlannerDetailField extends StatelessWidget {
  const PlannerDetailField({
    required this.icon,
    required this.label,
    required this.value,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: AppTheme.detailCaptionOf(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(value),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The canonical Contacts identity marker and label treatment in Event-family
/// previews. It delegates shape, color, and favorite semantics to the same
/// canonical Contacts marker used by the Contacts list. Missing historical
/// contact records retain only the canonical neutral fallback.
final class PlannerPreviewContactRow extends StatelessWidget {
  const PlannerPreviewContactRow({
    required this.name,
    this.contact,
    super.key,
  });

  final String name;
  final ContactSummary? contact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          contact == null
              ? const ContactGroupIdentityDot(colorValue: ColorValue.neutral())
              : ContactGroupDot(summary: contact!),
          const SizedBox(width: 4),
          Expanded(child: Text(name)),
        ],
      ),
    );
  }
}

/// Domain-neutral row used by the shared anchored Preview More menu.
final class PlannerPreviewOverflowItem extends StatelessWidget {
  const PlannerPreviewOverflowItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: <Widget>[
              Icon(icon, color: color),
              const SizedBox(width: 14),
              Text(label, style: TextStyle(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}
