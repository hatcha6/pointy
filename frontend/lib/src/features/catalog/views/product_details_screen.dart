import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/barcode_label.dart';
import '../../../data/models/product.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/detail_section.dart';
import '../../../shared/formatters.dart';
import '../../../shared/product_status_pill.dart';
import '../view_models/product_stock_view_model.dart';
import 'product_details_hero.dart';
import 'stock_movement_form.dart';
import 'stock_movements_sheet.dart';

class ProductDetailsScreen extends StatelessWidget {
  const ProductDetailsScreen({
    super.key,
    required this.viewModel,
    required this.printingRepository,
    required this.capabilities,
  });

  final ProductStockViewModel viewModel;
  final PrintingRepository printingRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final product = viewModel.product;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(l10n.productDetailsTitle)),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ProductDetailsHero(product: product),
                const SizedBox(height: 16),
                StockViewGuard(
                  capabilities: capabilities,
                  child: _StockSummarySection(
                    viewModel: viewModel,
                    capabilities: capabilities,
                    onCreateMovement: () => _showMovementForm(context),
                    onOpenMovements: () => _openMovements(context),
                  ),
                ),
                if (capabilities.canViewStock) const SizedBox(height: 12),
                DetailSection(
                  title: l10n.productAvailabilityTitle,
                  icon: product.isActive
                      ? Icons.check_circle_outline
                      : Icons.pause_circle_outline,
                  child: Row(
                    children: [
                      ProductStatusPill(isActive: product.isActive),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          product.isActive
                              ? l10n.productAvailableForSale
                              : l10n.productUnavailableForSale,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                DetailSection(
                  title: l10n.productIdentifierTitle,
                  icon: Icons.qr_code_2,
                  child: Column(
                    children: [
                      DetailRow(label: l10n.skuLabel, value: product.sku),
                      const Divider(height: 20),
                      DetailRow(
                        label: l10n.barcodeLabel,
                        value: product.barcode.isEmpty
                            ? l10n.noBarcode
                            : product.barcode,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                DetailSection(
                  title: l10n.barcodeLabelPrintTitle,
                  icon: Icons.print_outlined,
                  child: _BarcodeLabelPrintSection(
                    product: product,
                    printingRepository: printingRepository,
                  ),
                ),
                const SizedBox(height: 12),
                DetailSection(
                  title: l10n.productDescriptionTitle,
                  icon: Icons.notes_outlined,
                  child: Text(
                    product.description.isEmpty
                        ? l10n.noDescription
                        : product.description,
                  ),
                ),
                const SizedBox(height: 12),
                DetailSection(
                  title: l10n.productCostHistoryTitle,
                  icon: Icons.trending_up_outlined,
                  child: _ProductCostHistorySection(viewModel: viewModel),
                ),
              ],
            ),
          ),
          backgroundColor: colorScheme.surface,
        );
      },
    );
  }

  Future<void> _showMovementForm(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: StockMovementForm(
            viewModel: viewModel,
            onSaved: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }

  Future<void> _openMovements(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return FractionallySizedBox(
          heightFactor: 0.9,
          child: StockMovementsSheet(
            viewModel: viewModel,
            capabilities: capabilities,
            onCreateMovement: () => _showMovementForm(sheetContext),
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }
}

class _ProductCostHistorySection extends StatelessWidget {
  const _ProductCostHistorySection({required this.viewModel});

  final ProductStockViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoadingCostInsights) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.hasCostInsightsError) {
      return Text(
        l10n.productCostHistoryLoadError,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }

    final impact = viewModel.marginImpact;
    final entries = viewModel.costHistory;
    if (impact == null && entries.isEmpty) {
      return Text(l10n.productCostHistoryEmpty);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (impact != null) ...[
          _MarginImpactGrid(
            impact: impact,
            fallbackPrice: viewModel.product.unitPrice,
          ),
          if (entries.isNotEmpty) const Divider(height: 24),
        ],
        for (final (index, entry) in entries.take(6).indexed) ...[
          if (index > 0) const Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(
              entry.supplierName?.isNotEmpty == true
                  ? entry.supplierName!
                  : l10n.noSupplierSelectedLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                if (entry.purchaseOrderNumber != null &&
                    entry.purchaseOrderNumber!.isNotEmpty)
                  l10n.purchaseOrderNumberValue(entry.purchaseOrderNumber!),
                l10n.purchaseOrderLineQuantity(entry.quantity),
                if (entry.recordedAt != null) _formatDate(entry.recordedAt!),
              ].join(' • '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              formatMoney(entry.effectiveUnitCost ?? entry.unitCost),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ],
      ],
    );
  }
}

class _MarginImpactGrid extends StatelessWidget {
  const _MarginImpactGrid({required this.impact, required this.fallbackPrice});

  final ProductMarginImpact impact;
  final double fallbackPrice;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final unitPrice = impact.unitPrice > 0 ? impact.unitPrice : fallbackPrice;
    final latestCost = impact.latestEffectiveUnitCost ?? impact.latestUnitCost;
    final grossProfit =
        impact.grossProfit ??
        (latestCost == null ? null : unitPrice - latestCost);
    final marginPercent =
        impact.marginPercent ??
        (grossProfit == null || unitPrice <= 0
            ? null
            : (grossProfit / unitPrice) * 100);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _MetricChip(
          label: l10n.productLatestCostLabel,
          value: latestCost == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(latestCost),
        ),
        _MetricChip(label: l10n.unitPriceLabel, value: formatMoney(unitPrice)),
        _MetricChip(
          label: l10n.productGrossProfitLabel,
          value: grossProfit == null
              ? l10n.shopSettingsEmptyValue
              : formatMoney(grossProfit),
        ),
        _MetricChip(
          label: l10n.productMarginPercentLabel,
          value: marginPercent == null
              ? l10n.shopSettingsEmptyValue
              : l10n.productMarginPercentValue(
                  _formatSignedPercent(
                    marginPercent,
                    includePositiveSign: false,
                  ),
                ),
        ),
        if (impact.costChange != null)
          _MetricChip(
            label: l10n.productCostChangeLabel,
            value: _formatSignedMoney(impact.costChange!),
          ),
        if (impact.marginChangePercent != null)
          _MetricChip(
            label: l10n.productMarginChangeLabel,
            value: l10n.productMarginPercentValue(
              _formatSignedPercent(impact.marginChangePercent!),
            ),
          ),
      ],
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 2),
            Text(value, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}

