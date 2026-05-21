import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order_totals.dart';
import '../view_models/purchase_view_model.dart';

class PurchaseDraftPane extends StatefulWidget {
  const PurchaseDraftPane({
    super.key,
    required this.viewModel,
    required this.contactRepository,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;

  @override
  State<PurchaseDraftPane> createState() => _PurchaseDraftPaneState();
}

class _PurchaseDraftPaneState extends State<PurchaseDraftPane> {
  late final TextEditingController _supplierInvoiceNumberController =
      TextEditingController(text: widget.viewModel.supplierInvoiceNumber);
  late final TextEditingController _supplierInvoiceDateController =
      TextEditingController(text: widget.viewModel.supplierInvoiceDateInput);
  late final TextEditingController _shippingCostController =
      TextEditingController(
        text: _costInputText(widget.viewModel.shippingCost),
      );
  late final TextEditingController _customsCostController =
      TextEditingController(text: _costInputText(widget.viewModel.customsCost));
  late final TextEditingController _handlingCostController =
      TextEditingController(
        text: _costInputText(widget.viewModel.handlingCost),
      );
  late final TextEditingController _discountCodeController =
      TextEditingController(text: widget.viewModel.discountCode);
  final FocusNode _supplierInvoiceNumberFocusNode = FocusNode();
  final FocusNode _supplierInvoiceDateFocusNode = FocusNode();
  final FocusNode _shippingCostFocusNode = FocusNode();
  final FocusNode _customsCostFocusNode = FocusNode();
  final FocusNode _handlingCostFocusNode = FocusNode();
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
      controller: _shippingCostController,
      focusNode: _shippingCostFocusNode,
      value: _costInputText(widget.viewModel.shippingCost),
      syncEmptyWhileFocused: false,
    );
    _syncController(
      controller: _customsCostController,
      focusNode: _customsCostFocusNode,
      value: _costInputText(widget.viewModel.customsCost),
      syncEmptyWhileFocused: false,
    );
    _syncController(
      controller: _handlingCostController,
      focusNode: _handlingCostFocusNode,
      value: _costInputText(widget.viewModel.handlingCost),
      syncEmptyWhileFocused: false,
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
    _shippingCostController.dispose();
    _customsCostController.dispose();
    _handlingCostController.dispose();
    _discountCodeController.dispose();
    _supplierInvoiceNumberFocusNode.dispose();
    _supplierInvoiceDateFocusNode.dispose();
    _shippingCostFocusNode.dispose();
    _customsCostFocusNode.dispose();
    _handlingCostFocusNode.dispose();
    _discountCodeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  l10n.purchaseDraftTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                IconButton(
                  tooltip: l10n.clearPurchaseDraftTooltip,
                  onPressed: viewModel.draft.isEmpty || viewModel.isSubmitting
                      ? null
                      : viewModel.clearDraft,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ContactSelectionTile(
              label: l10n.selectedSupplierLabel,
              value: viewModel.selectedSupplier?.name ?? '',
              placeholder: l10n.noSupplierSelectedLabel,
              icon: Icons.local_shipping_outlined,
              enabled: !viewModel.isSubmitting,
              onSelect: () => _selectSupplier(context),
              onClear: () => viewModel.selectSupplier(null),
              allowClear: false,
            ),
            if (viewModel.selectedSupplier == null) ...[
              const SizedBox(height: 6),
              Text(
                l10n.purchaseSupplierRequiredHint,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('supplier_invoice_number_field'),
                    controller: _supplierInvoiceNumberController,
                    focusNode: _supplierInvoiceNumberFocusNode,
                    enabled: !viewModel.isSubmitting,
                    decoration: InputDecoration(
                      labelText: l10n.supplierInvoiceNumberLabel,
                      hintText: l10n.supplierInvoiceNumberHint,
                      isDense: true,
                      prefixIcon: const Icon(Icons.receipt_long_outlined),
                    ),
                    onChanged: viewModel.updateSupplierInvoiceNumber,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('supplier_invoice_date_field'),
                    controller: _supplierInvoiceDateController,
                    focusNode: _supplierInvoiceDateFocusNode,
                    enabled: !viewModel.isSubmitting,
                    keyboardType: TextInputType.datetime,
                    inputFormatters: const [_DateDashInputFormatter()],
                    decoration: InputDecoration(
                      labelText: l10n.supplierInvoiceDateLabel,
                      hintText: l10n.supplierInvoiceDateHint,
                      errorText: viewModel.hasInvalidSupplierInvoiceDate
                          ? l10n.supplierInvoiceDateInvalid
                          : null,
                      isDense: true,
                      prefixIcon: const Icon(Icons.event_outlined),
                      suffixIcon: IconButton(
                        tooltip: l10n.supplierInvoiceDatePickerTooltip,
                        onPressed: viewModel.isSubmitting
                            ? null
                            : () => _pickSupplierInvoiceDate(context),
                        icon: const Icon(Icons.calendar_month_outlined),
                      ),
                    ),
                    onChanged: viewModel.updateSupplierInvoiceDateInput,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _buildLandedCostSection(l10n),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('purchase_discount_code_field'),
              controller: _discountCodeController,
              focusNode: _discountCodeFocusNode,
              enabled: !viewModel.isSubmitting,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.discountCouponCodeLabel,
                hintText: l10n.purchaseDiscountCodeHint,
                isDense: true,
                prefixIcon: const Icon(Icons.confirmation_number_outlined),
                suffixIcon: viewModel.isLoadingDiscountPreview
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: _discountCodeController.text.trim().isEmpty
                            ? l10n.refreshDiscountPreviewTooltip
                            : l10n.clearCouponCodeTooltip,
                        onPressed: viewModel.isSubmitting
                            ? null
                            : () {
                                if (_discountCodeController.text
                                    .trim()
                                    .isEmpty) {
                                  viewModel.refreshDiscountPreview();
                                } else {
                                  _discountCodeController.clear();
                                  viewModel.updateDiscountCode('');
                                }
                              },
                        icon: Icon(
                          _discountCodeController.text.trim().isEmpty
                              ? Icons.sync
                              : Icons.close,
                        ),
                      ),
                errorText: viewModel.unappliedDiscountCodes.isNotEmpty
                    ? l10n.discountCouponUnavailable(
                        viewModel.unappliedDiscountCodes.join('، '),
                      )
                    : viewModel.hasDiscountPreviewError
                    ? l10n.discountPreviewUnavailable
                    : null,
              ),
              onChanged: (value) {
                setState(() {});
                viewModel.updateDiscountCode(value);
              },
              onSubmitted: (_) => viewModel.refreshDiscountPreview(),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: viewModel.draft.isEmpty
                  ? Center(child: Text(l10n.emptyPurchaseDraft))
                  : ListView.separated(
                      itemCount: viewModel.draft.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final line = viewModel.draft[index];
                        return PurchaseDraftLineTile(
                          line: line,
                          enabled: !viewModel.isSubmitting,
                          onAdd: () => viewModel.addVariant(line.variant),
                          onRemove: () =>
                              viewModel.decrementVariant(line.variant),
                          onCostChanged: (unitCost) {
                            viewModel.updateLineCost(line.variant, unitCost);
                          },
                        );
                      },
                    ),
            ),
            Column(
              children: [
                TotalRow(label: l10n.subtotal, value: viewModel.subtotal),
                if (viewModel.discountTotal > 0)
                  TotalRow(
                    label: l10n.discountTotalLabel,
                    value: -viewModel.discountTotal,
                  ),
                for (final discount in viewModel.appliedDiscounts)
                  TotalRow(
                    label: discount.couponCode.isEmpty
                        ? discount.ruleName
                        : l10n.discountCouponAppliedLabel(discount.couponCode),
                    value: -discount.discountAmount,
                  ),
                if (viewModel.landedCostTotal > 0)
                  TotalRow(
                    label: l10n.purchaseLandedCostTotalLabel,
                    value: viewModel.landedCostTotal,
                  ),
                const Divider(),
                TotalRow(
                  label: l10n.total,
                  value: viewModel.total,
                  isStrong: true,
                ),
              ],
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              value: viewModel.receiveImmediately,
              onChanged: viewModel.isSubmitting
                  ? null
                  : (value) =>
                        viewModel.updateReceiveImmediately(value ?? true),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l10n.receivePurchaseImmediatelyLabel),
            ),
            const SizedBox(height: 6),
            FilledButton.icon(
              onPressed: viewModel.canSubmitDraft
                  ? () => _submitDraft(context)
                  : null,
              icon: viewModel.isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.inventory_outlined),
              label: Text(
                viewModel.isSubmitting
                    ? l10n.purchaseSubmitInProgressButton
                    : l10n.submitPurchaseDraftButton(
                        formatMoney(viewModel.total),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLandedCostSection(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _LandedCostField(
                key: const ValueKey('shipping_cost_field'),
                controller: _shippingCostController,
                focusNode: _shippingCostFocusNode,
                label: l10n.purchaseShippingCostLabel,
                icon: Icons.local_shipping_outlined,
                enabled: !viewModel.isSubmitting,
                onChanged: viewModel.updateShippingCost,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _LandedCostField(
                key: const ValueKey('customs_cost_field'),
                controller: _customsCostController,
                focusNode: _customsCostFocusNode,
                label: l10n.purchaseCustomsCostLabel,
                icon: Icons.account_balance_outlined,
                enabled: !viewModel.isSubmitting,
                onChanged: viewModel.updateCustomsCost,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _LandedCostField(
                key: const ValueKey('handling_cost_field'),
                controller: _handlingCostController,
                focusNode: _handlingCostFocusNode,
                label: l10n.purchaseHandlingCostLabel,
                icon: Icons.inventory_2_outlined,
                enabled: !viewModel.isSubmitting,
                onChanged: viewModel.updateHandlingCost,
              ),
            ),
          ],
        ),
        if (viewModel.landedCostTotal > 0) ...[
          const SizedBox(height: 8),
          SegmentedButton<LandedCostAllocationMethod>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity(horizontal: -2, vertical: -2),
            ),
            segments: [
              ButtonSegment(
                value: LandedCostAllocationMethod.byLineValue,
                label: Text(
                  l10n.landedCostAllocationByLineValueLabel,
                  overflow: TextOverflow.ellipsis,
                ),
                icon: const Icon(Icons.payments_outlined),
                enabled: !viewModel.isSubmitting,
              ),
              ButtonSegment(
                value: LandedCostAllocationMethod.byQuantity,
                label: Text(
                  l10n.landedCostAllocationByQuantityLabel,
                  overflow: TextOverflow.ellipsis,
                ),
                icon: const Icon(Icons.numbers_outlined),
                enabled: !viewModel.isSubmitting,
              ),
            ],
            selected: {viewModel.landedCostAllocationMethod},
            onSelectionChanged: viewModel.isSubmitting
                ? null
                : (selection) {
                    if (selection.isNotEmpty) {
                      viewModel.updateLandedCostAllocationMethod(
                        selection.first,
                      );
                    }
                  },
          ),
        ],
      ],
    );
  }

  Future<void> _submitDraft(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
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

  Future<void> _pickSupplierInvoiceDate(BuildContext context) async {
    final current = viewModel.supplierInvoiceDate ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !context.mounted) {
      return;
    }

    final formatted = _formatDateInput(selected);
    _supplierInvoiceDateController.text = formatted;
    viewModel.updateSupplierInvoiceDateInput(formatted);
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

  String _formatDateInput(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  String _costInputText(double value) {
    return value == 0 ? '' : value.toStringAsFixed(2);
  }
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

class _LandedCostField extends StatelessWidget {
  const _LandedCostField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final IconData icon;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [DecimalTextInputFormatter()],
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        prefixIcon: Icon(icon),
      ),
      onChanged: (value) {
        final normalized = value.trim().replaceAll(',', '.');
        final parsed = normalized.isEmpty ? 0.0 : double.tryParse(normalized);
        if (parsed != null && parsed >= 0) {
          onChanged(parsed);
        }
      },
    );
  }
}

class PurchaseDraftLineTile extends StatefulWidget {
  const PurchaseDraftLineTile({
    super.key,
    required this.line,
    required this.enabled,
    required this.onAdd,
    required this.onRemove,
    required this.onCostChanged,
  });

  final PurchaseDraftLine line;
  final bool enabled;
  final Future<void> Function() onAdd;
  final VoidCallback onRemove;
  final ValueChanged<double> onCostChanged;

  @override
  State<PurchaseDraftLineTile> createState() => _PurchaseDraftLineTileState();
}

class _PurchaseDraftLineTileState extends State<PurchaseDraftLineTile> {
  late final TextEditingController _costController = TextEditingController(
    text: widget.line.unitCost.toStringAsFixed(2),
  );
  final FocusNode _costFocusNode = FocusNode();

  @override
  void didUpdateWidget(covariant PurchaseDraftLineTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextText = widget.line.unitCost.toStringAsFixed(2);
    if (!_costFocusNode.hasFocus && _costController.text != nextText) {
      _costController.text = nextText;
    }
  }

  @override
  void dispose() {
    _costFocusNode.dispose();
    _costController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final line = widget.line;

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
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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
            child: Text(formatMoney(line.total), textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}
