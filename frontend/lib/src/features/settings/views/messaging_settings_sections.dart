import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/clock_time.dart';
import '../../../data/models/messaging_status.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// This month's sends against the cap: used / limit, a bar that warns as it
/// fills, what is left and when it resets. An unlimited plan shows the count
/// alone. Reads like the AI usage bars on the subscription page.
class MessagingUsageMeter extends StatelessWidget {
  const MessagingUsageMeter({super.key, required this.usage});

  final MessagingUsage usage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final unlimited = usage.isUnlimited;
    final color = usage.isExhausted
        ? colors.danger
        : (usage.fraction >= 0.8 ? colors.warning : colors.primary);
    final resetsAt = usage.resetsAt;
    final captions = [
      if (!unlimited) l10n.messagingUsageRemaining(usage.remaining),
      if (resetsAt != null) l10n.messagingUsageResets(formatDate(resetsAt)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.messagingUsageSentLabel,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              unlimited
                  ? l10n.messagingUsageUnlimited(usage.used)
                  : l10n.messagingUsageUsedOfLimit(usage.used, usage.limit),
              style: PointyTypography.numeric(
                (textTheme.titleSmall ?? const TextStyle()).copyWith(
                  fontWeight: FontWeight.w700,
                  color: usage.isExhausted ? colors.danger : colors.ink,
                ),
              ),
            ),
          ],
        ),
        if (!unlimited) ...[
          SizedBox(height: spacing.xs),
          PointyProgressBar(
            value: usage.fraction,
            minHeight: 7,
            borderRadius: BorderRadius.circular(6),
            backgroundColor: colors.line,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ],
        if (captions.isNotEmpty) ...[
          SizedBox(height: spacing.xs),
          Text(
            captions.join(' · '),
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ],
    );
  }
}

/// The quiet-hours window for promotions: a start and an end picked on a
/// 24-hour clock, and one action that clears both. Says why the pair is not
/// saveable instead of just greying the save button out.
class MessagingQuietHoursField extends StatelessWidget {
  const MessagingQuietHoursField({
    super.key,
    required this.start,
    required this.end,
    required this.hasIssue,
    required this.onStartChanged,
    required this.onEndChanged,
    required this.onClear,
    this.enabled = true,
  });

  final ClockTime? start;
  final ClockTime? end;
  final bool hasIssue;
  final ValueChanged<ClockTime> onStartChanged;
  final ValueChanged<ClockTime> onEndChanged;
  final VoidCallback onClear;
  final bool enabled;

  Future<void> _pick(
    BuildContext context,
    ClockTime? current,
    ClockTime fallback,
    ValueChanged<ClockTime> onPicked,
  ) async {
    final initial = current ?? fallback;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (picked != null) {
      onPicked(ClockTime(picked.hour, picked.minute));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final start = this.start;
    final end = this.end;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.messagingQuietHoursLabel, style: textTheme.titleSmall),
        SizedBox(height: spacing.xs),
        Wrap(
          spacing: spacing.sm,
          runSpacing: spacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('messaging_quiet_start'),
              onPressed: enabled
                  ? () => _pick(
                      context,
                      start,
                      const ClockTime(22, 0),
                      onStartChanged,
                    )
                  : null,
              icon: const Icon(Icons.bedtime_outlined, size: 18),
              label: Text(
                start == null
                    ? l10n.messagingQuietHoursPickStart
                    : l10n.messagingQuietHoursFrom(start.label),
              ),
            ),
            OutlinedButton.icon(
              key: const ValueKey('messaging_quiet_end'),
              onPressed: enabled
                  ? () =>
                        _pick(context, end, const ClockTime(8, 0), onEndChanged)
                  : null,
              icon: const Icon(Icons.wb_sunny_outlined, size: 18),
              label: Text(
                end == null
                    ? l10n.messagingQuietHoursPickEnd
                    : l10n.messagingQuietHoursTo(end.label),
              ),
            ),
            if (start != null || end != null)
              TextButton.icon(
                onPressed: enabled ? onClear : null,
                icon: const Icon(Icons.close, size: 18),
                label: Text(l10n.messagingQuietHoursClear),
              ),
          ],
        ),
        SizedBox(height: spacing.xs),
        Text(
          hasIssue
              ? l10n.messagingQuietHoursInvalid
              : l10n.messagingQuietHoursHelper,
          style: textTheme.bodySmall?.copyWith(
            color: hasIssue ? colors.danger : colors.mutedInk,
          ),
        ),
      ],
    );
  }
}

/// Every text Daftar sends a customer, as the shop's customers will read it:
/// what each is for, and an example with the shop's own name in it. Tells the
/// shop exactly what goes out under its name — and which kinds the provider
/// has not approved yet.
class MessagingTemplatesSection extends StatelessWidget {
  const MessagingTemplatesSection({super.key, required this.templates});

  final List<MessagingTemplateInfo> templates;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return PointyDetailSection(
      icon: Icons.chat_outlined,
      title: l10n.messagingTemplatesTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.messagingTemplatesIntro,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          for (final template in templates) ...[
            Divider(height: spacing.lg),
            _TemplateTile(template: template),
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

    return Column(
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
        ],
      ],
    );
  }
}
