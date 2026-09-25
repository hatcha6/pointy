import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/balance_entry.dart';
import '../../../shared/balance_labels.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/opening_balance_fields.dart';
import '../../../shared/responsive/responsive.dart';

/// Writes an opening balance or an adjustment. [onSubmit] performs the write
/// and answers null on success or why it was refused; the dialog stays open on
/// a refusal so nothing typed is lost. Resolves true when something was saved.
Future<bool> showBalanceEntryDialog(
  BuildContext context, {
  required BalanceParty party,
  required BalanceEntryKind kind,
  required Future<BalanceFailure?> Function(BalanceEntryDraft draft) onSubmit,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) =>
        _BalanceEntryDialog(party: party, kind: kind, onSubmit: onSubmit),
  );
  return saved ?? false;
}

/// Asks why an entry is being withdrawn, and withdraws it. Resolves true when
/// it was cancelled.
Future<bool> showCancelBalanceEntryDialog(
  BuildContext context, {
  required BalanceEntry entry,
  required Future<BalanceFailure?> Function(String reason) onSubmit,
}) async {
  final cancelled = await showDialog<bool>(
    context: context,
    builder: (_) => _CancelBalanceEntryDialog(entry: entry, onSubmit: onSubmit),
  );
  return cancelled ?? false;
}

class _BalanceEntryDialog extends StatefulWidget {
  const _BalanceEntryDialog({
    required this.party,
    required this.kind,
    required this.onSubmit,
  });

  final BalanceParty party;
  final BalanceEntryKind kind;
  final Future<BalanceFailure?> Function(BalanceEntryDraft draft) onSubmit;

  @override
  State<_BalanceEntryDialog> createState() => _BalanceEntryDialogState();
}

class _BalanceEntryDialogState extends State<_BalanceEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  BalanceDirection _direction = BalanceDirection.theyOweUs;
  DateTime? _effectiveDate;
  bool _isSaving = false;
  String? _error;

  bool get _isOpening => widget.kind == BalanceEntryKind.opening;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _effectiveDate ?? today,
      firstDate: DateTime(2000),
      lastDate: today,
    );
    if (picked != null && mounted) {
      setState(
        () => _effectiveDate = DateUtils.isSameDay(picked, today)
            ? null
            : DateUtils.dateOnly(picked),
      );
    }
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });
    final failure = await widget.onSubmit(
      BalanceEntryDraft(
        kind: widget.kind,
        direction: _direction,
        amount: double.parse(_amountController.text.trim()),
        note: _noteController.text.trim(),
        effectiveDate: _effectiveDate,
      ),
    );
    if (!mounted) {
      return;
    }
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _isSaving = false;
      _error = balanceFailureMessage(
        l10n,
        failure,
        fallback: l10n.balanceEntrySaveError,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return AlertDialog(
      title: Text(
        _isOpening ? l10n.addOpeningBalanceButton : l10n.balanceKindAdjustment,
      ),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _isOpening
                      ? l10n.balanceEntryOpeningHint
                      : l10n.balanceEntryAdjustmentHint,
                  style: textTheme.bodySmall,
                ),
                SizedBox(height: spacing.md),
                BalanceDirectionPicker(
                  key: const ValueKey('balance_entry_direction'),
                  party: widget.party,
                  value: _direction,
                  enabled: !_isSaving,
                  onChanged: (direction) =>
                      setState(() => _direction = direction),
                ),
                SizedBox(height: spacing.md),
                TextFormField(
                  key: const ValueKey('balance_entry_amount'),
                  controller: _amountController,
                  enabled: !_isSaving,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: l10n.balanceEntryAmountLabel,
                    prefixIcon: const Icon(Icons.payments_outlined),
                  ),
                  validator: (value) => validateBalanceAmount(l10n, value),
                ),
                SizedBox(height: spacing.sm),
                InkWell(
                  key: const ValueKey('balance_entry_date'),
                  onTap: _isSaving ? null : _pickDate,
                  borderRadius: BorderRadius.circular(PointyRadii.chip),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.balanceEntryDateLabel,
                      prefixIcon: const Icon(Icons.event_outlined),
                    ),
                    child: Text(
                      _effectiveDate == null
                          ? l10n.balanceEntryDateToday
                          : formatDate(_effectiveDate!),
                    ),
                  ),
                ),
                SizedBox(height: spacing.sm),
                TextFormField(
                  key: const ValueKey('balance_entry_note'),
                  controller: _noteController,
                  enabled: !_isSaving,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: _isOpening
                        ? l10n.balanceEntryNoteOptionalLabel
                        : l10n.balanceEntryNoteLabel,
                  ),
                  validator: (value) {
                    if (!_isOpening && (value ?? '').trim().isEmpty) {
                      return l10n.balanceEntryNoteRequired;
                    }
                    return null;
                  },
                ),
                if (_error != null) ...[
                  SizedBox(height: spacing.sm),
                  PointyInlineMessage.error(message: _error!),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          key: const ValueKey('balance_entry_save'),
          onPressed: _isSaving ? null : _submit,
          icon: _isSaving
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(l10n.saveButton),
        ),
      ],
    );
  }
}

