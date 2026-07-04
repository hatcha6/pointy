import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../purchasing/views/purchase_order_details_screen.dart';
import '../../purchasing/views/purchase_order_filter_sheet.dart';
import '../view_models/supplier_details_view_model.dart';

class SupplierDetailsScreen extends StatefulWidget {
  const SupplierDetailsScreen({
    super.key,
    required this.supplier,
    required this.contactRepository,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
  });

  final SupplierContact supplier;
  final ContactRepository contactRepository;
  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;

  @override
  State<SupplierDetailsScreen> createState() => _SupplierDetailsScreenState();
}

class _SupplierDetailsScreenState extends State<SupplierDetailsScreen> {
  late final SupplierDetailsViewModel _viewModel = SupplierDetailsViewModel(
    contactRepository: widget.contactRepository,
    purchaseRepository: widget.purchaseRepository,
    initialSupplier: widget.supplier,
  );

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final supplier = _viewModel.supplier;
        return Scaffold(
          appBar: AppBar(
            title: Text(supplier.name),
            actions: [
              IconButton(
                tooltip: l10n.refreshSupplierDetailsTooltip,
                onPressed: _viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(
            child: SupplierDetailsView(
              viewModel: _viewModel,
              purchaseRepository: widget.purchaseRepository,
              printingRepository: widget.printingRepository,
              shopSettingsRepository: widget.shopSettingsRepository,
              capabilities: widget.capabilities,
            ),
          ),
        );
      },
    );
  }
}

/// Embeddable supplier details body: used by [SupplierDetailsScreen] as a
/// pushed route on compact widths, and by the contacts master-detail pane on
/// desktop.
class SupplierDetailsView extends StatelessWidget {
  const SupplierDetailsView({
    super.key,
    required this.viewModel,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
    this.onEdited,
  });

  final SupplierDetailsViewModel viewModel;
  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;

  /// Invoked after the profile is edited (so list views can refresh the name).
  final VoidCallback? onEdited;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final supplier = viewModel.supplier;
        return AdaptiveMaxWidth(
          width: AppContentWidth.detail,
          child: ListView(
            padding: EdgeInsets.all(spacing.lg),
            children: [
              _SupplierHero(supplier: supplier),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.supplierProfileTitle,
                icon: Icons.badge_outlined,
                trailing: IconButton(
                  key: const ValueKey('edit_supplier_button'),
                  tooltip: l10n.editContactTooltip,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _edit(context),
                ),
                child: _SupplierProfile(supplier: supplier),
              ),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.supplierPurchaseSummaryTitle,
                icon: Icons.summarize_outlined,
                child: _SupplierTotals(viewModel: viewModel),
              ),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.supplierPurchaseHistoryTitle,
                icon: Icons.receipt_long_outlined,
                child: _SupplierPurchaseHistory(
                  viewModel: viewModel,
                  onOpenPurchaseOrder: (order) =>
                      _openPurchaseOrder(context, order),
                ),
              ),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                title: l10n.supplierReturnRefundHistoryTitle,
                icon: Icons.keyboard_return_outlined,
                child: _SupplierAdjustmentHistory(viewModel: viewModel),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openPurchaseOrder(BuildContext context, PurchaseOrder order) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PurchaseOrderDetailsScreen(
          purchaseRepository: purchaseRepository,
          printingRepository: printingRepository,
          shopSettingsRepository: shopSettingsRepository,
          initialOrder: order,
          capabilities: capabilities,
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final updated = await showEditSupplierSheet(
      context: context,
      repository: viewModel.repository,
      supplier: viewModel.supplier,
    );
    if (updated == null || !context.mounted) {
      return;
    }
    viewModel.applyUpdatedSupplier(updated);
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(l10n.supplierUpdatedMessage)));
    onEdited?.call();
  }
}

/// The supplier's own contact card (everything the edit form manages) — the
/// balances and histories below are derived, this is the editable identity.
class _SupplierProfile extends StatelessWidget {
  const _SupplierProfile({required this.supplier});

