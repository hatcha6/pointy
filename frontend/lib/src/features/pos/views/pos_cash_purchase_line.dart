import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/receipt_capture.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/unit_options.dart';

/// Mutable in-sheet draft line of the counter cash purchase. [revision] keys
/// the row widget so programmatic changes (cost prefill arriving, unit
/// switches, re-add increments) rebuild the row's text fields with fresh
/// values, while plain typing never does.
class PosCashPurchaseLine {
  PosCashPurchaseLine({
    required this.product,
    required this.variant,
    required this.unitOptions,
    required this.unit,
  });

  final Product product;
  final ProductVariant variant;
  final List<UnitOption> unitOptions;
  UnitOption unit;
  double quantity = 1;
  double? unitCost;
  bool costEdited = false;
  double? lastBaseCost;
  DateTime? expiryDate;
  int revision = 0;

  /// The identifiers scanned off the goods the customer is handing over. The
  /// counter purchase is the one flow where ordering and receiving are the same
  /// act, so they are captured here rather than at a receiving bay the article
  /// will never see.
  List<ReceiptUnitCapture> units = const [];

  /// The lots the goods came in, read off the box at the same counter. Base
  /// units, exactly as the receiving sheet sends them.
  List<ReceiptBatchCapture> batches = const [];

  bool get needsIdentifiers => product.trackingMode.tracksUnits;

  /// Does this line's stock belong to lots at all? Only then is a lot offered.
  bool get capturesLots => product.trackingMode.tracksLots;

  /// A serialised pack inside a lot cannot be bought without its lot. A plain
  /// lot-tracked line can: the server files it under one generated lot that
  /// carries the line's expiry, which is how the bread and milk runs this sheet
  /// was built for keep working without a lot code nobody prints on a loaf.
  bool get requiresLot => capturesLots && needsIdentifiers;

  /// How many base units this line is — what lots and identifiers are counted
  /// against. A carton of twelve is twelve.
  double get baseQuantity => quantity * unit.factorToBase;

  /// How many articles this line is, in base units — what the identifiers
  /// are counted against.
  int get baseUnitCount => baseQuantity.round();

  bool get identifiersComplete =>
      !needsIdentifiers || units.length == baseUnitCount;

  double get capturedLotQuantity =>
      batches.fold<double>(0, (sum, batch) => sum + batch.quantity);

  bool get lotsComplete {
    if (!capturesLots || batches.isEmpty) {
      return !requiresLot;
    }
    if (batches.any((batch) => batch.code.trim().isEmpty)) {
      return false;
    }
    // A serialised line's lot is one header over its scan loop; its quantity
    // is the line's by definition.
    if (needsIdentifiers) {
      return true;
    }
    return (capturedLotQuantity - baseQuantity).abs() < 0.0005;
  }

  /// Keeps the common case — one lot for the whole line — complete when the
  /// cashier changes the quantity or the pack after reading the lot. A split
  /// across several lots is left for the cashier to redo: which lot grew is not
  /// something to guess.
  void syncSingleLot() {
    if (batches.length == 1) {
      batches = [batches.single.copyWith(quantity: baseQuantity)];
    }
  }
}

class PosCashPurchaseLineRow extends StatefulWidget {
  const PosCashPurchaseLineRow({
    super.key,
    required this.line,
    required this.enabled,
    required this.onQuantityChanged,
    required this.onUnitCostChanged,
    required this.onUnitChanged,
    required this.onExpiryChanged,
    required this.onRemove,
    required this.onTotalDirty,
    this.onCaptureIdentifiers,
    this.onCaptureLots,
  });

  final PosCashPurchaseLine line;
  final bool enabled;
  final ValueChanged<double> onQuantityChanged;
  final ValueChanged<double> onUnitCostChanged;
  final ValueChanged<UnitOption> onUnitChanged;
  final ValueChanged<DateTime?> onExpiryChanged;
  final VoidCallback onRemove;
  final VoidCallback onTotalDirty;

  /// Null for anything a shop counts rather than identifies, which is how this
  /// row stays exactly as it was for the bread and the cooking oil.
  final VoidCallback? onCaptureIdentifiers;

  /// Null for anything that keeps no lots.
  final VoidCallback? onCaptureLots;

  @override
  State<PosCashPurchaseLineRow> createState() => _PosCashPurchaseLineRowState();
}

