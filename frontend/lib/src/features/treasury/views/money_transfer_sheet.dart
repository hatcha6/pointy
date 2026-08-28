import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/components/components.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/money_position_view_model.dart';
import 'treasury_ui.dart';

/// Records a move of the shop's own money: the bank deposit, the owner's draw,
/// capital put in. Either side may be "outside the shop", which is what makes
/// the last two expressible at all.
Future<void> showMoneyTransferSheet(
  BuildContext context, {
  required MoneyPositionViewModel viewModel,
  int? fromAccountId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) =>
        _MoneyTransferSheet(viewModel: viewModel, fromAccountId: fromAccountId),
  );
}

class _MoneyTransferSheet extends StatefulWidget {
  const _MoneyTransferSheet({required this.viewModel, this.fromAccountId});

  final MoneyPositionViewModel viewModel;
  final int? fromAccountId;

  @override
  State<_MoneyTransferSheet> createState() => _MoneyTransferSheetState();
}

class _MoneyTransferSheetState extends State<_MoneyTransferSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _reasonController = TextEditingController();

  int? _fromAccountId;
  int? _toAccountId;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final accounts = widget.viewModel.accounts;
    // Default to the shop's most common move: the cash box into the bank.
    _fromAccountId =
        widget.fromAccountId ??
        accounts
            .where((entry) => entry.account.isCash)
            .map((entry) => entry.account.id)
            .firstOrNull;
    _toAccountId = accounts
        .where(
          (entry) =>
              !entry.account.isCash && entry.account.id != _fromAccountId,
        )
        .map((entry) => entry.account.id)
        .firstOrNull;
  }

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (_fromAccountId == null && _toAccountId == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.treasuryTransferNeedsSide)),
      );
      return;
    }
    if (_fromAccountId != null && _fromAccountId == _toAccountId) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.treasuryTransferSameAccount)),
      );
      return;
    }

    setState(() => _submitting = true);
    final saved = await widget.viewModel.recordTransfer(
      MoneyTransferDraft(
        amount: double.parse(_amountController.text.trim()),
        fromAccountId: _fromAccountId,
        toAccountId: _toAccountId,
        reason: _reasonController.text.trim(),
      ),
    );
    if (!mounted) {
      return;
    }
    setState(() => _submitting = false);
    if (!saved) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.treasuryTransferFailed)),
      );
      return;
    }
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(l10n.treasuryTransferSaved)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: EdgeInsets.all(spacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PointySectionHeader(title: l10n.treasuryTransferSheetTitle),
                SizedBox(height: spacing.md),
                _AccountDropdown(
                  label: l10n.treasuryTransferFrom,
                  accounts: widget.viewModel.accounts,
                  value: _fromAccountId,
                  onChanged: (value) => setState(() => _fromAccountId = value),
                ),
                SizedBox(height: spacing.sm),
                _AccountDropdown(
                  label: l10n.treasuryTransferTo,
                  accounts: widget.viewModel.accounts,
                  value: _toAccountId,
                  onChanged: (value) => setState(() => _toAccountId = value),
                ),
                SizedBox(height: spacing.sm),
                TextFormField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: l10n.treasuryTransferAmount,
                  ),
                  validator: (value) {
                    final parsed = double.tryParse(value?.trim() ?? '');
                    if (parsed == null || parsed <= 0) {
                      return l10n.treasuryAmountInvalid;
                    }
                    return null;
                  },
                ),
                SizedBox(height: spacing.sm),
                TextFormField(
                  controller: _reasonController,
                  decoration: InputDecoration(
                    labelText: l10n.treasuryTransferReason,
                  ),
                ),
                SizedBox(height: spacing.md),
                FilledButton.icon(
                  onPressed: _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(l10n.treasuryTransferSubmit),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An account picker whose null option means "outside the shop" — the way an
/// owner's draw and a capital injection are expressed.
class _AccountDropdown extends StatelessWidget {
  const _AccountDropdown({
    required this.label,
    required this.accounts,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<MoneyAccountPosition> accounts;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return DropdownButtonFormField<int?>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem<int?>(
          value: null,
          child: Text(l10n.treasuryTransferOutside),
        ),
        for (final entry in accounts)
          DropdownMenuItem<int?>(
            value: entry.account.id,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(treasuryAccountIcon(entry.account), size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '${entry.account.name} · '
                    '${formatMoney(entry.expectedBalance)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
