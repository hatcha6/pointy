import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/consignment.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/consignment_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/consignment_view_model.dart';
import 'consignment_intake_sheet.dart';

/// مستحقات الأمانات — what the shop owes the owners of goods it has sold.
///
/// The screen exists because the honest answer to *"how much of the money in
/// this drawer is actually ours?"* used to be that we could not say. Every
/// figure on it is derived from the units' own sales and their own payout rows,
/// so it cannot drift from them.
///
/// The search field is a [ScanWedgeTarget]: a consignor arriving with the
/// article in their hand is the fastest way to find their row, and a burst
/// guard that rolled the digits back would make the answer arrive as a search
/// for nothing.
class ConsignmentPayablesScreen extends StatefulWidget {
  const ConsignmentPayablesScreen({
    super.key,
    required this.viewModel,
    required this.repository,
    required this.catalog,
    required this.contacts,
    required this.capabilities,
  });

  final ConsignmentViewModel viewModel;
  final ConsignmentRepository repository;
  final CatalogRepository catalog;
  final ContactRepository contacts;
  final AuthorizationCapabilities capabilities;

  @override
  State<ConsignmentPayablesScreen> createState() =>
      _ConsignmentPayablesScreenState();
}

class _ConsignmentPayablesScreenState extends State<ConsignmentPayablesScreen> {
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.load());
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.consignmentPayablesTitle),
            isLoading: viewModel.isLoading,
            actions: [
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _body(context, l10n, viewModel),
          floatingActionButton:
              widget.capabilities.canManageConsignmentAgreement
              ? FloatingActionButton.extended(
                  onPressed: _takeIn,
                  icon: const Icon(Icons.handshake_outlined),
                  label: Text(l10n.consignmentIntakeTitle),
                )
              : null,
          bottomNavigationBar: _payoutBar(context, l10n, viewModel),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    ConsignmentViewModel viewModel,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: spacing.pagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConsignmentPositionCard(position: viewModel.position),
              const SizedBox(height: 12),
              ScanWedgeTarget(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: l10n.consignmentPayablesSearchHint,
                  ),
                  onChanged: viewModel.setSearch,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _list(context, l10n, viewModel)),
      ],
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    ConsignmentViewModel viewModel,
  ) {
    if (viewModel.isLoading && viewModel.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasError && viewModel.isEmpty) {
      return PointyErrorState(
        title: l10n.consignmentPayablesTitle,
        icon: Icons.handshake_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }
    final rows = viewModel.payables;
    if (rows.isEmpty) {
      return PointyEmptyState(
        icon: Icons.handshake_outlined,
        title: l10n.consignmentPayablesEmptyTitle,
        message: l10n.consignmentPayablesEmptyBody,
      );
    }
    final spacing = AdaptiveSpacing.of(context);
    return ListView.separated(
      padding: spacing.pagePadding,
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final row = rows[index];
        return _PayableCard(
          row: row,
          isSelected: viewModel.selected.contains(row.unitId),
          onTap: () => viewModel.toggle(row),
          onSelectAll: () => viewModel.selectAllFor(row),
          onResend: () => _resend(context, viewModel, row),
        );
      },
    );
  }

  Widget? _payoutBar(
    BuildContext context,
    AppLocalizations l10n,
    ConsignmentViewModel viewModel,
  ) {
    if (viewModel.selected.isEmpty) {
      return null;
    }
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final oneOwner = viewModel.selectionIsOneConsignor;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!oneOwner)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PointyDetailCallout(
                  icon: Icons.person_outline,
                  tone: PointyCalloutTone.warning,
                  title: l10n.consignmentPayoutOneConsignor,
                ),
              ),
            Row(
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
                      ? () => _disburse(context, viewModel)
                      : null,
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(l10n.consignmentDisburseAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _disburse(
    BuildContext context,
    ConsignmentViewModel viewModel,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final method = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => _PayoutMethodSheet(total: viewModel.selectedTotal),
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
        ),
      );
  }

  Future<void> _takeIn() async {
    final agreement = await showConsignmentIntakeSheet(
      context,
      catalog: widget.catalog,
      contacts: widget.contacts,
      onSubmit: widget.repository.takeIn,
    );
    if (agreement == null || !mounted) {
      return;
    }
    // The goods are on the shelf now, so the custody figure on this page is
    // stale until it re-reads. Nothing here adjusts its own copy of a number
    // the server owns.
    unawaited(widget.viewModel.load());
  }

  Future<void> _resend(
    BuildContext context,
    ConsignmentViewModel viewModel,
    ConsignmentPayable row,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final queued = await viewModel.resendSms(row);
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

/// The four figures of the consignment position, side by side.
///
/// Stock value is always zero and is shown anyway: a page that did not say *"the
/// goods are worth nothing to this shop"* would be read as having forgotten to.
class ConsignmentPositionCard extends StatelessWidget {
  const ConsignmentPositionCard({super.key, required this.position});

  final ConsignmentPosition position;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return PointyMetricGrid(
      maxColumns: 4,
      gap: PointyMetricGridGap.compact,
      metrics: [
        PointyMetricGridItem(
          label: l10n.consignmentFigurePayable,
          value: formatMoney(position.payable),
          icon: Icons.account_balance_wallet_outlined,
          accentColor: colors.warning,
        ),
        PointyMetricGridItem(
          label: l10n.consignmentFigureCommission,
          value: formatMoney(position.shopCommission),
          icon: Icons.trending_up,
        ),
        PointyMetricGridItem(
          label: l10n.consignmentFigureCustody,
          value: '${position.custodyUnitCount}',
          subtitle: formatMoney(position.custodyDeclaredValue),
          icon: Icons.inventory_2_outlined,
        ),
        PointyMetricGridItem(
          label: l10n.consignmentFigureStockValue,
          value: formatMoney(position.stockValue),
          icon: Icons.remove_circle_outline,
          accentColor: colors.mutedInk,
        ),
      ],
    );
  }
}

