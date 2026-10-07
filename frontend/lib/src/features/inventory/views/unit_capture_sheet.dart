import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/receipt_capture.dart';
import '../../../data/models/unit_attribute.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/tracking/identifier_check.dart';
import '../../../shared/tracking/unit_attribute_catalog.dart';
import '../../../shared/tracking/unit_attribute_form.dart';
import '../../../shared/tracking/unit_attribute_summary.dart';
import '../../../shared/tracking/unit_details_sheet.dart';
import 'unit_capture_parts.dart';

/// The scan-and-fill loop: N identifiers for N articles, counted down.
///
/// One widget, several callers — receiving today, counter purchase, consignment
/// intake, opening identification and serialized stock count later. That is why
/// it takes a count and a line cost rather than a purchase line: it knows
/// nothing about where the goods came from.
///
/// **It is a [ScanWedgeTarget], and that is not optional.** `ScanBurstGuard`
/// exists to stop a scanner's digits becoming a line quantity, and it does that
/// by rolling back any digit run typed faster than a human can type — which is
/// exactly what an IMEI scanned into this field looks like. Without the opt-out
/// the guard swallows the scan and the loop appears to simply not work,
/// intermittently, on whichever pane happens to hold focus.
Future<List<ReceiptUnitCapture>?> showUnitCaptureSheet(
  BuildContext context, {
  required String productLabel,
  required int expectedCount,
  required double lineUnitCost,
  List<ReceiptUnitCapture> initial = const [],
  bool allowCaptureLater = false,

  /// Off where the server decides what the articles are worth — a supplier's
  /// replacement takes the shelf's own rate — so typing a cost per handset
  /// would be typing a number nothing reads.
  bool allowSplitCosts = true,

  /// The goods' kind. When set, each scanned row offers that kind's condition
  /// checklist (§6.2), and any field the shop marked required must be filled
  /// before the sheet confirms.
  int? assetTypeId,

  /// What sort of number the articles carry (`imei`, …). An IMEI that fails
  /// its check digit is questioned before it is added.
  String identifierKind = '',

  /// The lot every article joins (`serial_batch`), named above the scan field.
  ReceiptBatchCapture? lot,

  /// Whether this person may give each article its own selling price and its
  /// own warranty date — the unit page's reprice and warranty permissions,
  /// which the server asks again when the receipt posts.
  bool canSetPrice = false,
  bool canSetWarranty = false,

  /// The product's own price, named under each article's price field.
  double? productPrice,
}) {
  return showModalBottomSheet<List<ReceiptUnitCapture>>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) {
      return _UnitCaptureSheet(
        productLabel: productLabel,
        expectedCount: expectedCount,
        lineUnitCost: lineUnitCost,
        initial: initial,
        allowCaptureLater: allowCaptureLater,
        allowSplitCosts: allowSplitCosts,
        assetTypeId: assetTypeId,
        identifierKind: identifierKind,
        lot: lot,
        canSetPrice: canSetPrice,
        canSetWarranty: canSetWarranty,
        productPrice: productPrice,
      );
    },
  );
}

class _UnitCaptureSheet extends StatefulWidget {
  const _UnitCaptureSheet({
    required this.productLabel,
    required this.expectedCount,
    required this.lineUnitCost,
    required this.initial,
    required this.allowCaptureLater,
    required this.allowSplitCosts,
    required this.identifierKind,
    required this.canSetPrice,
    required this.canSetWarranty,
    this.assetTypeId,
    this.lot,
    this.productPrice,
  });

  final String productLabel;
  final int expectedCount;
  final double lineUnitCost;
  final List<ReceiptUnitCapture> initial;
  final bool allowCaptureLater;
  final bool allowSplitCosts;
  final int? assetTypeId;
  final String identifierKind;
  final ReceiptBatchCapture? lot;
  final bool canSetPrice;
  final bool canSetWarranty;
  final double? productPrice;

  @override
  State<_UnitCaptureSheet> createState() => _UnitCaptureSheetState();
}

