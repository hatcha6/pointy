import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/units.dart';
import '../view_models/purchase_view_model.dart';

/// Prices snap to the quarter-dinar denominations a Libyan till can make change
/// for — the same step the backend's suggestion engine uses (see
/// `apps/purchasing/pricing.py`). Kept in step with it deliberately: a price the
/// sheet proposes and a price the server proposes must not differ by a rounding
/// rule.
const double _priceStep = 0.25;

/// Opens the pricing sheet for a purchase draft [line]: every way this product
/// is sold, priced against the cost the buyer just entered.
///
/// It exists because a cost change is a pricing decision, and the shop sells
/// this product in more than one shape. A shop that buys a carton of 12 sells
/// the piece AND the carton, often at a wholesale price that is deliberately
/// less than twelve times the piece — so a dialog that can only reach
/// `ProductVariant.unit_price` leaves the wholesale price stranded on the old
/// cost, quietly selling cartons at a loss after every price rise.
///
/// Returns true when prices were saved.
Future<bool?> showPurchasePricingSheet(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  required PurchaseDraftLine line,
}) {
  return showAdaptiveModalBottomSheet<bool>(
    context: context,
    size: AdaptiveModalSize.expanded,
    maxHeightFactor: 0.94,
    builder: (_) => _PurchasePricingSheet(viewModel: viewModel, line: line),
  );
}

/// One priced row in the sheet — a variant's base-unit price, or a pack's own
/// price. The two are the same decision made against different denominations,
/// so they share a row model and a widget rather than drifting apart.
class _PriceRow {
  _PriceRow({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.originalPrice,
    required this.unitCost,
    required this.factorToBase,
    required this.isDerivable,
    required this.startsDerived,
    this.variantId,
    this.unitCode,
  }) : controller = TextEditingController(
         text: startsDerived ? '' : originalPrice.toStringAsFixed(2),
       ),
       isDerived = startsDerived;

  /// Stable identity for the row (`v:12`, `u:carton`).
  final String key;
  final String title;
  final String subtitle;

  /// The price this row had when the sheet opened — what "changed" is measured
  /// against, and what Reset restores.
  final double originalPrice;

  /// Cost of ONE of this row's units, at the draft line's new cost. A pack's
  /// cost is the base cost times its factor.
  final double unitCost;
  final double factorToBase;

  /// Whether this row is allowed to have no price of its own (packs only — a
  /// variant must always carry a price).
  final bool isDerivable;
  final bool startsDerived;

  final int? variantId;
  final String? unitCode;

  final TextEditingController controller;

  /// Whether the row currently has no price of its own and follows the base
  /// price instead. Only ever true for a pack.
  bool isDerived;

  void dispose() => controller.dispose();

  /// The price typed into this row, or null when the field is blank/unparseable.
  double? get typedPrice {
    final parsed = parseDecimal(controller.text);
    if (parsed == null || parsed < 0) {
      return null;
    }
    return parsed;
  }

  /// What this row would actually sell for: its own price, or — for a derived
  /// pack — the base price times the factor.
  double effectivePrice(double basePrice) =>
      isDerived ? basePrice * factorToBase : (typedPrice ?? 0);

  bool changedAgainst(double basePrice) {
    if (isDerived != startsDerived) {
      return true;
    }
    if (isDerived) {
      return false;
    }
    final typed = typedPrice;
    return typed != null && (typed - originalPrice).abs() >= 0.005;
  }
}

class _PurchasePricingSheet extends StatefulWidget {
  const _PurchasePricingSheet({required this.viewModel, required this.line});

  final PurchaseViewModel viewModel;
  final PurchaseDraftLine line;

  @override
  State<_PurchasePricingSheet> createState() => _PurchasePricingSheetState();
}

