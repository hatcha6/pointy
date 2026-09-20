import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_card.dart';
import '../../../data/models/integration_provider.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/integrations_view_model.dart';
import 'integration_presentation.dart';

/// The owner's retail prices for one provider. Resolves true when saved.
Future<bool?> showIntegrationPricesSheet({
  required BuildContext context,
  required IntegrationProviderKey providerKey,
  required IntegrationsViewModel viewModel,
}) {
  final l10n = AppLocalizations.of(context)!;
  viewModel.loadPrices(providerKey);
  return showAdaptiveFormSurface<bool>(
    context: context,
    title:
        '${l10n.integrationPricesTitle} · ${integrationProviderName(providerKey, l10n)}',
    size: AdaptiveModalSize.expanded,
    builder: (sheetContext) =>
        IntegrationPricesForm(viewModel: viewModel, providerKey: providerKey),
  );
}

/// Prices the things the provider has actually quoted this shop.
///
/// The list is learned rather than configured: HD Box only states its ladder
/// inside a per-card renew form, so until somebody looks a card up there is
/// nothing here to price — and the empty state says exactly that instead of
/// looking broken.
class IntegrationPricesForm extends StatefulWidget {
  const IntegrationPricesForm({
    super.key,
    required this.viewModel,
    required this.providerKey,
  });

  final IntegrationsViewModel viewModel;
  final IntegrationProviderKey providerKey;

  @override
  State<IntegrationPricesForm> createState() => _IntegrationPricesFormState();
}

class _IntegrationPricesFormState extends State<IntegrationPricesForm> {
  /// Only what the owner actually touched is sent, so a save never rewrites a
  /// price somebody else changed in the meantime.
  final Map<String, double?> _edited = {};
  final Map<String, TextEditingController> _controllers = {};
  String _seededFor = '';

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _seed(IntegrationPriceList list) {
    // Re-seed only when a different list arrives, or typing would be undone
    // on every rebuild.
    final signature = list.options.map((o) => o.optionCode).join(',');
    if (_seededFor == signature) return;
    _seededFor = signature;
    for (final option in list.options) {
      _controllers.putIfAbsent(
        option.optionCode,
        () => TextEditingController(
          // Seeded from the owner's OWN price only. A recommendation lives in
          // the hint, so a row nobody has touched still reads as "following
          // the provider" rather than as a number somebody typed.
          text: option.price == null ? '' : option.price!.toStringAsFixed(2),
        ),
      );
    }
  }

  Future<void> _save() async {
    final saved = await widget.viewModel.savePrices(
      widget.providerKey,
      _edited,
    );
    if (!mounted || !saved) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        if (viewModel.isLoadingPrices) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: PointyLoadingArea(),
          );
        }
        final list = viewModel.priceList;
        if (list == null || list.isEmpty) {
          return Padding(
            padding: EdgeInsets.all(spacing.md),
            child: PointyEmptyState(
              icon: Icons.price_change_outlined,
              title: l10n.integrationPricesEmpty,
            ),
          );
        }
        _seed(list);

        return Padding(
          padding: EdgeInsets.all(spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.integrationPricesUnsetHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.pointyColors.mutedInk,
                ),
              ),
              if (list.hasBelowCost) ...[
                SizedBox(height: spacing.sm),
                PointyInlineMessage.warning(
                  message: l10n.integrationPricesBelowCostBanner,
                  compact: true,
                ),
              ],
              SizedBox(height: spacing.md),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Durations only. Package switches are not offered
                      // anywhere in Pointy — see the recharge view model.
                      _section(
                        context,
                        l10n.integrationPricesRenewals,
                        list.options,
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: spacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: viewModel.isSavingPrices
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: Text(l10n.integrationCancel),
                  ),
                  SizedBox(width: spacing.sm),
                  FilledButton.icon(
                    onPressed: viewModel.isSavingPrices || _edited.isEmpty
                        ? null
                        : _save,
                    icon: viewModel.isSavingPrices
                        ? const SizedBox.square(
                            dimension: 16,
                            child: PointySpinner(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(l10n.integrationPricesSave),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    List<IntegrationOptionPrice> options,
  ) {
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: context.pointyColors.mutedInk,
          ),
        ),
        SizedBox(height: spacing.xs),
        for (final option in options)
          _PriceRow(
            option: option,
            controller: _controllers[option.optionCode]!,
            onChanged: (value) {
              setState(() => _edited[option.optionCode] = value);
            },
          ),
      ],
    );
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({
    required this.option,
    required this.controller,
    required this.onChanged,
  });

  final IntegrationOptionPrice option;
  final TextEditingController controller;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);

    final name = option.months > 0
        ? l10n.rechargeMonths(option.months)
        : option.label;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: theme.textTheme.titleSmall),
                Text(
                  '${l10n.integrationPricesCost} ${formatMoney(option.lastCost)}'
                  '${option.margin == null ? '' : ' · ${l10n.integrationPricesMargin} ${formatMoney(option.margin!)}'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: option.isBelowCost ? colors.danger : colors.mutedInk,
                  ),
                ),
                if (option.isSuggested && option.suggestedPrice != null)
                  Text(
                    l10n.integrationPricesFollowingSuggestion(
                      formatMoney(option.suggestedPrice!),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.primaryStrong,
                    ),
                  ),
                if (option.isBelowCost)
                  Text(
                    l10n.integrationPricesBelowCost,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.danger,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(width: spacing.sm),
          SizedBox(
            width: 128,
            child: TextField(
              controller: controller,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.end,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                isDense: true,
                labelText: l10n.integrationPricesSell,
                // Float the label permanently, or Material parks it inside an
                // empty field and hides the hint — which is exactly where the
                // provider's recommended number lives.
                floatingLabelBehavior: FloatingLabelBehavior.always,
                // A blank field is not an unfilled form: it means "use the
                // provider's recommendation", and the hint shows what that
                // number actually is.
                hintText: option.suggestedPrice == null
                    ? l10n.integrationPricesUnset
                    : option.suggestedPrice!.toStringAsFixed(2),
              ),
              onChanged: (text) {
                final trimmed = text.trim();
                onChanged(trimmed.isEmpty ? null : double.tryParse(trimmed));
              },
            ),
          ),
        ],
      ),
    );
  }
}
