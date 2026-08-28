import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/money_position_view_model.dart';
import 'money_count_sheet.dart';
import 'money_transfer_sheet.dart';
import 'treasury_ui.dart';

/// Opens the account drill-down: the balance, the arithmetic that produced it,
/// and the individual events behind that arithmetic.
Future<void> showMoneyAccountDetailsSheet(
  BuildContext context, {
  required MoneyPositionViewModel viewModel,
  required int accountId,
}) {
  viewModel.loadMovements(accountId);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) =>
        _MoneyAccountDetailsSheet(viewModel: viewModel, accountId: accountId),
  );
}

class _MoneyAccountDetailsSheet extends StatelessWidget {
  const _MoneyAccountDetailsSheet({
    required this.viewModel,
    required this.accountId,
  });

  final MoneyPositionViewModel viewModel;
  final int accountId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final entry = viewModel.accountById(accountId);
        if (entry == null) {
          return const SizedBox.shrink();
        }
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return ListView(
              controller: scrollController,
              padding: EdgeInsets.all(spacing.md),
              children: [
                _Header(entry: entry),
                SizedBox(height: spacing.md),
                _Actions(viewModel: viewModel, entry: entry),
                SizedBox(height: spacing.lg),
                if (entry.lastCount != null) ...[
                  _LastCountCallout(count: entry.lastCount!),
                  SizedBox(height: spacing.lg),
                ],
                PointySectionHeader(title: l10n.treasuryBreakdownTitle),
                SizedBox(height: spacing.sm),
                _Breakdown(entry: entry),
                if (entry.account.isCash) ...[
                  SizedBox(height: spacing.sm),
                  _AssumptionNote(text: l10n.treasuryPayrollAssumptionNote),
                ],
                SizedBox(height: spacing.lg),
                PointySectionHeader(title: l10n.treasuryMovementsTitle),
                SizedBox(height: spacing.sm),
                _Movements(viewModel: viewModel, accountId: accountId),
                SizedBox(height: spacing.lg),
              ],
            );
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entry});

  final MoneyAccountPosition entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final account = entry.account;
    final openingAt = account.openingAt;

    return PointyDetailHero(
      icon: treasuryAccountIcon(account),
      title: account.name,
      value: formatMoney(entry.expectedBalance),
      valueSubtitle: l10n.treasuryExpectedLabel,
      description: account.bankName == account.name ? null : account.bankName,
      pills: [
        if (account.isRouted)
          PointyHeroPill(
            label: l10n.treasuryRoutedHint,
            icon: Icons.call_merge,
          ),
        if (openingAt != null)
          PointyHeroPill(
            label: l10n.treasuryOpeningAtHint(formatDate(openingAt)),
            icon: Icons.flag_outlined,
          ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.viewModel, required this.entry});

  final MoneyPositionViewModel viewModel;
  final MoneyAccountPosition entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final busy = viewModel.isSubmitting;

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: busy
                ? null
                : () => showMoneyCountSheet(
                    context,
                    viewModel: viewModel,
                    entry: entry,
                  ),
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(l10n.treasuryActionCount),
          ),
        ),
        SizedBox(width: spacing.sm),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => showMoneyTransferSheet(
                    context,
                    viewModel: viewModel,
                    fromAccountId: entry.account.id,
                  ),
            icon: const Icon(Icons.move_down),
            label: Text(l10n.treasuryActionTransfer),
          ),
        ),
      ],
    );
  }
}

class _LastCountCallout extends StatelessWidget {
  const _LastCountCallout({required this.count});

  final MoneyCount count;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final countedOn = treasuryCountedOnLabel(l10n, count);
    final amount = formatMoney(count.variance.abs());

    final (tone, title) = switch (count.hasVariance) {
      false => (PointyCalloutTone.success, l10n.treasuryVarianceMatched),
      true when count.isShort => (
        PointyCalloutTone.danger,
        l10n.treasuryCountResultShort(amount),
      ),
      true => (PointyCalloutTone.warning, l10n.treasuryCountResultOver(amount)),
    };

    return PointyDetailCallout(
      icon: Icons.fact_check_outlined,
      tone: tone,
      title: title,
      message: [
        '${l10n.treasuryCountedLabel} ${formatMoney(count.countedAmount)}',
        ?countedOn,
        if (count.note.isNotEmpty) count.note,
      ].join(' · '),
    );
  }
}

/// The components, in the order the backend returned them, ending in the
/// balance they sum to — so the total is visibly the sum of what is above it.
class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.entry});

  final MoneyAccountPosition entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

    return PointySummaryList(
      rows: [
        for (final component in entry.components)
          PointySummaryRow(
            label: treasuryComponentLabel(l10n, component.code),
            value: treasurySignedMoney(component.amount),
            valueColor: component.amount < 0 ? colors.danger : null,
          ),
        PointySummaryRow(
          label: l10n.treasuryExpectedLabel,
          value: formatMoney(entry.expectedBalance),
          emphasized: true,
          dividerAbove: true,
        ),
      ],
    );
  }
}

class _AssumptionNote extends StatelessWidget {
  const _AssumptionNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return PointyInlineMessage(message: text, icon: Icons.info_outline);
  }
}

class _Movements extends StatelessWidget {
  const _Movements({required this.viewModel, required this.accountId});

  final MoneyPositionViewModel viewModel;
  final int accountId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoadingMovements(accountId)) {
      return PointySkeleton(
        child: Column(
          children: [
            for (var i = 0; i < 4; i++) ...[
              const PointySkeletonListTile(),
              SizedBox(height: spacing.xs),
            ],
          ],
        ),
      );
    }
    if (viewModel.hasMovementsError(accountId)) {
      return PointyInlineMessage.error(message: l10n.treasuryMovementsError);
    }

    final page = viewModel.movementsFor(accountId);
    if (page == null || page.rows.isEmpty) {
      return PointyInlineMessage(
        message: l10n.treasuryMovementsEmpty,
        icon: Icons.inbox_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (page.truncated) ...[
          PointyInlineMessage(
            message: l10n.treasuryMovementsTruncated,
            icon: Icons.filter_list,
          ),
          SizedBox(height: spacing.sm),
        ],
        for (final movement in page.rows) _MovementRow(movement: movement),
      ],
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.movement});

  final MoneyMovement movement;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    final date = movement.date;
    final subtitle = [
      if (date != null) formatDate(date),
      if (movement.description.isNotEmpty) movement.description,
    ].join(' · ');

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xs),
      child: Row(
        children: [
          Icon(
            treasuryComponentIcon(movement.source),
            size: 18,
            color: colors.mutedInk,
          ),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  treasuryComponentLabel(l10n, movement.source),
                  style: textTheme.bodyMedium,
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          Text(
            treasurySignedMoney(movement.amount),
            style: textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: movement.isInflow ? colors.success : colors.danger,
            ),
          ),
        ],
      ),
    );
  }
}
