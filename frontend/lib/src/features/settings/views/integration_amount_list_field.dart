import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// An owner-editable list of amounts — today, LNET's quick-pick
/// denominations — added and removed one at a time, never typed as a
/// delimited string.
///
/// Mirrors Shop Settings' trusted-card-terminal list editor: a summary of
/// what is set now plus a "manage" button that opens a dialog to add or
/// remove entries. The field it replaces asked an owner to type "10, 20, 25"
/// into one box and get the separator right, and the failure mode was
/// silent — Annaseem's list was edited down to two amounts with no error at
/// any point, and a cashier only found out at the till, when the quick-picks
/// a shop meant to keep were not there. Every amount this widget produces
/// was typed into its own field and parsed as a number before it could ever
/// reach the list, so there is nothing left for a save to reject.
class IntegrationAmountListField extends StatelessWidget {
  const IntegrationAmountListField({
    super.key,
    required this.label,
    required this.helper,
    required this.icon,
    required this.amounts,
    required this.enabled,
    required this.onManage,
  });

  final String label;
  final String helper;
  final IconData icon;

  /// Current amounts, as plain decimal strings (``"45"``, not ``"45.00"``).
  final List<String> amounts;
  final bool enabled;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final borderColor = enabled
        ? colors.line
        : colors.line.withValues(alpha: 0.55);
    final foregroundColor = enabled ? colors.ink : colors.mutedInk;

    return DecoratedBox(
      key: const ValueKey('integration_amount_list_field'),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: colors.primaryStrong),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foregroundColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        helper,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonalIcon(
                  key: const ValueKey('manage_integration_amount_list_button'),
                  onPressed: enabled ? onManage : null,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(l10n.integrationAmountListManageButton),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (amounts.isEmpty)
              PointyInlineMessage(
                message: l10n.integrationAmountListEmptyMessage,
                icon: Icons.info_outline,
                compact: true,
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final amount in amounts)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(formatMoney(double.tryParse(amount) ?? 0)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Opens the add/remove dialog; resolves the new list, or ``null`` if the
/// owner cancelled.
Future<List<String>?> showIntegrationAmountListDialog({
  required BuildContext context,
  required String title,
  required String description,
  required List<String> initialAmounts,
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (context) => _IntegrationAmountListDialog(
      title: title,
      description: description,
      initialAmounts: initialAmounts,
    ),
  );
}

class _IntegrationAmountListDialog extends StatefulWidget {
  const _IntegrationAmountListDialog({
    required this.title,
    required this.description,
    required this.initialAmounts,
  });

  final String title;
  final String description;
  final List<String> initialAmounts;

  @override
  State<_IntegrationAmountListDialog> createState() =>
      _IntegrationAmountListDialogState();
}

class _IntegrationAmountListDialogState
    extends State<_IntegrationAmountListDialog> {
  late final TextEditingController _amountController;
  late List<String> _amounts;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController();
    _amounts = _sorted(widget.initialAmounts);
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  /// De-duplicated by numeric value (``"45"`` and ``"45.0"`` are the same
  /// quick-pick) and sorted as numbers — never as strings, where "100" would
  /// sort before "20".
  static List<String> _sorted(Iterable<String> values) {
    final parsed = <double>{
      for (final value in values)
        if (double.tryParse(value) != null) double.parse(value),
    }.toList()..sort();
    return parsed.map(_plain).toList(growable: false);
  }

  static String _plain(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.standard,
      child: AlertDialog(
        icon: const Icon(Icons.payments_outlined),
        title: Text(widget.title),
        // AlertDialog does not scroll its content on its own, and this one's
        // height is the description plus the input row plus up to 240px of
        // list — comfortably more than some window has to give on a small
        // screen or a long description. Scrolling here means that overflows
        // rather than clipping something the owner needed to read or tap.
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.description),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 420;
                    final input = TextFormField(
                      key: const ValueKey('integration_amount_field'),
                      controller: _amountController,
                      autofocus: true,
                      textDirection: TextDirection.ltr,
                      textInputAction: TextInputAction.done,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [DecimalTextInputFormatter()],
                      onChanged: (_) {
                        if (_error != null) setState(() => _error = null);
                      },
                      onFieldSubmitted: (_) => _add(l10n),
                      decoration: InputDecoration(
                        labelText: l10n.integrationAmountListFieldLabel,
                        hintText: l10n.integrationAmountListFieldHint,
                        errorText: _error,
                        prefixIcon: const Icon(Icons.payments_outlined),
                      ),
                    );
                    final addButton = FilledButton.tonalIcon(
                      key: const ValueKey('add_integration_amount_button'),
                      onPressed: () => _add(l10n),
                      icon: const Icon(Icons.add),
                      label: Text(l10n.integrationAmountListAddButton),
                    );

                    if (isCompact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          input,
                          const SizedBox(height: 10),
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: addButton,
                          ),
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: input),
                        const SizedBox(width: 10),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: addButton,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                if (_amounts.isEmpty)
                  PointyInlineMessage(
                    message: l10n.integrationAmountListEmptyMessage,
                    icon: Icons.info_outline,
                    compact: true,
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _amounts.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final amount = _amounts[index];
                        return _EditableAmountRow(
                          amount: amount,
                          onRemove: () => _remove(amount),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('integration_amount_list_cancel_button'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            key: const ValueKey('integration_amount_list_done_button'),
            onPressed: () => Navigator.of(context).pop(_amounts),
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
    );
  }

  void _add(AppLocalizations l10n) {
    final raw = _amountController.text.trim().replaceAll(',', '.');
    final value = double.tryParse(raw);
    if (value == null || value <= 0) {
      setState(() => _error = l10n.integrationAmountListInvalidError);
      return;
    }
    final normalized = _plain(value);
    if (_amounts.contains(normalized)) {
      setState(() => _error = l10n.integrationAmountListDuplicateError);
      return;
    }
    setState(() {
      _amounts = _sorted([..._amounts, normalized]);
      _error = null;
      _amountController.clear();
    });
  }

  void _remove(String amount) {
    setState(() {
      _amounts = _amounts
          .where((current) => current != amount)
          .toList(growable: false);
    });
  }
}

class _EditableAmountRow extends StatelessWidget {
  const _EditableAmountRow({required this.amount, required this.onRemove});

  final String amount;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final formatted = formatMoney(double.tryParse(amount) ?? 0);

    return Material(
      color: context.pointyColors.surfaceSunken.withValues(alpha: 0.38),
      borderRadius: BorderRadius.circular(8),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.payments_outlined),
        title: Text(formatted),
        trailing: IconButton(
          key: ValueKey('remove_integration_amount_$amount'),
          tooltip: l10n.removeIntegrationAmountTooltip(formatted),
          onPressed: onRemove,
          icon: const Icon(Icons.delete_outline),
        ),
      ),
    );
  }
}
