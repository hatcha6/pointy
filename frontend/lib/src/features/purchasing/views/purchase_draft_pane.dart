import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../core/result.dart';
import '../../../data/models/product.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/catalog/catalog.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/unit_options.dart';
import '../../../shared/units.dart';
import '../view_models/purchase_view_model.dart';

class PurchaseDraftPane extends StatefulWidget {
  const PurchaseDraftPane({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    this.onSubmitSuccess,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;
  final VoidCallback? onSubmitSuccess;

  @override
  State<PurchaseDraftPane> createState() => _PurchaseDraftPaneState();
}

class _PurchaseDraftPaneState extends State<PurchaseDraftPane> {
  late final TextEditingController _supplierInvoiceNumberController =
      TextEditingController(text: widget.viewModel.supplierInvoiceNumber);
  late final TextEditingController _supplierInvoiceDateController =
      TextEditingController(text: widget.viewModel.supplierInvoiceDateInput);
  late final TextEditingController _discountCodeController =
      TextEditingController(text: widget.viewModel.discountCode);
  final FocusNode _supplierInvoiceNumberFocusNode = FocusNode();
  final FocusNode _supplierInvoiceDateFocusNode = FocusNode();
  final FocusNode _discountCodeFocusNode = FocusNode();

  PurchaseViewModel get viewModel => widget.viewModel;

  @override
  void didUpdateWidget(covariant PurchaseDraftPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController(
      controller: _supplierInvoiceNumberController,
      focusNode: _supplierInvoiceNumberFocusNode,
      value: widget.viewModel.supplierInvoiceNumber,
    );
    _syncController(
      controller: _supplierInvoiceDateController,
      focusNode: _supplierInvoiceDateFocusNode,
      value: widget.viewModel.supplierInvoiceDateInput,
    );
    _syncController(
      controller: _discountCodeController,
      focusNode: _discountCodeFocusNode,
      value: widget.viewModel.discountCode,
    );
  }

  @override
  void dispose() {
    _supplierInvoiceNumberController.dispose();
    _supplierInvoiceDateController.dispose();
    _discountCodeController.dispose();
    _supplierInvoiceNumberFocusNode.dispose();
    _supplierInvoiceDateFocusNode.dispose();
    _discountCodeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return ColoredBox(
      color: colors.page,
      child: Padding(
        padding: spacing.compactPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: PointyOrderPanel(
                title: l10n.purchaseDraftTitle,
                subtitle: _purchaseDraftSubtitle(l10n, viewModel),
                trailing: _PurchaseDraftHeaderActions(
                  viewModel: viewModel,
                  onEditSettings: () =>
                      _showPurchaseDraftSettingsDialog(context),
                ),
                child: _PurchaseDraftScrollContent(viewModel: viewModel),
              ),
            ),
            if (viewModel.selectedSupplier == null) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.warning(
                message: l10n.purchaseSupplierRequiredHint,
                compact: true,
              ),
            ],
            if (viewModel.hasMissingExpiryDates) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.warning(
                message: l10n.purchaseExpiryDatesRequired,
                compact: true,
              ),
            ],
            SizedBox(height: spacing.sm),
            PointyStickyActionFooter(
              padding: EdgeInsetsDirectional.fromSTEB(
                spacing.sm,
                6,
                spacing.sm,
                6,
              ),
              primaryActionHeight: 52,
              summary: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PurchaseDraftTotals(viewModel: viewModel),
                  _ReceiveImmediatelyToggle(viewModel: viewModel),
                ],
              ),
              primaryAction: FilledButton.icon(
                onPressed: viewModel.canSubmitDraft
                    ? () => _submitDraft(context)
                    : null,
                icon: viewModel.isSubmitting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.inventory_outlined),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    viewModel.isSubmitting
                        ? l10n.purchaseSubmitInProgressButton
                        : l10n.submitPurchaseDraftButton(
                            formatMoney(viewModel.total),
                          ),
                    maxLines: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPurchaseDraftSettingsDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => _PurchaseDraftSettingsDialog(
        viewModel: viewModel,
        contactRepository: widget.contactRepository,
        numberController: _supplierInvoiceNumberController,
        dateController: _supplierInvoiceDateController,
        discountController: _discountCodeController,
        numberFocusNode: _supplierInvoiceNumberFocusNode,
        dateFocusNode: _supplierInvoiceDateFocusNode,
        discountFocusNode: _discountCodeFocusNode,
      ),
    );
  }

  Future<void> _submitDraft(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    if (viewModel.hasMissingExpiryDates) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.purchaseExpiryDatesRequired)),
        );
      return;
    }
    await viewModel.refreshDiscountPreview();
    if (!context.mounted) {
      return;
    }
    if (viewModel.hasDiscountPreviewError) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.discountPreviewUnavailable)),
        );
      return;
    }
    if (viewModel.unappliedDiscountCodes.isNotEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              l10n.discountCouponUnavailable(
                viewModel.unappliedDiscountCodes.join('، '),
              ),
            ),
          ),
        );
      return;
    }
    final result = await viewModel.submitDraft();
    if (!context.mounted) {
      return;
    }

    final message = switch (result) {
      Ok(:final value) =>
        value.status == 'received'
            ? l10n.purchaseOrderReceiveSuccess(value.draftNumber)
            : l10n.purchaseDraftSubmitSuccess(value.draftNumber),
      Error() => l10n.purchaseDraftSubmitError,
    };

    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: result is Ok<PurchaseSubmission>
              ? null
              : SnackBarAction(
                  label: l10n.retryButton,
                  onPressed: () {
                    if (context.mounted) {
                      _submitDraft(context);
                    }
                  },
                ),
        ),
      );

    if (result is Ok<PurchaseSubmission>) {
      widget.onSubmitSuccess?.call();
    }
  }

  void _syncController({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String value,
    bool syncEmptyWhileFocused = true,
  }) {
    final canSync =
        !focusNode.hasFocus || (syncEmptyWhileFocused && value.isEmpty);
    if (canSync && controller.text != value) {
      controller.text = value;
    }
  }
}

