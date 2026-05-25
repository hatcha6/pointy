import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/contact.dart';
import '../../../data/models/customer_activity.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/detail_section.dart';
import '../../../shared/formatters.dart';
import '../../../shared/infinite_scroll_grid.dart';
import '../../../shared/payment_labels.dart';
import '../../register_sessions/views/sale_order_details_sheet.dart';
import '../view_models/customer_details_view_model.dart';

class CustomerDetailsScreen extends StatefulWidget {
  const CustomerDetailsScreen({
    super.key,
    required this.customer,
    required this.contactRepository,
  });

  final Customer customer;
  final ContactRepository contactRepository;

  @override
  State<CustomerDetailsScreen> createState() => _CustomerDetailsScreenState();
}

class _CustomerDetailsScreenState extends State<CustomerDetailsScreen> {
  late final CustomerDetailsViewModel _viewModel = CustomerDetailsViewModel(
    contactRepository: widget.contactRepository,
    initialCustomer: widget.customer,
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
        final customer = _viewModel.customer;
        return Scaffold(
          appBar: AppBar(
            title: Text(customer.fullName),
            actions: [
              IconButton(
                tooltip: l10n.refreshCustomerDetailsTooltip,
                onPressed: _viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _CustomerHeader(customer: customer),
                const SizedBox(height: 12),
                DetailSection(
                  title: l10n.customerProfileTitle,
                  icon: Icons.badge_outlined,
                  child: _CustomerProfile(viewModel: _viewModel),
                ),
                const SizedBox(height: 12),
                DetailSection(
                  title: l10n.customerSalesSummaryTitle,
                  icon: Icons.summarize_outlined,
                  child: _CustomerSalesSummary(viewModel: _viewModel),
                ),
                const SizedBox(height: 12),
                DetailSection(
                  title: l10n.customerInvoiceHistoryTitle,
                  icon: Icons.receipt_long_outlined,
                  child: _CustomerInvoiceHistory(viewModel: _viewModel),
                ),
                const SizedBox(height: 12),
                DetailSection(
                  title: l10n.customerAdjustmentHistoryTitle,
                  icon: Icons.assignment_return_outlined,
                  child: _CustomerAdjustmentHistory(viewModel: _viewModel),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CustomerHeader extends StatelessWidget {
  const _CustomerHeader({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  customer.marketingConsent
                      ? Icons.campaign_outlined
                      : Icons.person_outline,
                  color: colorScheme.onPrimary,
                  size: 34,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    customer.fullName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: colorScheme.onPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              [
                if (customer.customerNumber.isNotEmpty)
                  '${l10n.customerNumberLabel}: ${customer.customerNumber}',
                if (customer.phone.isNotEmpty) customer.phone,
                if (customer.email.isNotEmpty) customer.email,
                if (!customer.isActive) l10n.inactiveContactLabel,
              ].join(' • '),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colorScheme.onPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomerProfile extends StatelessWidget {
  const _CustomerProfile({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final customer = viewModel.customer;

    return Column(
      children: [
        if (viewModel.hasCustomerError)
          _ErrorText(text: l10n.customerDetailsLoadError),
        DetailRow(
          label: l10n.customerNumberLabel,
          value: _valueOrEmpty(l10n, customer.customerNumber),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.phoneOptionalLabel,
          value: _valueOrEmpty(l10n, customer.phone),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.emailOptionalLabel,
          value: _valueOrEmpty(l10n, customer.email),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.genderLabel,
          value: genderLabel(l10n, customer.gender),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerBirthdayLabel,
          value: customer.birthday == null
              ? l10n.customerEmptyValue
              : formatDate(customer.birthday!),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerMarketingConsentLabel,
          value: customer.marketingConsent
              ? l10n.marketingAllowedLabel
              : l10n.customerEmptyValue,
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerStatusLabel,
          value: customer.isActive
              ? l10n.activeContactLabel
              : l10n.inactiveContactLabel,
        ),
        if (customer.notes.trim().isNotEmpty) ...[
          const Divider(height: 20),
          _MultilineDetailRow(
            label: l10n.customerNotesLabel,
            value: customer.notes,
          ),
        ],
      ],
    );
  }
}

class _CustomerSalesSummary extends StatelessWidget {
  const _CustomerSalesSummary({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = viewModel.summary;

    if (viewModel.isLoadingSummary && summary.invoiceCount == 0) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        if (viewModel.hasSummaryError)
          _ErrorText(text: l10n.customerSalesSummaryLoadError),
        DetailRow(
          label: l10n.customerTotalInvoicedLabel,
          value: formatMoney(summary.totalInvoiced),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerNetSalesLabel,
          value: formatMoney(summary.netSales),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerInvoiceCountLabel,
          value: l10n.customerInvoiceCountValue(summary.invoiceCount),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerPaidInvoiceCountLabel,
          value: l10n.customerPaidInvoiceCountValue(summary.paidInvoiceCount),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerVoidCountLabel,
          value: l10n.customerVoidCountValue(summary.voidInvoiceCount),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerVoidTotalLabel,
          value: formatMoney(summary.voidTotal),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerReturnCountLabel,
          value: l10n.customerReturnCountValue(summary.returnCount),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerReturnTotalLabel,
          value: formatMoney(summary.returnTotal),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerRefundCountLabel,
          value: l10n.customerRefundCountValue(summary.refundCount),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerRefundTotalLabel,
          value: formatMoney(summary.refundTotal),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerExchangeCountLabel,
          value: l10n.customerExchangeCountValue(summary.exchangeCount),
        ),
        const Divider(height: 20),
        DetailRow(
          label: l10n.customerExchangeTotalLabel,
          value: formatMoney(summary.exchangeTotal),
        ),
        if (summary.lastInvoiceAt != null) ...[
          const Divider(height: 20),
          DetailRow(
            label: l10n.customerLastInvoiceAtLabel,
            value: formatDateTime(summary.lastInvoiceAt!),
          ),
        ],
      ],
    );
  }
}

class _CustomerInvoiceHistory extends StatelessWidget {
  const _CustomerInvoiceHistory({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoadingOrders && viewModel.orderHistory.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.hasOrderError && viewModel.orderHistory.isEmpty) {
      return _ErrorText(text: l10n.customerInvoiceHistoryLoadError);
    }
    if (viewModel.orderHistory.isEmpty) {
      return Text(l10n.customerInvoiceHistoryEmpty);
    }

    return SizedBox(
      height: _historyListHeight(
        viewModel.orderHistory.length,
        viewModel.hasMoreOrders,
      ),
      child: InfiniteScrollList<SaleOrder>(
        items: viewModel.orderHistory,
        onLoadMore: viewModel.loadMoreOrderHistory,
        hasMore: viewModel.hasMoreOrders,
        isLoadingInitial: viewModel.isLoadingOrders,
        isLoadingMore: viewModel.isLoadingMoreOrders,
        emptyBuilder: (context) => Text(l10n.customerInvoiceHistoryEmpty),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, order) {
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text(
              l10n.saleReceiptTitle(
                order.receiptNumber ?? l10n.saleReceiptFallback,
              ),
            ),
            subtitle: Text(
              [
                saleOrderStatusLabel(l10n, order.status),
                if (order.createdAt != null) formatDateTime(order.createdAt!),
                l10n.saleLineCount(order.lines.length),
                if (order.discountTotal > 0)
                  l10n.discountLineValue(formatMoney(order.discountTotal)),
              ].join(' • '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(formatMoney(order.total)),
            onTap: () => showSaleOrderDetailsSheet(context, order),
          );
        },
      ),
    );
  }
}

class _CustomerAdjustmentHistory extends StatelessWidget {
  const _CustomerAdjustmentHistory({required this.viewModel});

  final CustomerDetailsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoadingAdjustments && viewModel.adjustmentHistory.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.hasAdjustmentError && viewModel.adjustmentHistory.isEmpty) {
      return _ErrorText(text: l10n.customerAdjustmentHistoryLoadError);
    }
    if (viewModel.adjustmentHistory.isEmpty) {
      return Text(l10n.customerAdjustmentHistoryEmpty);
    }

    return SizedBox(
      height: _historyListHeight(
        viewModel.adjustmentHistory.length,
        viewModel.hasMoreAdjustments,
      ),
      child: InfiniteScrollList<CustomerAdjustmentHistoryEntry>(
        items: viewModel.adjustmentHistory,
        onLoadMore: viewModel.loadMoreAdjustmentHistory,
        hasMore: viewModel.hasMoreAdjustments,
        isLoadingInitial: viewModel.isLoadingAdjustments,
        isLoadingMore: viewModel.isLoadingMoreAdjustments,
        emptyBuilder: (context) => Text(l10n.customerAdjustmentHistoryEmpty),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, adjustment) {
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_adjustmentIcon(adjustment.type)),
            title: Text(customerAdjustmentTypeLabel(l10n, adjustment.type)),
            subtitle: Text(
              [
                if (adjustment.receiptNumber.isNotEmpty)
                  l10n.saleReceiptTitle(adjustment.receiptNumber),
                if (adjustment.createdAt != null)
                  formatDateTime(adjustment.createdAt!),
                l10n.customerAdjustmentLineCount(adjustment.lines.length),
                l10n.customerRefundMethodValue(
                  paymentMethodLabel(l10n, adjustment.refundMethod),
                ),
                if (adjustment.reason.isNotEmpty) adjustment.reason,
                if (adjustment.createdByUsername.isNotEmpty)
                  l10n.customerAdjustmentCreatedByValue(
                    adjustment.createdByUsername,
                  ),
              ].join(' • '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(formatMoney(adjustment.amount)),
          );
        },
      ),
    );
  }

  IconData _adjustmentIcon(CustomerAdjustmentType type) {
    return switch (type) {
      CustomerAdjustmentType.returnItems => Icons.keyboard_return_outlined,
      CustomerAdjustmentType.voidOrder => Icons.block_outlined,
      CustomerAdjustmentType.exchange => Icons.swap_horiz_outlined,
      CustomerAdjustmentType.refund => Icons.payments_outlined,
      CustomerAdjustmentType.unknown => Icons.assignment_return_outlined,
    };
  }
}

String saleOrderStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'paid' => l10n.saleOrderStatusPaid,
    'void' => l10n.saleOrderStatusVoid,
    'open' => l10n.saleOrderStatusOpen,
    _ => status,
  };
}

String customerAdjustmentTypeLabel(
  AppLocalizations l10n,
  CustomerAdjustmentType type,
) {
  return switch (type) {
    CustomerAdjustmentType.returnItems => l10n.customerAdjustmentTypeReturn,
    CustomerAdjustmentType.voidOrder => l10n.customerAdjustmentTypeVoid,
    CustomerAdjustmentType.exchange => l10n.customerAdjustmentTypeExchange,
    CustomerAdjustmentType.refund => l10n.customerAdjustmentTypeRefund,
    CustomerAdjustmentType.unknown => l10n.customerAdjustmentTypeUnknown,
  };
}

String _valueOrEmpty(AppLocalizations l10n, String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? l10n.customerEmptyValue : trimmed;
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

class _ErrorText extends StatelessWidget {
  const _ErrorText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}

class _MultilineDetailRow extends StatelessWidget {
  const _MultilineDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Text(value),
      ],
    );
  }
}
