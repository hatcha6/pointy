import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/balance_entry.dart';
import 'balance_labels.dart';
import 'responsive/responsive.dart';

/// What the opening-balance section of a create form holds. Owned by the form
/// state, so the fields can be rebuilt freely without losing what was typed.
class OpeningBalanceController {
  final amountController = TextEditingController();
  final noteController = TextEditingController();
  bool enabled = false;
  BalanceDirection direction = BalanceDirection.theyOweUs;

  /// The balance to send with the create request, or null for none. Only
  /// meaningful once the form has validated.
  OpeningBalanceDraft? get draft {
    if (!enabled) {
      return null;
    }
    final amount = double.tryParse(amountController.text.trim());
    if (amount == null || amount <= 0) {
      return null;
    }
    return OpeningBalanceDraft(
      direction: direction,
      amount: amount,
      note: noteController.text.trim(),
    );
  }

  void dispose() {
    amountController.dispose();
    noteController.dispose();
  }
}

/// The optional opening balance in the form that creates a customer or a
/// supplier: off until asked for, so the ordinary create stays as short as it
/// was.
class OpeningBalanceFields extends StatefulWidget {
  const OpeningBalanceFields({
    super.key,
    required this.controller,
    required this.party,
    this.enabled = true,
  });

  final OpeningBalanceController controller;
  final BalanceParty party;
  final bool enabled;

  @override
  State<OpeningBalanceFields> createState() => _OpeningBalanceFieldsState();
}

class _OpeningBalanceFieldsState extends State<OpeningBalanceFields> {
  OpeningBalanceController get _controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: const ValueKey('opening_balance_toggle'),
          value: _controller.enabled,
          onChanged: widget.enabled
              ? (value) => setState(() => _controller.enabled = value ?? false)
              : null,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.openingBalanceSectionTitle),
          subtitle: Text(l10n.openingBalanceSectionHint),
        ),
        if (_controller.enabled) ...[
          BalanceDirectionPicker(
            key: const ValueKey('opening_balance_direction'),
            party: widget.party,
            value: _controller.direction,
            enabled: widget.enabled,
            onChanged: (direction) =>
                setState(() => _controller.direction = direction),
          ),
          SizedBox(height: spacing.sm),
          TextFormField(
            key: const ValueKey('opening_balance_amount'),
            controller: _controller.amountController,
            enabled: widget.enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
          TextFormField(
            key: const ValueKey('opening_balance_note'),
            controller: _controller.noteController,
            enabled: widget.enabled,
            decoration: InputDecoration(
              labelText: l10n.balanceEntryNoteOptionalLabel,
            ),
          ),
          SizedBox(height: spacing.sm),
        ],
      ],
    );
  }
}

/// "عليه لنا" / "له علينا", with a line underneath saying what that means on
/// this party's account.
class BalanceDirectionPicker extends StatelessWidget {
  const BalanceDirectionPicker({
    super.key,
    required this.party,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final BalanceParty party;
  final BalanceDirection value;
  final ValueChanged<BalanceDirection> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<BalanceDirection>(
          segments: [
            for (final direction in BalanceDirection.values)
              ButtonSegment(
                value: direction,
                icon: Icon(balanceDirectionIcon(direction)),
                label: Text(balanceDirectionLabel(l10n, direction)),
              ),
          ],
          selected: {value},
          onSelectionChanged: enabled
              ? (selection) => onChanged(selection.first)
              : null,
        ),
        SizedBox(height: spacing.xs),
        Text(
          balanceDirectionHint(l10n, party, value),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// A balance amount must be a number above zero.
String? validateBalanceAmount(AppLocalizations l10n, String? value) {
  final amount = double.tryParse((value ?? '').trim());
  if (amount == null || amount <= 0) {
    return l10n.balanceEntryAmountInvalid;
  }
  return null;
}