class _CancelBalanceEntryDialog extends StatefulWidget {
  const _CancelBalanceEntryDialog({
    required this.entry,
    required this.onSubmit,
  });

  final BalanceEntry entry;
  final Future<BalanceFailure?> Function(String reason) onSubmit;

  @override
  State<_CancelBalanceEntryDialog> createState() =>
      _CancelBalanceEntryDialogState();
}

class _CancelBalanceEntryDialogState extends State<_CancelBalanceEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });
    final failure = await widget.onSubmit(_reasonController.text.trim());
    if (!mounted) {
      return;
    }
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _isSaving = false;
      _error = balanceFailureMessage(
        l10n,
        failure,
        fallback: l10n.balanceEntryCancelError,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return AlertDialog(
      title: Text(l10n.balanceEntryCancelTitle(widget.entry.number)),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.balanceEntryCancelBody,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(height: spacing.md),
              TextFormField(
                key: const ValueKey('balance_cancel_reason'),
                controller: _reasonController,
                enabled: !_isSaving,
                autofocus: true,
                minLines: 2,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l10n.balanceEntryCancelReasonLabel,
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? l10n.balanceEntryCancelReasonRequired
                    : null,
              ),
              if (_error != null) ...[
                SizedBox(height: spacing.sm),
                PointyInlineMessage.error(message: _error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          key: const ValueKey('balance_cancel_confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: context.pointyColors.danger,
          ),
          onPressed: _isSaving ? null : _submit,
          child: Text(l10n.balanceEntryCancelAction),
        ),
      ],
    );
  }
}

/// Settles the party's credit side with cash: pays a customer what the shop
/// owes them, or takes in what a supplier owes it. [available] is the most it
/// can be. Resolves true once the money has been recorded.
Future<bool> showBalanceRefundDialog(
  BuildContext context, {
  required BalanceParty party,
  required double available,
  required Future<BalanceFailure?> Function(double amount, String note)
  onSubmit,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _BalanceRefundDialog(
      party: party,
      available: available,
      onSubmit: onSubmit,
    ),
  );
  return saved ?? false;
}

class _BalanceRefundDialog extends StatefulWidget {
  const _BalanceRefundDialog({
    required this.party,
    required this.available,
    required this.onSubmit,
  });

  final BalanceParty party;
  final double available;
  final Future<BalanceFailure?> Function(double amount, String note) onSubmit;

  @override
  State<_BalanceRefundDialog> createState() => _BalanceRefundDialogState();
}

class _BalanceRefundDialogState extends State<_BalanceRefundDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amountController = TextEditingController(
    text: widget.available.toStringAsFixed(2),
  );
  final _noteController = TextEditingController();
  bool _isSaving = false;
  String? _error;

  bool get _isCustomer => widget.party == BalanceParty.customer;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });
    final failure = await widget.onSubmit(
      double.parse(_amountController.text.trim()),
      _noteController.text.trim(),
    );
    if (!mounted) {
      return;
    }
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _isSaving = false;
      _error = balanceFailureMessage(
        l10n,
        failure,
        fallback: l10n.balanceEntrySaveError,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return AlertDialog(
      title: Text(
        _isCustomer ? l10n.customerRefundTitle : l10n.supplierRefundTitle,
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _isCustomer
                      ? l10n.customerRefundHint
                      : l10n.supplierRefundHint,
                  style: textTheme.bodySmall,
                ),
                SizedBox(height: spacing.md),
                TextFormField(
                  key: const ValueKey('balance_refund_amount'),
                  controller: _amountController,
                  enabled: !_isSaving,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: l10n.balanceEntryAmountLabel,
                    helperText: l10n.balanceRefundAvailableValue(
                      formatMoney(widget.available),
                    ),
                    prefixIcon: const Icon(Icons.payments_outlined),
                  ),
                  validator: (value) {
                    final invalid = validateBalanceAmount(l10n, value);
                    if (invalid != null) {
                      return invalid;
                    }
                    final amount = double.parse(value!.trim());
                    // A cent of slack for the float the field parses into;
                    // the server holds the real ceiling.
                    if (amount > widget.available + 0.005) {
                      return l10n.balanceRefundAmountTooHigh(
                        formatMoney(widget.available),
                      );
                    }
                    return null;
                  },
                ),
                SizedBox(height: spacing.sm),
                TextFormField(
                  key: const ValueKey('balance_refund_note'),
                  controller: _noteController,
                  enabled: !_isSaving,
                  decoration: InputDecoration(
                    labelText: l10n.balanceEntryNoteOptionalLabel,
                  ),
                ),
                if (_error != null) ...[
                  SizedBox(height: spacing.sm),
                  PointyInlineMessage.error(message: _error!),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          key: const ValueKey('balance_refund_confirm'),
          onPressed: _isSaving ? null : _submit,
          icon: _isSaving
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.payments_outlined),
          label: Text(
            _isCustomer ? l10n.customerRefundButton : l10n.supplierRefundButton,
          ),
        ),
      ],
    );
  }
}
