import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/money_position_view_model.dart';
import 'treasury_ui.dart';

/// Asks which account to count when the action was started from the screen
/// rather than from an account.
Future<void> showMoneyCountPickerSheet(
  BuildContext context, {
  required MoneyPositionViewModel viewModel,
}) async {
  final entries = viewModel.accounts;
  if (entries.length == 1) {
    return showMoneyCountSheet(
      context,
      viewModel: viewModel,
      entry: entries.first,
    );
  }

  final l10n = AppLocalizations.of(context)!;
  final chosen = await showModalBottomSheet<MoneyAccountPosition>(
    context: context,
    useSafeArea: true,
    builder: (sheetContext) {
      final spacing = AdaptiveSpacing.of(sheetContext);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.all(spacing.md),
              child: PointySectionHeader(title: l10n.treasuryActionCount),
            ),
            for (final entry in entries)
              ListTile(
                leading: Icon(treasuryAccountIcon(entry.account)),
                title: Text(entry.account.name),
                subtitle: Text(formatMoney(entry.expectedBalance)),
                onTap: () => Navigator.of(sheetContext).pop(entry),
              ),
            SizedBox(height: spacing.md),
          ],
        ),
      );
    },
  );
  if (chosen != null && context.mounted) {
    await showMoneyCountSheet(context, viewModel: viewModel, entry: chosen);
  }
}

/// Records what is physically in an account.
///
/// The expected balance is deliberately **not** shown while the amount is being
/// entered: a count that can see the answer stops being a count. It is revealed
/// with the variance once the number is committed.
Future<void> showMoneyCountSheet(
  BuildContext context, {
  required MoneyPositionViewModel viewModel,
  required MoneyAccountPosition entry,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) =>
        _MoneyCountSheet(viewModel: viewModel, entry: entry),
  );
}

class _MoneyCountSheet extends StatefulWidget {
  const _MoneyCountSheet({required this.viewModel, required this.entry});

  final MoneyPositionViewModel viewModel;
  final MoneyAccountPosition entry;

  @override
  State<_MoneyCountSheet> createState() => _MoneyCountSheetState();
}

class _MoneyCountSheetState extends State<_MoneyCountSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  bool _submitting = false;

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
    final amount = double.parse(_amountController.text.trim());
    setState(() => _submitting = true);

    final count = await widget.viewModel.recordCount(
      accountId: widget.entry.account.id,
      countedAmount: amount,
      note: _noteController.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() => _submitting = false);

    final messenger = ScaffoldMessenger.of(context);
    if (count == null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.treasuryCountFailed)));
      return;
    }
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(content: Text(_resultMessage(l10n, count))),
    );
  }

  String _resultMessage(AppLocalizations l10n, MoneyCount count) {
    if (!count.hasVariance) {
      return l10n.treasuryCountResultMatched;
    }
    final amount = formatMoney(count.variance.abs());
    return count.isShort
        ? l10n.treasuryCountResultShort(amount)
        : l10n.treasuryCountResultOver(amount);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Form(
          key: _formKey,
          child: Padding(
            padding: EdgeInsets.all(spacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PointySectionHeader(
                  title: l10n.treasuryCountSheetTitle(
                    widget.entry.account.name,
                  ),
                ),
                SizedBox(height: spacing.sm),
                Text(
                  l10n.treasuryCountSheetPrompt,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
                ),
                SizedBox(height: spacing.md),
                TextFormField(
                  controller: _amountController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: l10n.treasuryCountFieldLabel,
                  ),
                  validator: (value) {
                    final parsed = double.tryParse(value?.trim() ?? '');
                    if (parsed == null || parsed < 0) {
                      return l10n.treasuryAmountInvalid;
                    }
                    return null;
                  },
                  onFieldSubmitted: (_) => _submit(),
                ),
                SizedBox(height: spacing.sm),
                TextFormField(
                  controller: _noteController,
                  decoration: InputDecoration(
                    labelText: l10n.treasuryCountNoteLabel,
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
                  label: Text(l10n.treasuryCountSubmit),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
