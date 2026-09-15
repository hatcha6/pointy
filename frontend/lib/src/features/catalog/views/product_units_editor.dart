import 'package:flutter/material.dart';

import '../../../core/parsing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_unit.dart';
import '../../../data/models/unit_of_measure.dart';
import '../../../shared/barcode/camera_text_barcode_scanner_sheet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/units.dart';

/// Editor for a product's additional units and their per-product conversions and
/// optional custom prices, plus the default sale/purchase units. The base unit
/// is implicit (factor 1) and is offered as the first default option.
class ProductUnitsEditor extends StatefulWidget {
  const ProductUnitsEditor({
    super.key,
    required this.availableUnits,
    required this.baseUnitCode,
    required this.units,
    required this.defaultSaleUnit,
    required this.defaultPurchaseUnit,
    required this.onUnitsChanged,
    required this.onDefaultSaleChanged,
    required this.onDefaultPurchaseChanged,
    this.enabled = true,
    this.isLoading = false,
    this.hasError = false,
    this.onReload,
  });

  final List<UnitOfMeasure> availableUnits;
  final String baseUnitCode;
  final List<ProductUnit> units;
  final String defaultSaleUnit;
  final String defaultPurchaseUnit;
  final ValueChanged<List<ProductUnit>> onUnitsChanged;
  final ValueChanged<String> onDefaultSaleChanged;
  final ValueChanged<String> onDefaultPurchaseChanged;
  final bool enabled;
  final bool isLoading;
  final bool hasError;
  final VoidCallback? onReload;

  @override
  State<ProductUnitsEditor> createState() => _ProductUnitsEditorState();
}

class _UnitRow {
  _UnitRow({
    required this.unit,
    required double factor,
    double? price,
    this.barcodes = const [],
  }) : factorController = TextEditingController(text: _trimNumber(factor)),
       priceController = TextEditingController(
         text: price == null ? '' : price.toStringAsFixed(2),
       ),
       isSellable = true,
       isPurchasable = true;

  UnitOfMeasure unit;
  final TextEditingController factorController;
  final TextEditingController priceController;
  bool isSellable;
  bool isPurchasable;

  /// Packaging barcodes attached to this unit (the carton EAN). Scanning one
  /// rings the product up as this unit at this unit's price. Editable in the
  /// card below; carried through edits so saving never wipes existing codes.
  List<String> barcodes;

  /// Ephemeral input + focus for the "add barcode" field. Kept on the row (not
  /// in the card widget) so typed text and focus survive parent rebuilds and
  /// follow the row when others are added or removed.
  final TextEditingController barcodeInputController = TextEditingController();
  final FocusNode barcodeInputFocusNode = FocusNode();

  void dispose() {
    factorController.dispose();
    priceController.dispose();
    barcodeInputController.dispose();
    barcodeInputFocusNode.dispose();
  }
}

/// Result of trying to add a barcode to a unit, so the input can clear/refocus
/// on success and conflicts across units can be surfaced.
enum _BarcodeAddOutcome { added, alreadyOnThisUnit, usedByAnotherUnit }