class _PosCashPurchaseLineRowState extends State<PosCashPurchaseLineRow> {
  late final TextEditingController _quantityController = TextEditingController(
    text: _trimmedNumber(widget.line.quantity),
  );
  late final TextEditingController _costController = TextEditingController(
    text: widget.line.unitCost == null
        ? ''
        : widget.line.unitCost!.toStringAsFixed(2),
  );

  @override
  void dispose() {
    _quantityController.dispose();
    _costController.dispose();
    super.dispose();
  }

  static String _trimmedNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toString();
  }

  static String _isoDate(DateTime date) =>
      date.toIso8601String().split('T').first;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final line = widget.line;
    final lineTotal = (line.unitCost ?? 0) * line.quantity;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  line.product.name,
                  style: textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                formatMoney(lineTotal),
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              IconButton(
                tooltip: l10n.posCashPurchaseRemoveLineTooltip,
                onPressed: widget.enabled ? widget.onRemove : null,
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
            ],
          ),
          Row(
            children: [
              if (line.unitOptions.length > 1) ...[
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: line.unit.code,
                    isDense: true,
                    items: [
                      for (final option in line.unitOptions)
                        DropdownMenuItem(
                          value: option.code,
                          child: Text(option.label),
                        ),
                    ],
                    onChanged: widget.enabled
                        ? (code) {
                            final option = line.unitOptions
                                .where((candidate) => candidate.code == code)
                                .firstOrNull;
                            if (option != null) {
                              widget.onUnitChanged(option);
                            }
                          }
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              SizedBox(
                width: 88,
                child: TextFormField(
                  controller: _quantityController,
                  enabled: widget.enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: InputDecoration(
                    labelText: l10n.posCashPurchaseQuantityLabel,
                    isDense: true,
                  ),
                  onChanged: (value) {
                    widget.onQuantityChanged(parseDecimal(value) ?? 0);
                    widget.onTotalDirty();
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 112,
                child: TextFormField(
                  controller: _costController,
                  enabled: widget.enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: InputDecoration(
                    labelText: l10n.posCashPurchaseUnitCostLabel,
                    isDense: true,
                  ),
                  onChanged: (value) {
                    widget.onUnitCostChanged(parseDecimal(value) ?? 0);
                  },
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              if (line.product.tracksExpiry)
                _CaptureChip(
                  icon: Icons.event_outlined,
                  complete: line.expiryDate != null,
                  label: line.expiryDate == null
                      ? l10n.posCashPurchaseExpiryLabel
                      : _isoDate(line.expiryDate!),
                  onPressed: widget.enabled ? _pickExpiry : null,
                ),
              if (widget.onCaptureLots != null)
                _CaptureChip(
                  icon: Icons.inventory_2_outlined,
                  complete: line.lotsComplete,
                  label: _lotLabel(l10n, line),
                  onPressed: widget.enabled ? widget.onCaptureLots : null,
                ),
              if (widget.onCaptureIdentifiers != null)
                _CaptureChip(
                  icon: Icons.qr_code_2_outlined,
                  complete: line.identifiersComplete,
                  label: l10n.unitCaptureProgress(
                    line.units.length,
                    line.baseUnitCount,
                  ),
                  onPressed: widget.enabled
                      ? widget.onCaptureIdentifiers
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _lotLabel(AppLocalizations l10n, PosCashPurchaseLine line) {
    final batches = line.batches;
    if (batches.isEmpty) {
      return line.requiresLot
          ? l10n.batchCaptureLotCode
          : l10n.posCashPurchaseLotOptionalLabel;
    }
    if (batches.length == 1) {
      return l10n.posCashPurchaseLotLabel(batches.single.code.trim());
    }
    return l10n.posCashPurchaseLotsCountLabel(batches.length);
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.line.expiryDate ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (picked != null) {
      widget.onExpiryChanged(picked);
    }
  }
}

/// One of the line's captures — expiry, lot, identifiers — as a chip that
/// turns red while the line still owes it.
class _CaptureChip extends StatelessWidget {
  const _CaptureChip({
    required this.icon,
    required this.complete,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final bool complete;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ActionChip(
        avatar: Icon(
          icon,
          size: 18,
          color: complete ? colors.mutedInk : colors.danger,
        ),
        label: Text(label),
        onPressed: onPressed,
      ),
    );
  }
}
