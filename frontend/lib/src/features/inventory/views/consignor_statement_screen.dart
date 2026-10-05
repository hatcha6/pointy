import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/consignment.dart';
import '../../../data/models/consignor_statement.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/consignor_statement_view_model.dart';
import 'consignment_payout_method_sheet.dart';
import 'consignor_statement_header.dart';
import 'consignor_statement_line_tile.dart';

/// كشف حساب صاحب الأمانة — one consignor, every agreement they signed.
///
/// The page a consignor is shown (or handed, printed) when they ask what the
/// shop holds and owes them: owed now first, then everything on the shelf,
/// then the history. Paying out happens here too, because the consignor is
/// usually standing at the counter when somebody opens it.
class ConsignorStatementScreen extends StatefulWidget {
  const ConsignorStatementScreen({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final ConsignorStatementViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  State<ConsignorStatementScreen> createState() =>
      _ConsignorStatementScreenState();
}

class _ConsignorStatementScreenState extends State<ConsignorStatementScreen> {
  @override
  void initState() {
    super.initState();
    if (!widget.viewModel.hasLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(widget.viewModel.load());
        }
      });
    }
  }

  bool get _canPay => widget.capabilities.canDisburseConsignmentPayout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.consignorStatementTitle),
            isLoading: viewModel.isLoading || viewModel.isPrinting,
            actions: [
              IconButton(
                tooltip: l10n.consignorStatementPrint,
                onPressed: viewModel.hasLoaded && !viewModel.isPrinting
                    ? () => _print(context)
                    : null,
                icon: const Icon(Icons.print_outlined),
              ),
              IconButton(
                tooltip: l10n.consignorStatementRefresh,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: _list(context, l10n, viewModel),
          ),
          bottomNavigationBar: _payoutBar(context, l10n, viewModel),
        );
      },
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    ConsignorStatementViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    final header = viewModel.hasLoaded
        ? Padding(
            // The list pads its rows, not its header.
            padding: spacing.pagePadding.copyWith(bottom: 0),
            child: ConsignorStatementHeader(
              statement: viewModel.statement,
              period: viewModel.period,
              filter: viewModel.filter,
              onFilterChanged: viewModel.setFilter,
              onPickPeriod: () => _pickPeriod(context),
              onClearPeriod: () => viewModel.setPeriod(null),
              onPayAll: _canPay && viewModel.awaitingLines.isNotEmpty
                  ? () => _payAll(context)
                  : null,
            ),
          )
        : null;
    return PointyDataList<ConsignorStatementLine>(
      items: viewModel.lines,
      header: header,
      framed: false,
      padding: spacing.pagePadding,
      isLoadingInitial: viewModel.isLoading && !viewModel.hasLoaded,
      isLoadingMore: viewModel.isLoadingMore,
      hasMore: viewModel.hasMore,
      onLoadMore: viewModel.loadMore,
      loadMoreFailed: viewModel.loadMoreFailed,
      loadMoreErrorMessage: l10n.consignorStatementLoadFailed,
      hasError: viewModel.hasError && !viewModel.hasLoaded,
      skeletonItemBuilder: (_) => const PointySkeletonCard(),
      separatorBuilder: (_, _) => SizedBox(height: spacing.sm),
      emptyBuilder: (context) => Padding(
        padding: spacing.pagePadding,
        child: PointyEmptyState(
          icon: Icons.handshake_outlined,
          title: l10n.consignorStatementEmptyTitle,
          message: viewModel.figures.hasHistory
              ? l10n.consignorStatementEmptyBody
              : l10n.consignorStatementNoHistory,
        ),
      ),
      errorBuilder: (context) => PointyErrorState(
        title: l10n.consignorStatementLoadFailed,
        icon: Icons.handshake_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      ),
      itemBuilder: (context, line) => ConsignorStatementLineTile(
        line: line,
        reminderRounds: viewModel.statement.reminders.maxRounds,
        isSelected: viewModel.selected.contains(line.unitId),
        onToggle: _canPay ? () => viewModel.toggle(line) : null,
        onResendSms: () => _resend(context, line),
      ),
    );
  }

  Widget? _payoutBar(
    BuildContext context,
    AppLocalizations l10n,
    ConsignorStatementViewModel viewModel,
  ) {
    if (viewModel.selected.isEmpty) {
      return null;
    }
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return SafeArea(
      child: Material(
        color: colors.surface,
        elevation: 0,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.line)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.consignmentPayoutSelected(
                          viewModel.selected.length,
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        formatMoney(viewModel.selectedTotal),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colors.primaryStrong,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: viewModel.clearSelection,
                  child: Text(l10n.cancelButton),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: viewModel.canDisburse
                      ? () => _disburse(context)
                      : null,
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(l10n.consignmentDisburseAction),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickPeriod(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: widget.viewModel.period,
    );
    if (picked != null) {
      widget.viewModel.setPeriod(picked);
    }
  }

  Future<void> _payAll(BuildContext context) async {
    widget.viewModel.selectAllAwaiting();
    await _disburse(context);
  }

  Future<void> _disburse(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final viewModel = widget.viewModel;
    final method = await showConsignmentPayoutMethodSheet(
      context,
      total: viewModel.selectedTotal,
    );
    if (method == null) {
      return;
    }
    final payout = await viewModel.disburse(method: method);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            payout == null
                ? l10n.consignmentDisburseFailed
                : l10n.consignmentDisburseDone(payout.number),
          ),
          action: payout == null
              ? null
              : SnackBarAction(
                  label: l10n.consignmentPrintPayout,
                  onPressed: () => unawaited(
                    _printPayout(
                      payout,
                      messenger,
                      l10n.consignmentPrintFailed,
                    ),
                  ),
                ),
        ),
      );
  }

  Future<void> _printPayout(
    ConsignorPayout payout,
    ScaffoldMessengerState messenger,
    String failureMessage,
  ) async {
    if (await widget.viewModel.printPayout(payout)) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(failureMessage)));
  }

  Future<void> _print(BuildContext context) async {
    final failure = AppLocalizations.of(context)!.consignmentPrintFailed;
    final messenger = ScaffoldMessenger.of(context);
    if (await widget.viewModel.printStatement()) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(failure)));
  }

  Future<void> _resend(
    BuildContext context,
    ConsignorStatementLine line,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final queued = await widget.viewModel.resendSaleSms(line);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            queued ? l10n.consignmentSmsQueued : l10n.consignmentSmsFailed,
          ),
        ),
      );
  }
}