String _purchaseDraftSubtitle(
  AppLocalizations l10n,
  PurchaseViewModel viewModel,
) {
  final supplierName = viewModel.selectedSupplier?.name.trim();
  final invoiceNumber = viewModel.supplierInvoiceNumber.trim();
  final parts = <String>[
    if (supplierName != null && supplierName.isNotEmpty)
      supplierName
    else
      l10n.noSupplierSelectedLabel,
    if (invoiceNumber.isNotEmpty)
      l10n.supplierInvoiceNumberValue(invoiceNumber),
  ];
  return parts.join(' • ');
}

class _PurchaseDraftHeaderActions extends StatelessWidget {
  const _PurchaseDraftHeaderActions({
    required this.viewModel,
    required this.onEditSettings,
  });

  final PurchaseViewModel viewModel;
  final VoidCallback onEditSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final supplier = viewModel.selectedSupplier;
    final hasInvoiceDetails =
        viewModel.supplierInvoiceNumber.trim().isNotEmpty ||
        viewModel.supplierInvoiceDateInput.trim().isNotEmpty;
    final hasDiscountCode = viewModel.discountCode.trim().isNotEmpty;
    final hasDiscountIssue =
        viewModel.hasDiscountPreviewError ||
        viewModel.unappliedDiscountCodes.isNotEmpty;
    final hasAppliedDiscount = viewModel.appliedDiscounts.isNotEmpty;
    final hasLandedCosts = viewModel.landedCostTotal > 0;
    final hasSettings =
        supplier != null ||
        hasInvoiceDetails ||
        hasDiscountCode ||
        hasAppliedDiscount ||
        hasLandedCosts;
    final hasSettingsIssue =
        supplier == null ||
        viewModel.hasInvalidSupplierInvoiceDate ||
        hasDiscountIssue;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('purchase_draft_settings_button'),
          tooltip: l10n.purchaseDraftSettingsActionTooltip,
          onPressed: viewModel.isSubmitting ? null : onEditSettings,
          icon: const Icon(Icons.tune),
          color: hasSettingsIssue
              ? colors.danger
              : hasSettings
              ? colors.primaryStrong
              : null,
        ),
        IconButton(
          tooltip: l10n.clearPurchaseDraftTooltip,
          onPressed: viewModel.draft.isEmpty || viewModel.isSubmitting
              ? null
              : () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (_) => PointyDestructiveConfirmationDialog(
                      icon: Icons.delete_sweep_outlined,
                      title: l10n.clearPurchaseDraftConfirmTitle,
                      message: l10n.clearPurchaseDraftConfirmMessage,
                      confirmLabel: l10n.clearButton,
                    ),
                  );
                  if (confirmed == true) {
                    viewModel.clearDraft(source: 'purchase_draft_clear_button');
                  }
                },
          icon: const Icon(Icons.delete_outline),
          color: colors.danger,
        ),
      ],
    );
  }
}

