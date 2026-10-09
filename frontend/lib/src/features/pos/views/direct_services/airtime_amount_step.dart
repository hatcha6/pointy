import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../direct_services/foreign_amount.dart';
import '../../view_models/airtime_view_model.dart';
import '../../view_models/service_blocker.dart';
import 'airtime_phone_step.dart';
import 'service_amount_tiles.dart';
import 'service_text_scale.dart';

/// Step three of the airtime form: the amounts the chosen network sells, what
/// the recipient gets big and what the customer pays small — and, for a
/// network that takes any amount, a field of the cashier's own with the
/// limits said in it.
class AirtimeAmountStep extends StatefulWidget {
  const AirtimeAmountStep({
    super.key,
    required this.viewModel,
    this.onSubmitted,
  });

  final AirtimeViewModel viewModel;

  /// Enter in the amount field — the last field of the form.
  final VoidCallback? onSubmitted;

  @override
  State<AirtimeAmountStep> createState() => _AirtimeAmountStepState();
}

class _AirtimeAmountStepState extends State<AirtimeAmountStep> {
  final FocusNode _customFocus = FocusNode(debugLabel: 'service_custom_amount');
  final FocusNode _firstTileFocus = FocusNode(
    debugLabel: 'service_first_amount',
  );
  late int _focusRevision = widget.viewModel.amountFocusRevision;

  @override
  void didUpdateWidget(covariant AirtimeAmountStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    final revision = widget.viewModel.amountFocusRevision;
    if (revision == _focusRevision) {
      return;
    }
    _focusRevision = revision;
    // After the frame: the field may only just have opened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        (widget.viewModel.isCustomOpen ? _customFocus : _firstTileFocus)
            .requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _customFocus.dispose();
    _firstTileFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    final operator = viewModel.operator;
    final country = viewModel.country;
    if (operator == null) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.subtleFill,
          borderRadius: BorderRadius.circular(PointyRadii.input),
          border: Border.all(color: colors.line),
        ),
        child: Text(
          l10n.posAirtimeAmountWaiting,
          style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
        ),
      );
    }

    final directory = viewModel.catalog.directory;
    final receiveLabel = serviceCurrencyLabel(
      l10n,
      country,
      operator.receiveCurrency,
      directory: directory,
    );
    final amountLabel = serviceCurrencyLabel(
      l10n,
      country,
      operator.amountCurrency,
      directory: directory,
    );
    final selected = viewModel.amount;
    final customOpen = viewModel.isCustomOpen;
    final problem = viewModel.customProblem;
    final quote = viewModel.quote.ready;
    final min = operator.min;
    final max = operator.max;

    return LayoutBuilder(
      builder: (context, constraints) {
        final grid = serviceTileColumns(
          constraints.maxWidth,
          minWidth: 104,
          gap: 8,
        );
        final tileHeight = textBoundExtent(context, 84);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (index, tile) in operator.amounts.indexed)
                  SizedBox(
                    width: grid.tileWidth,
                    height: tileHeight,
                    child: ServiceAmountTile(
                      key: ValueKey('service_amount_${tile.amount}'),
                      focusNode: index == 0 ? _firstTileFocus : null,
                      amountText: formatForeignAmountText(tile.received),
                      unitText: serviceCurrencyLabel(
                        l10n,
                        country,
                        tile.receiveCurrency.isEmpty
                            ? operator.receiveCurrency
                            : tile.receiveCurrency,
                        directory: directory,
                      ),
                      price: tile.price,
                      approximate: operator.approximate,
                      selected: !customOpen && selected == tile.amount,
                      onTap: () => viewModel.selectAmount(tile),
                    ),
                  ),
                if (operator.takesCustomAmount)
                  SizedBox(
                    width: grid.tileWidth,
                    height: tileHeight,
                    child: ServiceOtherAmountTile(
                      key: const ValueKey('service_amount_other'),
                      label: l10n.posAirtimeCustom,
                      selected: customOpen,
                      onTap: viewModel.openCustomAmount,
                    ),
                  ),
              ],
            ),
            if (customOpen) ...[
              SizedBox(height: spacing.sm),
              ServiceCustomAmountField(
                focusNode: _customFocus,
                onSubmitted: widget.onSubmitted,
                label: l10n.posAirtimeCustomLabel(amountLabel),
                hint: min != null && max != null
                    ? l10n.posAirtimeCustomRange(
                        formatForeignAmount(min),
                        formatForeignAmount(max),
                      )
                    : l10n.posAirtimeCustomAnyAmount,
                initialText: viewModel.customText,
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
                priceText: quote != null && viewModel.amount != null
                    ? formatMoney(quote.price)
                    : null,
                onChanged: viewModel.setCustomAmount,
              ),
            ],
            if (operator.approximate) ...[
              SizedBox(height: spacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: colors.mutedInk,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.posAirtimeApproximate(receiveLabel),
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
