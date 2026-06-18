import 'package:flutter/material.dart';

import '../../../core/parsing.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

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
  void initState() {
    super.initState();
    for (final controller in [
      _closingCashController,
      _count025Controller,
      _count050Controller,
      _count075Controller,
      _count100Controller,
    ]) {
      controller.addListener(_onAmountsChanged);
    }
  }

  void _onAmountsChanged() {
    setState(() {});
  }

  double get _denominationTotal {
    return _parseCount(_count025Controller.text) * 0.25 +
        _parseCount(_count050Controller.text) * 0.50 +
        _parseCount(_count075Controller.text) * 0.75 +
        _parseCount(_count100Controller.text) * 1.00;
  }

  double get _closingCashTotal {
    final cash = parseDecimal(_closingCashController.text) ?? 0.0;
    return cash + _denominationTotal;
  }

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
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.sheet),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CloseSheetHeader(
                title: l10n.closeRegisterSessionTitle,
                isSubmitting: _isSubmitting,
                onCancel: () => Navigator.of(context).pop(false),
              ),
              Divider(height: 1, color: colors.line),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsetsDirectional.only(
                    start: spacing.lg,
                    end: spacing.lg,
                    top: spacing.lg,
                    bottom:
                        spacing.lg + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        key: const ValueKey(
                          'register_session_closing_cash_field',
                        ),
                        controller: _closingCashController,
                        enabled: !_isSubmitting,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [DecimalTextInputFormatter()],
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: l10n.closingCashInputLabel,
                          prefixIcon: const Icon(Icons.payments_outlined),
                        ),
                        validator: (value) => _validateMoney(value, l10n),
                      ),
                      SizedBox(height: spacing.md),
                      ResponsiveFormGrid(
                        minChildWidth: 148,
                        maxColumns: 4,
                        children: [
                          _CountField(
                            key: const ValueKey(
                              'register_session_count_025_field',
                            ),
                            controller: _count025Controller,
                            enabled: !_isSubmitting,
                            label: l10n.denominationCountLabel('0.25'),
                          ),
                          _CountField(
                            key: const ValueKey(
                              'register_session_count_050_field',
                            ),
                            controller: _count050Controller,
                            enabled: !_isSubmitting,
                            label: l10n.denominationCountLabel('0.50'),
                          ),
                          _CountField(
                            key: const ValueKey(
                              'register_session_count_075_field',
                            ),
                            controller: _count075Controller,
                            enabled: !_isSubmitting,
                            label: l10n.denominationCountLabel('0.75'),
                          ),
                          _CountField(
                            key: const ValueKey(
                              'register_session_count_100_field',
                            ),
                            controller: _count100Controller,
                            enabled: !_isSubmitting,
                            label: l10n.denominationCountLabel('1.00'),
                          ),
                        ],
                      ),
                      SizedBox(height: spacing.md),
                      PointyMetricTile(
                        key: const ValueKey(
                          'register_session_closing_total_tile',
                        ),
                        icon: Icons.point_of_sale_outlined,
                        label: l10n.closingCashTotalLabel,
                        value: formatMoney(_closingCashTotal),
                      ),
                      if (_showError) ...[
                        SizedBox(height: spacing.md),
                        PointyInlineMessage.error(
                          message: l10n.closeRegisterSessionError,
                          icon: Icons.warning_amber_outlined,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              PointyStickyActionFooter(
                secondaryActions: [
                  TextButton(
                    key: const ValueKey('register_session_close_cancel_button'),
                    onPressed: _isSubmitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: Text(l10n.cancelButton),
                  ),
                ],
                primaryAction: FilledButton.icon(
                  key: const ValueKey('register_session_close_submit_button'),
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
              ),
            ],
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
    return parseDecimal(value) ?? 0;
  }

  int _parseCount(String value) {
    if (value.trim().isEmpty) {
      return 0;
    }
    return int.parse(value);
  }
}

class _CloseSheetHeader extends StatelessWidget {
  const _CloseSheetHeader({
    required this.title,
    required this.isSubmitting,
    required this.onCancel,
  });

  final String title;
  final bool isSubmitting;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.lg,
        spacing.sm,
        spacing.sm,
        spacing.sm,
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, color: context.pointyColors.primaryStrong),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context)!.cancelButton,
            onPressed: isSubmitting ? null : onCancel,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
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
    super.key,
    required this.controller,
    required this.enabled,
    required this.label,
  });

  final TextEditingController controller;
  final bool enabled;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(labelText: label),
    );
  }
}
