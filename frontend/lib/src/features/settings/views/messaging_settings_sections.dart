import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/clock_time.dart';
import '../../../data/models/messaging_status.dart';
import '../../../data/models/wallet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'wallet_presentation.dart';

/// The SMS balance on the SMS page: what it holds, how many messages that
/// pays for, what one costs, how many went out this month — and the transfer
/// that fills it from the wallet. The company's monthly brake, when it set one
/// for this shop, shows under it as the usual meter.
class MessagingBalanceSection extends StatelessWidget {
  const MessagingBalanceSection({
    super.key,
    required this.smsWallet,
    this.usage,
    this.onAllocate,
  });

  final SmsWallet smsWallet;
  final MessagingUsage? usage;

  /// Opens the transfer from the wallet; null where there is no wallet to
  /// move money from (the button is then left out).
  final VoidCallback? onAllocate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final usage = this.usage;
    final empty = !smsWallet.canSend;

    return PointyDetailSection(
      icon: Icons.account_balance_wallet_outlined,
      title: l10n.messagingBalanceTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            formatWalletMoney(smsWallet.balance),
            style: PointyTypography.numeric(
              (textTheme.headlineMedium ?? const TextStyle()).copyWith(
                fontWeight: FontWeight.w800,
                color: empty ? colors.warning : colors.ink,
              ),
            ),
          ),
          SizedBox(height: spacing.xs),
          Text(
            smsWalletSummary(smsWallet, l10n),
            style: textTheme.bodyMedium?.copyWith(
              color: smsWallet.owed > 0 ? colors.warning : colors.mutedInk,
            ),
          ),
          Text(
            l10n.walletSmsLengthNote,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          if (usage != null) ...[
            SizedBox(height: spacing.xs),
            Text(
              l10n.messagingBalanceSentThisMonth(usage.used),
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
            if (!usage.isUnlimited) ...[
              SizedBox(height: spacing.md),
              MessagingUsageMeter(usage: usage),
            ],
          ],
          if (onAllocate != null) ...[
            SizedBox(height: spacing.md),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonalIcon(
                key: const ValueKey('messaging_allocate'),
                onPressed: onAllocate,
                icon: const Icon(Icons.swap_horiz),
                label: Text(l10n.walletSmsAllocateButton),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

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