class _PurchaseDraftScrollContent extends StatelessWidget {
  const _PurchaseDraftScrollContent({required this.viewModel});

  final PurchaseViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final visibleDraft = viewModel.draft.reversed.toList(growable: false);

    return ListView(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.md,
        spacing.sm,
        spacing.md,
        spacing.md,
      ),
      children: [
        if (viewModel.draft.isEmpty)
          SizedBox(
            height: 240,
            child: PointyEmptyState(
              icon: Icons.inventory_2_outlined,
              title: l10n.emptyPurchaseDraft,
              message: l10n.emptyPurchaseDraftMessage,
            ),
          )
        else
          for (var index = 0; index < visibleDraft.length; index += 1) ...[
            if (index > 0) Divider(height: 1, color: colors.line),
            PurchaseDraftLineTile(
              line: visibleDraft[index],
              previewLine: viewModel.discountPreviewLineForDraftIndex(
                viewModel.draft.length - index - 1,
              ),
              enabled: !viewModel.isSubmitting,
              onAdd: () => viewModel.addVariant(
                visibleDraft[index].variant,
                source: 'purchase_draft_quantity_button',
              ),
              onRemove: () => viewModel.decrementVariant(
                visibleDraft[index].variant,
                source: 'purchase_draft_quantity_button',
              ),
              onCostChanged: (unitCost) {
                viewModel.updateLineCost(visibleDraft[index].variant, unitCost);
              },
              onExpiryDateChanged: (expiryDate) {
                viewModel.updateLineExpiryDate(
                  visibleDraft[index].variant,
                  expiryDate,
                );
              },
              onUnitChanged: (code, label, factor) {
                viewModel.updateLineUnit(
                  visibleDraft[index].variant,
                  unitCode: code,
                  unitLabel: label,
                  unitFactor: factor,
                );
              },
            ),
          ],
      ],
    );
  }
}

class _PurchaseDraftTotals extends StatelessWidget {
  const _PurchaseDraftTotals({required this.viewModel});

  final PurchaseViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final appliedDiscounts = viewModel.appliedDiscounts;

    return PointyTotalsPanel(
      compact: true,
      lines: [
        PointyTotalLine(
          label: l10n.subtotal,
          value: formatMoney(viewModel.subtotal),
        ),
        // Itemized discount breakdown when available, otherwise the aggregate
        // line — never both (a lone discount used to render twice).
        if (appliedDiscounts.isNotEmpty)
          for (final discount in appliedDiscounts)
            PointyTotalLine(
              label: discount.couponCode.isEmpty
                  ? discount.ruleName
                  : l10n.discountCouponAppliedLabel(discount.couponCode),
              value: formatMoney(-discount.discountAmount),
              isMuted: true,
            )
        else if (viewModel.discountTotal > 0)
          PointyTotalLine(
            label: l10n.discountTotalLabel,
            value: formatMoney(-viewModel.discountTotal),
            isMuted: true,
          ),
        if (viewModel.landedCostTotal > 0)
          PointyTotalLine(
            label: l10n.purchaseLandedCostTotalLabel,
            value: formatMoney(viewModel.landedCostTotal),
          ),
        PointyTotalLine(
          label: l10n.total,
          value: formatMoney(viewModel.total),
          isStrong: true,
        ),
      ],
    );
  }
}

class _ReceiveImmediatelyToggle extends StatelessWidget {
  const _ReceiveImmediatelyToggle({required this.viewModel});

  final PurchaseViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyOrderToggleRow(
      label: l10n.receivePurchaseImmediatelyLabel,
      value: viewModel.receiveImmediately,
      enabled: !viewModel.isSubmitting,
      onChanged: viewModel.updateReceiveImmediately,
    );
  }
}