class _PurchasePricingSheetState extends State<_PurchasePricingSheet> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _markupController = TextEditingController();

  List<_PriceRow> _variantRows = const [];
  List<_PriceRow> _unitRows = const [];
  List<ProductVariant> _variants = const [];
  VariantCostSummary? _costSummary;

  double? _suggestedMarkupPercent;
  bool _loading = true;
  bool _submitting = false;

  /// The line's cost expressed per BASE unit. [PurchaseDraftLine.unitCost] is
  /// per the selected purchase unit (per carton), whereas a variant's price is
  /// always per base unit — so every margin in this sheet is computed from this
  /// number, never from the raw line cost.
  late final double _baseUnitCost = _computeBaseUnitCost();

  double _computeBaseUnitCost() {
    final line = widget.line;
    final factor = line.unitFactor > 0 ? line.unitFactor : 1;
    return line.unitCost / factor;
  }

  Product get _product => Product.fromVariant(widget.line.variant);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final row in [..._variantRows, ..._unitRows]) {
      row.dispose();
    }
    _markupController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final line = widget.line;
    final productId = line.variant.productId;
    // Siblings aren't embedded on a catalog summary variant, so fetch them;
    // fall back to this line's own variant so the sheet still works offline of
    // that call. Cost history and the markup suggestion are context, not
    // requirements — either coming back empty just renders fewer figures.
    final results = await Future.wait([
      widget.viewModel.loadSiblingVariants(productId),
      widget.viewModel.loadProductCostSummary(productId),
      widget.viewModel.loadPricingSuggestion(
        _baseUnitCost,
        productId: productId,
      ),
    ]);
    if (!mounted) {
      return;
    }
    final siblings = results[0] as List<ProductVariant>;
    final summaries = results[1] as List<VariantCostSummary>;
    final suggestion =
        results[2] as ({double? suggestedPrice, double? markupPercent});

    final variants = siblings.isEmpty ? [line.variant] : siblings;
    setState(() {
      _variants = variants;
      _variantRows = [
        for (final variant in variants)
          _PriceRow(
            key: 'v:${variant.id}',
            title: variant.displayLabel.isEmpty
                ? variant.productLabel
                : variant.displayLabel,
            subtitle: variant.sku,
            originalPrice: variant.unitPrice,
            unitCost: _baseUnitCost,
            factorToBase: 1,
            isDerivable: false,
            startsDerived: false,
            variantId: variant.id,
          ),
      ];
      _unitRows = [
        for (final unit in _product.units)
          if (unit.isSellable)
            _PriceRow(
              key: 'u:${unit.code}',
              title: unit.label,
              subtitle: '',
              originalPrice: unit.price ?? 0,
              unitCost: _baseUnitCost * unit.factorToBase,
              factorToBase: unit.factorToBase,
              isDerivable: true,
              startsDerived: unit.price == null,
              unitCode: unit.code,
            ),
      ];
      _costSummary = _summaryFor(summaries, line.variant.id);
      _suggestedMarkupPercent = suggestion.markupPercent;
      _loading = false;
    });
  }

  VariantCostSummary? _summaryFor(
    List<VariantCostSummary> summaries,
    int variantId,
  ) {
    for (final summary in summaries) {
      if (summary.variantId == variantId) {
        return summary;
      }
    }
    return summaries.isEmpty ? null : summaries.first;
  }

  /// The base price every derived pack follows: the default variant's typed
  /// price, falling back to the first row. Recomputed on every keystroke so a
  /// derived carton's figure tracks the piece price as it is typed.
  ///
  /// A pack price is per PRODUCT while a base price is per variant, so on a
  /// multi-variant product a derived pack can only be shown against one of
  /// them; the default variant is the honest choice, and the row is badged
  /// "derived" so the figure never reads as a price somebody set.
  double get _basePrice {
    if (_variantRows.isEmpty) {
      return 0;
    }
    final defaultIndex = _variants.indexWhere((variant) => variant.isDefault);
    final row = _variantRows[defaultIndex == -1 ? 0 : defaultIndex];
    return row.typedPrice ?? row.originalPrice;
  }

  List<_PriceRow> get _allRows => [..._variantRows, ..._unitRows];

  int get _changeCount =>
      _allRows.where((row) => row.changedAgainst(_basePrice)).length;

  /// Applies a markup to every priced row at once: the reason the sheet exists
  /// as a sheet and not a field. "Cost went up 12%, keep my 30% margin" is one
  /// decision across the piece, the box and the carton — not three arithmetic
  /// problems for somebody standing at a counter.
  void _applyMarkup(double percent) {
    setState(() {
      for (final row in _allRows) {
        if (row.unitCost <= 0) {
          continue;
        }
        final target = row.unitCost * (1 + percent / 100);
        final snapped = _snapToStep(math.max(target, row.unitCost));
        row.isDerived = false;
        row.controller.text = snapped.toStringAsFixed(2);
      }
    });
  }

  void _resetPrices() {
    setState(() {
      for (final row in _allRows) {
        row.isDerived = row.startsDerived;
        row.controller.text = row.startsDerived
            ? ''
            : row.originalPrice.toStringAsFixed(2);
      }
      _markupController.clear();
    });
  }

  /// Snaps to the nearest quarter-dinar, never below the value's own step —
  /// mirrors `_snap_to_step` on the server.
  static double _snapToStep(double value) {
    final snapped = (value / _priceStep).roundToDouble() * _priceStep;
    return snapped < _priceStep ? _priceStep : snapped;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final basePrice = _basePrice;
    final pricesByVariant = <int, double>{};
    final pricesByUnitCode = <String, double?>{};
    for (final row in _allRows) {
      if (!row.changedAgainst(basePrice)) {
        continue;
      }
      if (row.variantId != null) {
        final typed = row.typedPrice;
        if (typed != null) {
          pricesByVariant[row.variantId!] = typed;
        }
        continue;
      }
      final code = row.unitCode;
      if (code == null) {
        continue;
      }
      // A pack handed back to "derived" sends an explicit null — that is how a
      // wholesale price stops existing without deleting the unit itself.
      pricesByUnitCode[code] = row.isDerived ? null : row.typedPrice;
    }
    if (pricesByVariant.isEmpty && pricesByUnitCode.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }

    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final success = await widget.viewModel.repriceProduct(
      widget.line.variant.productId,
      pricesByVariant: pricesByVariant,
      pricesByUnitCode: pricesByUnitCode,
    );
    if (!mounted) {
      return;
    }
    setState(() => _submitting = false);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            success ? l10n.changePricesSuccess : l10n.changePricesError,
          ),
        ),
      );
    if (success) {
      navigator.pop(true);
    }
  }

  String? _validatePrice(String? value, _PriceRow row) {
    if (row.isDerived) {
      return null;
    }
    final parsed = parseDecimal(value);
    if (parsed == null || parsed < 0) {
      return AppLocalizations.of(context)!.invalidNumber;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    if (_loading) {
      return const SizedBox(height: 260, child: Center(child: PointySpinner()));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsetsDirectional.fromSTEB(
              spacing.lg,
              spacing.xs,
              spacing.lg,
              spacing.md,
            ),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PricingHeader(
                    productName: widget.line.variant.productLabel,
                    line: widget.line,
                  ),
                  SizedBox(height: spacing.md),
                  _CostContext(
                    line: widget.line,
                    baseUnitCost: _baseUnitCost,
                    previousBaseCost: widget.viewModel.previousBaseCostFor(
                      widget.line.variant.id,
                    ),
                    summary: _costSummary,
                    baseUnitLabel: unitLabel(l10n, widget.line.variant.unit),
                  ),
                  SizedBox(height: spacing.md),
                  _MarkupBar(
                    controller: _markupController,
                    suggestedPercent: _suggestedMarkupPercent,
                    enabled: !_submitting,
                    onApply: _applyMarkup,
                  ),
                  SizedBox(height: spacing.md),
                  PointySectionHeader(
                    title: _variantRows.length > 1
                        ? l10n.pricingSheetVariantsSectionTitle
                        : l10n.pricingSheetBasePriceSectionTitle,
                    subtitle: l10n.pricingSheetVariantsSectionSubtitle(
                      unitLabel(l10n, widget.line.variant.unit),
                    ),
                  ),
                  for (final row in _variantRows) ...[
                    SizedBox(height: spacing.sm),
                    _PriceRowTile(
                      row: row,
                      basePrice: _basePrice,
                      enabled: !_submitting,
                      validator: (value) => _validatePrice(value, row),
                      onChanged: () => setState(() {}),
                      onUseDerived: null,
                    ),
                  ],
                  if (_unitRows.isNotEmpty) ...[
                    SizedBox(height: spacing.lg),
                    PointySectionHeader(
                      title: l10n.pricingSheetPackSectionTitle,
                      subtitle: l10n.pricingSheetPackSectionSubtitle,
                    ),
                    for (final row in _unitRows) ...[
                      SizedBox(height: spacing.sm),
                      _PriceRowTile(
                        row: row,
                        basePrice: _basePrice,
                        enabled: !_submitting,
                        validator: (value) => _validatePrice(value, row),
                        onChanged: () => setState(() {}),
                        onUseDerived: () => setState(() {
                          row.isDerived = !row.isDerived;
                          if (!row.isDerived) {
                            row.controller.text = row
                                .effectivePrice(_basePrice)
                                .toStringAsFixed(2);
                          }
                        }),
                      ),
                    ],
                  ],
                  if (_variantRows.isEmpty && _unitRows.isEmpty) ...[
                    SizedBox(height: spacing.md),
                    Text(
                      l10n.changePricesNoVariants,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        PointyStickyActionFooter(
          summary: _PricingFooterSummary(
            changeCount: _changeCount,
            onReset: _submitting || _changeCount == 0 ? null : _resetPrices,
          ),
          primaryAction: FilledButton.icon(
            onPressed: _submitting || _changeCount == 0 ? null : _submit,
            icon: _submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.sell_outlined),
            label: Text(l10n.changePricesSaveButton),
          ),
        ),
      ],
    );
  }
}

