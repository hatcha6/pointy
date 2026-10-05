import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/consignor_statement.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// One article on a consignor's statement.
///
/// Status is said in words as well as colour, the amount on the trailing edge
/// is what the line means *now* — owed, paid, or only an estimate — and an
/// awaiting line can be picked for a payout when [onToggle] is given.
class ConsignorStatementLineTile extends StatelessWidget {
  const ConsignorStatementLineTile({
    super.key,
    required this.line,
    this.reminderRounds = 3,
    this.isSelected = false,
    this.onToggle,
    this.onResendSms,
  });

  final ConsignorStatementLine line;
  final int reminderRounds;
  final bool isSelected;
  final VoidCallback? onToggle;
  final VoidCallback? onResendSms;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final tone = _tone(colors, line.state);
    final selectable = onToggle != null && line.isAwaiting;

    return Material(
      color: isSelected ? colors.primaryContainer : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        side: BorderSide(
          color: isSelected ? colors.primaryStrong : colors.line,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: selectable ? onToggle : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Leading(
                state: line.state,
                tone: tone,
                selectable: selectable,
                isSelected: isSelected,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.productName.isEmpty ? line.code : line.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        ltrIsolated(line.code),
                        if (line.agreementNumber.isNotEmpty)
                          l10n.consignorLineAgreement(
                            ltrIsolated(line.agreementNumber),
                          ),
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        PointyStatusPill(
                          label: stateLabel(l10n, line.state),
                          color: tone,
                        ),
                        ..._facts(context, l10n),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Amount(line: line, tone: tone),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _facts(BuildContext context, AppLocalizations l10n) {
    final colors = context.pointyColors;
    final reminder = line.lastReminder;
    final when = line.activityAt;
    return [
      if (when != null)
        _Fact(
          icon: Icons.event_outlined,
          label: switch (line.state) {
            ConsignorLineState.awaiting => l10n.consignorLineSoldOn(
              formatDate(when),
            ),
            ConsignorLineState.paid => l10n.consignorLinePaidOn(
              formatDate(when),
            ),
            ConsignorLineState.held => l10n.consignorLineReceivedOn(
              formatDate(when),
            ),
            _ => formatDate(when),
          },
        ),
      if (line.invoiceNumber.isNotEmpty)
        _Fact(
          icon: Icons.receipt_long_outlined,
          label: ltrIsolated(line.invoiceNumber),
        ),
      if (line.payoutNumber.isNotEmpty && line.state == ConsignorLineState.paid)
        _Fact(
          icon: Icons.request_quote_outlined,
          label: ltrIsolated(line.payoutNumber),
        ),
      if (line.daysWaiting != null)
        _Fact(
          icon: Icons.hourglass_bottom_outlined,
          label: l10n.consignmentWaitingDays(line.daysWaiting!),
          tone: line.daysWaiting! >= 30 ? colors.warning : null,
        ),
      if (line.soldOnCredit && line.isAwaiting)
        _Fact(
          icon: Icons.schedule_outlined,
          label: l10n.consignorLineSoldOnCredit,
          tone: colors.danger,
        ),
      if (line.advance > 0)
        _Fact(
          icon: Icons.history_outlined,
          label: l10n.consignmentAdvanceChip(formatMoney(line.advance)),
        ),
      if (reminder != null && line.isAwaiting)
        _Fact(
          icon: reminder.failed
              ? Icons.sms_failed_outlined
              : Icons.notifications_active_outlined,
          label: reminder.failed
              ? l10n.consignorLineReminderFailed(formatDate(reminder.sentAt))
              : l10n.consignorLineReminded(
                  formatDate(reminder.sentAt),
                  reminder.round,
                  reminderRounds,
                ),
          tone: reminder.failed ? colors.danger : colors.primaryStrong,
        ),
      if (onResendSms != null && line.isAwaiting)
        SizedBox(
          height: 32,
          child: TextButton.icon(
            onPressed: onResendSms,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.sms_outlined, size: 16),
            label: Text(l10n.consignmentResendSms),
          ),
        ),
    ];
  }
}

/// The status word for a line, shared with anything else that lists them.
String stateLabel(AppLocalizations l10n, String state) {
  return switch (state) {
    ConsignorLineState.awaiting => l10n.consignorLineFilterAwaiting,
    ConsignorLineState.held => l10n.consignorLineFilterHeld,
    ConsignorLineState.paid => l10n.consignorLineFilterPaid,
    ConsignorLineState.returned => l10n.consignorLineStateReturned,
    _ => l10n.consignorLineStateLost,
  };
}

Color _tone(PointySemanticColors colors, String state) {
  return switch (state) {
    ConsignorLineState.awaiting => colors.warning,
    ConsignorLineState.held => colors.primaryStrong,
    ConsignorLineState.paid => colors.success,
    ConsignorLineState.returned => colors.mutedInk,
    _ => colors.danger,
  };
}

class _Leading extends StatelessWidget {
  const _Leading({
    required this.state,
    required this.tone,
    required this.selectable,
    required this.isSelected,
  });

  final String state;
  final Color tone;
  final bool selectable;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    if (selectable) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 24,
          color: isSelected ? colors.primaryStrong : colors.mutedInk,
        ),
      );
    }
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: 0.12), colors.surface),
        shape: BoxShape.circle,
      ),
      child: Icon(_icon(state), size: 20, color: tone),
    );
  }

  static IconData _icon(String state) {
    return switch (state) {
      ConsignorLineState.awaiting => Icons.payments_outlined,
      ConsignorLineState.held => Icons.inventory_2_outlined,
      ConsignorLineState.paid => Icons.check_circle_outline,
      ConsignorLineState.returned => Icons.undo_outlined,
      _ => Icons.report_gmailerrorred_outlined,
    };
  }
}

class _Amount extends StatelessWidget {
  const _Amount({required this.line, required this.tone});

  final ConsignorStatementLine line;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final (amount, caption, color) = switch (line.state) {
      ConsignorLineState.awaiting => (
        line.netDue,
        line.advance > 0
            ? l10n.consignmentGrossPayout(formatMoney(line.payoutDue))
            : null,
        colors.primaryStrong,
      ),
      ConsignorLineState.paid => (line.payoutDue, null, colors.ink),
      ConsignorLineState.held => (
        line.payoutDue,
        l10n.consignorLineEstimate,
        colors.mutedInk,
      ),
      _ => (line.declaredValue, l10n.consignorLineDeclared, colors.mutedInk),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 88),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            amount == null ? '—' : formatMoney(amount),
            style: PointyTypography.numeric(
              (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
                color: color,
              ),
            ),
          ),
          if (caption != null)
            Text(
              caption,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, this.tone});

  final IconData icon;
  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone ?? context.pointyColors.mutedInk;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: color)),
      ],
    );
  }
}