class _PurchaseDraftSettingsDialog extends StatefulWidget {
  const _PurchaseDraftSettingsDialog({
    required this.viewModel,
    required this.contactRepository,
    required this.numberController,
    required this.dateController,
    required this.discountController,
    required this.numberFocusNode,
    required this.dateFocusNode,
    required this.discountFocusNode,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;
  final TextEditingController numberController;
  final TextEditingController dateController;
  final TextEditingController discountController;
  final FocusNode numberFocusNode;
  final FocusNode dateFocusNode;
  final FocusNode discountFocusNode;

  @override
  State<_PurchaseDraftSettingsDialog> createState() =>
      _PurchaseDraftSettingsDialogState();
}

class _PurchaseDraftSettingsDialogState
    extends State<_PurchaseDraftSettingsDialog> {
  late var _selectedSupplier = widget.viewModel.selectedSupplier;
  late final List<_LandedCostEntryControllers> _landedCostControllers =
      (widget.viewModel.landedCostEntries.isEmpty
              ? const [PurchaseLandedCostEntry(name: '', cost: 0)]
              : widget.viewModel.landedCostEntries)
          .map(_LandedCostEntryControllers.new)
          .toList(growable: true);
  late LandedCostAllocationMethod _landedCostAllocationMethod =
      widget.viewModel.landedCostAllocationMethod;
  late final String _initialNumber = widget.numberController.text;
  late final String _initialDate = widget.dateController.text;
  late final String _initialDiscountCode = widget.discountController.text;

  @override
  void dispose() {
    for (final controllers in _landedCostControllers) {
      controllers.dispose();
    }
    super.dispose();
  }

  String get _currentDiscountCode => widget.discountController.text.trim();

  bool get _matchesSavedDiscountCode =>
      _currentDiscountCode == widget.viewModel.discountCode.trim();

  bool get _hasInvalidDate {
    final text = widget.dateController.text.trim();
    return text.isNotEmpty && _parseDateInputValue(text) == null;
  }

  bool get _hasInvalidDiscountCode {
    return _matchesSavedDiscountCode &&
        widget.viewModel.unappliedDiscountCodes.isNotEmpty;
  }

  List<PurchaseLandedCostEntry> _currentLandedCostEntries(
    AppLocalizations l10n,
  ) {
    return _landedCostControllers
        .map((controllers) {
          final name = controllers.name.text.trim();
          final cost = _parseLandedCost(controllers.cost.text);
          if (cost <= 0) {
            return null;
          }
          return PurchaseLandedCostEntry(
            name: name.isEmpty ? l10n.defaultLandedCostEntryName : name,
            cost: cost,
          );
        })
        .nonNulls
        .toList(growable: false);
  }

  bool _landedCostsChanged(List<PurchaseLandedCostEntry> entries) {
    final savedEntries = widget.viewModel.landedCostEntries;
    if (_landedCostAllocationMethod !=
            widget.viewModel.landedCostAllocationMethod ||
        savedEntries.length != entries.length) {
      return true;
    }
    for (var index = 0; index < savedEntries.length; index += 1) {
      final saved = savedEntries[index];
      final pending = entries[index];
      if (saved.name != pending.name ||
          (saved.cost - pending.cost).abs() >= 0.005) {
        return true;
      }
    }
    return false;
  }

  double _landedCostTotal(List<PurchaseLandedCostEntry> entries) {
    return entries.fold<double>(0, (sum, entry) => sum + entry.cost);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasDiscountCode = _currentDiscountCode.isNotEmpty;
    final landedCostEntries = _currentLandedCostEntries(l10n);
    final landedCostTotal = _landedCostTotal(landedCostEntries);

    return AlertDialog(
      icon: const Icon(Icons.tune),
      title: Text(l10n.purchaseDraftSettingsDialogTitle),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ContactSelectionTile(
                label: l10n.selectedSupplierLabel,
                value: _selectedSupplier?.name ?? '',
                placeholder: l10n.noSupplierSelectedLabel,
                icon: Icons.local_shipping_outlined,
                enabled: !widget.viewModel.isSubmitting,
                onSelect: _selectSupplier,
                onClear: () => setState(() => _selectedSupplier = null),
                allowClear: _selectedSupplier != null,
                selectActionIcon: Icons.edit_outlined,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('supplier_invoice_number_field'),
                controller: widget.numberController,
                focusNode: widget.numberFocusNode,
                enabled: !widget.viewModel.isSubmitting,
                decoration: InputDecoration(
                  labelText: l10n.supplierInvoiceNumberLabel,
                  hintText: l10n.supplierInvoiceNumberHint,
                  isDense: true,
                  prefixIcon: const Icon(Icons.receipt_long_outlined),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _saveIfValid(),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('supplier_invoice_date_field'),
                controller: widget.dateController,
                focusNode: widget.dateFocusNode,
                enabled: !widget.viewModel.isSubmitting,
                keyboardType: TextInputType.datetime,
                inputFormatters: const [_DateDashInputFormatter()],
                decoration: InputDecoration(
                  labelText: l10n.supplierInvoiceDateLabel,
                  hintText: l10n.supplierInvoiceDateHint,
                  errorText: _hasInvalidDate
                      ? l10n.supplierInvoiceDateInvalid
                      : null,
                  isDense: true,
                  prefixIcon: const Icon(Icons.event_outlined),
                  suffixIcon: IconButton(
                    tooltip: l10n.supplierInvoiceDatePickerTooltip,
                    onPressed: widget.viewModel.isSubmitting ? null : _pickDate,
                    icon: const Icon(Icons.calendar_month_outlined),
                  ),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _saveIfValid(),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.request_quote_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.purchaseLandedCostSheetTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    formatMoney(landedCostTotal),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<LandedCostAllocationMethod>(
                initialValue: _landedCostAllocationMethod,
                decoration: InputDecoration(
                  labelText: l10n.landedCostAllocationMethodLabel,
                  isDense: true,
                  prefixIcon: const Icon(Icons.call_split_outlined),
                ),
                items: [
                  for (final method in LandedCostAllocationMethod.values)
                    DropdownMenuItem(
                      value: method,
                      child: Text(_landedCostAllocationLabel(l10n, method)),
                    ),
                ],
                onChanged: widget.viewModel.isSubmitting
                    ? null
                    : (method) {
                        if (method == null) {
                          return;
                        }
                        setState(() => _landedCostAllocationMethod = method);
                      },
              ),
              const SizedBox(height: 8),
              for (final (index, controllers)
                  in _landedCostControllers.indexed) ...[
                if (index > 0) const SizedBox(height: 8),
                _LandedCostEntryRow(
                  nameController: controllers.name,
                  costController: controllers.cost,
                  canRemove: _landedCostControllers.length > 1,
                  enabled: !widget.viewModel.isSubmitting,
                  onChanged: () => setState(() {}),
                  onRemove: () => _removeLandedCostEntry(index),
                ),
              ],
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('landed_cost_button'),
                  onPressed: widget.viewModel.isSubmitting
                      ? null
                      : _addLandedCostEntry,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.addLandedCostEntryButton),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('purchase_discount_code_field'),
                controller: widget.discountController,
                focusNode: widget.discountFocusNode,
                enabled: !widget.viewModel.isSubmitting,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: l10n.discountCouponCodeLabel,
                  hintText: l10n.purchaseDiscountCodeHint,
                  isDense: true,
                  prefixIcon: const Icon(Icons.confirmation_number_outlined),
                  errorText: _hasInvalidDiscountCode
                      ? l10n.discountCouponUnavailable(
                          widget.viewModel.unappliedDiscountCodes.join('، '),
                        )
                      : _matchesSavedDiscountCode &&
                            widget.viewModel.hasDiscountPreviewError
                      ? l10n.discountPreviewUnavailable
                      : null,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _saveIfValid(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: Text(l10n.cancelButton)),
        if (hasDiscountCode)
          TextButton(
            onPressed: _clearDiscountCode,
            child: Text(l10n.clearCouponCodeTooltip),
          ),
        TextButton(
          onPressed: _refreshDiscountPreview,
          child: Text(l10n.refreshDiscountPreviewTooltip),
        ),
        FilledButton(
          onPressed: _hasInvalidDate ? null : _save,
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }

  Future<void> _selectSupplier() async {
    final supplier = await showSupplierPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (supplier == null || !mounted) {
      return;
    }
    setState(() => _selectedSupplier = supplier);
  }

  Future<void> _pickDate() async {
    final current =
        _parseDateInputValue(widget.dateController.text) ??
        widget.viewModel.supplierInvoiceDate ??
        DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() {
      widget.dateController.text = _formatDateInputValue(selected);
    });
  }

  void _addLandedCostEntry() {
    setState(() {
      _landedCostControllers.add(
        _LandedCostEntryControllers(
          const PurchaseLandedCostEntry(name: '', cost: 0),
        ),
      );
    });
  }

  void _removeLandedCostEntry(int index) {
    setState(() {
      final removed = _landedCostControllers.removeAt(index);
      removed.dispose();
    });
  }

  void _saveIfValid() {
    if (!_hasInvalidDate) {
      _save();
    }
  }

  void _save() {
    if (_hasInvalidDate) {
      setState(() {});
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    _saveSettings(l10n);
    Navigator.of(context).pop();
  }

  void _clearDiscountCode() {
    if (_hasInvalidDate) {
      setState(() {});
      return;
    }
    widget.discountController.clear();
    final l10n = AppLocalizations.of(context)!;
    _saveSettings(l10n);
    Navigator.of(context).pop();
  }

  void _refreshDiscountPreview() {
    if (_hasInvalidDate) {
      setState(() {});
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final landedCostEntries = _currentLandedCostEntries(l10n);
    final refreshWillAlreadyRun =
        _selectedSupplier?.id != widget.viewModel.selectedSupplier?.id ||
        _landedCostsChanged(landedCostEntries) ||
        _currentDiscountCode != widget.viewModel.discountCode.trim();
    _saveSettings(l10n, landedCostEntries: landedCostEntries);
    if (!refreshWillAlreadyRun) {
      unawaited(widget.viewModel.refreshDiscountPreview());
    }
    Navigator.of(context).pop();
  }

  void _saveSettings(
    AppLocalizations l10n, {
    List<PurchaseLandedCostEntry>? landedCostEntries,
  }) {
    final currentLandedCostEntries =
        landedCostEntries ?? _currentLandedCostEntries(l10n);
    if (_selectedSupplier?.id != widget.viewModel.selectedSupplier?.id) {
      widget.viewModel.selectSupplier(_selectedSupplier);
    }
    final invoiceNumber = widget.numberController.text.trim();
    if (invoiceNumber != widget.viewModel.supplierInvoiceNumber.trim()) {
      widget.viewModel.updateSupplierInvoiceNumber(invoiceNumber);
    }
    final invoiceDate = widget.dateController.text.trim();
    if (invoiceDate != widget.viewModel.supplierInvoiceDateInput.trim()) {
      widget.viewModel.updateSupplierInvoiceDateInput(invoiceDate);
    }
    if (_landedCostsChanged(currentLandedCostEntries)) {
      widget.viewModel.updateLandedCosts(
        entries: currentLandedCostEntries,
        allocationMethod: _landedCostAllocationMethod,
      );
    }
    if (_currentDiscountCode != widget.viewModel.discountCode.trim()) {
      widget.viewModel.updateDiscountCode(_currentDiscountCode);
    }
  }

  void _cancel() {
    widget.numberController.text = _initialNumber;
    widget.dateController.text = _initialDate;
    widget.discountController.text = _initialDiscountCode;
    Navigator.of(context).pop();
  }
}

String _formatDateInputValue(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

DateTime? _parseDateInputValue(String text) {
  if (text.length != 10) {
    return null;
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    return null;
  }
  final date = DateTime(parsed.year, parsed.month, parsed.day);
  return _formatDateInputValue(date) == text ? date : null;
}

class _DateDashInputFormatter extends TextInputFormatter {
  const _DateDashInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final limited = digits.length > 8 ? digits.substring(0, 8) : digits;
    final buffer = StringBuffer();
    for (var index = 0; index < limited.length; index += 1) {
      if (index == 4 || index == 6) {
        buffer.write('-');
      }
      buffer.write(limited[index]);
    }
    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class _LandedCostEntryControllers {
  _LandedCostEntryControllers(PurchaseLandedCostEntry entry)
    : name = TextEditingController(text: entry.name),
      cost = TextEditingController(
        text: entry.cost == 0 ? '' : entry.cost.toStringAsFixed(2),
      );

  final TextEditingController name;
  final TextEditingController cost;

  void dispose() {
    name.dispose();
    cost.dispose();
  }
}

double _parseLandedCost(String value) {
  final normalized = value.trim().replaceAll(',', '.');
  return double.tryParse(normalized) ?? 0;
}

String _landedCostAllocationLabel(
  AppLocalizations l10n,
  LandedCostAllocationMethod method,
) {
  return switch (method) {
    LandedCostAllocationMethod.byLineValue =>
      l10n.landedCostAllocationByLineValueLabel,
    LandedCostAllocationMethod.byQuantity =>
      l10n.landedCostAllocationByQuantityLabel,
    LandedCostAllocationMethod.byRetailValue =>
      l10n.landedCostAllocationByRetailValueLabel,
    LandedCostAllocationMethod.equallyByLine =>
      l10n.landedCostAllocationEquallyByLineLabel,
  };
}

class _LandedCostEntryRow extends StatelessWidget {
  const _LandedCostEntryRow({
    required this.nameController,
    required this.costController,
    required this.canRemove,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  final TextEditingController nameController;
  final TextEditingController costController;
  final bool canRemove;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: nameController,
            enabled: enabled,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l10n.landedCostEntryNameLabel,
              isDense: true,
              prefixIcon: const Icon(Icons.edit_note_outlined),
            ),
            onChanged: (_) => onChanged(),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 120,
          child: TextField(
            controller: costController,
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.landedCostEntryCostLabel,
              isDense: true,
            ),
            onChanged: (_) => onChanged(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: l10n.removeLandedCostEntryTooltip,
          onPressed: enabled && canRemove ? onRemove : null,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

class PurchaseDraftLineTile extends StatefulWidget {
  const PurchaseDraftLineTile({
    super.key,
    required this.line,
    this.previewLine,
    required this.enabled,
    required this.onAdd,
    required this.onRemove,
    required this.onCostChanged,
    required this.onExpiryDateChanged,
    this.onUnitChanged,
  });

  final PurchaseDraftLine line;
  final PurchaseDiscountPreviewLine? previewLine;
  final bool enabled;
  final Future<void> Function() onAdd;
  final VoidCallback onRemove;
  final ValueChanged<double> onCostChanged;
  final ValueChanged<DateTime?> onExpiryDateChanged;

  /// Selected purchase unit changed: (code, label, factorToBase). Base unit is
  /// reported with an empty code.
  final void Function(String code, String label, double factor)? onUnitChanged;

  @override
  State<PurchaseDraftLineTile> createState() => _PurchaseDraftLineTileState();
}

class _PurchaseDraftLineTileState extends State<PurchaseDraftLineTile> {
  late final TextEditingController _costController = TextEditingController(
    text: widget.line.unitCost.toStringAsFixed(2),
  );
  late final TextEditingController _expiryController = TextEditingController(
    text: _formatNullableDate(widget.line.expiryDate),
  );
  final FocusNode _costFocusNode = FocusNode();
  final FocusNode _expiryFocusNode = FocusNode();
  bool _expiryInputInvalid = false;

  @override
  void didUpdateWidget(covariant PurchaseDraftLineTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextText = widget.line.unitCost.toStringAsFixed(2);
    if (!_costFocusNode.hasFocus && _costController.text != nextText) {
      _costController.text = nextText;
    }
    final nextExpiryText = _formatNullableDate(widget.line.expiryDate);
    if (!_expiryFocusNode.hasFocus &&
        _expiryController.text != nextExpiryText) {
      _expiryController.text = nextExpiryText;
      _expiryInputInvalid = false;
    }
  }

  @override
  void dispose() {
    _costFocusNode.dispose();
    _costController.dispose();
    _expiryFocusNode.dispose();
    _expiryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final line = widget.line;
    final theme = Theme.of(context);
    final previewLine = widget.previewLine;
    final allocatedLandedCost = previewLine?.allocatedLandedCost ?? 0;
    final effectiveUnitCost = previewLine?.effectiveUnitCost;
    final hasAllocatedLandedCost = allocatedLandedCost > 0;
    final costDetails = <String>[
      if (hasAllocatedLandedCost)
        l10n.purchaseLineLandedCostValue(formatMoney(allocatedLandedCost)),
      if (hasAllocatedLandedCost &&
          effectiveUnitCost != null &&
          (effectiveUnitCost - line.unitCost).abs() >= 0.005)
        l10n.purchaseLineEffectiveCostValue(formatMoney(effectiveUnitCost)),
    ];
    final lineTotal = hasAllocatedLandedCost
        ? previewLine!.effectiveLineTotal ?? line.total + allocatedLandedCost
        : line.total;

    final colors = context.pointyColors;
    final imageUrl =
        line.variant.primaryImage?.contentUrl ??
        line.variant.productDetail?.primaryImage?.contentUrl;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          line.variant.displayLabel,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (line.variant.sku.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            line.variant.sku,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
        if (costDetails.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            costDetails.join(' • '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.primaryStrong,
            ),
          ),
        ],
      ],
    );

    final costField = TextField(
      controller: _costController,
      focusNode: _costFocusNode,
      enabled: widget.enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [DecimalTextInputFormatter()],
      decoration: InputDecoration(
        labelText: l10n.purchaseLineCostLabel,
        isDense: true,
        prefixIcon: const Icon(Icons.sell_outlined),
      ),
      onChanged: (value) {
        final parsed = parseDecimal(value);
        if (parsed != null && parsed >= 0) {
          widget.onCostChanged(parsed);
        }
      },
    );

    final stepper = PointyQuantityStepper(
      quantity: line.quantity.toDouble(),
      incrementTooltip: l10n.addOneTooltip,
      decrementTooltip: l10n.removeOneTooltip,
      onIncrement: widget.enabled ? () => widget.onAdd() : null,
      onDecrement: widget.enabled ? widget.onRemove : null,
    );

    final unitOptions = purchasableUnitOptions(
      l10n,
      Product.fromVariant(line.variant),
    );
    final selectedUnitCode = line.isBaseUnit
        ? unitOptions.first.code
        : line.unitCode;
    final unitField = unitOptions.length <= 1 || widget.onUnitChanged == null
        ? null
        : DropdownButtonFormField<String>(
            initialValue: selectedUnitCode,
            isDense: true,
            decoration: InputDecoration(
              labelText: l10n.purchaseLineUnitLabel,
              isDense: true,
              prefixIcon: const Icon(Icons.straighten_outlined),
            ),
            items: [
              for (final option in unitOptions)
                DropdownMenuItem(value: option.code, child: Text(option.label)),
            ],
            onChanged: widget.enabled
                ? (value) {
                    final option = unitOptions.firstWhere(
                      (option) => option.code == value,
                      orElse: () => unitOptions.first,
                    );
                    widget.onUnitChanged!(
                      option.isBase ? '' : option.code,
                      option.label,
                      option.factorToBase,
                    );
                  }
                : null,
          );

    // For a pack unit, show how many base units the line resolves to.
    final baseEquivalent = line.isBaseUnit
        ? null
        : Text(
            l10n.purchaseLineBaseEquivalent(
              formatQuantity(line.baseQuantity),
              unitLabel(l10n, line.variant.unit),
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          );

    final totalText = Text(
      formatMoney(lineTotal),
      maxLines: 1,
      textAlign: TextAlign.end,
      style: switch (theme.textTheme.titleMedium?.copyWith(
        color: colors.ink,
        fontWeight: FontWeight.w800,
      )) {
        final style? => PointyTypography.numeric(style),
        null => null,
      },
    );

    final expiryField = line.variant.tracksExpiry
        ? Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: TextField(
                key: ValueKey('purchase_line_expiry_${line.variant.id}_field'),
                controller: _expiryController,
                focusNode: _expiryFocusNode,
                enabled: widget.enabled,
                keyboardType: TextInputType.datetime,
                inputFormatters: const [_DateDashInputFormatter()],
                decoration: InputDecoration(
                  labelText: l10n.purchaseLineExpiryDateLabel,
                  hintText: l10n.purchaseLineExpiryDateHint,
                  isDense: true,
                  prefixIcon: const Icon(Icons.event_busy_outlined),
                  suffixIcon: IconButton(
                    tooltip: l10n.purchaseLineExpiryDatePickerTooltip,
                    onPressed: widget.enabled ? _pickExpiryDate : null,
                    icon: const Icon(Icons.calendar_month_outlined),
                  ),
                  errorText: _expiryErrorText(l10n),
                ),
                onChanged: _handleExpiryInputChanged,
              ),
            ),
          )
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PointyProductImageFrame(
                imageUrl: imageUrl,
                fallbackText: line.variant.displayLabel,
                width: 54,
                height: 54,
                padding: const EdgeInsets.all(6),
              ),
              const SizedBox(width: 12),
              Expanded(child: info),
              const SizedBox(width: 10),
              totalText,
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 190),
                    child: costField,
                  ),
                ),
              ),
              if (unitField != null) ...[
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: unitField,
                ),
              ],
              const SizedBox(width: 12),
              stepper,
            ],
          ),
          if (baseEquivalent != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: baseEquivalent,
            ),
          ],
          if (expiryField != null) ...[const SizedBox(height: 12), expiryField],
        ],
      ),
    );
  }

  void _handleExpiryInputChanged(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      setState(() => _expiryInputInvalid = false);
      widget.onExpiryDateChanged(null);
      return;
    }
    final parsed = _parseDateInputValue(text);
    if (parsed == null) {
      setState(() => _expiryInputInvalid = true);
      widget.onExpiryDateChanged(null);
      return;
    }
    setState(() => _expiryInputInvalid = false);
    widget.onExpiryDateChanged(parsed);
  }

  Future<void> _pickExpiryDate() async {
    final current = widget.line.expiryDate ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) {
      return;
    }
    final value = DateTime(selected.year, selected.month, selected.day);
    _expiryController.text = _formatDateInputValue(value);
    setState(() => _expiryInputInvalid = false);
    widget.onExpiryDateChanged(value);
  }

  String? _expiryErrorText(AppLocalizations l10n) {
    if (_expiryInputInvalid) {
      return l10n.purchaseLineExpiryDateInvalid;
    }
    if (widget.line.variant.tracksExpiry && widget.line.expiryDate == null) {
      return l10n.purchaseLineExpiryDateRequired;
    }
    return null;
  }

  String _formatNullableDate(DateTime? date) {
    return date == null ? '' : _formatDateInputValue(date);
  }
}
