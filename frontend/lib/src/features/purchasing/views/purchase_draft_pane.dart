import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
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
                trailing: _PurchaseDraftHeaderActions(
                  viewModel: viewModel,
                  onSelectSupplier: () => _selectSupplier(context),
                  onEditInvoiceDetails: () =>
                      _showSupplierInvoiceDetailsDialog(context),
                  onEditLandedCosts: () => _editLandedCosts(context),
                  onEditDiscountCode: () => _showDiscountCodeDialog(context),
                ),
                child: _PurchaseDraftScrollContent(viewModel: viewModel),
              ),
            ),
            if (viewModel.selectedSupplier == null) ...[
              SizedBox(height: spacing.xs),
              Text(
                l10n.purchaseSupplierRequiredHint,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.danger),
              ),
            ],
            if (viewModel.hasMissingExpiryDates) ...[
              SizedBox(height: spacing.xs),
              Text(
                l10n.purchaseExpiryDatesRequired,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.danger),
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

  Future<void> _showSupplierInvoiceDetailsDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => _SupplierInvoiceDetailsDialog(
        viewModel: viewModel,
        numberController: _supplierInvoiceNumberController,
        dateController: _supplierInvoiceDateController,
        numberFocusNode: _supplierInvoiceNumberFocusNode,
        dateFocusNode: _supplierInvoiceDateFocusNode,
      ),
    );
  }

  Future<void> _showDiscountCodeDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => _PurchaseDiscountCodeDialog(
        viewModel: viewModel,
        controller: _discountCodeController,
        focusNode: _discountCodeFocusNode,
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
      ..showSnackBar(SnackBar(content: Text(message)));

    if (result is Ok<PurchaseSubmission>) {
      widget.onSubmitSuccess?.call();
    }
  }

  Future<void> _selectSupplier(BuildContext context) async {
    final supplier = await showSupplierPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (supplier != null) {
      viewModel.selectSupplier(supplier);
    }
  }

  Future<void> _editLandedCosts(BuildContext context) async {
    final result = await showModalBottomSheet<_LandedCostSheetResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return _LandedCostSheet(
          entries: viewModel.landedCostEntries,
          allocationMethod: viewModel.landedCostAllocationMethod,
        );
      },
    );
    if (result == null || !context.mounted) {
      return;
    }
    viewModel.updateLandedCosts(
      entries: result.entries,
      allocationMethod: result.allocationMethod,
    );
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

class _PurchaseDraftHeaderActions extends StatelessWidget {
  const _PurchaseDraftHeaderActions({
    required this.viewModel,
    required this.onSelectSupplier,
    required this.onEditInvoiceDetails,
    required this.onEditLandedCosts,
    required this.onEditDiscountCode,
  });

