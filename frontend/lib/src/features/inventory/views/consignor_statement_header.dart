import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/consignor_statement.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// The top of a consignor's statement: what is owed now, what the period did,
/// how the shop reminds them, and the filters over the lines below.
///
/// Parameter-driven and free of the view model, so a preview or a test can
/// render any state of it directly.
class ConsignorStatementHeader extends StatelessWidget {
  const ConsignorStatementHeader({
    super.key,
    required this.statement,
    required this.filter,
    required this.onFilterChanged,
    required this.onPickPeriod,
    this.period,
    this.onClearPeriod,
    this.onPayAll,
  });

  final ConsignorStatement statement;
  final DateTimeRange? period;
  final ConsignorLineFilter filter;
  final ValueChanged<ConsignorLineFilter> onFilterChanged;
  final VoidCallback onPickPeriod;
  final VoidCallback? onClearPeriod;

  /// Select every awaiting line and pay. Null when nothing waits or the user
  /// may not hand money over.
  final VoidCallback? onPayAll;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final figures = statement.figures;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(statement: statement),
        if (onPayAll != null) ...[
          SizedBox(height: spacing.sm),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: onPayAll,
              icon: const Icon(Icons.payments_outlined),
              label: Text(
                AppLocalizations.of(context)!.consignorStatementPayAll,
              ),
            ),
          ),
        ],
        ..._callouts(context, figures, spacing),
        SizedBox(height: spacing.md),
        _Metrics(figures: figures, hasPeriod: period != null),
        SizedBox(height: spacing.md),
        _Filters(
          period: period,
          filter: filter,
          onFilterChanged: onFilterChanged,
          onPickPeriod: onPickPeriod,
          onClearPeriod: onClearPeriod,
        ),
        SizedBox(height: spacing.sm),
      ],
    );
  }

  List<Widget> _callouts(
    BuildContext context,
    ConsignorStatementFigures figures,
    AdaptiveSpacing spacing,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final reminders = statement.reminders;
    final showReminders = figures.awaitingCount > 0 || reminders.lastAt != null;
    return [
      // The debt that runs the other way, said beside the payable and never
      // netted into it.
      if (figures.receivable > 0) ...[
        SizedBox(height: spacing.md),
        PointyDetailCallout(
          icon: Icons.undo_outlined,
          tone: PointyCalloutTone.warning,
          title: l10n.consignorStatementReceivableTitle(
            formatMoney(figures.receivable),
          ),
          message: l10n.consignorStatementReceivableBody,
        ),
      ],
      if (figures.claimsOpen > 0 || figures.claimsUnassessed > 0) ...[
        SizedBox(height: spacing.md),
        PointyDetailCallout(
          icon: Icons.report_gmailerrorred_outlined,
          tone: PointyCalloutTone.danger,
          title: l10n.consignorStatementClaimsTitle(
            formatMoney(figures.claimsOpen),
          ),
          message: figures.claimsUnassessed > 0
              ? l10n.custodyIncidentUnassessedCount(figures.claimsUnassessed)
              : null,
        ),
      ],
      if (showReminders) ...[
        SizedBox(height: spacing.md),
        PointyDetailCallout(
          icon: reminders.enabled
              ? Icons.alarm_on_outlined
              : Icons.alarm_off_outlined,
          tone: reminders.enabled
              ? PointyCalloutTone.primary
              : PointyCalloutTone.neutral,
          title: l10n.consignorStatementRemindersTitle,
          message: [
            reminders.enabled
                ? l10n.consignorStatementRemindersOn(
                    reminders.everyDays,
                    reminders.maxRounds,
                  )
                : l10n.consignorStatementRemindersOff,
            reminders.lastAt == null
                ? l10n.consignorStatementNeverReminded
                : l10n.consignorStatementLastReminder(
                    formatDate(reminders.lastAt!),
                  ),
            // Said on the page, not only in a plan: an unclaimed payout is
            // somebody else's money however long it waits (§17.8).
            l10n.consignorStatementMoneyStaysTheirs,
          ].join('\n'),
        ),
      ],
    ];
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.statement});

  final ConsignorStatement statement;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final figures = statement.figures;
    final oldest = figures.oldestAwaitingDays;
    final phone = statement.consignorPhone.trim();
    return PointyDetailHero(
      icon: Icons.handshake_outlined,
      title: statement.consignorName.isEmpty
          ? l10n.consignorStatementTitle
          : statement.consignorName,
      value: formatMoney(figures.payable),
      valueSubtitle: figures.payable > 0
          ? l10n.consignorStatementOwedNow
          : l10n.consignorStatementNothingOwed,
      description: phone.isEmpty ? null : ltrIsolated(phone),
      pills: [
        PointyHeroPill(
          label: l10n.consignorStatementPillHeld(figures.heldCount),
          icon: Icons.inventory_2_outlined,
        ),
        PointyHeroPill(
          label: l10n.consignorStatementPillAwaiting(figures.awaitingCount),
          icon: Icons.hourglass_bottom_outlined,
        ),
        if (figures.agreementCount > 0)
          PointyHeroPill(
            label: l10n.consignorStatementPillAgreements(
              figures.agreementCount,
            ),
            icon: Icons.description_outlined,
          ),
        if (oldest != null)
          PointyHeroPill(
            label: l10n.consignorStatementOldestWaiting(
              l10n.consignmentWaitingDays(oldest),
            ),
            icon: Icons.schedule_outlined,
          ),
        if (statement.doNotContact)
          PointyHeroPill(
            label: l10n.consignorStatementDoNotContact,
            icon: Icons.speaker_notes_off_outlined,
          ),
      ],
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.figures, required this.hasPeriod});

  final ConsignorStatementFigures figures;
  final bool hasPeriod;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final commission = figures.shopCommission;
    return PointyMetricGrid(
      maxColumns: 4,
      minTileWidth: 170,
      gap: PointyMetricGridGap.compact,
      metrics: [
        PointyMetricGridItem(
          label: hasPeriod
              ? l10n.consignorStatementSoldInPeriod
              : l10n.consignorStatementSoldAll,
          value: '${figures.periodSoldCount}',
          subtitle: formatMoney(figures.periodSoldValue),
          icon: Icons.sell_outlined,
        ),
        PointyMetricGridItem(
          label: hasPeriod
              ? l10n.consignorStatementPaidInPeriod
              : l10n.consignorStatementPaidAll,
          value: formatMoney(figures.periodPaidTotal),
          subtitle: l10n.consignorStatementPayoutCount(
            figures.periodPayoutCount,
          ),
          icon: Icons.payments_outlined,
          accentColor: colors.success,
        ),
        PointyMetricGridItem(
          label: l10n.consignmentFigureCustody,
          value: '${figures.heldCount}',
          subtitle: formatMoney(figures.heldDeclaredValue),
          icon: Icons.inventory_2_outlined,
          accentColor: colors.primaryStrong,
        ),
        if (commission != null)
          PointyMetricGridItem(
            label: l10n.consignmentFigureCommission,
            value: formatMoney(commission),
            icon: Icons.trending_up,
          ),
      ],
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.period,
    required this.filter,
    required this.onFilterChanged,
    required this.onPickPeriod,
    required this.onClearPeriod,
  });

  final DateTimeRange? period;
  final ConsignorLineFilter filter;
  final ValueChanged<ConsignorLineFilter> onFilterChanged;
  final VoidCallback onPickPeriod;
  final VoidCallback? onClearPeriod;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final range = period;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.consignorStatementLinesTitle,
              style: theme.textTheme.titleMedium,
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: onPickPeriod,
              icon: const Icon(Icons.date_range_outlined, size: 18),
              label: Text(
                range == null
                    ? l10n.consignorStatementPeriodAll
                    : l10n.consignorStatementPeriodRange(
                        formatDate(range.start),
                        formatDate(range.end),
                      ),
              ),
            ),
            if (range != null && onClearPeriod != null)
              IconButton(
                tooltip: l10n.consignorStatementPeriodClear,
                onPressed: onClearPeriod,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        if (range != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.consignorStatementPeriodHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final option in ConsignorLineFilter.values)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ChoiceChip(
                    label: Text(_filterLabel(l10n, option)),
                    selected: option == filter,
                    onSelected: (_) => onFilterChanged(option),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String _filterLabel(AppLocalizations l10n, ConsignorLineFilter filter) {
  return switch (filter) {
    ConsignorLineFilter.all => l10n.consignorLineFilterAll,
    ConsignorLineFilter.awaiting => l10n.consignorLineFilterAwaiting,
    ConsignorLineFilter.held => l10n.consignorLineFilterHeld,
    ConsignorLineFilter.paid => l10n.consignorLineFilterPaid,
    ConsignorLineFilter.closed => l10n.consignorLineFilterClosed,
  };
}