class _BarcodeLabelPrintSection extends StatefulWidget {
  const _BarcodeLabelPrintSection({
    required this.product,
    required this.printingRepository,
  });

  final Product product;
  final PrintingRepository printingRepository;

  @override
  State<_BarcodeLabelPrintSection> createState() =>
      _BarcodeLabelPrintSectionState();
}

class _BarcodeLabelPrintSectionState extends State<_BarcodeLabelPrintSection> {
  bool _isPrinting = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final hasBarcode = widget.product.barcode.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!hasBarcode) ...[
          Text(
            l10n.barcodeLabelPrintNoBarcode,
            style: TextStyle(color: colorScheme.error),
          ),
          const SizedBox(height: 12),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SizedBox(
            width: 240,
            child: FilledButton.icon(
              onPressed: hasBarcode && !_isPrinting ? _printLabel : null,
              icon: _isPrinting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined),
              label: Text(
                _isPrinting
                    ? l10n.barcodeLabelPrintInProgressButton
                    : l10n.barcodeLabelPrintButton,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _printLabel() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final copies = await _askLabelCopies();
    if (copies == null) {
      return;
    }

    setState(() => _isPrinting = true);

    final result = await widget.printingRepository.printBarcodeLabels([
      BarcodeLabelPrintLine.product(widget.product, copies: copies),
    ]);

    if (!mounted) {
      return;
    }
    setState(() => _isPrinting = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.isSuccess
              ? l10n.barcodeLabelPrintSuccess(copies)
              : l10n.barcodeLabelPrintError,
        ),
      ),
    );
  }

  Future<int?> _askLabelCopies() {
    return showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return const _BarcodeLabelCopiesDialog();
      },
    );
  }
}

class _BarcodeLabelCopiesDialog extends StatefulWidget {
  const _BarcodeLabelCopiesDialog();

  @override
  State<_BarcodeLabelCopiesDialog> createState() =>
      _BarcodeLabelCopiesDialogState();
}

class _BarcodeLabelCopiesDialogState extends State<_BarcodeLabelCopiesDialog> {
  final _formKey = GlobalKey<FormState>();
  final _copiesController = TextEditingController(text: '1');

  @override
  void dispose() {
    _copiesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.barcodeLabelCopiesDialogTitle),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _copiesController,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: l10n.barcodeLabelCopiesLabel,
            hintText: l10n.barcodeLabelCopiesHint,
          ),
          validator: (value) {
            final copies = int.tryParse(value ?? '');
            if (copies == null || copies <= 0) {
              return l10n.invalidNumber;
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.print_outlined),
          label: Text(l10n.barcodeLabelCopiesPrintButton),
        ),
      ],
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    Navigator.of(context).pop(int.parse(_copiesController.text));
  }
}

class _StockSummarySection extends StatelessWidget {
  const _StockSummarySection({
    required this.viewModel,
    required this.capabilities,
    required this.onCreateMovement,
    required this.onOpenMovements,
  });

  final ProductStockViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onCreateMovement;
  final VoidCallback onOpenMovements;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return DetailSection(
      title: l10n.stockSummaryTitle,
      icon: Icons.inventory_2_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (viewModel.isLoadingStock)
            const LinearProgressIndicator()
          else if (viewModel.errorMessage == 'stock_load_error')
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                l10n.stockLoadError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            )
          else
            _StockOnHandPanel(
              label: l10n.stockOnHandLabel,
              value: viewModel.quantityOnHand,
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StockMovementCreateGuard(
                capabilities: capabilities,
                child: SizedBox(
                  width: 220,
                  child: FilledButton.icon(
                    onPressed: onCreateMovement,
                    icon: const Icon(Icons.add_chart_outlined),
                    label: Text(l10n.newStockMovementButton),
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: OutlinedButton.icon(
                  onPressed: onOpenMovements,
                  icon: const Icon(Icons.list_alt_outlined),
                  label: Text(l10n.stockMovementsButton),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StockOnHandPanel extends StatelessWidget {
  const _StockOnHandPanel({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colorScheme.primaryContainer,
              foregroundColor: colorScheme.onPrimaryContainer,
              child: const Icon(Icons.inventory_outlined),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text(
              '$value',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime dateTime) {
  final date = dateTime.toLocal();
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}/$month/$day';
}

String _formatSignedMoney(double value) {
  final amount = formatMoney(value.abs());
  if (value > 0) {
    return '+$amount';
  }
  if (value < 0) {
    return '-$amount';
  }
  return amount;
}

String _formatSignedPercent(double value, {bool includePositiveSign = true}) {
  final amount = value.abs().toStringAsFixed(2);
  if (value > 0 && includePositiveSign) {
    return '+$amount';
  }
  if (value < 0) {
    return '-$amount';
  }
  return amount;
}