String _trimNumber(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value
      .toStringAsFixed(6)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

class _ProductUnitsEditorState extends State<ProductUnitsEditor> {
  final List<_UnitRow> _rows = [];

  @override
  void initState() {
    super.initState();
    _seedRows();
  }

  @override
  void didUpdateWidget(ProductUnitsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-seed when an edited product's units arrive after an async load.
    if (oldWidget.units != widget.units && _rows.isEmpty) {
      _seedRows();
    }
  }

  void _seedRows() {
    for (final row in _rows) {
      row.dispose();
    }
    _rows
      ..clear()
      ..addAll([
        for (final unit in widget.units)
          (_UnitRow(
              unit: unit.unit,
              factor: unit.factorToBase,
              price: unit.price,
              barcodes: unit.barcodes,
            )
            ..isSellable = unit.isSellable
            ..isPurchasable = unit.isPurchasable),
      ]);
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  List<UnitOfMeasure> _availableForRow(_UnitRow row) {
    final taken = {
      widget.baseUnitCode,
      for (final other in _rows)
        if (other != row) other.unit.code,
    };
    return [
      for (final unit in widget.availableUnits)
        if (!taken.contains(unit.code)) unit,
    ];
  }

  void _emitUnits() {
    widget.onUnitsChanged([
      for (var index = 0; index < _rows.length; index += 1)
        ProductUnit(
          unit: _rows[index].unit,
          factorToBase:
              double.tryParse(_rows[index].factorController.text.trim()) ?? 1,
          price: _parsePrice(_rows[index].priceController.text),
          isSellable: _rows[index].isSellable,
          isPurchasable: _rows[index].isPurchasable,
          displayOrder: index,
          barcodes: _rows[index].barcodes,
        ),
    ]);
  }

  double? _parsePrice(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return parseDecimal(trimmed);
  }

  void _addRow() {
    final candidate = widget.availableUnits
        .where(
          (unit) =>
              unit.code != widget.baseUnitCode &&
              _rows.every((row) => row.unit.code != unit.code),
        )
        .toList();
    if (candidate.isEmpty) return;
    final unit = candidate.first;
    setState(() {
      _rows.add(_UnitRow(unit: unit, factor: _suggestedFactor(unit) ?? 1));
    });
    _emitUnits();
  }

  void _removeRow(int index) {
    final removed = _rows.removeAt(index);
    removed.dispose();
    setState(() {});
    _emitUnits();
  }

  /// Append a (trimmed, non-empty) barcode to the row at [index], rejecting a
  /// code already on another unit — the backend enforces one-code-one-meaning,
  /// so we catch the same-product case here for instant feedback. Same-unit
  /// re-adds are a no-op. Mirrors the server's strip-only normalization.
  _BarcodeAddOutcome _addBarcode(int index, String code) {
    if (!mounted) return _BarcodeAddOutcome.alreadyOnThisUnit;
    final l10n = AppLocalizations.of(context)!;
    for (var i = 0; i < _rows.length; i += 1) {
      if (_rows[i].barcodes.contains(code)) {
        if (i == index) {
          _showBarcodeSnack(l10n.productUnitBarcodeDuplicate);
          return _BarcodeAddOutcome.alreadyOnThisUnit;
        }
        _showBarcodeSnack(l10n.productUnitBarcodeConflict(_rows[i].unit.name));
        return _BarcodeAddOutcome.usedByAnotherUnit;
      }
    }
    setState(() {
      _rows[index].barcodes = [..._rows[index].barcodes, code];
    });
    _emitUnits();
    return _BarcodeAddOutcome.added;
  }

  void _removeBarcode(int index, String code) {
    setState(() {
      _rows[index].barcodes = [
        for (final existing in _rows[index].barcodes)
          if (existing != code) existing,
      ];
    });
    _emitUnits();
  }

  void _showBarcodeSnack(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Suggested per-product factor when a unit shares the base unit's dimension
  /// (kg→1000 g). Null for packaging units, which the manager must set.
  double? _suggestedFactor(UnitOfMeasure unit) {
    final base = _baseUnit;
    if (base == null) return null;
    final baseRef = base.referenceFactor;
    final unitRef = unit.referenceFactor;
    if (baseRef == null || unitRef == null) return null;
    if (base.dimension != unit.dimension || baseRef == 0) return null;
    return unitRef / baseRef;
  }

  UnitOfMeasure? get _baseUnit {
    for (final unit in widget.availableUnits) {
      if (unit.code == widget.baseUnitCode) return unit;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    if (widget.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: PointySpinner()),
      );
    }
    if (widget.hasError) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyInlineMessage.error(message: l10n.productUnitsLoadError),
          if (widget.onReload != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: widget.onReload,
                child: Text(l10n.retryButton),
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.productUnitsSectionDescription,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        SizedBox(height: spacing.md),
        for (var index = 0; index < _rows.length; index += 1) ...[
          if (index > 0) SizedBox(height: spacing.sm),
          _UnitRowCard(
            l10n: l10n,
            row: _rows[index],
            baseUnitLabel: unitLabel(l10n, widget.baseUnitCode),
            availableUnits: _availableForRow(_rows[index]),
            enabled: widget.enabled,
            onUnitChanged: (unit) {
              setState(() {
                _rows[index].unit = unit;
                final suggested = _suggestedFactor(unit);
                if (suggested != null) {
                  _rows[index].factorController.text = _trimNumber(suggested);
                }
              });
              _emitUnits();
            },
            onChanged: _emitUnits,
            onRemove: () => _removeRow(index),
            onAddBarcode: (code) => _addBarcode(index, code),
            onRemoveBarcode: (code) => _removeBarcode(index, code),
          ),
        ],
        SizedBox(height: spacing.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TutorTarget(
            anchor: TutorAnchor.productAddUnitButton,
            child: OutlinedButton.icon(
              onPressed: widget.enabled ? _addRow : null,
              icon: const Icon(Icons.add),
              label: Text(l10n.productUnitsAddButton),
            ),
          ),
        ),
        if (_rows.isNotEmpty) ...[
          SizedBox(height: spacing.lg),
          _DefaultUnitPickers(
            l10n: l10n,
            baseUnitCode: widget.baseUnitCode,
            rows: _rows,
            defaultSaleUnit: widget.defaultSaleUnit,
            defaultPurchaseUnit: widget.defaultPurchaseUnit,
            enabled: widget.enabled,
            onDefaultSaleChanged: widget.onDefaultSaleChanged,
            onDefaultPurchaseChanged: widget.onDefaultPurchaseChanged,
          ),
        ],
      ],
    );
  }
}

class _UnitRowCard extends StatelessWidget {
  const _UnitRowCard({
    required this.l10n,
    required this.row,
    required this.baseUnitLabel,
    required this.availableUnits,
    required this.enabled,
    required this.onUnitChanged,
    required this.onChanged,
    required this.onRemove,
    required this.onAddBarcode,
    required this.onRemoveBarcode,
  });

  final AppLocalizations l10n;
  final _UnitRow row;
  final String baseUnitLabel;
  final List<UnitOfMeasure> availableUnits;
  final bool enabled;
  final ValueChanged<UnitOfMeasure> onUnitChanged;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final _BarcodeAddOutcome Function(String code) onAddBarcode;
  final ValueChanged<String> onRemoveBarcode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    // The current unit may not be in availableUnits (it's filtered out of other
    // rows), so include it explicitly to keep the dropdown value valid.
    final options = {row.unit.code: row.unit};
    for (final unit in availableUnits) {
      options.putIfAbsent(unit.code, () => unit);
    }

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.line),
      ),
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: row.unit.code,
                  isDense: true,
                  decoration: InputDecoration(
                    labelText: l10n.productUnitPickLabel,
                    isDense: true,
                  ),
                  items: [
                    for (final unit in options.values)
                      DropdownMenuItem(
                        value: unit.code,
                        child: Text(unit.name),
                      ),
                  ],
                  onChanged: enabled
                      ? (value) {
                          final unit = options[value];
                          if (unit != null) onUnitChanged(unit);
                        }
                      : null,
                ),
              ),
              IconButton(
                tooltip: l10n.productUnitRemoveTooltip,
                onPressed: enabled ? onRemove : null,
                icon: Icon(Icons.delete_outline, color: colors.danger),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('1 ${row.unit.label} =', style: theme.textTheme.bodyMedium),
              SizedBox(width: spacing.sm),
              SizedBox(
                width: 96,
                child: TextField(
                  controller: row.factorController,
                  enabled: enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: const InputDecoration(isDense: true),
                  onChanged: (_) => onChanged(),
                ),
              ),
              SizedBox(width: spacing.sm),
              Flexible(
                child: Text(
                  baseUnitLabel,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: row.priceController,
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.productUnitPriceLabel,
              helperText: l10n.productUnitPriceHelper,
              isDense: true,
              prefixIcon: const Icon(Icons.sell_outlined),
            ),
            onChanged: (_) => onChanged(),
          ),
          SizedBox(height: spacing.xs),
          Wrap(
            spacing: spacing.md,
            children: [
              _ToggleChip(
                label: l10n.productUnitSellable,
                value: row.isSellable,
                enabled: enabled,
                onChanged: (value) {
                  row.isSellable = value;
                  onChanged();
                },
              ),
              _ToggleChip(
                label: l10n.productUnitPurchasable,
                value: row.isPurchasable,
                enabled: enabled,
                onChanged: (value) {
                  row.isPurchasable = value;
                  onChanged();
                },
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          _UnitBarcodesField(
            l10n: l10n,
            row: row,
            enabled: enabled,
            onAddBarcode: onAddBarcode,
            onRemoveBarcode: onRemoveBarcode,
          ),
        ],
      ),
    );
  }
}

