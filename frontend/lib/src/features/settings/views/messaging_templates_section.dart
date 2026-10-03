import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/messaging_status.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'wallet_presentation.dart';

/// Every text Daftar sends, as the shop's customers will read it, under its
/// family — invoices, debts, repair jobs…: what each is for, an example with
/// the shop's own name in it and what that example costs (SMS are paid per
/// part), whether it goes out by itself, and which kinds the provider has not
/// approved yet.
class MessagingTemplatesSection extends StatelessWidget {
  const MessagingTemplatesSection({super.key, required this.sections});

  final List<
    ({MessagingTemplateGroup group, List<MessagingTemplateInfo> templates})
  >
  sections;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return PointyDetailSection(
      icon: Icons.chat_outlined,
      title: l10n.messagingTemplatesTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.messagingTemplatesIntro,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          for (final section in sections) ...[
            if (section.group.title.isNotEmpty) ...[
              SizedBox(height: spacing.lg),
              Text(
                section.group.title,
                key: ValueKey('messaging_template_group_${section.group.key}'),
                style: textTheme.labelLarge?.copyWith(
                  color: colors.primaryStrong,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
            for (final (index, template) in section.templates.indexed) ...[
              if (index > 0 || section.group.title.isEmpty)
                Divider(height: spacing.lg)
              else
                SizedBox(height: spacing.sm),
              _TemplateTile(template: template),
            ],
          ],
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({required this.template});

  final MessagingTemplateInfo template;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final sample = template.example.trim().isNotEmpty
        ? template.example.trim()
        : template.text.trim();
    final autoEnabled = template.autoEnabled ?? false;

    return Column(
      key: ValueKey('messaging_template_${template.kind}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
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
            if (template.automatic)
              PointyStatusPill(
                label: autoEnabled
                    ? l10n.messagingTemplateAutoOn
                    : l10n.messagingTemplateAutoOff,
                icon: autoEnabled ? Icons.bolt : Icons.bolt_outlined,
                color: autoEnabled ? colors.success : colors.mutedInk,
              ),
            if (template.isMarketing)
              PointyStatusPill(
                label: l10n.messagingTemplateMarketingBadge,
                icon: Icons.campaign_outlined,
                color: colors.primaryStrong,
              ),
            if (template.configured == false)
              PointyStatusPill(
                label: l10n.messagingTemplateNotConfigured,
                icon: Icons.hourglass_empty,
                color: colors.warning,
              ),
          ],
        ),
        if (template.description.trim().isNotEmpty) ...[
          SizedBox(height: spacing.xs / 2),
          Text(
            template.description.trim(),
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
        if (sample.isNotEmpty) ...[
          SizedBox(height: spacing.xs),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceSunken,
              borderRadius: BorderRadius.circular(PointyRadii.chip),
              border: Border.all(color: colors.line),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: spacing.md,
                vertical: spacing.sm,
              ),
              child: Text(
                sample,
                textDirection: TextDirection.rtl,
                style: textTheme.bodyMedium?.copyWith(color: colors.ink),
              ),
            ),
          ),
          SizedBox(height: spacing.xs / 2),
          Text(
            messagingExampleCost(template, l10n),
            style: textTheme.labelSmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ],
    );
  }
}

/// What a template's example goes out as, and what that costs from the SMS
/// balance when SMS is sold from one: "هذا المثال: رسالتان بـ 0.30 د.ل".
String messagingExampleCost(
  MessagingTemplateInfo template,
  AppLocalizations l10n,
) {
  final parts = l10n.messagingTemplateParts(template.exampleParts);
  final price = template.examplePrice;
  if (price == null) {
    return l10n.messagingTemplateExampleParts(parts);
  }
  return l10n.messagingTemplateExampleCost(parts, formatWalletMoney(price));
}