class _PayableCard extends StatelessWidget {
  const _PayableCard({
    required this.row,
    required this.isSelected,
    required this.onTap,
    required this.onSelectAll,
    required this.onResend,
  });

  final ConsignmentPayable row;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onSelectAll;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Card(
      margin: EdgeInsets.zero,
      color: isSelected ? colors.primaryContainer : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onSelectAll,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: isSelected ? colors.primaryStrong : theme.hintColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          row.consignorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          '${row.productName} · ${row.code}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    formatMoney(row.payoutDue),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.primaryStrong,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (row.invoiceNumber.isNotEmpty)
                    _Chip(
                      icon: Icons.receipt_long_outlined,
                      label: row.invoiceNumber,
                    ),
                  if (row.soldAt != null)
                    _Chip(
                      icon: Icons.event_outlined,
                      label: formatDate(row.soldAt!),
                    ),
                  if (row.daysWaiting != null)
                    _Chip(
                      icon: Icons.hourglass_bottom_outlined,
                      label: l10n.consignmentWaitingDays(row.daysWaiting!),
                      tone: row.isOverdue ? colors.warning : null,
                    ),
                  // The second number, said out loud: this consignment sold on
                  // آجل, so the shop owes cash it has not collected.
                  if (row.soldOnCredit)
                    _Chip(
                      icon: Icons.schedule_outlined,
                      label: l10n.consignmentSoldOnCredit(
                        formatMoney(row.invoiceBalanceDue ?? 0),
                      ),
                      tone: colors.danger,
                    ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onResend,
                    icon: const Icon(Icons.sms_outlined, size: 16),
                    label: Text(l10n.consignmentResendSms),
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

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, this.tone});

  final IconData icon;
  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone ?? theme.hintColor;
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

class _PayoutMethodSheet extends StatelessWidget {
  const _PayoutMethodSheet({required this.total});

  final double total;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.consignmentPayoutMethodTitle(formatMoney(total)),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.payments_outlined),
              title: Text(l10n.consignmentPayoutCash),
              subtitle: Text(l10n.consignmentPayoutCashHint),
              onTap: () => Navigator.of(context).pop('cash'),
            ),
            ListTile(
              leading: const Icon(Icons.account_balance_outlined),
              title: Text(l10n.consignmentPayoutBank),
              onTap: () => Navigator.of(context).pop('bank'),
            ),
          ],
        ),
      ),
    );
  }
}
