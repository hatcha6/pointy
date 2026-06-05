import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/query_controls/query_filter_sheet.dart';

class InvoiceFilterSheet extends StatefulWidget {
  const InvoiceFilterSheet({
    super.key,
    required this.query,
    required this.contactRepository,
  });

  final SaleOrderQuery query;
  final ContactRepository contactRepository;

  @override
  State<InvoiceFilterSheet> createState() => _InvoiceFilterSheetState();
}

class _InvoiceFilterSheetState extends State<InvoiceFilterSheet> {
  late SaleOrderStatusFilter _status = widget.query.status;
  late SaleOrderOrdering _ordering = widget.query.ordering;
  late int? _customerId = widget.query.customerId;
  late String? _customerName = widget.query.customerName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryFilterSheet(
      title: l10n.filtersSheetTitle,
      resetLabel: l10n.resetFiltersButton,
      applyLabel: l10n.applyFiltersButton,
      onReset: () => Navigator.of(context).pop(const SaleOrderQuery()),
      onApply: () {
        Navigator.of(context).pop(
          widget.query.copyWith(
            status: _status,
            ordering: _ordering,
            customerId: _customerId,
            customerName: _customerName,
          ),
        );
      },
      children: [
        const SizedBox(height: 22),
        QueryFilterSection(
          title: l10n.invoiceCustomerFilterTitle,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(_customerName ?? l10n.allCustomersFilterLabel),
              trailing: _customerId == null
                  ? const Icon(Icons.chevron_right)
                  : IconButton(
                      tooltip: l10n.clearCustomerFilterTooltip,
                      onPressed: () {
                        setState(() {
                          _customerId = null;
                          _customerName = null;
                        });
                      },
                      icon: const Icon(Icons.close),
                    ),
              onTap: _chooseCustomer,
            ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.invoiceStatusFilterTitle,
          children: [
            for (final status in SaleOrderStatusFilter.values)
              QueryFilterOptionTile(
                label: saleOrderStatusFilterLabel(l10n, status),
                icon: _statusIcon(status),
                isSelected: _status == status,
                onTap: () => setState(() => _status = status),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.orderingTitle,
          children: [
            for (final ordering in SaleOrderOrdering.values)
              QueryFilterOptionTile(
                label: saleOrderOrderingLabel(l10n, ordering),
                icon: _orderingIcon(ordering),
                isSelected: _ordering == ordering,
                onTap: () => setState(() => _ordering = ordering),
              ),
          ],
        ),
      ],
    );
  }

  IconData _statusIcon(SaleOrderStatusFilter status) {
    return switch (status) {
      SaleOrderStatusFilter.all => Icons.all_inbox_outlined,
      SaleOrderStatusFilter.open => Icons.pending_outlined,
      SaleOrderStatusFilter.paid => Icons.check_circle_outline,
      SaleOrderStatusFilter.voided => Icons.block_outlined,
    };
  }

  IconData _orderingIcon(SaleOrderOrdering ordering) {
    return switch (ordering) {
      SaleOrderOrdering.newest => Icons.schedule_outlined,
      SaleOrderOrdering.updated => Icons.update_outlined,
      SaleOrderOrdering.totalDesc => Icons.payments_outlined,
      SaleOrderOrdering.receiptNumber => Icons.tag_outlined,
    };
  }

  Future<void> _chooseCustomer() async {
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (!mounted || customer == null) {
      return;
    }
    setState(() {
      _customerId = customer.id;
      _customerName = customer.fullName;
    });
  }
}

String saleOrderStatusFilterLabel(
  AppLocalizations l10n,
  SaleOrderStatusFilter status,
) {
  return switch (status) {
    SaleOrderStatusFilter.all => l10n.invoiceStatusAll,
    SaleOrderStatusFilter.open => l10n.invoiceStatusOpen,
    SaleOrderStatusFilter.paid => l10n.invoiceStatusPaid,
    SaleOrderStatusFilter.voided => l10n.invoiceStatusVoid,
  };
}

String saleOrderOrderingLabel(
  AppLocalizations l10n,
  SaleOrderOrdering ordering,
) {
  return switch (ordering) {
    SaleOrderOrdering.newest => l10n.invoiceOrderingNewest,
    SaleOrderOrdering.updated => l10n.invoiceOrderingUpdated,
    SaleOrderOrdering.totalDesc => l10n.invoiceOrderingTotalDesc,
    SaleOrderOrdering.receiptNumber => l10n.invoiceOrderingReceiptNumber,
  };
}
