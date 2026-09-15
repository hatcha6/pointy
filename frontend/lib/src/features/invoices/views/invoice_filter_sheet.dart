import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/user_repository.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/query_controls/query_filter_sheet.dart';
import '../../../shared/user_picker_sheet.dart';

class InvoiceFilterSheet extends StatefulWidget {
  const InvoiceFilterSheet({
    super.key,
    required this.query,
    required this.contactRepository,
    this.userRepository,
  });

  final SaleOrderQuery query;
  final ContactRepository contactRepository;

  /// Given only when the viewer sees shop-wide sales; the cashier section is
  /// omitted otherwise, because the backend scopes the list to that person's
  /// own register sessions and the filter could only ever narrow it to
  /// themselves or to nothing.
  final UserRepository? userRepository;

  @override
  State<InvoiceFilterSheet> createState() => _InvoiceFilterSheetState();
}

class _InvoiceFilterSheetState extends State<InvoiceFilterSheet> {
  late SaleOrderStatusFilter _status = widget.query.status;
  late SaleOrderOrdering _ordering = widget.query.ordering;
  late int? _customerId = widget.query.customerId;
  late String? _customerName = widget.query.customerName;
  late int? _cashierId = widget.query.cashierId;
  late String? _cashierName = widget.query.cashierName;

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
            cashierId: _cashierId,
            cashierName: _cashierName,
          ),
        );
      },
      children: [
        const SizedBox(height: 22),
        if (widget.userRepository != null) ...[
          QueryFilterSection(
            title: l10n.invoiceCashierFilterTitle,
            children: [
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(_cashierName ?? l10n.allCashiersFilterLabel),
                trailing: _cashierId == null
                    ? const PointyDisclosureChevron()
                    : IconButton(
                        tooltip: l10n.clearCashierFilterTooltip,
                        onPressed: () {
                          setState(() {
                            _cashierId = null;
                            _cashierName = null;
                          });
                        },
                        icon: const Icon(Icons.close),
                      ),
                onTap: _chooseCashier,
              ),
            ],
          ),
          const SizedBox(height: 18),
        ],
        QueryFilterSection(
          title: l10n.invoiceCustomerFilterTitle,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(_customerName ?? l10n.allCustomersFilterLabel),
              trailing: _customerId == null
                  ? const PointyDisclosureChevron()
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

  Future<void> _chooseCashier() async {
    final repository = widget.userRepository;
    if (repository == null) {
      return;
    }
    final user = await showUserPickerSheet(
      context: context,
      repository: repository,
      selectedId: _cashierId,
      selectedName: _cashierName,
    );
    if (!mounted || user == null) {
      return;
    }
    setState(() {
      _cashierId = user.id;
      _cashierName = user.name;
    });
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
