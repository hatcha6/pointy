import 'package:flutter/material.dart';

import '../../data/models/bank_account_ref.dart';
import '../design/design.dart';
import 'bank_mark.dart';
import 'libyan_banks.dart';

/// "الجمهورية · حساب المحل" — one line saying which bank took the money.
///
/// The single way a bank account is written anywhere in the app: the invoice
/// details screen, the purchase order, the money position card, the terminal
/// settings row and the checkout picker all draw this, so an owner never has
/// to work out whether two surfaces mean the same account.
///
/// Two things degrade independently, and neither is ever an error:
///
/// * **no slug, or a slug this build does not carry** — the mark is dropped and
///   the names stay. The marks are bank trademarks, added deliberately, and a
///   build without them must still be readable.
/// * **no bank name at all** — the account's own name stands alone. A shop that
///   called its account "الحساب الرئيسي" and never picked a bank has said
///   everything it wanted to say.
class BankAccountRow extends StatelessWidget {
  const BankAccountRow({
    super.key,
    required this.account,
    this.markSize = 24,
    this.compact = false,
    this.trailing,
  });

  final BankAccountRef account;

  final double markSize;

  /// Puts the bank's name on the same line as the account's, for a dense row
  /// (a payment line, a settings row) rather than a card.
  final bool compact;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final bank = account.bankSlug.isEmpty
        ? null
        : bankForSlug(account.bankSlug);
    // The bank's own spelling when we recognise it, the shop's when we do not.
    // Never both: a row reading "مصرف الجمهورية · الجمهورية" is the same word
    // twice, which is how a shop learns to stop reading this line.
    final bankLabel = bank?.arabicName ?? account.bankName;
    final showBankLabel =
        bankLabel.isNotEmpty && bankLabel != account.displayName;

    final names = compact
        ? Text(
            showBankLabel
                ? '${account.displayName} · $bankLabel'
                : account.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.ink,
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                account.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colors.ink,
                ),
              ),
              if (showBankLabel)
                Text(
                  bankLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
            ],
          );

    return Row(
      children: [
        if (bank != null) ...[
          BankLogo(bank: bank, size: markSize),
          const SizedBox(width: 8),
        ] else ...[
          Icon(
            Icons.account_balance_outlined,
            size: markSize * 0.8,
            color: colors.mutedInk,
          ),
          const SizedBox(width: 8),
        ],
        Expanded(child: names),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}
