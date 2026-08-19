import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/query_controls/query_control_bar.dart';
import '../../../shared/responsive/responsive.dart';
import 'purchase_order_filter_sheet.dart';

class PurchaseOrderQueryControls extends StatelessWidget {
  const PurchaseOrderQueryControls({
    super.key,
    required this.query,
    required this.contactRepository,
    required this.onSearchChanged,
    required this.onQueryChanged,
    this.enabled = true,
  });

  final PurchaseOrderQuery query;
  final ContactRepository contactRepository;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<PurchaseOrderQuery> onQueryChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryControlBar(
      searchValue: query.search,
      searchHint: l10n.searchPurchaseOrdersHint,
      clearSearchTooltip: l10n.clearSearchTooltip,
      filterLabel: l10n.filtersButtonLabel,
      openFiltersTooltip: l10n.openFiltersTooltip,
      activeFilterCount: _activeFilterCount,
      onSearchChanged: onSearchChanged,
      onOpenFilters: () => _showFilters(context),
      enabled: enabled,
    );
  }

  int get _activeFilterCount {
    return narrowingFilterCount(query) +
        (query.ordering == PurchaseOrderOrdering.newest ? 0 : 1);
  }

  /// How many user-set filters can actually empty the list. Ordering is
  /// excluded — it reorders, never removes — and so are
  /// [PurchaseOrderQuery.productId] / [PurchaseOrderQuery.variantId], which
  /// callers set to scope a listing rather than the user.
  static int narrowingFilterCount(PurchaseOrderQuery query) {
    return (query.status == PurchaseOrderStatusFilter.all ? 0 : 1) +
        (query.supplierId == null ? 0 : 1);
  }

  /// Drops the search term and every user-set filter, keeping the caller's
  /// scope and the chosen ordering intact.
  static PurchaseOrderQuery cleared(PurchaseOrderQuery query) {
    return query.copyWith(
      search: '',
      status: PurchaseOrderStatusFilter.all,
      supplierId: null,
      supplierName: null,
    );
  }

  Future<void> _showFilters(BuildContext context) async {
    final updatedQuery = await showAdaptiveModalBottomSheet<PurchaseOrderQuery>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (context) => PurchaseOrderFilterSheet(
        query: query,
        contactRepository: contactRepository,
      ),
    );

    if (updatedQuery != null) {
      onQueryChanged(updatedQuery);
    }
  }
}
