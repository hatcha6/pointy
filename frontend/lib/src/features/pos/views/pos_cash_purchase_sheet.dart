import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_page.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/models/receipt_capture.dart';
import '../../inventory/views/unit_capture_sheet.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/api_session.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/unit_options.dart';
import 'pos_variant_picker_sheet.dart';
import '../../../data/models/purchase_cost_warning.dart';
import '../../../shared/components/pointy_progress.dart';

/// Opens the POS quick cash-purchase sheet. Returns the recorded submission,
/// or null when dismissed.
///
/// The whole flow is one backend call: the PO is created, received into stock,
/// and paid in cash against the cashier's open register session — the linked
/// pay-out keeps the drawer reconciled, which is the entire point (cashiers
/// used to mentally track drawer money spent on bread/milk runs and the close
/// always showed variances).
Future<PurchaseSubmission?> showPosCashPurchaseSheet(
  BuildContext context, {
  required ContactRepository contactRepository,
  required CatalogRepository catalogRepository,
  required PurchaseRepository purchaseRepository,
  required ShopSettingsRepository shopSettingsRepository,
}) {
  return showAdaptiveModalBottomSheet<PurchaseSubmission>(
    context: context,
    size: AdaptiveModalSize.expanded,
    builder: (context) {
      return PosCashPurchaseSheet(
        contactRepository: contactRepository,
        catalogRepository: catalogRepository,
        purchaseRepository: purchaseRepository,
        shopSettingsRepository: shopSettingsRepository,
      );
    },
  );
}

class PosCashPurchaseSheet extends StatefulWidget {
  const PosCashPurchaseSheet({
    super.key,
    required this.contactRepository,
    required this.catalogRepository,
    required this.purchaseRepository,
    required this.shopSettingsRepository,
  });

  final ContactRepository contactRepository;
  final CatalogRepository catalogRepository;
  final PurchaseRepository purchaseRepository;
  final ShopSettingsRepository shopSettingsRepository;

  @override
  State<PosCashPurchaseSheet> createState() => _PosCashPurchaseSheetState();
}

class _PosCashPurchaseSheetState extends State<PosCashPurchaseSheet> {
  final TextEditingController _supplierSearchController =
      TextEditingController();
  final TextEditingController _productSearchController =
      TextEditingController();
  final FocusNode _productSearchFocus = FocusNode();

  Timer? _supplierDebounce;
  Timer? _productDebounce;

  List<SupplierContact> _suppliers = const [];
  bool _loadingSuppliers = false;
  SupplierContact? _supplier;

  List<Product> _productResults = const [];
  bool _searchingProducts = false;

  final List<_CashPurchaseLine> _lines = [];

