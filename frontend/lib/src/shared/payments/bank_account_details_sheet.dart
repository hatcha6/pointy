import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/money_position.dart';
import '../components/components.dart';
import '../design/design.dart';
import '../formatters.dart';
import '../responsive/responsive.dart';
import 'bank_account_row.dart';

/// The shop's own bank details, big enough to be read across a counter — and
/// as a QR the customer can point a banking app at.
///
/// This exists because of what it replaces. Today a shopkeeper taking a
/// transfer reads a 25-character IBAN out loud, digit by digit, while the
/// customer types it into their phone; the digits that get transposed are the
/// shop's problem to chase a week later. A code on screen ends that, and the
/// typed copy stays beside it because a customer standing in a basement with
/// no camera permission still has to be served.
Future<void> showBankAccountDetailsSheet(
  BuildContext context, {
  required MoneyAccount account,
}) {
  return showAdaptiveFormSurface<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (sheetContext) => _BankAccountDetailsSheet(account: account),
  );
}

/// Which number the code carries. Both are real answers: an IBAN is what a
/// transfer from another bank needs, an account number is what a transfer
/// inside the same bank is usually given.
enum _BankIdentifier { iban, accountNumber }

class _BankAccountDetailsSheet extends StatefulWidget {
  const _BankAccountDetailsSheet({required this.account});

  final MoneyAccount account;

  @override
  State<_BankAccountDetailsSheet> createState() =>
      _BankAccountDetailsSheetState();
}

class _BankAccountDetailsSheetState extends State<_BankAccountDetailsSheet> {
  late _BankIdentifier _selected = widget.account.iban.isNotEmpty
      ? _BankIdentifier.iban
      : _BankIdentifier.accountNumber;

  bool get _hasIban => widget.account.iban.isNotEmpty;
  bool get _hasAccountNumber => widget.account.accountNumber.isNotEmpty;
  bool get _hasBoth => _hasIban && _hasAccountNumber;

  String get _selectedValue => _selected == _BankIdentifier.iban
      ? widget.account.iban
      : widget.account.accountNumber;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BankAccountRow(account: widget.account.asRef, markSize: 40),
            SizedBox(height: spacing.md),
            if (!_hasIban && !_hasAccountNumber)
              PointyInlineMessage(
                key: const ValueKey('bank_account_no_identifiers'),
                icon: Icons.info_outline,
                message: l10n.bankAccountNoIdentifiers,
              )
            else ...[
              // Always both segments, even when only one number is saved.
              // Hiding the control when there was nothing to switch to left
              // an owner with an IBAN-only account unable to tell whether the
              // app could show an account-number code at all; a segment that
              // is present but greyed says the feature exists and the number
              // has simply not been entered yet.
              SegmentedButton<_BankIdentifier>(
                key: const ValueKey('bank_identifier_selector'),
                segments: [
                  ButtonSegment(
                    value: _BankIdentifier.iban,
                    label: Text(l10n.bankAccountIbanLabel),
                    enabled: _hasIban,
                  ),
                  ButtonSegment(
                    value: _BankIdentifier.accountNumber,
                    label: Text(l10n.bankAccountNumberLabel),
                    enabled: _hasAccountNumber,
                  ),
                ],
                selected: {_selected},
                onSelectionChanged: (selection) =>
                    setState(() => _selected = selection.first),
              ),
              SizedBox(height: spacing.sm),
              if (!_hasBoth)
                PointyInlineMessage(
                  key: const ValueKey('bank_identifier_missing_hint'),
                  compact: true,
                  icon: Icons.info_outline,
                  message: _hasIban
                      ? l10n.bankAccountNumberMissingHint
                      : l10n.bankAccountIbanMissingHint,
                ),
              SizedBox(height: spacing.md),
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // A quiet white plate under the code whatever the theme:
                    // an inverted QR is a QR most phone cameras will not read.
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(PointyRadii.card),
                    border: Border.all(color: colors.line),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(spacing.sm),
                    child: PointyQrImage(
                      key: ValueKey('bank_account_qr_${_selected.name}'),
                      data: _selectedValue,
                      size: 240,
                      semanticsLabel: _selected == _BankIdentifier.iban
                          ? l10n.bankAccountIbanLabel
                          : l10n.bankAccountNumberLabel,
                    ),
                  ),
                ),
              ),
              SizedBox(height: spacing.md),
              if (_hasIban)
                _IdentifierField(
                  label: l10n.bankAccountIbanLabel,
                  value: formatIban(widget.account.iban),
                  copyValue: widget.account.iban,
                ),
              if (_hasIban && _hasAccountNumber) SizedBox(height: spacing.sm),
              if (_hasAccountNumber)
                _IdentifierField(
                  label: l10n.bankAccountNumberLabel,
                  value: widget.account.accountNumber,
                  copyValue: widget.account.accountNumber,
                ),
            ],
            SizedBox(height: spacing.md),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.closeButton),
            ),
          ],
        ),
      ),
    );
  }
}

/// One number, big, LTR-isolated, with a copy button.
class _IdentifierField extends StatelessWidget {
  const _IdentifierField({
    required this.label,
    required this.value,
    required this.copyValue,
  });

  final String label;
  final String value;
  final String copyValue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 4, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // The digits are a left-to-right run inside an Arabic
                  // paragraph; without the isolate the groups reorder and the
                  // number a customer copies off the screen is not the one
                  // stored. Same trap as the price checker's "rows x cols".
                  SelectableText(
                    ltrIsolated(value),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.copyButton,
              icon: const Icon(Icons.copy_outlined),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: copyValue));
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l10n.copiedToClipboard)));
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// An IBAN in the groups of four every bank statement prints it in. Purely
/// cosmetic — the stored value never carries the spaces, so a copy and a scan
/// always agree.
String formatIban(String iban) {
  final compact = iban.replaceAll(' ', '');
  final groups = <String>[];
  for (var index = 0; index < compact.length; index += 4) {
    groups.add(compact.substring(index, (index + 4).clamp(0, compact.length)));
  }
  return groups.join(' ');
}
