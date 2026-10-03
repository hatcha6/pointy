import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/messaging_status.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'messaging_templates_section.dart';

/// The texts that go out by themselves when their event happens — a job ready
/// for pickup, a payment taken — each with its switch. Every one is paid from
/// the SMS balance, so the owner decides which go out; the switch saves at
/// once.
class MessagingAutoMessagesSection extends StatelessWidget {
  const MessagingAutoMessagesSection({
    super.key,
    required this.templates,
    required this.onChanged,
    required this.isSaving,
    this.enabled = true,
  });

  final List<MessagingTemplateInfo> templates;
  final void Function(String kind, bool enabled) onChanged;
  final bool Function(String kind) isSaving;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return PointyDetailSection(
      icon: Icons.bolt_outlined,
      title: l10n.messagingAutoTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.messagingAutoIntro,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          for (final template in templates) ...[
            Divider(height: spacing.lg),
            SwitchListTile(
              key: ValueKey('messaging_auto_${template.kind}'),
              contentPadding: EdgeInsets.zero,
              value: template.autoEnabled ?? false,
              onChanged: enabled && !isSaving(template.kind)
                  ? (value) => onChanged(template.kind, value)
                  : null,
              title: Wrap(
                spacing: spacing.xs,
                runSpacing: spacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    template.title,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (template.configured == false)
                    PointyStatusPill(
                      label: l10n.messagingTemplateNotConfigured,
                      icon: Icons.hourglass_empty,
                      color: colors.warning,
                    ),
                ],
              ),
              subtitle: Text(
                [
                  if (template.autoLabel.trim().isNotEmpty)
                    template.autoLabel.trim(),
                  messagingExampleCost(template, l10n),
                ].join('\n'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
