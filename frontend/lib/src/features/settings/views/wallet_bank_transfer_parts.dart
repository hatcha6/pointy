import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/bank_account_details_sheet.dart';
import '../../../shared/payments/bank_mark.dart';
import '../../../shared/payments/libyan_banks.dart';
import '../../../shared/responsive/responsive.dart';
import 'wallet_presentation.dart';

/// Where to send the money, as the chosen app asks for it: LYPay takes our
/// IBAN, OnePay our bank and account number. Each number copies with one tap,
/// and the name the payer's app will show is spelled out to check against.
class WalletTransferSendTo extends StatelessWidget {
  const WalletTransferSendTo({
    super.key,
    required this.account,
    required this.amount,
    required this.channel,
    required this.onChannel,
    this.enabled = true,
  });

  final WalletBankAccount account;
  final double amount;
  final WalletTransferChannel channel;
  final ValueChanged<WalletTransferChannel> onChannel;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final bank = bankForSlug(account.bank);
    final amountText = formatWalletMoney(amount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.walletTransferSendTitle(amountText),
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        SizedBox(height: spacing.sm),
        SegmentedButton<WalletTransferChannel>(
          segments: [
            ButtonSegment(
              value: WalletTransferChannel.lyPay,
              label: Text(l10n.walletTransferChannelLyPay),
            ),
            ButtonSegment(
              value: WalletTransferChannel.onePay,
              label: Text(l10n.walletTransferChannelOnePay),
            ),
          ],
          selected: {channel},
          onSelectionChanged: enabled
              ? (selection) => onChannel(selection.first)
              : null,
          showSelectedIcon: false,
        ),
        SizedBox(height: spacing.sm),
        Text(
          channel == WalletTransferChannel.lyPay
              ? l10n.walletTransferLyPayHint
              : l10n.walletTransferOnePayHint,
          style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
        ),
        SizedBox(height: spacing.xs),
        if (channel == WalletTransferChannel.lyPay)
          BankIdentifierField(
            label: l10n.walletTransferIban,
            value: formatIban(account.iban),
            copyValue: account.iban,
          )
        else ...[
          _BankLine(
            label: l10n.walletTransferBank,
            bank: bank,
            name: account.bankName,
          ),
          SizedBox(height: spacing.xs),
          BankIdentifierField(
            label: l10n.walletTransferAccountNumber,
            value: account.accountNumber,
            copyValue: account.accountNumber,
          ),
        ],
        SizedBox(height: spacing.xs),
        BankIdentifierField(
          label: l10n.walletTransferAmount,
          value: amountText,
          copyValue: formatWalletBound(amount),
        ),
        SizedBox(height: spacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.verified_user_outlined, size: 18, color: colors.success),
            SizedBox(width: spacing.xs),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: l10n.walletTransferHolderCheck(''),
                  children: [
                    TextSpan(
                      text: account.holder,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                style: textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BankLine extends StatelessWidget {
  const _BankLine({
    required this.label,
    required this.bank,
    required this.name,
  });

  final String label;
  final LibyanBank? bank;
  final String name;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final bank = this.bank;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
        child: Row(
          children: [
            if (bank != null) ...[
              BankLogo(bank: bank, size: 32),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                  Text(
                    bank?.arabicName ?? name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The attached receipt: a thumbnail of a photo, a page for a PDF, its name
/// and size, and a way to take it off.
class WalletReceiptTile extends StatelessWidget {
  const WalletReceiptTile({
    super.key,
    required this.receipt,
    required this.onRemove,
  });

  final WalletTransferReceipt receipt;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final shown = receipt.shownBytes;
    final radius = BorderRadius.circular(PointyRadii.chip);

    Widget preview;
    if (!receipt.isPdf && shown != null && shown.isNotEmpty) {
      preview = ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          shown is Uint8List ? shown : Uint8List.fromList(shown),
          width: 64,
          height: 80,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fileIcon(colors, Icons.image_outlined),
        ),
      );
    } else {
      preview = _fileIcon(
        colors,
        receipt.isPdf ? Icons.picture_as_pdf_outlined : Icons.receipt_long,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            preview,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    receipt.fromPhone
                        ? l10n.walletTransferReceiptFromPhoneDone
                        : ltrIsolated(receipt.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if ((shown?.length ?? 0) > 0)
                    Text(
                      ltrIsolated(_size(shown!.length)),
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.walletTransferReceiptRemove,
              icon: const Icon(Icons.close),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileIcon(PointySemanticColors colors, IconData icon) {
    return Container(
      width: 64,
      height: 80,
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Icon(icon, size: 30, color: colors.primaryStrong),
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).ceil()} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
