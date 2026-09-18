import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/consignment.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// سند استلام أمانة — the voucher, and the goods, in one act.
///
/// Signing the page is what starts custody, so the terms and the articles are
/// filled in together and submitted together: a signed page with no goods
/// behind it is a promise about nothing, and goods with no page behind them are
/// a liability nobody wrote down.
///
/// The identifier field is a [ScanWedgeTarget]. A watch's serial is scanned or
/// read off a caseback, and the burst guard that stops a wedge becoming a line
/// quantity would otherwise swallow it.
Future<ConsignmentAgreement?> showConsignmentIntakeSheet(
  BuildContext context, {
  required CatalogRepository catalog,
  required ContactRepository contacts,
  required Future<Result<ConsignmentAgreement>> Function({
    required int consignorId,
    required String payoutMode,
    double? payoutRate,
    double? commissionPct,
    double? reservePrice,
    required String liabilityPolicy,
    DateTime? expiresOn,
    String notes,
    required List<ConsignmentIntakeItem> items,
  })
  onSubmit,
}) {
  return showModalBottomSheet<ConsignmentAgreement>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => _ConsignmentIntakeSheet(
      catalog: catalog,
      contacts: contacts,
      onSubmit: onSubmit,
    ),
  );
}

class _ConsignmentIntakeSheet extends StatefulWidget {
  const _ConsignmentIntakeSheet({
    required this.catalog,
    required this.contacts,
    required this.onSubmit,
  });

  final CatalogRepository catalog;
  final ContactRepository contacts;
  final Future<Result<ConsignmentAgreement>> Function({
    required int consignorId,
    required String payoutMode,
    double? payoutRate,
    double? commissionPct,
    double? reservePrice,
    required String liabilityPolicy,
    DateTime? expiresOn,
    String notes,
    required List<ConsignmentIntakeItem> items,
  })
  onSubmit;

  @override
  State<_ConsignmentIntakeSheet> createState() =>
      _ConsignmentIntakeSheetState();
}

class _ConsignmentIntakeSheetState extends State<_ConsignmentIntakeSheet> {
  int? _consignorId;
  String _consignorName = '';
  String _payoutMode = ConsignmentPayoutMode.fixed;
  String _liability = ConsignmentLiability.ownerRisk;
  double? _payoutRate;
  double? _commissionPct;
  double? _reservePrice;
  final List<_IntakeRow> _rows = [_IntakeRow()];
  bool _isSaving = false;
  String _error = '';

  bool get _isFixed => _payoutMode == ConsignmentPayoutMode.fixed;

  bool get _canSubmit =>
      !_isSaving &&
      _consignorId != null &&
      (_isFixed ? (_payoutRate ?? 0) > 0 : (_commissionPct ?? 0) > 0) &&
      _rows.every((row) => row.variant != null && row.code.trim().isNotEmpty);

  /// The price this agreement's goods may not be sold below. Shown while the
  /// terms are being agreed, because it is the number the cashier will hit at
  /// the till and the consignor is standing right here.
  double? get _floor {
    if (!_isFixed) {
      return null;
    }
    final reserve = _reservePrice ?? 0;
    final payout = _payoutRate ?? 0;
    return reserve > payout ? reserve : payout;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

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
                const Icon(Icons.handshake_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.consignmentIntakeTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickConsignor,
              icon: const Icon(Icons.person_outline),
              label: Text(
                _consignorName.isEmpty
                    ? l10n.consignmentIntakeConsignor
                    : _consignorName,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: ConsignmentPayoutMode.fixed,
                  label: Text(l10n.consignmentIntakeFixed),
                ),
                ButtonSegment(
                  value: ConsignmentPayoutMode.commission,
                  label: Text(l10n.consignmentIntakeCommission),
                ),
              ],
              selected: {_payoutMode},
              onSelectionChanged: (values) =>
                  setState(() => _payoutMode = values.first),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _NumberField(
                    label: _isFixed
                        ? l10n.consignmentIntakePayoutRate
                        : l10n.consignmentIntakeCommissionPct,
                    onChanged: (value) => setState(() {
                      if (_isFixed) {
                        _payoutRate = value;
                      } else {
                        _commissionPct = value;
                      }
                    }),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _NumberField(
                    label: l10n.consignmentIntakeReserve,
                    onChanged: (value) => setState(() => _reservePrice = value),
                  ),
                ),
              ],
            ),
            if (_floor != null && _floor! > 0) ...[
              const SizedBox(height: 8),
              // Not a warning: it is the agreement, said in the form of the
              // number the till will enforce.
              PointyDetailCallout(
                icon: Icons.gavel_outlined,
                tone: PointyCalloutTone.primary,
                title: l10n.consignmentIntakeFloorHint(formatMoney(_floor!)),
              ),
            ],
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _liability,
              decoration: InputDecoration(
                labelText: l10n.consignmentIntakeLiability,
              ),
              items: [
                DropdownMenuItem(
                  value: ConsignmentLiability.ownerRisk,
                  child: Text(l10n.consignmentIntakeLiabilityOwner),
                ),
                DropdownMenuItem(
                  value: ConsignmentLiability.shopLiableExceptForceMajeure,
                  child: Text(l10n.consignmentIntakeLiabilityExceptFm),
                ),
                DropdownMenuItem(
                  value: ConsignmentLiability.shopLiable,
                  child: Text(l10n.consignmentIntakeLiabilityShop),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _liability = value ?? _liability),
            ),
            const Divider(height: 20),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _rows.length,
                separatorBuilder: (_, _) => const Divider(height: 14),
                itemBuilder: (context, index) => _IntakeRowEditor(
                  key: ValueKey('intake-$index'),
                  row: _rows[index],
                  catalog: widget.catalog,
                  canRemove: _rows.length > 1,
                  onChanged: () => setState(() {}),
                  onRemove: () => setState(() => _rows.removeAt(index)),
                ),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => setState(() => _rows.add(_IntakeRow())),
                icon: const Icon(Icons.add),
                label: Text(l10n.consignmentIntakeAddItem),
              ),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.danger,
                  ),
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
                  flex: 2,
                  child: FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    child: Text(l10n.consignmentIntakeConfirm),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickConsignor() async {
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: widget.contacts,
    );
    if (customer == null || !mounted) {
      return;
    }
    setState(() {
      _consignorId = customer.id;
      _consignorName = customer.fullName;
    });
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _isSaving = true;
      _error = '';
    });
    final result = await widget.onSubmit(
      consignorId: _consignorId!,
      payoutMode: _payoutMode,
      payoutRate: _isFixed ? _payoutRate : null,
      commissionPct: _isFixed ? null : _commissionPct,
      reservePrice: _reservePrice,
      liabilityPolicy: _liability,
      notes: '',
      items: [
        for (final row in _rows)
          ConsignmentIntakeItem(
            variantId: row.variant!.id,
            code: row.code.trim(),
            declaredValue: row.declaredValue,
            listPrice: row.listPrice,
          ),
      ],
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<ConsignmentAgreement>(:final value):
        Navigator.of(context).pop(value);
      case Error<ConsignmentAgreement>():
        setState(() {
          _isSaving = false;
          _error = l10n.consignmentIntakeFailed;
        });
    }
  }
}

