import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/query_controls/query_control_bar.dart';
import '../../../shared/responsive/responsive.dart';
import 'invoice_filter_sheet.dart';

class InvoiceQueryControls extends StatelessWidget {
  const InvoiceQueryControls({
    super.key,
    required this.query,
    required this.contactRepository,
    required this.onSearchChanged,
    required this.onQueryChanged,
    this.enabled = true,
  });

  final SaleOrderQuery query;
  final ContactRepository contactRepository;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<SaleOrderQuery> onQueryChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryControlBar(
      searchValue: query.search,
      searchHint: l10n.searchInvoicesHint,
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
    return (query.status == SaleOrderStatusFilter.all ? 0 : 1) +
        (query.ordering == SaleOrderOrdering.newest ? 0 : 1) +
        (query.customerId == null ? 0 : 1);
  }

  Future<void> _showFilters(BuildContext context) async {
    final updatedQuery = await showAdaptiveModalBottomSheet<SaleOrderQuery>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (context) => InvoiceFilterSheet(
        query: query,
        contactRepository: contactRepository,
      ),
    );

    if (updatedQuery != null) {
      onQueryChanged(updatedQuery);
    }
  }
}
