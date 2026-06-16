import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_movement.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../view_models/product_stock_view_model.dart';
import 'stock_movement_labels.dart';

class StockMovementForm extends StatefulWidget {
  const StockMovementForm({
    super.key,
    required this.viewModel,
    required this.onSaved,
  });

  final ProductStockViewModel viewModel;
  final VoidCallback onSaved;

  @override
  State<StockMovementForm> createState() => _StockMovementFormState();
}

class _StockMovementFormState extends State<StockMovementForm> {
  final _formKey = GlobalKey<FormState>();
  final _quantityController = TextEditingController();
  final _noteController = TextEditingController();
  StockMovementType _movementType = StockMovementType.increase;

  @override
  void dispose() {
    _quantityController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    Text(
                      l10n.newStockMovementTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<StockMovementType>(
                      initialValue: _movementType,
                      decoration: InputDecoration(
                        labelText: l10n.stockMovementTypeLabel,
                        prefixIcon: const Icon(Icons.swap_horiz_outlined),
                      ),
                      items: StockMovementType.values
                          .map(
                            (type) => DropdownMenuItem(
                              value: type,
                              child: Text(stockMovementTypeLabel(l10n, type)),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: widget.viewModel.isSavingMovement
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _movementType = value);
                              }
                            },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _quantityController,
                      enabled: !widget.viewModel.isSavingMovement,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [DecimalTextInputFormatter()],
                      decoration: InputDecoration(
                        labelText: l10n.stockMovementQuantityLabel,
                        prefixIcon: const Icon(Icons.numbers_outlined),
                      ),
                      validator: (value) {
                        final quantity = double.tryParse(value ?? '');
                        if (quantity == null || quantity <= 0) {
                          return l10n.invalidNumber;
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _noteController,
                      enabled: !widget.viewModel.isSavingMovement,
                      minLines: 2,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: l10n.stockMovementNoteLabel,
                        prefixIcon: const Icon(Icons.notes_outlined),
                      ),
                    ),
                    if (widget.viewModel.errorMessage ==
                        'stock_movement_create_error') ...[
                      const SizedBox(height: 12),
                      Text(
                        l10n.stockMovementCreateError,
                        style: TextStyle(color: context.pointyColors.danger),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: widget.viewModel.isSavingMovement
                          ? null
                          : _submit,
                      icon: widget.viewModel.isSavingMovement
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(
                        widget.viewModel.isSavingMovement
                            ? l10n.savingButton
                            : l10n.saveStockMovementButton,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final created = await widget.viewModel.createMovement(
      movementType: _movementType,
      quantity: double.parse(_quantityController.text),
      note: _noteController.text,
    );
    if (created && mounted) {
      widget.onSaved();
    }
  }
}