  final SupplierContact supplier;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    String valueOrEmpty(String value) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? l10n.customerEmptyValue : trimmed;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyMetricGrid(
          maxColumns: 2,
          minTileWidth: 200,
          gap: PointyMetricGridGap.compact,
          metrics: [
            PointyMetricGridItem(
              label: l10n.contactPersonLabel,
              value: valueOrEmpty(supplier.contactName),
              icon: Icons.person_outline,
            ),
            PointyMetricGridItem(
              label: l10n.phoneOptionalLabel,
              value: valueOrEmpty(supplier.phone),
              icon: Icons.phone_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.emailOptionalLabel,
              value: valueOrEmpty(supplier.email),
              icon: Icons.alternate_email_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.addressOptionalLabel,
              value: valueOrEmpty(supplier.address),
              icon: Icons.location_on_outlined,
            ),
          ],
        ),
        if (supplier.notes.trim().isNotEmpty) ...[
          SizedBox(height: spacing.md),
          PointyDetailCallout(
            icon: Icons.sticky_note_2_outlined,
            tone: PointyCalloutTone.neutral,
            title: l10n.notesOptionalLabel,
            message: supplier.notes,
          ),
        ],
      ],
    );
  }
}

class _SupplierHero extends StatelessWidget {
  const _SupplierHero({required this.supplier});

  final SupplierContact supplier;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDetailHero(
      icon: Icons.local_shipping_outlined,
      title: supplier.name,
      value: formatMoney(supplier.totalBought),
      valueSubtitle: l10n.supplierPurchaseCountValue(supplier.purchaseCount),
      pills: [
        PointyHeroPill(
          label: supplier.isActive
              ? l10n.activeContactLabel
              : l10n.inactiveContactLabel,
          icon: supplier.isActive
              ? Icons.check_circle_outline
              : Icons.pause_circle_outline,
        ),
        if (supplier.contactName.trim().isNotEmpty)
          PointyHeroPill(
            label: supplier.contactName,
            icon: Icons.person_outline,
          ),
        if (supplier.phone.trim().isNotEmpty)
          PointyHeroPill(label: supplier.phone, icon: Icons.phone_outlined),
      ],
    );
  }
}

class _SupplierTotals extends StatelessWidget {
  const _SupplierTotals({required this.viewModel});

  final SupplierDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final supplier = viewModel.supplier;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (viewModel.hasSupplierError) ...[
          PointyInlineMessage.error(message: l10n.supplierDetailsLoadError),
          SizedBox(height: spacing.sm),
        ],
        PointyMetricGrid(
          maxColumns: 3,
          minTileWidth: 170,
          gap: PointyMetricGridGap.compact,
          metrics: [
            PointyMetricGridItem(
              label: l10n.supplierTotalBoughtLabel,
              value: formatMoney(supplier.totalBought),
              icon: Icons.shopping_bag_outlined,
              accentColor: colors.primaryStrong,
            ),
            PointyMetricGridItem(
              label: l10n.supplierPurchaseCountLabel,
              value: supplier.purchaseCount.toString(),
              icon: Icons.receipt_long_outlined,
            ),
            PointyMetricGridItem(
              label: l10n.purchaseOrderBalanceDueLabel,
              value: formatMoney(supplier.payableBalance),
              icon: Icons.account_balance_wallet_outlined,
              accentColor: supplier.payableBalance > 0
                  ? colors.danger
                  : colors.success,
            ),
            if (supplier.creditBalance > 0)
              PointyMetricGridItem(
                label: l10n.purchaseOrderCreditAppliedLabel,
                value: formatMoney(supplier.creditBalance),
                icon: Icons.savings_outlined,
                accentColor: colors.success,
              ),
          ],
        ),
      ],
    );
  }
}

class _SupplierPurchaseHistory extends StatelessWidget {
  const _SupplierPurchaseHistory({
    required this.viewModel,
    required this.onOpenPurchaseOrder,
  });

