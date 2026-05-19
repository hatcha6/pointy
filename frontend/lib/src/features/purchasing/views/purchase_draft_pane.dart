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
  final FocusNode _supplierInvoiceNumberFocusNode = FocusNode();
  final FocusNode _supplierInvoiceDateFocusNode = FocusNode();

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
  }

  @override
  void dispose() {
    _supplierInvoiceNumberController.dispose();
    _supplierInvoiceDateController.dispose();
    _supplierInvoiceNumberFocusNode.dispose();
    _supplierInvoiceDateFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
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
            const SizedBox(height: 8),
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
            const SizedBox(height: 8),
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
            const SizedBox(height: 8),
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
                          onAdd: () => viewModel.addProduct(line.product),
                          onRemove: () =>
                              viewModel.decrementProduct(line.product),
                          onCostChanged: (unitCost) {
                            viewModel.updateLineCost(line.product, unitCost);
                          },
                        );
                      },
                    ),
            ),
            OrderTotals(
              subtotalLabel: l10n.subtotal,
              totalLabel: l10n.total,
              subtotal: viewModel.subtotal,
              total: viewModel.total,
            ),
            const SizedBox(height: 8),
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
            const SizedBox(height: 12),
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

  Future<void> _submitDraft(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
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
  }) {
    if ((!focusNode.hasFocus || value.isEmpty) && controller.text != value) {
      controller.text = value;
    }
  }

  String _formatDateInput(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
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
                  line.product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (line.product.sku.isNotEmpty)
                  Text(
                    line.product.sku,
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