/// The per-unit packaging-barcode editor: deletable chips for the codes already
/// on the unit, plus a field to add more by typing (or a hardware wedge scanner)
/// and a camera-scan button. Scanning one of these codes at the POS rings the
/// product up as this unit at this unit's price.
class _UnitBarcodesField extends StatelessWidget {
  const _UnitBarcodesField({
    required this.l10n,
    required this.row,
    required this.enabled,
    required this.onAddBarcode,
    required this.onRemoveBarcode,
  });

  final AppLocalizations l10n;
  final _UnitRow row;
  final bool enabled;
  final _BarcodeAddOutcome Function(String code) onAddBarcode;
  final ValueChanged<String> onRemoveBarcode;

  void _submit(String raw) {
    final code = raw.trim();
    if (code.isNotEmpty) {
      final outcome = onAddBarcode(code);
      // Keep a rejected cross-unit code visible so the manager can retarget it;
      // otherwise clear so the field is ready for the next scan.
      if (outcome != _BarcodeAddOutcome.usedByAnotherUnit) {
        row.barcodeInputController.clear();
      }
    }
    // Re-focus so a wedge scanner (or repeated manual entry) can keep going.
    row.barcodeInputFocusNode.requestFocus();
  }

  Future<void> _scan(BuildContext context) async {
    final code = await showCameraTextBarcodeScannerSheet(
      context,
      title: l10n.productUnitBarcodeScanTitle,
    );
    final trimmed = code?.trim() ?? '';
    if (trimmed.isNotEmpty) onAddBarcode(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.productUnitBarcodesLabel, style: theme.textTheme.labelLarge),
        SizedBox(height: spacing.xs),
        Text(
          l10n.productUnitBarcodesHelper,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        if (row.barcodes.isNotEmpty) ...[
          SizedBox(height: spacing.xs),
          Wrap(
            spacing: spacing.xs,
            runSpacing: spacing.xs,
            children: [
              for (final barcode in row.barcodes)
                InputChip(
                  avatar: const Icon(Icons.qr_code_2, size: 16),
                  label: Text(barcode),
                  isEnabled: enabled,
                  onDeleted: enabled ? () => onRemoveBarcode(barcode) : null,
                  deleteButtonTooltipMessage:
                      l10n.productUnitBarcodeRemoveTooltip,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ],
        SizedBox(height: spacing.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TutorTarget(
                anchor: TutorAnchor.productUnitBarcodeField,
                child: TextField(
                  controller: row.barcodeInputController,
                  focusNode: row.barcodeInputFocusNode,
                  enabled: enabled,
                  textInputAction: TextInputAction.done,
                  onSubmitted: enabled ? _submit : null,
                  decoration: InputDecoration(
                    labelText: l10n.productUnitBarcodeAddHint,
                    isDense: true,
                    prefixIcon: const Icon(Icons.qr_code_2),
                  ),
                ),
              ),
            ),
            SizedBox(width: spacing.xs),
            IconButton(
              tooltip: l10n.productUnitBarcodeScanTooltip,
              onPressed: enabled ? () => _scan(context) : null,
              icon: const Icon(Icons.photo_camera_outlined),
            ),
            TutorTarget(
              anchor: TutorAnchor.productUnitAddBarcodeButton,
              child: IconButton(
                tooltip: l10n.productUnitBarcodeAddTooltip,
                onPressed: enabled
                    ? () => _submit(row.barcodeInputController.text)
                    : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ToggleChip extends StatefulWidget {
  const _ToggleChip({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  State<_ToggleChip> createState() => _ToggleChipState();
}

class _ToggleChipState extends State<_ToggleChip> {
  late bool _value = widget.value;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(widget.label),
      selected: _value,
      onSelected: widget.enabled
          ? (value) {
              setState(() => _value = value);
              widget.onChanged(value);
            }
          : null,
    );
  }
}

class _DefaultUnitPickers extends StatelessWidget {
  const _DefaultUnitPickers({
    required this.l10n,
    required this.baseUnitCode,
    required this.rows,
    required this.defaultSaleUnit,
    required this.defaultPurchaseUnit,
    required this.enabled,
    required this.onDefaultSaleChanged,
    required this.onDefaultPurchaseChanged,
  });

  final AppLocalizations l10n;
  final String baseUnitCode;
  final List<_UnitRow> rows;
  final String defaultSaleUnit;
  final String defaultPurchaseUnit;
  final bool enabled;
  final ValueChanged<String> onDefaultSaleChanged;
  final ValueChanged<String> onDefaultPurchaseChanged;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    // Default options: the base unit (value "") plus each configured unit.
    final saleItems = <DropdownMenuItem<String>>[
      DropdownMenuItem(value: '', child: Text(_baseLabel)),
      for (final row in rows)
        if (row.isSellable)
          DropdownMenuItem(value: row.unit.code, child: Text(row.unit.name)),
    ];
    final purchaseItems = <DropdownMenuItem<String>>[
      DropdownMenuItem(value: '', child: Text(_baseLabel)),
      for (final row in rows)
        if (row.isPurchasable)
          DropdownMenuItem(value: row.unit.code, child: Text(row.unit.name)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _valueIfPresent(defaultSaleUnit, saleItems),
          decoration: InputDecoration(
            labelText: l10n.productDefaultSaleUnitLabel,
            prefixIcon: const Icon(Icons.point_of_sale_outlined),
          ),
          items: saleItems,
          onChanged: enabled
              ? (value) => onDefaultSaleChanged(value ?? '')
              : null,
        ),
        SizedBox(height: spacing.md),
        DropdownButtonFormField<String>(
          initialValue: _valueIfPresent(defaultPurchaseUnit, purchaseItems),
          decoration: InputDecoration(
            labelText: l10n.productDefaultPurchaseUnitLabel,
            prefixIcon: const Icon(Icons.local_shipping_outlined),
          ),
          items: purchaseItems,
          onChanged: enabled
              ? (value) => onDefaultPurchaseChanged(value ?? '')
              : null,
        ),
      ],
    );
  }

  String get _baseLabel =>
      l10n.productUnitBaseOption(unitLabel(l10n, baseUnitCode));

  String _valueIfPresent(String value, List<DropdownMenuItem<String>> items) {
    return items.any((item) => item.value == value) ? value : '';
  }
}