class _PricingHeader extends StatelessWidget {
  const _PricingHeader({required this.productName, required this.line});

  final String productName;
  final PurchaseDraftLine line;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.sell_outlined, color: colors.primaryStrong),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.pricingSheetTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: colors.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                productName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The figures a price is decided against: what this delivery cost, what the
/// last one cost, and the range the shop has ever paid. Purchasing had all of
/// this on the server and showed none of it — the buyer was typing a price
/// against a number they had to remember.
class _CostContext extends StatelessWidget {
  const _CostContext({
    required this.line,
    required this.baseUnitCost,
    required this.previousBaseCost,
    required this.summary,
    required this.baseUnitLabel,
  });

  final PurchaseDraftLine line;
  final double baseUnitCost;
  final double? previousBaseCost;
  final VariantCostSummary? summary;
  final String baseUnitLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final previous = previousBaseCost;
    final delta = (previous != null && previous > 0)
        ? (baseUnitCost - previous) / previous * 100
        : null;

    return PointyMetricGrid(
      minTileWidth: 160,
      maxColumns: 4,
      metrics: [
        PointyMetricGridItem(
          label: l10n.pricingSheetNewCostLabel,
          value: formatMoney(baseUnitCost),
          subtitle: line.isBaseUnit
              ? baseUnitLabel
              : l10n.pricingSheetCostPerPackSubtitle(
                  formatMoney(line.unitCost),
                  line.unitLabel,
                ),
          icon: Icons.shopping_bag_outlined,
        ),
        if (previous != null && previous > 0)
          PointyMetricGridItem(
            label: l10n.pricingSheetPreviousCostLabel,
            value: formatMoney(previous),
            subtitle: delta == null || delta.abs() < 0.05
                ? null
                : delta > 0
                ? l10n.pricingSheetCostUp(delta.toStringAsFixed(1))
                : l10n.pricingSheetCostDown(delta.abs().toStringAsFixed(1)),
            icon: delta != null && delta > 0
                ? Icons.trending_up
                : delta != null && delta < 0
                ? Icons.trending_down
                : Icons.trending_flat,
            accentColor: delta == null || delta.abs() < 0.05
                ? colors.mutedInk
                : delta > 0
                ? colors.danger
                : colors.success,
          ),
        if (summary?.lowestCost != null)
          PointyMetricGridItem(
            label: l10n.pricingSheetLowestCostLabel,
            value: formatMoney(summary!.lowestCost!),
            icon: Icons.south,
            accentColor: colors.mutedInk,
          ),
        if (summary?.highestCost != null)
          PointyMetricGridItem(
            label: l10n.pricingSheetHighestCostLabel,
            value: formatMoney(summary!.highestCost!),
            icon: Icons.north,
            accentColor: colors.mutedInk,
          ),
      ],
    );
  }
}