  final PurchaseViewModel viewModel;
  final VoidCallback onSelectSupplier;
  final VoidCallback onEditInvoiceDetails;
  final VoidCallback onEditLandedCosts;
  final VoidCallback onEditDiscountCode;

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

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: supplier?.name ?? l10n.purchaseSupplierActionTooltip,
          onPressed: viewModel.isSubmitting ? null : onSelectSupplier,
          icon: Icon(
            supplier == null
                ? Icons.local_shipping_outlined
                : Icons.local_shipping,
          ),
          color: supplier == null ? colors.danger : colors.primaryStrong,
        ),
        IconButton(
          tooltip: l10n.purchaseInvoiceDetailsActionTooltip,
          onPressed: viewModel.isSubmitting ? null : onEditInvoiceDetails,
          icon: const Icon(Icons.receipt_long_outlined),
          color: viewModel.hasInvalidSupplierInvoiceDate
              ? colors.danger
              : hasInvoiceDetails
              ? colors.primaryStrong
              : null,
        ),
        IconButton(
          key: const ValueKey('landed_cost_button'),
          tooltip: l10n.purchaseLandedCostActionTooltip,
          onPressed: viewModel.isSubmitting ? null : onEditLandedCosts,
          icon: const Icon(Icons.request_quote_outlined),
          color: hasLandedCosts ? colors.primaryStrong : null,
        ),
        IconButton(
          tooltip: hasDiscountCode
              ? '${l10n.discountCouponCodeLabel}: ${viewModel.discountCode.trim()}'
              : l10n.purchaseDiscountActionTooltip,
          onPressed: viewModel.isSubmitting ? null : onEditDiscountCode,
          icon: viewModel.isLoadingDiscountPreview
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.confirmation_number_outlined),
          color: hasDiscountIssue
              ? colors.danger
              : hasDiscountCode || hasAppliedDiscount
              ? colors.primaryStrong
              : null,
        ),
        IconButton(
          tooltip: l10n.clearPurchaseDraftTooltip,
          onPressed: viewModel.draft.isEmpty || viewModel.isSubmitting
              ? null
              : () =>
                    viewModel.clearDraft(source: 'purchase_draft_clear_button'),
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
            height: 220,
            child: PointyEmptyState(
              icon: Icons.inventory_2_outlined,
              title: l10n.emptyPurchaseDraft,
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

    return PointyTotalsPanel(
      compact: true,
      lines: [
        PointyTotalLine(
          label: l10n.subtotal,
          value: formatMoney(viewModel.subtotal),
        ),
        if (viewModel.discountTotal > 0)
          PointyTotalLine(
            label: l10n.discountTotalLabel,
            value: formatMoney(-viewModel.discountTotal),
          ),
        for (final discount in viewModel.appliedDiscounts)
          PointyTotalLine(
            label: discount.couponCode.isEmpty
                ? discount.ruleName
                : l10n.discountCouponAppliedLabel(discount.couponCode),
            value: formatMoney(-discount.discountAmount),
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

    return InkWell(
      onTap: viewModel.isSubmitting
          ? null
          : () => viewModel.updateReceiveImmediately(
              !viewModel.receiveImmediately,
            ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(top: 2),
        child: Row(
          children: [
            Checkbox(
              value: viewModel.receiveImmediately,
              onChanged: viewModel.isSubmitting
                  ? null
                  : (value) =>
                        viewModel.updateReceiveImmediately(value ?? true),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                l10n.receivePurchaseImmediatelyLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SupplierInvoiceDetailsDialog extends StatefulWidget {
  const _SupplierInvoiceDetailsDialog({
    required this.viewModel,
    required this.numberController,
    required this.dateController,
    required this.numberFocusNode,
    required this.dateFocusNode,
  });

  final PurchaseViewModel viewModel;
  final TextEditingController numberController;
  final TextEditingController dateController;
  final FocusNode numberFocusNode;
  final FocusNode dateFocusNode;

  @override
  State<_SupplierInvoiceDetailsDialog> createState() =>
      _SupplierInvoiceDetailsDialogState();
}

class _SupplierInvoiceDetailsDialogState
    extends State<_SupplierInvoiceDetailsDialog> {
  late final String _initialNumber = widget.numberController.text;
  late final String _initialDate = widget.dateController.text;

  bool get _hasInvalidDate {
    final text = widget.dateController.text.trim();
    return text.isNotEmpty && _parseDateInputValue(text) == null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      icon: const Icon(Icons.receipt_long_outlined),
      title: Text(l10n.purchaseInvoiceDetailsDialogTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: Text(l10n.cancelButton)),
        FilledButton(
          onPressed: _hasInvalidDate ? null : _save,
          child: Text(l10n.saveButton),
        ),
      ],
    );
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

  void _saveIfValid() {
    if (!_hasInvalidDate) {
      _save();
    }
  }

  void _save() {
    widget.viewModel.updateSupplierInvoiceNumber(
      widget.numberController.text.trim(),
    );
    widget.viewModel.updateSupplierInvoiceDateInput(
      widget.dateController.text.trim(),
    );
    Navigator.of(context).pop();
  }

  void _cancel() {
    widget.numberController.text = _initialNumber;
    widget.dateController.text = _initialDate;
    Navigator.of(context).pop();
  }
}

class _PurchaseDiscountCodeDialog extends StatefulWidget {
  const _PurchaseDiscountCodeDialog({
    required this.viewModel,
    required this.controller,
    required this.focusNode,
  });

  final PurchaseViewModel viewModel;
  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  State<_PurchaseDiscountCodeDialog> createState() =>
      _PurchaseDiscountCodeDialogState();
}

class _PurchaseDiscountCodeDialogState
    extends State<_PurchaseDiscountCodeDialog> {
  late final String _initialValue = widget.controller.text;

  String get _currentCode => widget.controller.text.trim();

  bool get _matchesSavedCode =>
      _currentCode == widget.viewModel.discountCode.trim();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasCoupon = _currentCode.isNotEmpty;
    final hasInvalidCoupon =
        _matchesSavedCode && widget.viewModel.unappliedDiscountCodes.isNotEmpty;

    return AlertDialog(
      icon: const Icon(Icons.confirmation_number_outlined),
      title: Text(l10n.discountCouponCodeLabel),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          key: const ValueKey('purchase_discount_code_field'),
          controller: widget.controller,
          focusNode: widget.focusNode,
          enabled: !widget.viewModel.isSubmitting,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            hintText: l10n.purchaseDiscountCodeHint,
            isDense: true,
            errorText: hasInvalidCoupon
                ? l10n.discountCouponUnavailable(
                    widget.viewModel.unappliedDiscountCodes.join('، '),
                  )
                : _matchesSavedCode && widget.viewModel.hasDiscountPreviewError
                ? l10n.discountPreviewUnavailable
                : null,
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _apply(),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: Text(l10n.cancelButton)),
        if (hasCoupon)
          TextButton(
            onPressed: _clear,
            child: Text(l10n.clearCouponCodeTooltip),
          ),
        TextButton(
          onPressed: _refresh,
          child: Text(l10n.refreshDiscountPreviewTooltip),
        ),
        FilledButton(
          onPressed: _apply,
          child: Text(l10n.applyDiscountCodeButton),
        ),
      ],
    );
  }

  void _apply() {
    _saveCode();
    Navigator.of(context).pop();
  }

  void _clear() {
    widget.controller.clear();
    widget.viewModel.updateDiscountCode('');
    Navigator.of(context).pop();
  }

  void _refresh() {
    _saveCode();
    unawaited(widget.viewModel.refreshDiscountPreview());
    Navigator.of(context).pop();
  }

  void _saveCode() {
    final value = _currentCode;
    if (value == widget.viewModel.discountCode.trim()) {
      return;
    }
    widget.viewModel.updateDiscountCode(value);
  }

  void _cancel() {
    widget.controller.text = _initialValue;
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

class _LandedCostSheetResult {
  const _LandedCostSheetResult({
    required this.entries,
    required this.allocationMethod,
  });

  final List<PurchaseLandedCostEntry> entries;
  final LandedCostAllocationMethod allocationMethod;
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

class _LandedCostSheet extends StatefulWidget {
  const _LandedCostSheet({
    required this.entries,
    required this.allocationMethod,
  });

  final List<PurchaseLandedCostEntry> entries;
  final LandedCostAllocationMethod allocationMethod;

  @override
  State<_LandedCostSheet> createState() => _LandedCostSheetState();
}

class _LandedCostSheetState extends State<_LandedCostSheet> {
  late final List<_LandedCostEntryControllers> _entryControllers;
  late LandedCostAllocationMethod _allocationMethod;

  @override
  void initState() {
    super.initState();
    _allocationMethod = widget.allocationMethod;
    final entries = widget.entries.isEmpty
        ? const [PurchaseLandedCostEntry(name: '', cost: 0)]
        : widget.entries;
    _entryControllers = entries
        .map(_LandedCostEntryControllers.new)
        .toList(growable: true);
  }

  @override
  void dispose() {
    for (final controller in _entryControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final total = _currentEntries(
      l10n,
    ).fold<double>(0, (sum, entry) => sum + entry.cost);

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.purchaseLandedCostSheetTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    formatMoney(total),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<LandedCostAllocationMethod>(
                initialValue: _allocationMethod,
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
                onChanged: (method) {
                  if (method == null) {
                    return;
                  }
                  setState(() => _allocationMethod = method);
                },
              ),
              const SizedBox(height: 12),
              for (final (index, controllers) in _entryControllers.indexed) ...[
                if (index > 0) const SizedBox(height: 8),
                _LandedCostEntryRow(
                  nameController: controllers.name,
                  costController: controllers.cost,
                  canRemove: _entryControllers.length > 1,
                  onChanged: () => setState(() {}),
                  onRemove: () => _removeEntry(index),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _addEntry,
                icon: const Icon(Icons.add),
                label: Text(l10n.addLandedCostEntryButton),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop(
                    _LandedCostSheetResult(
                      entries: _currentEntries(l10n),
                      allocationMethod: _allocationMethod,
                    ),
                  );
                },
                icon: const Icon(Icons.check),
                label: Text(l10n.saveLandedCostEntriesButton),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _addEntry() {
    setState(() {
      _entryControllers.add(
        _LandedCostEntryControllers(
          const PurchaseLandedCostEntry(name: '', cost: 0),
        ),
      );
    });
  }

  void _removeEntry(int index) {
    setState(() {
      final removed = _entryControllers.removeAt(index);
      removed.dispose();
    });
  }

  List<PurchaseLandedCostEntry> _currentEntries(AppLocalizations l10n) {
    return _entryControllers
        .map((controllers) {
          final name = controllers.name.text.trim();
          final cost = _parseCost(controllers.cost.text);
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

  double _parseCost(String value) {
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
}

class _LandedCostEntryRow extends StatelessWidget {
  const _LandedCostEntryRow({
    required this.nameController,
    required this.costController,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final TextEditingController nameController;
  final TextEditingController costController;
  final bool canRemove;
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
          onPressed: canRemove ? onRemove : null,
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
  });

  final PurchaseDraftLine line;
  final PurchaseDiscountPreviewLine? previewLine;
  final bool enabled;
  final Future<void> Function() onAdd;
  final VoidCallback onRemove;
  final ValueChanged<double> onCostChanged;
  final ValueChanged<DateTime?> onExpiryDateChanged;

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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.variant.displayLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (line.variant.sku.isNotEmpty)
                  Text(
                    line.variant.sku,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                if (costDetails.isNotEmpty)
                  Text(
                    costDetails.join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                if (line.variant.tracksExpiry) ...[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: TextField(
                      key: ValueKey(
                        'purchase_line_expiry_${line.variant.id}_field',
                      ),
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
                ],
              ],
            ),
          ),
          SizedBox(
            width: 108,
            child: TextField(
              controller: _costController,
              focusNode: _costFocusNode,
              enabled: widget.enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
              decoration: InputDecoration(
                labelText: l10n.purchaseLineCostLabel,
                isDense: true,
              ),
              onChanged: (value) {
                final parsed = double.tryParse(
                  value.trim().replaceAll(',', '.'),
                );
                if (parsed != null && parsed >= 0) {
                  widget.onCostChanged(parsed);
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: l10n.removeOneTooltip,
            onPressed: widget.enabled ? widget.onRemove : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(width: 36, child: Center(child: Text('${line.quantity}'))),
          IconButton.filledTonal(
            tooltip: l10n.addOneTooltip,
            onPressed: widget.enabled ? () => widget.onAdd() : null,
            icon: const Icon(Icons.add),
          ),
          SizedBox(
            width: 72,
            child: Text(formatMoney(lineTotal), textAlign: TextAlign.end),
          ),
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