class _UnitCaptureSheetState extends State<_UnitCaptureSheet> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  late List<ReceiptUnitCapture> _captured;
  bool _splitCosts = false;
  String _error = '';

  /// A doubtful number the receiver was warned about. The same number entered
  /// again is taken as it is — the box in their hand may well say exactly that.
  String _warning = '';
  String? _warnedCode;

  /// The kind's checklist, once known. Null while there is nothing to offer.
  List<UnitAttributeDefinition>? _definitions;
  bool _askedForDefinitions = false;

  @override
  void initState() {
    super.initState();
    _captured = List<ReceiptUnitCapture>.from(widget.initial);
    _splitCosts =
        widget.allowSplitCosts &&
        _captured.any((unit) => unit.unitCost != null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_askedForDefinitions || widget.assetTypeId == null) return;
    _askedForDefinitions = true;
    final catalog = UnitAttributeCatalogScope.maybeOf(context);
    if (catalog == null) return;
    catalog.definitionsFor(widget.assetTypeId).then((definitions) {
      if (mounted) setState(() => _definitions = definitions);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  List<UnitAttributeDefinition> get _checklist => _definitions ?? const [];

  bool get _offersChecklist => _checklist.isNotEmpty;

  /// Something to record per article: its condition, or its own price.
  bool get _offersDetails => _offersChecklist || widget.canSetPrice;

  int get _remaining => widget.expectedCount - _captured.length;

  /// What is left to account for when the receiver is splitting the line's
  /// cost across individual articles. Every article not yet scanned — the ones
  /// a capture-later receipt leaves owed — is booked at the line rate, exactly
  /// as the server books it, so the residual has to reach zero either way.
  double get _costResidual {
    return _captured.fold<double>(
      0,
      (sum, unit) => sum + widget.lineUnitCost - (unit.unitCost ?? 0),
    );
  }

  bool _missingRequired(ReceiptUnitCapture unit) {
    if (!_checklist.any((definition) => definition.isRequired)) {
      return false;
    }
    final l10n = AppLocalizations.of(context)!;
    return validateUnitAttributes(_checklist, unit.attributes, l10n).isNotEmpty;
  }

  UnitDetailsState _detailsState(ReceiptUnitCapture unit) {
    if (!_offersChecklist) return UnitDetailsState.notOffered;
    if (_missingRequired(unit)) return UnitDetailsState.missingRequired;
    return unit.attributes.isEmpty
        ? UnitDetailsState.missing
        : UnitDetailsState.described;
  }

  int get _describedCount =>
      _captured.where((unit) => unit.attributes.isNotEmpty).length;

  int get _incompleteCount => _captured.where(_missingRequired).length;

  void _add() {
    final code = _input.text.trim();
    final l10n = AppLocalizations.of(context)!;
    if (code.isEmpty) {
      return;
    }
    final normalized = _normalize(code);
    if (_captured.any((unit) => _normalize(unit.code) == normalized)) {
      setState(() {
        _error = l10n.unitCaptureDuplicate(code);
        _warning = '';
      });
      _input.clear();
      return;
    }
    if (_remaining <= 0) {
      setState(() {
        _error = l10n.unitCaptureTooMany(widget.expectedCount);
        _warning = '';
      });
      _input.clear();
      return;
    }
    final problem = checkIdentifier(code, kind: widget.identifierKind);
    if (problem != null && _warnedCode != normalized) {
      // Kept in the field: re-scanning replaces it, Enter again accepts it.
      setState(() {
        _error = '';
        _warnedCode = normalized;
        _warning = switch (problem) {
          IdentifierProblem.imeiChecksum => l10n.unitCaptureImeiChecksum(code),
          IdentifierProblem.imeiLength => l10n.unitCaptureImeiLength(code),
          IdentifierProblem.imeiNotNumeric => l10n.unitCaptureImeiNotNumeric(
            code,
          ),
        };
      });
      _input.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _input.text.length,
      );
      _inputFocus.requestFocus();
      return;
    }
    setState(() {
      _captured = [
        ..._captured,
        ReceiptUnitCapture(
          code: code,
          identifierKind: widget.identifierKind,
          unitCost: _splitCosts ? widget.lineUnitCost : null,
        ),
      ];
      _error = '';
      _warning = '';
      _warnedCode = null;
    });
    _input.clear();
    // Straight back to the field: the receiver's next action is always another
    // scan, and reaching for the mouse forty times is the thing this loop
    // exists to avoid.
    _inputFocus.requestFocus();
  }

  String _normalize(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[\s\-._/]'), '');

  void _removeAt(int index) {
    setState(() {
      _captured = [..._captured]..removeAt(index);
      _error = '';
    });
  }

  void _setCost(int index, double? cost) {
    setState(() {
      _captured = [..._captured];
      _captured[index] = _captured[index].copyWith(unitCost: cost);
    });
  }

  void _toggleSplit(bool value) {
    setState(() {
      _splitCosts = value;
      _captured = _captured
          .map(
            (unit) =>
                unit.copyWith(unitCost: value ? widget.lineUnitCost : null),
          )
          .toList();
    });
  }

  Future<void> _editDetails(int index) async {
    final l10n = AppLocalizations.of(context)!;
    final row = _captured[index];
    final draft = await showUnitDetailsSheet(
      context,
      title: l10n.unitCaptureDeviceDetailsTitle(row.code),
      definitions: _checklist,
      attributes: row.attributes,
      editAttributes: _offersChecklist,
      editWarranty: widget.canSetWarranty,
      warrantyOverride: row.warrantyOverrideExpiresOn,
      editListPrice: widget.canSetPrice,
      listPrice: row.listPrice,
      productPrice: widget.productPrice,
    );
    if (draft == null || !mounted) return;
    setState(() {
      _captured = [..._captured];
      _captured[index] = _captured[index].copyWith(
        attributes: draft.attributes,
        warrantyOverrideExpiresOn: draft.warrantyOverride,
        listPrice: widget.canSetPrice ? draft.listPrice : row.listPrice,
      );
    });
    // Straight back to scanning.
    _inputFocus.requestFocus();
  }

  /// Why confirming is not possible yet, in the receiver's terms — or empty.
  String _blockedReason(AppLocalizations l10n) {
    if (_remaining > 0 && !widget.allowCaptureLater) {
      return l10n.unitCaptureBlockedScanMore(_remaining);
    }
    if (_splitCosts && _costResidual.abs() >= 0.005) {
      return l10n.unitCaptureBlockedCostResidual(formatMoney(_costResidual));
    }
    final incomplete = _incompleteCount;
    if (incomplete > 0) {
      return l10n.unitCaptureBlockedRequired(incomplete);
    }
    return '';
  }

  String _detailsLabel(AppLocalizations l10n) {
    if (_offersChecklist && widget.canSetPrice) {
      return l10n.unitCaptureDetailsAndPriceButton;
    }
    return _offersChecklist
        ? l10n.unitCaptureDetailsButton
        : l10n.unitCapturePriceButton;
  }

  String _rowSummary(ReceiptUnitCapture unit, AppLocalizations l10n) {
    final warranty = unit.warrantyOverrideExpiresOn;
    final price = unit.listPrice;
    return [
      // The price first — it is what a used handset is bought and sold on —
      // and held together, so «د.ل» never wraps away from its amount.
      if (price != null)
        l10n.unitCaptureRowPrice(formatMoney(price).replaceAll(' ', '\u00A0')),
      if (_offersChecklist)
        UnitAttributeSummary.describe(
          displayUnitAttributes(_checklist, unit.attributes, l10n),
        ),
      if (warranty != null) l10n.stockUnitWarrantyUntil(formatDate(warranty)),
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final blocked = _blockedReason(l10n);
    final complete = _remaining == 0;
    final lot = widget.lot;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_scanner_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.productLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  l10n.unitCaptureProgress(
                    _captured.length,
                    widget.expectedCount,
                  ),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: complete ? colors.primaryStrong : theme.hintColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            PointyProgressBar(
              value: widget.expectedCount == 0
                  ? 1
                  : _captured.length / widget.expectedCount,
              minHeight: 4,
              color: colors.primaryStrong,
              backgroundColor: colors.line,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 10),
            if (lot != null && lot.code.trim().isNotEmpty) ...[
              UnitCaptureLotBanner(lot: lot),
              const SizedBox(height: 10),
            ],
            ScanWedgeTarget(
              child: TextField(
                key: const ValueKey('unit-capture-input'),
                controller: _input,
                focusNode: _inputFocus,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.qr_code_2_outlined),
                  hintText: l10n.unitCaptureHint,
                  errorText: _error.isEmpty ? null : _error,
                  helperText: _warning.isEmpty ? null : _warning,
                  helperMaxLines: 3,
                  helperStyle: theme.textTheme.bodySmall?.copyWith(
                    color: colors.warning,
                  ),
                ),
                onChanged: (_) {
                  if (_warning.isNotEmpty || _error.isNotEmpty) {
                    setState(() {
                      _warning = '';
                      _error = '';
                      _warnedCode = null;
                    });
                  }
                },
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(height: 6),
            if (widget.allowSplitCosts)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _splitCosts,
                onChanged: _toggleSplit,
                title: Text(
                  l10n.unitCaptureSplitCosts,
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: _splitCosts
                    ? Text(
                        l10n.unitCaptureCostResidual(
                          formatMoney(_costResidual),
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _costResidual.abs() < 0.005
                              ? colors.primaryStrong
                              : colors.warning,
                        ),
                      )
                    : null,
              ),
            if (_offersChecklist && _captured.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  l10n.unitCaptureDetailsProgress(
                    _describedCount,
                    _captured.length,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _describedCount == _captured.length
                        ? colors.primaryStrong
                        : colors.mutedInk,
                  ),
                ),
              ),
            const Divider(height: 12),
            Flexible(
              child: _captured.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        l10n.unitCaptureEmpty,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: _captured.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final unit = _captured[index];
                        return CapturedUnitRow(
                          // Keyed by the identifier, not the row number. The
                          // cost box is an uncontrolled TextFormField seeded
                          // from initialValue, so with a positional key (or
                          // none) removing a row left the deleted unit's cost
                          // sitting over the one that shifted up.
                          key: ValueKey(unit.code),
                          index: index,
                          unit: unit,
                          summary: _rowSummary(unit, l10n),
                          detailsState: _detailsState(unit),
                          showsCost: _splitCosts,
                          onRemove: () => _removeAt(index),
                          onCostChanged: (cost) => _setCost(index, cost),
                          detailsLabel: _detailsLabel(l10n),
                          detailsIsPriceOnly: !_offersChecklist,
                          onEditDetails: _offersDetails
                              ? () => _editDetails(index)
                              : null,
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            if (blocked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: colors.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        blocked,
                        key: const ValueKey('unit-capture-blocked'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancelButton),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('unit-capture-confirm'),
                    onPressed: blocked.isEmpty
                        ? () => Navigator.of(context).pop(_captured)
                        : null,
                    child: Text(
                      _remaining > 0 && widget.allowCaptureLater
                          ? l10n.unitCaptureConfirmLater(_remaining)
                          : l10n.unitCaptureConfirm,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
