import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/exchange_rate.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// Picks the currency a product's price sheet is written in, and shows what the
/// entered price becomes in the shop's own currency.
///
/// The whole point of the preview line is that the conversion is **not** a
/// mystery the owner discovers after saving. They type 12, they see
/// "≈ 82.20 د.ل at 6.85", and that is exactly the number that gets stored —
/// frozen at that rate until somebody deliberately reprices.
///
/// Hidden entirely when the shop has no other currencies enabled, so a shop with
/// no foreign exposure never meets the concept.
class PricingCurrencyField extends StatelessWidget {
  const PricingCurrencyField({
    super.key,
    required this.currencies,
    required this.baseCurrencyCode,
    required this.selectedCode,
    required this.onChanged,
    required this.rate,
    required this.enteredAmount,
  });

  final List<Currency> currencies;
  final String baseCurrencyCode;

  /// Blank means the shop's own currency.
  final String selectedCode;
  final ValueChanged<String> onChanged;

  /// The resolved rate for [selectedCode], or null when none is known.
  final ResolvedRate? rate;

  /// The number currently typed in the price field, for the live preview.
  final double? enteredAmount;

  bool get _isForeign => selectedCode.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (currencies.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('product_pricing_currency_field'),
          initialValue: selectedCode,
          decoration: InputDecoration(
            labelText: l10n.productPricingCurrencyLabel,
            prefixIcon: const Icon(Icons.currency_exchange_outlined),
            helperText: _isForeign ? l10n.productPricingCurrencyHelp : null,
            helperMaxLines: 3,
          ),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(
                '${l10n.productPricingCurrencyBase} '
                '(${currencySymbolFor(baseCurrencyCode)})',
              ),
            ),
            for (final currency in currencies)
              DropdownMenuItem(
                value: currency.code,
                child: Text('${currency.name} (${currency.code})'),
              ),
          ],
          onChanged: (value) => onChanged(value ?? ''),
        ),
        if (_isForeign) ...[
          const SizedBox(height: 8),
          _ConversionPreview(
            currencyCode: selectedCode,
            rate: rate,
            enteredAmount: enteredAmount,
            textStyle: theme.textTheme.bodySmall,
            colors: colors,
          ),
        ],
      ],
    );
  }
}

class _ConversionPreview extends StatelessWidget {
  const _ConversionPreview({
    required this.currencyCode,
    required this.rate,
    required this.enteredAmount,
    required this.textStyle,
    required this.colors,
  });

  final String currencyCode;
  final ResolvedRate? rate;
  final double? enteredAmount;
  final TextStyle? textStyle;
  final PointySemanticColors colors;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final resolved = rate;

    // No rate at all. Say so plainly instead of showing a converted number we
    // cannot stand behind — the price is still saved, and reprices itself the
    // moment a rate arrives.
    if (resolved == null) {
      return _line(
        Icons.help_outline,
        l10n.productPricingNoRate(currencyCode),
        colors.warning,
      );
    }

    final amount = enteredAmount;
    if (amount == null) {
      return _line(
        Icons.info_outline,
        formatExchangeRate(resolved.rate, currencyCode, resolved.toCode),
        colors.mutedInk,
      );
    }

    final converted = amount * resolved.rate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(
          Icons.swap_horiz,
          formatDualPrice(amount, currencyCode, converted),
          colors.ink,
        ),
        const SizedBox(height: 4),
        _line(
          resolved.isStale ? Icons.schedule : Icons.check_circle_outline,
          formatExchangeRate(resolved.rate, currencyCode, resolved.toCode),
          resolved.isStale ? colors.warning : colors.mutedInk,
        ),
        if (resolved.isStale) ...[
          const SizedBox(height: 4),
          _line(
            Icons.warning_amber_outlined,
            l10n.exchangeRateStaleBadge,
            colors.warning,
          ),
        ],
      ],
    );
  }

  Widget _line(IconData icon, String text, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: textStyle?.copyWith(color: color)),
        ),
      ],
    );
  }
}
