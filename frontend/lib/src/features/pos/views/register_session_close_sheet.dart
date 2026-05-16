import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/decimal_text_input_formatter.dart';

class RegisterSessionCloseSheet extends StatefulWidget {
  const RegisterSessionCloseSheet({
    super.key,
    required this.onClose,
    this.initialClosingCash = '',
  });

  final Future<bool> Function(RegisterSessionCloseInput input) onClose;
  final String initialClosingCash;

  @override
  State<RegisterSessionCloseSheet> createState() =>
      _RegisterSessionCloseSheetState();
}

class _RegisterSessionCloseSheetState extends State<RegisterSessionCloseSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _closingCashController =
      TextEditingController(text: widget.initialClosingCash);
  final TextEditingController _count025Controller = TextEditingController();
  final TextEditingController _count050Controller = TextEditingController();
  final TextEditingController _count075Controller = TextEditingController();
  final TextEditingController _count100Controller = TextEditingController();
  bool _isSubmitting = false;
  bool _showError = false;

  @override
  void dispose() {
    _closingCashController.dispose();
    _count025Controller.dispose();
    _count050Controller.dispose();
    _count075Controller.dispose();
    _count100Controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

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
                      l10n.closeRegisterSessionTitle,
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
                  controller: _closingCashController,
                  enabled: !_isSubmitting,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.closingCashInputLabel,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.payments_outlined),
                  ),
                  validator: (value) => _validateMoney(value, l10n),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _CountField(
                      controller: _count025Controller,
                      enabled: !_isSubmitting,
                      label: l10n.denominationCountLabel('0.25'),
                    ),
                    _CountField(
                      controller: _count050Controller,
                      enabled: !_isSubmitting,
                      label: l10n.denominationCountLabel('0.50'),
                    ),
                    _CountField(
                      controller: _count075Controller,
                      enabled: !_isSubmitting,
                      label: l10n.denominationCountLabel('0.75'),
                    ),
                    _CountField(
                      controller: _count100Controller,
                      enabled: !_isSubmitting,
                      label: l10n.denominationCountLabel('1.00'),
                    ),
                  ],
                ),
                if (_showError) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.closeRegisterSessionError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
                          : const Icon(Icons.lock_outline),
                      label: Text(
                        _isSubmitting
                            ? l10n.closingRegisterSessionButton
                            : l10n.closeRegisterSessionButton,
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

  String? _validateMoney(String? value, AppLocalizations l10n) {
    final normalized = (value ?? '').replaceAll(',', '.');
    if (double.tryParse(normalized) == null) {
      return l10n.invalidNumber;
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _showError = false;
    });

    final didClose = await widget.onClose(
      RegisterSessionCloseInput(
        closingCash: _parseMoney(_closingCashController.text),
        count025: _parseCount(_count025Controller.text),
        count050: _parseCount(_count050Controller.text),
        count075: _parseCount(_count075Controller.text),
        count100: _parseCount(_count100Controller.text),
      ),
    );

    if (!mounted) {
      return;
    }

    if (didClose) {
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _isSubmitting = false;
      _showError = true;
    });
  }

  double _parseMoney(String value) {
    return double.parse(value.replaceAll(',', '.'));
  }

  int _parseCount(String value) {
    if (value.trim().isEmpty) {
      return 0;
    }
    return int.parse(value);
  }
}

class RegisterSessionCloseInput {
  const RegisterSessionCloseInput({
    required this.closingCash,
    required this.count025,
    required this.count050,
    required this.count075,
    required this.count100,
  });

  final double closingCash;
  final int count025;
  final int count050;
  final int count075;
  final int count100;
}

class _CountField extends StatelessWidget {
  const _CountField({
    required this.controller,
    required this.enabled,
    required this.label,
  });

  final TextEditingController controller;
  final bool enabled;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
