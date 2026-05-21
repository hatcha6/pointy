import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/discount_rule.dart';
import '../../../shared/query_controls/query_filter_sheet.dart';

class DiscountRuleFilterSheet extends StatefulWidget {
  const DiscountRuleFilterSheet({super.key, required this.query});

  final DiscountRuleQuery query;

  @override
  State<DiscountRuleFilterSheet> createState() =>
      _DiscountRuleFilterSheetState();
}

class _DiscountRuleFilterSheetState extends State<DiscountRuleFilterSheet> {
  late var _status = widget.query.status;
  late var _channel = widget.query.channel;
  late var _application = widget.query.application;
  late var _ordering = widget.query.ordering;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryFilterSheet(
      title: l10n.filtersSheetTitle,
      resetLabel: l10n.resetFiltersButton,
      applyLabel: l10n.applyFiltersButton,
      onReset: _reset,
      onApply: _apply,
      children: [
        const SizedBox(height: 22),
        QueryFilterSection(
          title: l10n.discountStatusFilterLabel,
          children: [
            for (final status in DiscountRuleStatusFilter.values)
              QueryFilterOptionTile(
                label: discountRuleStatusFilterLabel(l10n, status),
                icon: _statusIcon(status),
                isSelected: _status == status,
                onTap: () => setState(() => _status = status),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.discountChannelLabel,
          children: [
            for (final channel in DiscountRuleChannelFilter.values)
              QueryFilterOptionTile(
                label: discountRuleChannelFilterLabel(l10n, channel),
                icon: _channelIcon(channel),
                isSelected: _channel == channel,
                onTap: () => setState(() => _channel = channel),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.discountApplicationTypeLabel,
          children: [
            for (final application in DiscountRuleApplicationFilter.values)
              QueryFilterOptionTile(
                label: discountRuleApplicationFilterLabel(l10n, application),
                icon: _applicationIcon(application),
                isSelected: _application == application,
                onTap: () => setState(() => _application = application),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.discountOrderingLabel,
          children: [
            for (final ordering in DiscountRuleOrdering.values)
              QueryFilterOptionTile(
                label: discountRuleOrderingLabel(l10n, ordering),
                icon: _orderingIcon(ordering),
                isSelected: _ordering == ordering,
                onTap: () => setState(() => _ordering = ordering),
              ),
          ],
        ),
      ],
    );
  }

  void _reset() {
    setState(() {
      _status = DiscountRuleStatusFilter.all;
      _channel = DiscountRuleChannelFilter.all;
      _application = DiscountRuleApplicationFilter.all;
      _ordering = DiscountRuleOrdering.priority;
    });
  }

  void _apply() {
    Navigator.of(context).pop(
      widget.query.copyWith(
        status: _status,
        channel: _channel,
        application: _application,
        ordering: _ordering,
      ),
    );
  }

  IconData _statusIcon(DiscountRuleStatusFilter status) {
    return switch (status) {
      DiscountRuleStatusFilter.all => Icons.all_inbox_outlined,
      DiscountRuleStatusFilter.active => Icons.check_circle_outline,
      DiscountRuleStatusFilter.inactive => Icons.pause_circle_outline,
    };
  }

  IconData _channelIcon(DiscountRuleChannelFilter channel) {
    return switch (channel) {
      DiscountRuleChannelFilter.all => Icons.storefront_outlined,
      DiscountRuleChannelFilter.sales => Icons.point_of_sale_outlined,
      DiscountRuleChannelFilter.purchasing => Icons.local_shipping_outlined,
      DiscountRuleChannelFilter.both => Icons.sync_alt_outlined,
    };
  }

  IconData _applicationIcon(DiscountRuleApplicationFilter application) {
    return switch (application) {
      DiscountRuleApplicationFilter.all => Icons.discount_outlined,
      DiscountRuleApplicationFilter.automatic => Icons.auto_awesome_outlined,
      DiscountRuleApplicationFilter.couponCode =>
        Icons.confirmation_num_outlined,
    };
  }

  IconData _orderingIcon(DiscountRuleOrdering ordering) {
    return switch (ordering) {
      DiscountRuleOrdering.priority => Icons.low_priority_outlined,
      DiscountRuleOrdering.name => Icons.sort_by_alpha,
      DiscountRuleOrdering.newest => Icons.schedule_outlined,
      DiscountRuleOrdering.updated => Icons.update_outlined,
    };
  }
}

String discountRuleStatusFilterLabel(
  AppLocalizations l10n,
  DiscountRuleStatusFilter status,
) {
  return switch (status) {
    DiscountRuleStatusFilter.all => l10n.discountFilterAll,
    DiscountRuleStatusFilter.active => l10n.discountStatusActive,
    DiscountRuleStatusFilter.inactive => l10n.discountStatusInactive,
  };
}

String discountRuleChannelFilterLabel(
  AppLocalizations l10n,
  DiscountRuleChannelFilter channel,
) {
  return switch (channel) {
    DiscountRuleChannelFilter.all => l10n.discountFilterAll,
    DiscountRuleChannelFilter.sales => l10n.discountChannelSales,
    DiscountRuleChannelFilter.purchasing => l10n.discountChannelPurchasing,
    DiscountRuleChannelFilter.both => l10n.discountChannelBoth,
  };
}

String discountRuleApplicationFilterLabel(
  AppLocalizations l10n,
  DiscountRuleApplicationFilter application,
) {
  return switch (application) {
    DiscountRuleApplicationFilter.all => l10n.discountFilterAll,
    DiscountRuleApplicationFilter.automatic =>
      l10n.discountApplicationAutomatic,
    DiscountRuleApplicationFilter.couponCode => l10n.discountApplicationCoupon,
  };
}

String discountRuleOrderingLabel(
  AppLocalizations l10n,
  DiscountRuleOrdering ordering,
) {
  return switch (ordering) {
    DiscountRuleOrdering.priority => l10n.discountOrderingPriority,
    DiscountRuleOrdering.name => l10n.discountOrderingName,
    DiscountRuleOrdering.newest => l10n.discountOrderingNewest,
    DiscountRuleOrdering.updated => l10n.discountOrderingUpdated,
  };
}
