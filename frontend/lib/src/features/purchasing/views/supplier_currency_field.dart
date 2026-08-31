import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/exchange_rate.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// Picks the currency a supplier invoiced in, and shows what it costs the shop.
///
/// Three things it makes visible, none of which the buyer should have to work
/// out for themselves:
///
/// * **which rate** the order will be costed at, and **which date** that rate
///   was read as of — the supplier's invoice date, not today, because an
///   invoice billed last Tuesday was priced at Tuesday's rate;
/// * **the invoice total in the supplier's own currency**, so the screen can be
///   checked against the paper invoice it was typed from;
/// * **a rate the buyer types**, which overrides the feed — a shop that
///   negotiated its own rate with a changer records that one.
///
/// Hidden entirely when the shop has no other currencies enabled.
class SupplierCurrencyField extends StatefulWidget {
  const SupplierCurrencyField({
    super.key,
    required this.currencies,
    required this.baseCurrencyCode,
    required this.selectedCode,
    required this.onChanged,
    required this.rate,
    required this.typedRate,
    required this.onTypedRateChanged,
    required this.invoiceDateText,
    required this.foreignTotal,
    this.enabled = true,
  });

  final List<Currency> currencies;
  final String baseCurrencyCode;

  /// Blank means the shop's own currency.
  final String selectedCode;
  final ValueChanged<String> onChanged;

  /// The rate the feed knows for [selectedCode], or null when it knows none.
  final ResolvedRate? rate;

  /// A rate the buyer typed, overriding the feed.
  final double? typedRate;
  final ValueChanged<double?> onTypedRateChanged;

  /// What the buyer typed as the supplier's invoice date, shown so it is
  /// obvious that this is the date the rate is read as of.
  final String invoiceDateText;

  /// The draft total in the supplier's currency, for reconciling the screen
  /// against the paper invoice.
  final double foreignTotal;

  final bool enabled;

  @override
  State<SupplierCurrencyField> createState() => _SupplierCurrencyFieldState();
}

class _SupplierCurrencyFieldState extends State<SupplierCurrencyField> {
  late final TextEditingController _rateController = TextEditingController(
    text: widget.typedRate?.toString() ?? '',
  );

  @override
  void dispose() {
    _rateController.dispose();
    super.dispose();
  }

  bool get _isForeign => widget.selectedCode.isNotEmpty;

  /// The rate the order will actually be costed at.
  double? get _effectiveRate => widget.typedRate ?? widget.rate?.rate;

  @override
  Widget build(BuildContext context) {
    if (widget.currencies.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('purchase_supplier_currency_field'),
          initialValue: widget.selectedCode,
          decoration: InputDecoration(
            labelText: l10n.supplierCurrencyLabel,
            isDense: true,
            prefixIcon: const Icon(Icons.currency_exchange_outlined),
          ),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(
                '${l10n.productPricingCurrencyBase} '
                '(${currencySymbolFor(widget.baseCurrencyCode)})',
              ),
            ),
            for (final currency in widget.currencies)
              DropdownMenuItem(
                value: currency.code,
                child: Text('${currency.name} (${currency.code})'),
              ),
          ],
          onChanged: widget.enabled
              ? (value) => widget.onChanged(value ?? '')
              : null,
        ),
        if (_isForeign) ...[
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('purchase_exchange_rate_field'),
            controller: _rateController,
            enabled: widget.enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.supplierExchangeRateLabel(widget.selectedCode),
              hintText: widget.rate?.rate.toStringAsFixed(4),
              helperText: l10n.supplierExchangeRateHelp,
              helperMaxLines: 3,
              isDense: true,
              prefixIcon: const Icon(Icons.sync_alt),
            ),
            onChanged: (value) =>
                widget.onTypedRateChanged(double.tryParse(value.trim())),
          ),
          const SizedBox(height: 8),
          _CostSummary(
            currencyCode: widget.selectedCode,
            rate: widget.rate,
            effectiveRate: _effectiveRate,
            isTyped: widget.typedRate != null,
            invoiceDateText: widget.invoiceDateText,
            foreignTotal: widget.foreignTotal,
          ),
        ],
      ],
    );
  }
}

class _CostSummary extends StatelessWidget {
  const _CostSummary({
    required this.currencyCode,
    required this.rate,
    required this.effectiveRate,
    required this.isTyped,
    required this.invoiceDateText,
    required this.foreignTotal,
  });

  final String currencyCode;
  final ResolvedRate? rate;
  final double? effectiveRate;
  final bool isTyped;
  final String invoiceDateText;
  final double foreignTotal;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final resolved = effectiveRate;

    // No rate from the feed and none typed: the order cannot be costed, and
    // saying so is better than letting the buyer discover it on submit.
    if (resolved == null) {
      return _line(
        theme,
        Icons.warning_amber_outlined,
        l10n.supplierExchangeRateMissing(currencyCode),
        colors.warning,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(
          theme,
          isTyped ? Icons.edit_outlined : Icons.cloud_done_outlined,
          isTyped
              ? l10n.supplierExchangeRateTyped
              : l10n.supplierExchangeRateFromFeed,
          isTyped ? colors.primaryStrong : colors.mutedInk,
        ),
        const SizedBox(height: 4),
        // The date the rate is read as of. Stated because it is the single
        // thing most likely to surprise: it is the invoice's date, not today's.
        _line(
          theme,
          Icons.event_outlined,
          invoiceDateText.trim().isEmpty
              ? l10n.supplierRateAsOfToday
              : l10n.supplierRateAsOfInvoiceDate(invoiceDateText.trim()),
          colors.mutedInk,
        ),
        if (foreignTotal > 0) ...[
          const SizedBox(height: 4),
          _line(
            theme,
            Icons.receipt_long_outlined,
            l10n.supplierInvoiceTotalPreview(
              formatForeignMoney(foreignTotal, currencyCode),
              formatMoney(foreignTotal * resolved),
            ),
            colors.ink,
          ),
        ],
        if (rate != null && rate!.isStale) ...[
          const SizedBox(height: 4),
          _line(
            theme,
            Icons.schedule,
            l10n.exchangeRateStaleBadge,
            colors.warning,
          ),
        ],
      ],
    );
  }

  Widget _line(ThemeData theme, IconData icon, String text, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
