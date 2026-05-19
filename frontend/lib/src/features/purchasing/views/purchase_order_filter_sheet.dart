import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/query_controls/query_filter_sheet.dart';

class PurchaseOrderFilterSheet extends StatefulWidget {
  const PurchaseOrderFilterSheet({
    super.key,
    required this.query,
    required this.contactRepository,
  });

  final PurchaseOrderQuery query;
  final ContactRepository contactRepository;

  @override
  State<PurchaseOrderFilterSheet> createState() =>
      _PurchaseOrderFilterSheetState();
}

class _PurchaseOrderFilterSheetState extends State<PurchaseOrderFilterSheet> {
  late PurchaseOrderStatusFilter _status = widget.query.status;
  late PurchaseOrderOrdering _ordering = widget.query.ordering;
  late int? _supplierId = widget.query.supplierId;
  late String? _supplierName = widget.query.supplierName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryFilterSheet(
      title: l10n.filtersSheetTitle,
      resetLabel: l10n.resetFiltersButton,
      applyLabel: l10n.applyFiltersButton,
      onReset: () => Navigator.of(context).pop(const PurchaseOrderQuery()),
      onApply: () {
        Navigator.of(context).pop(
          widget.query.copyWith(
            status: _status,
            ordering: _ordering,
            supplierId: _supplierId,
            supplierName: _supplierName,
          ),
        );
      },
      children: [
        const SizedBox(height: 22),
        QueryFilterSection(
          title: l10n.purchaseOrderSupplierFilterTitle,
          children: [
            ListTile(
              leading: const Icon(Icons.local_shipping_outlined),
              title: Text(_supplierName ?? l10n.allSuppliersFilterLabel),
              trailing: _supplierId == null
                  ? const Icon(Icons.chevron_right)
                  : IconButton(
                      tooltip: l10n.clearSupplierFilterTooltip,
                      onPressed: () {
                        setState(() {
                          _supplierId = null;
                          _supplierName = null;
                        });
                      },
                      icon: const Icon(Icons.close),
                    ),
              onTap: _chooseSupplier,
            ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.purchaseOrderStatusFilterTitle,
          children: [
            for (final status in PurchaseOrderStatusFilter.values)
              QueryFilterOptionTile(
                label: purchaseOrderStatusFilterLabel(l10n, status),
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
            for (final ordering in PurchaseOrderOrdering.values)
              QueryFilterOptionTile(
                label: purchaseOrderOrderingLabel(l10n, ordering),
                icon: _orderingIcon(ordering),
                isSelected: _ordering == ordering,
                onTap: () => setState(() => _ordering = ordering),
              ),
          ],
        ),
      ],
    );
  }

  IconData _statusIcon(PurchaseOrderStatusFilter status) {
    return switch (status) {
      PurchaseOrderStatusFilter.all => Icons.all_inbox_outlined,
      PurchaseOrderStatusFilter.draft => Icons.edit_note_outlined,
      PurchaseOrderStatusFilter.submitted => Icons.send_outlined,
      PurchaseOrderStatusFilter.received => Icons.inventory_outlined,
      PurchaseOrderStatusFilter.cancelled => Icons.cancel_outlined,
    };
  }

  IconData _orderingIcon(PurchaseOrderOrdering ordering) {
    return switch (ordering) {
      PurchaseOrderOrdering.newest => Icons.schedule_outlined,
      PurchaseOrderOrdering.updated => Icons.update_outlined,
      PurchaseOrderOrdering.totalDesc => Icons.payments_outlined,
      PurchaseOrderOrdering.orderNumber => Icons.tag_outlined,
    };
  }

  Future<void> _chooseSupplier() async {
    final supplier = await showSupplierPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (!mounted || supplier == null) {
      return;
    }
    setState(() {
      _supplierId = supplier.id;
      _supplierName = supplier.name;
    });
  }
}

String purchaseOrderStatusFilterLabel(
  AppLocalizations l10n,
  PurchaseOrderStatusFilter status,
) {
  return switch (status) {
    PurchaseOrderStatusFilter.all => l10n.purchaseOrderStatusAll,
    PurchaseOrderStatusFilter.draft => l10n.purchaseOrderStatusDraft,
    PurchaseOrderStatusFilter.submitted => l10n.purchaseOrderStatusSubmitted,
    PurchaseOrderStatusFilter.received => l10n.purchaseOrderStatusReceived,
    PurchaseOrderStatusFilter.cancelled => l10n.purchaseOrderStatusCancelled,
  };
}

String purchaseOrderOrderingLabel(
  AppLocalizations l10n,
  PurchaseOrderOrdering ordering,
) {
  return switch (ordering) {
    PurchaseOrderOrdering.newest => l10n.purchaseOrderOrderingNewest,
    PurchaseOrderOrdering.updated => l10n.purchaseOrderOrderingUpdated,
    PurchaseOrderOrdering.totalDesc => l10n.purchaseOrderOrderingTotalDesc,
    PurchaseOrderOrdering.orderNumber => l10n.purchaseOrderOrderingNumber,
  };
}

String purchaseOrderStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'draft' => l10n.purchaseOrderStatusDraft,
    'submitted' => l10n.purchaseOrderStatusSubmitted,
    'received' => l10n.purchaseOrderStatusReceived,
    'cancelled' => l10n.purchaseOrderStatusCancelled,
    _ => status,
  };
}