/// "Keep my margin" as one control. The suggested chip carries the shop's own
/// median markup (its real pricing strategy, inferred from the catalog), so the
/// common case is one tap rather than arithmetic per row.
class _MarkupBar extends StatelessWidget {
  const _MarkupBar({
    required this.controller,
    required this.suggestedPercent,
    required this.enabled,
    required this.onApply,
  });

  final TextEditingController controller;
  final double? suggestedPercent;
  final bool enabled;
  final ValueChanged<double> onApply;

  static const List<double> _presets = [10, 20, 30, 50];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final suggested = suggestedPercent;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: const BorderRadius.all(Radius.circular(PointyRadii.card)),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.pricingSheetMarkupTitle,
            style: theme.textTheme.labelLarge?.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            l10n.pricingSheetMarkupSubtitle,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (suggested != null)
                ActionChip(
                  avatar: const Icon(Icons.auto_awesome, size: 16),
                  label: Text(
                    l10n.pricingSheetSuggestedMarkupChip(
                      suggested.toStringAsFixed(0),
                    ),
                  ),
                  onPressed: enabled ? () => onApply(suggested) : null,
                ),
              for (final preset in _presets)
                ActionChip(
                  label: Text(
                    l10n.pricingSheetMarkupChip(preset.toStringAsFixed(0)),
                  ),
                  onPressed: enabled ? () => onApply(preset) : null,
                ),
              SizedBox(
                width: 150,
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: InputDecoration(
                    labelText: l10n.pricingSheetCustomMarkupLabel,
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: l10n.pricingSheetApplyMarkupTooltip,
                      icon: const Icon(Icons.check, size: 18),
                      onPressed: enabled
                          ? () {
                              final parsed = parseDecimal(controller.text);
                              if (parsed != null && parsed >= 0) {
                                onApply(parsed);
                              }
                            }
                          : null,
                    ),
                  ),
                  onSubmitted: (value) {
                    final parsed = parseDecimal(value);
                    if (parsed != null && parsed >= 0) {
                      onApply(parsed);
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One row: what it is, what it costs, what it sells for, and what that leaves.
/// The margin readout is the point — a price field with no margin beside it
/// makes the buyer do the division in their head, which is exactly when a
/// carton gets priced below what it cost.
class _PriceRowTile extends StatelessWidget {
  const _PriceRowTile({
    required this.row,
    required this.basePrice,
    required this.enabled,
    required this.validator,
    required this.onChanged,
    required this.onUseDerived,
  });

  final _PriceRow row;
  final double basePrice;
  final bool enabled;
  final FormFieldValidator<String> validator;
  final VoidCallback onChanged;

  /// Toggles a pack between its own price and the derived one. Null for a
  /// variant, which must always carry a price of its own.
  final VoidCallback? onUseDerived;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    final price = row.effectivePrice(basePrice);
    final cost = row.unitCost;
    final profit = price - cost;
    final markupPercent = cost > 0 ? profit / cost * 100 : null;
    final severity = _severityFor(price: price, cost: cost);
    final severityColor = switch (severity) {
      _MarginSeverity.belowCost => colors.danger,
      _MarginSeverity.unpriced => colors.warning,
      _MarginSeverity.healthy => colors.success,
    };

    final subtitleParts = <String>[
      if (row.subtitle.isNotEmpty) row.subtitle,
      if (row.factorToBase != 1)
        l10n.pricingSheetPackFactor(formatQuantity(row.factorToBase)),
      if (cost > 0) l10n.pricingSheetRowCost(formatMoney(cost)),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.all(Radius.circular(PointyRadii.card)),
        border: Border.all(
          color: severity == _MarginSeverity.belowCost
              ? colors.danger
              : colors.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            row.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: colors.ink,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (row.isDerived) ...[
                          const SizedBox(width: 6),
                          PointyStatusPill(
                            label: l10n.pricingSheetDerivedBadge,
                            color: colors.mutedInk,
                          ),
                        ],
                      ],
                    ),
                    if (subtitleParts.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitleParts.join(' • '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 160,
                child: row.isDerived
                    ? _DerivedPriceDisplay(price: price)
                    : TextFormField(
                        controller: row.controller,
                        enabled: enabled,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [DecimalTextInputFormatter()],
                        decoration: InputDecoration(
                          labelText: l10n.changePricesNewPriceLabel,
                          isDense: true,
                        ),
                        validator: validator,
                        onChanged: (_) => onChanged(),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _MarginReadout(
                  severity: severity,
                  color: severityColor,
                  profit: profit,
                  markupPercent: markupPercent,
                  originalPrice: row.originalPrice,
                  price: price,
                  isDerived: row.isDerived,
                ),
              ),
              if (onUseDerived != null)
                TextButton.icon(
                  onPressed: enabled ? onUseDerived : null,
                  icon: Icon(
                    row.isDerived ? Icons.edit_outlined : Icons.link,
                    size: 16,
                  ),
                  label: Text(
                    row.isDerived
                        ? l10n.pricingSheetSetOwnPriceButton
                        : l10n.pricingSheetUseDerivedButton,
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static _MarginSeverity _severityFor({
    required double price,
    required double cost,
  }) {
    if (price <= 0) {
      return _MarginSeverity.unpriced;
    }
    if (cost > 0 && price <= cost) {
      return _MarginSeverity.belowCost;
    }
    return _MarginSeverity.healthy;
  }
}

enum _MarginSeverity { healthy, unpriced, belowCost }

class _DerivedPriceDisplay extends StatelessWidget {
  const _DerivedPriceDisplay({required this.price});

  final double price;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return InputDecorator(
      decoration: InputDecoration(
        labelText: l10n.changePricesNewPriceLabel,
        isDense: true,
        enabled: false,
      ),
      child: Text(
        formatMoney(price),
        maxLines: 1,
        style: theme.textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
      ),
    );
  }
}

class _MarginReadout extends StatelessWidget {
  const _MarginReadout({
    required this.severity,
    required this.color,
    required this.profit,
    required this.markupPercent,
    required this.originalPrice,
    required this.price,
    required this.isDerived,
  });

  final _MarginSeverity severity;
  final Color color;
  final double profit;
  final double? markupPercent;
  final double originalPrice;
  final double price;
  final bool isDerived;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    final message = switch (severity) {
      _MarginSeverity.unpriced => l10n.pricingSheetUnpriced,
      _MarginSeverity.belowCost => l10n.pricingSheetBelowCost,
      _MarginSeverity.healthy => markupPercent == null
          ? formatMoney(price)
          : l10n.pricingSheetMargin(
              formatMoney(profit),
              markupPercent!.toStringAsFixed(0),
            ),
    };
    final priceMoved =
        !isDerived && (price - originalPrice).abs() >= 0.005 && originalPrice > 0;

    return Row(
      children: [
        Icon(
          switch (severity) {
            _MarginSeverity.healthy => Icons.check_circle_outline,
            _MarginSeverity.unpriced => Icons.help_outline,
            _MarginSeverity.belowCost => Icons.warning_amber_rounded,
          },
          size: 16,
          color: color,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (priceMoved) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l10n.pricingSheetWasPrice(formatMoney(originalPrice)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PricingFooterSummary extends StatelessWidget {
  const _PricingFooterSummary({required this.changeCount, required this.onReset});

  final int changeCount;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Row(
      children: [
        Expanded(
          child: Text(
            changeCount == 0
                ? l10n.pricingSheetNoChanges
                : l10n.pricingSheetChangeCount(changeCount),
            style: theme.textTheme.bodySmall?.copyWith(
              color: changeCount == 0 ? colors.mutedInk : colors.primaryStrong,
              fontWeight: changeCount == 0 ? null : FontWeight.w700,
            ),
          ),
        ),
        TextButton.icon(
          onPressed: onReset,
          icon: const Icon(Icons.undo, size: 16),
          label: Text(l10n.pricingSheetResetButton),
        ),
      ],
    );
  }
}
