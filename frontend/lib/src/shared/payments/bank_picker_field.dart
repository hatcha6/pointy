import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../components/components.dart';
import '../design/design.dart';
import '../responsive/responsive.dart';
import 'bank_mark.dart';
import 'libyan_banks.dart';

/// "Which bank is this account with?" — answered by pointing at a logo.
///
/// A dropdown of twenty-five Arabic bank names is a wall of text in which the
/// one a shopkeeper is looking for is indistinguishable from its four
/// neighbours; the mark is how they actually recognise their own bank, and it
/// is already in the bundle. So the field shows the chosen bank's mark, and
/// opens a searchable list of marks rather than a menu of strings.
class BankPickerField extends StatelessWidget {
  const BankPickerField({
    super.key,
    required this.selectedSlug,
    required this.onChanged,
    this.enabled = true,
  });

  /// The Central Bank slug, or blank for "not said". Blank is a legitimate
  /// answer and stays available: an account at a bank this build does not
  /// carry is still an account, and its typed name carries it.
  final String selectedSlug;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final bank = selectedSlug.isEmpty ? null : bankForSlug(selectedSlug);

    return InkWell(
      key: const ValueKey('bank_picker_field'),
      onTap: enabled ? () => _pick(context) : null,
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: l10n.treasuryAccountBankLabel,
          suffixIcon: const Icon(Icons.expand_more),
          enabled: enabled,
        ),
        child: bank == null
            ? Text(
                l10n.treasuryAccountBankUnset,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.mutedInk,
                ),
              )
            : BankMark(bank: bank, size: 26),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _BankPickerSheet(selectedSlug: selectedSlug),
    );
    if (chosen != null) {
      onChanged(chosen);
    }
  }
}

class _BankPickerSheet extends StatefulWidget {
  const _BankPickerSheet({required this.selectedSlug});

  final String selectedSlug;

  @override
  State<_BankPickerSheet> createState() => _BankPickerSheetState();
}

class _BankPickerSheetState extends State<_BankPickerSheet> {
  final _queryController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  /// Matches on either name. A shopkeeper types Arabic; an accountant
  /// reconciling against a statement types "Jumhouria".
  List<LibyanBank> get _matches {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) {
      return libyanBanks;
    }
    return libyanBanks
        .where(
          (bank) =>
              bank.arabicName.contains(needle) ||
              bank.englishName.toLowerCase().contains(needle) ||
              bank.slug.contains(needle),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final matches = _matches;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                spacing.md,
                spacing.md,
                spacing.md,
                spacing.sm,
              ),
              child: TextField(
                key: const ValueKey('bank_picker_search'),
                controller: _queryController,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: l10n.treasuryAccountBankSearchHint,
                  prefixIcon: const Icon(Icons.search),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                // +1 for the "no bank" row, which must stay reachable: it is
                // how an account is un-set, and how a shop records one at a
                // bank the register does not list.
                itemCount: matches.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ListTile(
                      key: const ValueKey('bank_picker_unset'),
                      leading: const Icon(Icons.block_outlined),
                      title: Text(l10n.treasuryAccountBankUnset),
                      selected: widget.selectedSlug.isEmpty,
                      onTap: () => Navigator.of(context).pop(''),
                    );
                  }
                  final bank = matches[index - 1];
                  return ListTile(
                    key: ValueKey('bank_picker_${bank.slug}'),
                    leading: BankLogo(bank: bank, size: 32),
                    title: Text(bank.arabicName),
                    subtitle: Text(bank.englishName),
                    selected: bank.slug == widget.selectedSlug,
                    onTap: () => Navigator.of(context).pop(bank.slug),
                  );
                },
              ),
            ),
            if (matches.isEmpty)
              Padding(
                padding: EdgeInsets.all(spacing.md),
                child: PointyInlineMessage(
                  icon: Icons.search_off,
                  message: l10n.treasuryAccountBankUnset,
                  compact: true,
                ),
              ),
            SizedBox(height: spacing.sm),
          ],
        ),
      ),
    );
  }
}
