import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/services/order_document_service.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_denied_view.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/sale_order_details_content.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/invoice_list_view_model.dart';
import 'invoice_query_controls.dart';

class InvoiceListScreen extends StatelessWidget {
  const InvoiceListScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    required this.onOpenInvoice,
    required this.navigation,
    this.detailPaneBuilder,
  });

  final InvoiceListViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final ValueChanged<SaleOrder> onOpenInvoice;
  final AppNavigation navigation;

  /// When provided, wide layouts show the selected invoice inline in a
  /// trailing detail pane instead of pushing a route.
  final Widget Function(BuildContext context, SaleOrder order)?
  detailPaneBuilder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.invoices,
            navigation: navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.invoicesTitle),
            actions: [
              AuthorizationGuard(
                capabilities: capabilities,
                capability: AppCapability.viewInvoices,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshInvoicesTooltip,
                  onPressed: viewModel.loadInvoices,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: AuthorizationGuard(
            capabilities: capabilities,
            capability: AppCapability.viewInvoices,
            fallback: const AuthorizationDeniedView(),
            child: _InvoiceListBody(
              viewModel: viewModel,
              contactRepository: contactRepository,
              onOpenInvoice: onOpenInvoice,
              detailPaneBuilder: detailPaneBuilder,
            ),
          ),
        );
      },
    );
  }
}

class _InvoiceListBody extends StatefulWidget {
  const _InvoiceListBody({
    required this.viewModel,
    required this.contactRepository,
    required this.onOpenInvoice,
    this.detailPaneBuilder,
  });

  final InvoiceListViewModel viewModel;
  final ContactRepository contactRepository;
  final ValueChanged<SaleOrder> onOpenInvoice;
  final Widget Function(BuildContext context, SaleOrder order)?
  detailPaneBuilder;

  @override
  State<_InvoiceListBody> createState() => _InvoiceListBodyState();
}

class _InvoiceListBodyState extends State<_InvoiceListBody> {
  InvoiceListViewModel get viewModel => widget.viewModel;

  SaleOrder? _selectedOrder;

  void _openInvoice(SaleOrder order, bool isDualPane) {
    if (isDualPane && widget.detailPaneBuilder != null) {
      setState(() {
        _selectedOrder = order;
      });
      return;
    }
    widget.onOpenInvoice(order);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (widget.detailPaneBuilder == null) {
      return _buildList(context, false);
    }

    return MasterDetailLayout(
      listPaneBuilder: _buildList,
      placeholder: PointyEmptyState(
        icon: Icons.receipt_long_outlined,
        title: l10n.invoicesSelectInvoicePlaceholder,
      ),
      detailPane: _selectedOrder == null || widget.detailPaneBuilder == null
          ? null
          : KeyedSubtree(
              key: ValueKey('invoice_detail_${_selectedOrder!.id}'),
              child: widget.detailPaneBuilder!(context, _selectedOrder!),
            ),
    );
  }

  Widget _buildList(BuildContext context, bool isDualPane) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: spacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InvoiceQueryControls(
            query: viewModel.query,
            contactRepository: widget.contactRepository,
            onSearchChanged: viewModel.updateSearch,
            onQueryChanged: viewModel.applyQuery,
            enabled: !viewModel.isLoading,
          ),
          SizedBox(height: spacing.md),
          Expanded(
            child: PointyDataList<SaleOrder>(
              items: viewModel.invoices,
              onLoadMore: viewModel.loadMoreInvoices,
              hasMore: viewModel.hasMoreInvoices,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              hasError: viewModel.hasLoadError,
              errorBuilder: (context) => PointyErrorState(
                title: l10n.invoicesLoadError,
                icon: Icons.receipt_long_outlined,
              ),
              emptyBuilder: (context) => PointyEmptyState(
                icon: Icons.receipt_long_outlined,
                title: l10n.emptyInvoices,
              ),
              itemBuilder: (context, invoice) {
                return InvoiceTile(
                  invoice: invoice,
                  onTap: () => _openInvoice(invoice, isDualPane),
                  onPrint: () => _printInvoice(context, invoice),
                  onShare: () => _shareInvoice(context, invoice),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _printInvoice(BuildContext context, SaleOrder invoice) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final didPrint = await viewModel.printInvoice(invoice);
    if (!context.mounted) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            didPrint ? l10n.invoicePrintSuccess : l10n.invoicePrintError,
          ),
        ),
      );
  }

  Future<void> _shareInvoice(BuildContext context, SaleOrder invoice) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final status = await viewModel.shareInvoice(invoice);
    if (!context.mounted || status == OrderDocumentActionStatus.canceled) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            status == OrderDocumentActionStatus.completed
                ? l10n.invoiceShareSuccess
                : l10n.invoiceShareError,
          ),
        ),
      );
  }
}

class InvoiceTile extends StatelessWidget {
  const InvoiceTile({
    super.key,
    required this.invoice,
    this.onTap,
    this.onPrint,
    this.onShare,
  });

  final SaleOrder invoice;
  final VoidCallback? onTap;
  final VoidCallback? onPrint;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final receiptNumber = invoice.receiptNumber ?? l10n.saleReceiptFallback;

    return PointyDataRow(
      leading: Icon(
        saleOrderStatusIcon(invoice.status),
        color: colors.primaryStrong,
      ),
      title: l10n.invoiceNumberValue(receiptNumber),
      subtitle: [
        if (invoice.createdAt != null) formatDateTime(invoice.createdAt!),
        l10n.lineItemCount(invoice.lines.length),
        if (invoice.customerName != null && invoice.customerName!.isNotEmpty)
          invoice.customerName!,
        if (invoice.registerSessionNumber != null &&
            invoice.registerSessionNumber!.isNotEmpty)
          l10n.invoiceRegisterSessionValue(invoice.registerSessionNumber!),
      ].join(' • '),
      badges: [
        PointyStatusPill(
          label: saleOrderStatusLabel(l10n, invoice.status),
          icon: saleOrderStatusIcon(invoice.status),
        ),
      ],
      actions: [
        if (onPrint != null || onShare != null)
          PopupMenuButton<_InvoiceRowAction>(
            tooltip: l10n.invoiceRowActionsTooltip,
            icon: const Icon(Icons.more_vert),
            onSelected: (action) {
              switch (action) {
                case _InvoiceRowAction.print:
                  onPrint?.call();
                case _InvoiceRowAction.share:
                  onShare?.call();
              }
            },
            itemBuilder: (context) => [
              if (onPrint != null)
                PopupMenuItem<_InvoiceRowAction>(
                  value: _InvoiceRowAction.print,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.print_outlined),
                    title: Text(l10n.invoiceReprintButton),
                  ),
                ),
              if (onShare != null)
                PopupMenuItem<_InvoiceRowAction>(
                  value: _InvoiceRowAction.share,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.ios_share_outlined),
                    title: Text(l10n.invoiceShareButton),
                  ),
                ),
            ],
          ),
      ],
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatMoney(invoice.total),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (invoice.profit != null)
            Text(
              l10n.invoiceProfitValue(formatMoney(invoice.profit!)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.primaryStrong,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
      onTap: onTap,
    );
  }
}

enum _InvoiceRowAction { print, share }