class _IntakeRow {
  ProductVariant? variant;
  String productLabel = '';
  String code = '';
  double? declaredValue;
  double? listPrice;
}

class _IntakeRowEditor extends StatefulWidget {
  const _IntakeRowEditor({
    super.key,
    required this.row,
    required this.catalog,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final _IntakeRow row;
  final CatalogRepository catalog;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_IntakeRowEditor> createState() => _IntakeRowEditorState();
}

class _IntakeRowEditorState extends State<_IntakeRowEditor> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickVariant,
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                label: Text(
                  widget.row.productLabel.isEmpty
                      ? l10n.consignmentIntakeAddItem
                      : widget.row.productLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (widget.canRemove)
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.onRemove,
              ),
          ],
        ),
        const SizedBox(height: 6),
        ScanWedgeTarget(
          child: TextFormField(
            initialValue: widget.row.code,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.qr_code_2_outlined),
              labelText: l10n.unitCaptureHint,
            ),
            onChanged: (value) {
              widget.row.code = value;
              widget.onChanged();
            },
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _NumberField(
                label: l10n.consignmentIntakeDeclaredValue,
                onChanged: (value) {
                  widget.row.declaredValue = value;
                  widget.onChanged();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _NumberField(
                label: l10n.stockUnitOwnPrice,
                onChanged: (value) {
                  widget.row.listPrice = value;
                  widget.onChanged();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickVariant() async {
    final picked = await showModalBottomSheet<_PickedVariant>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _VariantSearchSheet(catalog: widget.catalog),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      widget.row.variant = picked.variant;
      widget.row.productLabel = picked.label;
    });
    widget.onChanged();
  }
}

class _PickedVariant {
  const _PickedVariant(this.variant, this.label);

  final ProductVariant variant;
  final String label;
}

/// A catalog search narrowed to the only thing a consignment can be: an
/// article the shop identifies one by one.
class _VariantSearchSheet extends StatefulWidget {
  const _VariantSearchSheet({required this.catalog});

  final CatalogRepository catalog;

  @override
  State<_VariantSearchSheet> createState() => _VariantSearchSheetState();
}

class _VariantSearchSheetState extends State<_VariantSearchSheet> {
  List<Product> _products = const [];
  bool _isLoading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_search(''));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search(String term) async {
    setState(() => _isLoading = true);
    final result = await widget.catalog.loadProducts(
      query: ProductQuery(search: term),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
      if (result case Ok(:final value)) {
        _products = value.products;
      }
    });
  }

  void _onTyped(String term) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(term));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final rows = <_PickedVariant>[
      for (final product in _products)
        // Only tracked articles: a consignment is a thing with a number on it,
        // and offering a shop's bags of rice here would be offering a mistake.
        if (product.trackingMode.tracksUnits)
          for (final variant in product.variants)
            _PickedVariant(variant, '${product.name} · ${variant.displayName}'),
    ];
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
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.searchProductsHint,
              ),
              onChanged: _onTyped,
            ),
            const SizedBox(height: 10),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: PointySpinner(),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => ListTile(
                    dense: true,
                    title: Text(rows[index].label),
                    onTap: () => Navigator.of(context).pop(rows[index]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({required this.label, required this.onChanged});

  final String label;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(isDense: true, labelText: label),
      onChanged: (value) => onChanged(double.tryParse(value.trim())),
    );
  }
}
