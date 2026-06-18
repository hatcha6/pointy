import 'package:flutter/material.dart';

import '../../../core/parsing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/register_cash_movement.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';

class RegisterCashMovementSheet extends StatefulWidget {
  const RegisterCashMovementSheet({
    super.key,
    required this.movementType,
    required this.onSubmit,
  });

  final RegisterCashMovementType movementType;
  final Future<bool> Function(RegisterCashMovementInput input) onSubmit;

  @override
  State<RegisterCashMovementSheet> createState() =>
      _RegisterCashMovementSheetState();
}

class _RegisterCashMovementSheetState extends State<RegisterCashMovementSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _reasonController = TextEditingController();
  bool _isSubmitting = false;
  bool _showError = false;

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final isPayIn = widget.movementType == RegisterCashMovementType.payIn;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      isPayIn
                          ? l10n.payInRegisterSessionTitle
                          : l10n.payOutRegisterSessionTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: l10n.cancelButton,
                      onPressed: _isSubmitting
                          ? null
                          : () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amountController,
                  enabled: !_isSubmitting,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.cashMovementAmountLabel,
                    prefixIcon: const Icon(Icons.payments_outlined),
                  ),
                  validator: (value) => _validateAmount(value, l10n),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _reasonController,
                  enabled: !_isSubmitting,
                  minLines: 2,
                  maxLines: 4,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: l10n.cashMovementReasonLabel,
                    prefixIcon: const Icon(Icons.notes_outlined),
                  ),
                  validator: (value) => _validateReason(value, l10n),
                  onFieldSubmitted: (_) => _submit(),
                ),
                if (_showError) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.cashMovementCreateError,
                    style: TextStyle(color: colors.danger),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    TextButton(
                      onPressed: _isSubmitting
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: Text(l10n.cancelButton),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _isSubmitting ? null : _submit,
                      icon: _isSubmitting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(isPayIn ? Icons.input : Icons.output),
                      label: Text(
                        _isSubmitting
                            ? l10n.savingButton
                            : isPayIn
                            ? l10n.payInRegisterSessionButton
                            : l10n.payOutRegisterSessionButton,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _validateAmount(String? value, AppLocalizations l10n) {
    final amount = parseDecimal(value);
    if (amount == null || amount <= 0) {
      return l10n.positiveAmountRequiredError;
    }
    return null;
  }

  String? _validateReason(String? value, AppLocalizations l10n) {
    if ((value ?? '').trim().isEmpty) {
      return l10n.cashMovementReasonRequiredError;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _showError = false;
    });

    final didCreate = await widget.onSubmit(
      RegisterCashMovementInput(
        movementType: widget.movementType,
        amount: parseDecimal(_amountController.text) ?? 0,
        reason: _reasonController.text.trim(),
      ),
    );

    if (!mounted) {
      return;
    }

    if (didCreate) {
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _isSubmitting = false;
      _showError = true;
    });
  }
}

class RegisterCashMovementInput {
  const RegisterCashMovementInput({
    required this.movementType,
    required this.amount,
    required this.reason,
  });

  final RegisterCashMovementType movementType;
  final double amount;
  final String reason;
}