  ShopSettings? _settings;
  bool _submitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _loadSuppliers('');
    _loadSettings();
  }

  @override
  void dispose() {
    _supplierDebounce?.cancel();
    _productDebounce?.cancel();
    _supplierSearchController.dispose();
    _productSearchController.dispose();
    _productSearchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final result = await widget.shopSettingsRepository.loadSettings();
    if (!mounted || result is! Ok<ShopSettings>) {
      return;
    }
    setState(() => _settings = result.value);
  }

  // --- supplier picking -----------------------------------------------------

  void _onSupplierQueryChanged(String query) {
    _supplierDebounce?.cancel();
    _supplierDebounce = Timer(const Duration(milliseconds: 250), () {
      _loadSuppliers(query.trim());
    });
  }

  Future<void> _loadSuppliers(String search) async {
    setState(() => _loadingSuppliers = true);
    final result = await widget.contactRepository.loadSuppliers(
      query: ContactQuery(search: search),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _loadingSuppliers = false;
      if (result is Ok<SupplierPage>) {
        _suppliers = result.value.suppliers;
      }
    });
  }

  // --- product search / line building ---------------------------------------

  void _onProductQueryChanged(String query) {
    _productDebounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() => _productResults = const []);
      return;
    }
    _productDebounce = Timer(const Duration(milliseconds: 250), () {
      _searchProducts(trimmed);
    });
  }

  Future<void> _searchProducts(String search) async {
    setState(() => _searchingProducts = true);
    final result = await widget.catalogRepository.loadProducts(
      query: ProductQuery(search: search),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _searchingProducts = false;
      if (result is Ok<ProductPage>) {
        // Services and in-house prepared items are made, not bought.
        _productResults = result.value.products
            .where((product) => !product.isService && !product.isPrepared)
            .toList(growable: false);
      }
    });
  }

  Future<void> _addProduct(Product product) async {
    final l10n = AppLocalizations.of(context)!;
    ProductVariant? variant = product.defaultVariant;
    if (product.variants.length > 1) {
      variant = await showPosVariantPickerSheet(
        context,
        product: product,
        variants: product.variants,
      );
    }
    if (variant == null || !mounted) {
      return;
    }

    _productSearchController.clear();
    setState(() => _productResults = const []);
    _productSearchFocus.requestFocus();

    final existing = _lines
        .where((line) => line.variant.id == variant!.id)
        .firstOrNull;
    if (existing != null) {
      setState(() {
        existing.quantity += 1;
        existing.revision += 1;
      });
      return;
    }

    final options = purchasableUnitOptions(l10n, product);
    final defaultUnit = options
        .where((option) => option.code == product.defaultPurchaseUnit)
        .firstOrNull;
    final line = _CashPurchaseLine(
      product: product,
      variant: variant,
      unitOptions: options,
      unit: defaultUnit ?? options.first,
    );
    setState(() => _lines.add(line));
    _prefillLastCost(line);
  }

  /// The scan-and-fill loop, reused exactly as receiving uses it.
  ///
  /// One widget, several callers: what differs between buying forty handsets
  /// from a distributor and buying one off a walk-in is the paperwork, not the
  /// act of reading a number off a box.
  Future<void> _captureIdentifiers(_CashPurchaseLine line) async {
    final captured = await showUnitCaptureSheet(
      context,
      productLabel: line.product.name,
      expectedCount: line.quantity.round(),
      lineUnitCost: line.unitCost ?? 0,
      initial: line.units,
    );
    if (captured == null || !mounted) {
      return;
    }
    setState(() => line.units = captured);
  }

  Future<void> _prefillLastCost(_CashPurchaseLine line) async {
    final result = await widget.purchaseRepository.loadLastProductCost(
      line.product.id,
      variantId: line.variant.id,
    );
    if (!mounted || result is! Ok<double?>) {
      return;
    }
    final baseCost = result.value;
    if (baseCost == null) {
      return;
    }
    setState(() {
      line.lastBaseCost = baseCost;
      if (!line.costEdited) {
        line.unitCost = baseCost * line.unit.factorToBase;
        line.revision += 1;
      }
    });
  }

  void _changeLineUnit(_CashPurchaseLine line, UnitOption unit) {
    setState(() {
      line.unit = unit;
      // A not-yet-touched cost keeps tracking the last known cost in the newly
      // chosen unit (base cost × pack factor).
      if (!line.costEdited && line.lastBaseCost != null) {
        line.unitCost = line.lastBaseCost! * unit.factorToBase;
      }
      line.revision += 1;
    });
  }

  void _removeLine(_CashPurchaseLine line) {
    setState(() => _lines.remove(line));
  }

  // --- validation / submit --------------------------------------------------

  double get _total =>
      _lines.fold(0, (sum, line) => sum + (line.unitCost ?? 0) * line.quantity);

  double? get _limit {
    final settings = _settings;
    if (settings == null || !settings.hasPosCashPurchaseLimit) {
      return null;
    }
    return settings.posCashPurchaseLimit;
  }

  bool get _overLimit {
    final limit = _limit;
    return limit != null && _total > limit;
  }

  String? _validationError(AppLocalizations l10n) {
    if (_supplier == null || _lines.isEmpty) {
      return null; // The submit button is simply disabled for these.
    }
    for (final line in _lines) {
      if (line.quantity <= 0 || (line.unitCost ?? -1) < 0) {
        return null;
      }
      if (line.product.tracksExpiry && line.expiryDate == null) {
        return l10n.posCashPurchaseExpiryRequiredError;
      }
    }
    if (_overLimit) {
      return l10n.posCashPurchaseOverLimitError(formatMoney(_limit!));
    }
    return null;
  }

  bool get _canSubmit {
    if (_submitting || _supplier == null || _lines.isEmpty || _overLimit) {
      return false;
    }
    return _lines.every(
      (line) =>
          line.quantity > 0 &&
          (line.unitCost ?? -1) >= 0 &&
          (!line.product.tracksExpiry || line.expiryDate != null) &&
          // A serialized article bought over the counter is refused without its
          // number, here rather than at the server: the seller is standing in
          // front of the cashier and the handset is in their hand, which is the
          // only moment the number is free to get.
          line.identifiersComplete,
    );
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_canSubmit) {
      return;
    }
    setState(() {
      _submitting = true;
      _errorText = null;
    });

    final drafts = [
      for (final line in _lines)
        PurchaseDraftLine(
          variant: line.variant,
          quantity: line.quantity,
          unitCost: line.unitCost ?? 0,
          unitCode: line.unit.isBase ? '' : line.unit.code,
          unitLabel: line.unit.label,
          unitFactor: line.unit.factorToBase,
          unitAllowsFractional: line.unit.allowsFractional,
          expiryDate: line.expiryDate,
          units: line.units,
        ),
    ];
    final result = await widget.purchaseRepository.submitPosCashPurchase(
      drafts,
      supplierId: _supplier!.id,
      idempotencyKey: 'pos-cash-${DateTime.now().microsecondsSinceEpoch}',
    );

    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<PurchaseSubmission>(value: final submission):
        Navigator.of(context).pop(submission);
      case Error<PurchaseSubmission>(exception: final exception):
        setState(() {
          _submitting = false;
          _errorText = _describeSubmitError(l10n, exception);
        });
    }
  }

  String _describeSubmitError(AppLocalizations l10n, Exception exception) {
    // A refused cost comes back with the two numbers that make the mistake
    // obvious — "130.00 for something that sells for 1.00". Show that sentence
    // rather than a generic failure, and offer no way past it: this sheet is
    // used by cashiers, who cannot judge the number and cannot override it.
    final costWarnings = purchaseCostWarningsFromException(exception);
    if (costWarnings.isNotEmpty) {
      return costWarnings
          .map((warning) => warning.message)
          .where((message) => message.isNotEmpty)
          .join('\n');
    }
    if (exception is PosApiException) {
      final detail = exception.responseBody;
      if (detail.contains('register session')) {
        return l10n.posCashPurchaseNoSessionError;
      }
      if (detail.contains('capped')) {
        final limit = _limit;
        if (limit != null) {
          return l10n.posCashPurchaseOverLimitError(formatMoney(limit));
        }
      }
      if (detail.contains('Expiry date')) {
        return l10n.posCashPurchaseExpiryRequiredError;
      }
    }
    return l10n.posCashPurchaseCreateError;
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final validationError = _validationError(l10n);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.shopping_basket_outlined, color: colors.mutedInk),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.posCashPurchaseTitle,
                    style: textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: l10n.cancelButton,
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildSupplierSection(l10n, colors, textTheme),
            const SizedBox(height: 12),
            _buildProductSearch(l10n, colors),
            const SizedBox(height: 8),
            Flexible(child: _buildLines(l10n, colors, textTheme)),
            const SizedBox(height: 8),
            _buildFooter(l10n, colors, textTheme, validationError),
          ],
        ),
      ),
    );
  }

  Widget _buildSupplierSection(
    AppLocalizations l10n,
    PointySemanticColors colors,
    TextTheme textTheme,
  ) {
    final supplier = _supplier;
    if (supplier != null) {
      return Row(
        children: [
          Icon(Icons.storefront_outlined, color: colors.mutedInk),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.posCashPurchaseSupplierLabel,
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
                Text(supplier.name, style: textTheme.titleMedium),
              ],
            ),
          ),
          TextButton(
            onPressed: _submitting
                ? null
                : () => setState(() => _supplier = null),
            child: Text(l10n.posCashPurchaseChangeSupplierButton),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _supplierSearchController,
          enabled: !_submitting,
          onChanged: _onSupplierQueryChanged,
          decoration: InputDecoration(
            labelText: l10n.posCashPurchaseSelectSupplierHint,
            hintText: l10n.posCashPurchaseSupplierSearchHint,
            prefixIcon: const Icon(Icons.storefront_outlined),
            suffixIcon: _loadingSuppliers
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 168),
          child: _suppliers.isEmpty && !_loadingSuppliers
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    l10n.posCashPurchaseNoSuppliersMessage,
                    style: TextStyle(color: colors.mutedInk),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _suppliers.length,
                  itemBuilder: (context, index) {
                    final candidate = _suppliers[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.storefront_outlined),
                      title: Text(candidate.name),
                      onTap: _submitting
                          ? null
                          : () {
                              setState(() => _supplier = candidate);
                              _productSearchFocus.requestFocus();
                            },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildProductSearch(
    AppLocalizations l10n,
    PointySemanticColors colors,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _productSearchController,
          focusNode: _productSearchFocus,
          enabled: !_submitting,
          onChanged: _onProductQueryChanged,
          onSubmitted: (_) {
            // Scanner flow: the wedge types the barcode and sends Enter — take
            // the first (typically only) match.
            final first = _productResults.firstOrNull;
            if (first != null) {
              _addProduct(first);
            }
          },
          decoration: InputDecoration(
            labelText: l10n.posCashPurchaseProductSearchHint,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchingProducts
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 18,
                      child: PointySpinner(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        ),
        if (_productSearchController.text.trim().isNotEmpty &&
            _productResults.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _productResults.length,
              itemBuilder: (context, index) {
                final product = _productResults[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(product.name),
                  subtitle: product.effectiveSku.isEmpty
                      ? null
                      : Text(product.effectiveSku),
                  onTap: _submitting ? null : () => _addProduct(product),
                );
              },
            ),
          )
        else if (_productSearchController.text.trim().isNotEmpty &&
            !_searchingProducts)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              l10n.posCashPurchaseNoProductsMessage,
              style: TextStyle(color: colors.mutedInk),
            ),
          ),
      ],
    );
  }

  Widget _buildLines(
    AppLocalizations l10n,
    PointySemanticColors colors,
    TextTheme textTheme,
  ) {
    if (_lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          l10n.posCashPurchaseLinesEmptyMessage,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.mutedInk),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _lines.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final line = _lines[index];
        return _CashPurchaseLineRow(
          key: ValueKey(
            '${line.variant.id}:${line.unit.code}:${line.revision}',
          ),
          line: line,
          enabled: !_submitting,
          onQuantityChanged: (value) => line.quantity = value,
          onUnitCostChanged: (value) {
            line.unitCost = value;
            line.costEdited = true;
            // Rebuild only the footer total; the row keeps its own state.
            setState(() {});
          },
          onUnitChanged: (unit) => _changeLineUnit(line, unit),
          onExpiryChanged: (date) => setState(() => line.expiryDate = date),
          onRemove: () => _removeLine(line),
          onTotalDirty: () => setState(() {}),
          onCaptureIdentifiers: line.needsIdentifiers
              ? () => _captureIdentifiers(line)
              : null,
        );
      },
    );
  }

  Widget _buildFooter(
    AppLocalizations l10n,
    PointySemanticColors colors,
    TextTheme textTheme,
    String? validationError,
  ) {
    final limit = _limit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.posCashPurchaseTotalLabel,
                style: textTheme.titleMedium,
              ),
            ),
            Text(
              formatMoney(_total),
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: _overLimit ? colors.danger : null,
              ),
            ),
          ],
        ),
        if (limit != null && !_overLimit)
          Text(
            l10n.posCashPurchaseLimitHint(formatMoney(limit)),
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        if (validationError != null) ...[
          const SizedBox(height: 6),
          Text(validationError, style: TextStyle(color: colors.danger)),
        ],
        if (_errorText != null) ...[
          const SizedBox(height: 6),
          Text(_errorText!, style: TextStyle(color: colors.danger)),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _canSubmit ? _submit : null,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.point_of_sale_outlined),
          label: Text(
            _submitting ? l10n.savingButton : l10n.posCashPurchaseSubmitButton,
          ),
        ),
      ],
    );
  }
}

