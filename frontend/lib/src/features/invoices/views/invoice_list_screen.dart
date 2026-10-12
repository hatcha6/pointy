import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/user_repository.dart';
import '../../../data/services/order_document_service.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_denied_view.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/sale_order_details_content.dart';
import '../../../shared/query_controls/query_empty_state.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/invoice_list_view_model.dart';
import 'invoice_query_controls.dart';
import '../../../shared/payments/card_receipt_status.dart';

class InvoiceListScreen extends StatelessWidget {
  const InvoiceListScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.userRepository,
    required this.capabilities,
    required this.onOpenInvoice,
    required this.navigation,
    this.detailPaneBuilder,
  });

  final InvoiceListViewModel viewModel;
  final ContactRepository contactRepository;

  /// Backs the cashier filter — "show me Bahr's invoices". Only offered to a
  /// viewer who sees shop-wide sales; everyone else is scoped by the backend to
  /// their own register sessions, so filtering by someone else would only ever
  /// return nothing.
  final UserRepository userRepository;
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
              userRepository: capabilities.canViewShopWideSales
                  ? userRepository
                  : null,
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
    required this.userRepository,
    required this.onOpenInvoice,
    this.detailPaneBuilder,
  });

  final InvoiceListViewModel viewModel;
  final ContactRepository contactRepository;
  final UserRepository? userRepository;
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
    final horizontal = EdgeInsetsDirectional.symmetric(
      horizontal: spacing.pageHorizontal,
    );

    // One sliver page: the filters float above the rows (gone while reading
    // down, back on the first scroll up), and the wheel scrolls the page from
    // anywhere on it rather than only over the rows.
    return PointyDataList<SaleOrder>(
      items: viewModel.invoices,
      onLoadMore: viewModel.loadMoreInvoices,
      hasMore: viewModel.hasMoreInvoices,
      isLoadingInitial: viewModel.isLoading,
      isLoadingMore: viewModel.isLoadingMore,
      hasError: viewModel.hasLoadError,
      padding: horizontal.add(
        EdgeInsetsDirectional.only(bottom: spacing.pageVertical),
      ),
      headerSlivers: [
        SliverFloatingHeader(
          child: ColoredBox(
            color: context.pointyColors.page,
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                spacing.pageHorizontal,
                spacing.pageVertical,
                spacing.pageHorizontal,
                spacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  InvoiceQueryControls(
                    query: viewModel.query,
                    contactRepository: widget.contactRepository,
                    userRepository: widget.userRepository,
                    onSearchChanged: viewModel.updateSearch,
                    onQueryChanged: viewModel.applyQuery,
                    enabled: !viewModel.isLoading,
                  ),
                  SizedBox(height: spacing.sm),
                  PointyDocumentListHeader(
                    documentLabel: l10n.documentListColumnDocument,
                    partyLabel: l10n.documentListColumnCustomer,
                    statusLabel: l10n.documentListColumnStatus,
                    amountLabel: l10n.documentListColumnAmount,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      errorBuilder: (context) => PointyErrorState(
        title: l10n.invoicesLoadError,
        icon: Icons.receipt_long_outlined,
        action: FilledButton.tonalIcon(
          onPressed: viewModel.loadInvoices,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      ),
      emptyBuilder: (context) => QueryEmptyState(
        icon: Icons.receipt_long_outlined,
        search: viewModel.query.search,
        hasFilters:
            InvoiceQueryControls.narrowingFilterCount(viewModel.query) > 0,
        emptyTitle: l10n.emptyInvoices,
        onClear: () =>
            viewModel.applyQuery(InvoiceQueryControls.cleared(viewModel.query)),
      ),
      itemBuilder: (context, invoice) {
        return InvoiceTile(
          invoice: invoice,
          onTap: () => _openInvoice(invoice, isDualPane),
          onPrint: () => _printInvoice(context, invoice),
          onShare: () => _shareInvoice(context, invoice),
        );
      },
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
    final customer = (invoice.customerName ?? '').trim();
    final cashier = (invoice.cashierName ?? '').trim();
    final session = (invoice.registerSessionNumber ?? '').trim();
    final isVoid = invoice.status == 'void';
    final owing = !isVoid && invoice.balanceDue > 0;
    final profit = invoice.profit;

    return PointyDocumentRow(
      party: customer.isEmpty ? l10n.walkInCustomerLabel : customer,
      reference: l10n.invoiceNumberValue(receiptNumber),
      date: invoice.createdAt == null
          ? null
          : formatDateTime(invoice.createdAt!),
      amount: formatMoney(invoice.total),
      // What is still owed is the figure a credit sale is opened for; the
      // profit (owners only — null for everyone else) otherwise.
      secondaryAmount: owing
          ? l10n.invoiceBalanceDueValue(formatMoney(invoice.balanceDue))
          : profit == null
          ? null
          : l10n.invoiceProfitValue(formatMoney(profit)),
      secondaryAmountColor: owing ? colors.warning : colors.primaryStrong,
      accentColor: invoice.isOverdue
          ? colors.danger
          : _invoiceStatusColor(colors, invoice.status),
      badges: [
        PointyStatusPill(
          label: saleOrderStatusLabel(l10n, invoice.status),
          icon: saleOrderStatusIcon(invoice.status),
          color: _invoiceStatusColor(colors, invoice.status),
        ),
        // Whether the card money on this sale is backed by a receipt the
        // shop could show someone. Draws nothing on a cash sale.
        CardReceiptStatusBadge(status: invoice.cardReceiptStatus),
        // Late first, because that is the one an owner scanning this list is
        // looking for. Falls back to the agreed date when the invoice is still
        // inside its terms, so a credit sale always says where it stands.
        if (invoice.isOverdue)
          PointyStatusPill(
            label: l10n.invoiceOverdueBadge(invoice.daysOverdue),
            icon: Icons.warning_amber_rounded,
            color: colors.danger,
          )
        else if (invoice.dueDate != null)
          PointyStatusPill(
            label: l10n.invoiceDueOnLabel(formatDate(invoice.dueDate!)),
            icon: Icons.event_available_outlined,
          ),
      ],
      meta: [
        PointyDocumentMeta(
          icon: Icons.shopping_basket_outlined,
          label: l10n.lineItemCount(invoice.lineCount),
        ),
        if (cashier.isNotEmpty)
          PointyDocumentMeta(
            icon: Icons.person_outline,
            label: l10n.invoiceCashierValue(cashier),
          ),
        if (session.isNotEmpty)
          PointyDocumentMeta(
            icon: Icons.point_of_sale_outlined,
            label: l10n.invoiceRegisterSessionValue(session),
          ),
      ],
      menu: onPrint == null && onShare == null
          ? null
          : PopupMenuButton<_InvoiceRowAction>(
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
      onTap: onTap,
    );
  }
}

Color _invoiceStatusColor(PointySemanticColors colors, String status) {
  return switch (status) {
    'paid' => colors.success,
    'open' => colors.warning,
    'void' => colors.danger,
    _ => colors.mutedInk,
  };
}

enum _InvoiceRowAction { print, share }