  final SupplierDetailsViewModel viewModel;
  final ValueChanged<PurchaseOrder> onOpenPurchaseOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoadingHistory && viewModel.purchaseHistory.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasHistoryError && viewModel.purchaseHistory.isEmpty) {
      return PointyInlineMessage.error(
        message: l10n.supplierPurchaseHistoryLoadError,
      );
    }
    if (viewModel.purchaseHistory.isEmpty) {
      return PointyEmptyState(
        icon: Icons.receipt_long_outlined,
        title: l10n.supplierPurchaseHistoryEmpty,
      );
    }

    return SizedBox(
      height: _historyListHeight(
        viewModel.purchaseHistory.length,
        viewModel.hasMorePurchaseHistory,
      ),
      child: PointyDataList<PurchaseOrder>(
        items: viewModel.purchaseHistory,
        onLoadMore: viewModel.loadMorePurchaseHistory,
        hasMore: viewModel.hasMorePurchaseHistory,
        isLoadingInitial: viewModel.isLoadingHistory,
        isLoadingMore: viewModel.isLoadingMoreHistory,
        emptyBuilder: (context) => PointyEmptyState(
          icon: Icons.receipt_long_outlined,
          title: l10n.supplierPurchaseHistoryEmpty,
        ),
        padding: EdgeInsets.zero,
        framed: false,
        itemBuilder: (context, order) {
          return PointyDataRow(
            leading: const Icon(Icons.receipt_long_outlined),
            title: order.orderNumber.isEmpty
                ? l10n.purchaseOrderFallbackTitle(order.id)
                : order.orderNumber,
            subtitle: [
              purchaseOrderStatusLabel(l10n, order.status),
              l10n.lineItemCount(order.lineCount),
              if (order.receivedAt != null) formatDateTime(order.receivedAt!),
              if (order.balanceDue > 0)
                l10n.purchaseOutstandingAmountValue(
                  formatMoney(order.balanceDue),
                ),
            ].join(' • '),
            trailing: Text(formatMoney(order.total)),
            onTap: () => onOpenPurchaseOrder(order),
          );
        },
      ),
    );
  }
}

class _SupplierAdjustmentHistory extends StatelessWidget {
  const _SupplierAdjustmentHistory({required this.viewModel});

  final SupplierDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoadingAdjustments && viewModel.adjustmentHistory.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasAdjustmentError && viewModel.adjustmentHistory.isEmpty) {
      return PointyInlineMessage.error(
        message: l10n.supplierReturnRefundHistoryLoadError,
      );
    }
    if (viewModel.adjustmentHistory.isEmpty) {
      return PointyEmptyState(
        icon: Icons.keyboard_return_outlined,
        title: l10n.supplierReturnRefundHistoryEmpty,
      );
    }

    return SizedBox(
      height: _historyListHeight(
        viewModel.adjustmentHistory.length,
        viewModel.hasMoreAdjustments,
      ),
      child: PointyDataList<PurchaseAdjustmentHistoryEntry>(
        items: viewModel.adjustmentHistory,
        onLoadMore: viewModel.loadMoreAdjustments,
        hasMore: viewModel.hasMoreAdjustments,
        isLoadingInitial: viewModel.isLoadingAdjustments,
        isLoadingMore: viewModel.isLoadingMoreAdjustments,
        emptyBuilder: (context) => PointyEmptyState(
          icon: Icons.keyboard_return_outlined,
          title: l10n.supplierReturnRefundHistoryEmpty,
        ),
        padding: EdgeInsets.zero,
        framed: false,
        itemBuilder: (context, adjustment) {
          return PointyDataRow(
            leading: Icon(_adjustmentIcon(adjustment.type)),
            title: _adjustmentTypeLabel(l10n, adjustment.type),
            subtitle: [
              if (adjustment.purchaseOrderNumber != null &&
                  adjustment.purchaseOrderNumber!.isNotEmpty)
                l10n.purchaseOrderNumberValue(adjustment.purchaseOrderNumber!),
              if (adjustment.createdAt != null)
                formatDateTime(adjustment.createdAt!),
              l10n.lineItemCount(adjustment.lines.length),
              if (adjustment.reason.isNotEmpty) adjustment.reason,
            ].join(' • '),
            trailing: Text(formatMoney(adjustment.amount)),
          );
        },
      ),
    );
  }

  IconData _adjustmentIcon(PurchaseAdjustmentType type) {
    return switch (type) {
      PurchaseAdjustmentType.returnItems => Icons.keyboard_return_outlined,
      PurchaseAdjustmentType.refund => Icons.payments_outlined,
      PurchaseAdjustmentType.exchange => Icons.swap_horiz_outlined,
    };
  }

  String _adjustmentTypeLabel(
    AppLocalizations l10n,
    PurchaseAdjustmentType type,
  ) {
    return switch (type) {
      PurchaseAdjustmentType.returnItems => l10n.purchaseAdjustmentTypeReturn,
      PurchaseAdjustmentType.refund => l10n.purchaseAdjustmentTypeRefund,
      PurchaseAdjustmentType.exchange => l10n.purchaseAdjustmentTypeExchange,
    };
  }
}

double _historyListHeight(int itemCount, bool hasMore) {
  if (hasMore || itemCount > 3) {
    return 248;
  }
  if (itemCount == 1) {
    return 80;
  }
  if (itemCount == 2) {
    return 160;
  }
  return 240;
}
