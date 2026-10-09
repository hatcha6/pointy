import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/repositories/integrations_repository.dart';
import '../../../shared/components/components.dart';
import '../view_models/voucher_pricing_view_model.dart';
import 'voucher_pricing_cards_tab.dart';
import 'voucher_pricing_services_tab.dart';

/// Opens «أسعار كروت دفتر» (owner and manager).
Future<void> showVoucherPricingScreen(
  BuildContext context,
  IntegrationsRepository repository, {
  bool belowCost = false,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VoucherPricingScreen(
        viewModel: VoucherPricingViewModel(repository),
        ownsViewModel: true,
        initialTab: belowCost ? 1 : 0,
        initialBelowCost: belowCost,
      ),
    ),
  );
}

/// Whether the shop follows the company's suggested prices or sets its own,
/// for the direct services and for each card.
class VoucherPricingScreen extends StatefulWidget {
  const VoucherPricingScreen({
    super.key,
    required this.viewModel,
    this.ownsViewModel = false,
    this.initialTab = 0,
    this.initialBelowCost = false,
  });

  final VoucherPricingViewModel viewModel;
  final bool ownsViewModel;
  final int initialTab;

  /// Opens on the cards blocked for being priced under cost (from the alert).
  final bool initialBelowCost;

  @override
  State<VoucherPricingScreen> createState() => _VoucherPricingScreenState();
}

class _VoucherPricingScreenState extends State<VoucherPricingScreen> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.loadPricing();
    widget.viewModel.loadCards(belowCostOnly: widget.initialBelowCost);
  }

  @override
  void dispose() {
    if (widget.ownsViewModel) {
      widget.viewModel.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final vm = widget.viewModel;
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.voucherPricingTitle),
          bottom: TabBar(
            tabs: [
              Tab(
                key: const ValueKey('pricing_tab_services'),
                text: l10n.voucherPricingTabServices,
              ),
              Tab(
                key: const ValueKey('pricing_tab_cards'),
                text: l10n.voucherPricingTabCards,
              ),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: vm,
          builder: (context, _) {
            if (vm.isForbidden) {
              return PointyErrorState(
                title: l10n.voucherPricingForbidden,
                icon: Icons.lock_outline_rounded,
              );
            }
            return TabBarView(
              children: [
                VoucherPricingServicesTab(viewModel: vm),
                VoucherPricingCardsTab(viewModel: vm),
              ],
            );
          },
        ),
      ),
    );
  }
}