/// Mutable in-sheet draft line. [revision] keys the row widget so programmatic
/// changes (cost prefill arriving, unit switches, re-add increments) rebuild
/// the row's text fields with fresh values, while plain typing never does.
class _CashPurchaseLine {
  _CashPurchaseLine({
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

  bool get needsIdentifiers => product.trackingMode.tracksUnits;

  bool get identifiersComplete =>
      !needsIdentifiers || units.length == quantity.round();
}

class _CashPurchaseLineRow extends StatefulWidget {
  const _CashPurchaseLineRow({
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
  });

  final _CashPurchaseLine line;
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

  @override
  State<_CashPurchaseLineRow> createState() => _CashPurchaseLineRowState();
}

class _CashPurchaseLineRowState extends State<_CashPurchaseLineRow> {
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
    final colors = context.pointyColors;
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
          if (line.product.tracksExpiry)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ActionChip(
                  avatar: Icon(
                    Icons.event_outlined,
                    size: 18,
                    color: line.expiryDate == null
                        ? colors.danger
                        : colors.mutedInk,
                  ),
                  label: Text(
                    line.expiryDate == null
                        ? l10n.posCashPurchaseExpiryLabel
                        : _isoDate(line.expiryDate!),
                  ),
                  onPressed: widget.enabled ? _pickExpiry : null,
                ),
              ),
            ),
          if (widget.onCaptureIdentifiers != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ActionChip(
                  avatar: Icon(
                    Icons.qr_code_2_outlined,
                    size: 18,
                    color: line.identifiersComplete
                        ? colors.mutedInk
                        : colors.danger,
                  ),
                  label: Text(
                    l10n.unitCaptureProgress(
                      line.units.length,
                      line.quantity.round(),
                    ),
                  ),
                  onPressed: widget.enabled
                      ? widget.onCaptureIdentifiers
                      : null,
                ),
              ),
            ),
        ],
      ),
    );
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
