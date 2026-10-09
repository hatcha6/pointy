import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_country_detail.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../direct_services/foreign_amount.dart';
import '../../view_models/bill_flow_view_model.dart';
import '../../view_models/service_blocker.dart';
import 'airtime_phone_step.dart';
import 'service_amount_tiles.dart';
import 'service_text_scale.dart';

/// Step four of a bill: how much. A provider that takes any amount offers
/// round suggestions and a field with its limits in it; one that sells plans
/// lists them with their Arabic descriptions; a postpaid bill asks for the
/// invoice total exactly as it is written on the invoice.
class BillAmountStep extends StatelessWidget {
  const BillAmountStep({super.key, required this.viewModel});

  final BillFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final vm = viewModel;
    final biller = vm.biller;
    final country = vm.country;
    if (biller == null || country == null) {
      return const SizedBox.shrink();
    }
    final unit = serviceCurrencyLabel(
      l10n,
      country,
      biller.amountCurrency,
      directory: vm.catalog.directory,
    );

    if (biller.isFixed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final plan in biller.plans)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ServicePlanTile(
                key: ValueKey('bill_plan_${plan.id}'),
                description: plan.label,
                amountText: formatForeignAmountText(plan.amount),
                unitText: unit,
                price: plan.price,
                selected: vm.plan?.id == plan.id,
                onTap: () {
                  vm.selectPlan(plan);
                  vm.continueFromAmount();
                },
              ),
            ),
        ],
      );
    }

    final suggestions = biller.requiresInvoice
        ? const <BillAmount>[]
        : biller.suggested;
    final problem = vm.customProblem;
    final min = biller.min;
    final max = biller.max;
    final quote = vm.quote.ready;
    return LayoutBuilder(
      builder: (context, constraints) {
        final grid = serviceTileColumns(
          constraints.maxWidth,
          minWidth: 120,
          gap: 8,
        );
        final customOpen = vm.isCustomOpen || suggestions.isEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (suggestions.isNotEmpty) ...[
              Text(
                l10n.posBillSuggestedAmounts,
                style: textTheme.labelLarge?.copyWith(
                  color: colors.mutedInk,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final suggestion in biller.suggested)
                    SizedBox(
                      width: grid.tileWidth,
                      height: textBoundExtent(context, 88),
                      child: ServiceAmountTile(
                        key: ValueKey('bill_amount_${suggestion.amount}'),
                        amountText: formatForeignAmountText(suggestion.amount),
                        unitText: unit,
                        price: suggestion.price,
                        selected:
                            !vm.isCustomOpen && vm.amount == suggestion.amount,
                        onTap: () {
                          vm.selectSuggestion(suggestion);
                          vm.continueFromAmount();
                        },
                      ),
                    ),
                  SizedBox(
                    width: grid.tileWidth,
                    height: textBoundExtent(context, 88),
                    child: ServiceOtherAmountTile(
                      key: const ValueKey('bill_amount_other'),
                      label: l10n.posAirtimeCustom,
                      selected: vm.isCustomOpen,
                      onTap: vm.openCustomAmount,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (customOpen) ...[
              if (biller.requiresInvoice)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.receipt_long_rounded,
                        size: 18,
                        color: colors.primaryStrong,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          l10n.posBillInvoiceAmountNote,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colors.ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ServiceCustomAmountField(
                label: l10n.posAirtimeCustomLabel(unit),
                hint: min != null && max != null
                    ? l10n.posAirtimeCustomRange(
                        formatForeignAmount(min),
                        formatForeignAmount(max),
                      )
                    : l10n.posAirtimeCustomAnyAmount,
                initialText: vm.customText,
                errorText: switch (problem) {
                  ServiceAmountProblem.invalid => l10n.posAirtimeCustomInvalid,
                  ServiceAmountProblem.belowMin => l10n.posAirtimeCustomTooLow(
                    formatForeignAmount(min ?? 0),
                  ),
                  ServiceAmountProblem.aboveMax => l10n.posAirtimeCustomTooHigh(
                    formatForeignAmount(max ?? 0),
                  ),
                  null => null,
                },
                helperText: min != null && max != null && problem == null
                    ? l10n.posAirtimeCustomRange(
                        formatForeignAmount(min),
                        formatForeignAmount(max),
                      )
                    : null,
                priceText: quote != null && vm.amount != null
                    ? formatMoney(quote.price)
                    : null,
                autofocus: suggestions.isEmpty,
                onChanged: vm.setCustomAmount,
                onSubmitted: vm.continueFromAmount,
              ),
            ],
          ],
        );
      },
    );
  }
}
