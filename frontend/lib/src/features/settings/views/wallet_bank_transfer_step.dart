import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/wallet.dart';
import '../../../data/services/file_dialogs.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/bank_mark.dart';
import '../../../shared/payments/bank_picker_field.dart';
import '../../../shared/payments/libyan_banks.dart';
import '../../../shared/responsive/responsive.dart';
import '../../companion/companion_scope.dart';
import '../../companion/views/companion_capture_sheet.dart';
import '../view_models/wallet_bank_transfer_view_model.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_bank_transfer_parts.dart';
import 'wallet_presentation.dart';

/// The bank-transfer step: send the money to our account, say which account
/// it came from (one tap when it was used before), attach the receipt — from
/// this device, or straight from the owner's phone — and send it for the
/// company's team to check.
class WalletBankTransferStep extends StatefulWidget {
  const WalletBankTransferStep({super.key, required this.viewModel});

  final WalletViewModel viewModel;

  @override
  State<WalletBankTransferStep> createState() => _WalletBankTransferStepState();
}

class _WalletBankTransferStepState extends State<WalletBankTransferStep> {
  final _iban = TextEditingController();
  final _account = TextEditingController();
  bool _triedToSend = false;

  WalletBankTransferViewModel get _transfer => widget.viewModel.transfer;

  @override
  void initState() {
    super.initState();
    _syncFields();
    _transfer.addListener(_syncFields);
  }

  @override
  void dispose() {
    _transfer.removeListener(_syncFields);
    _iban.dispose();
    _account.dispose();
    super.dispose();
  }

  /// A saved account, or the account number read off the IBAN, fills the
  /// fields without fighting the owner's typing.
  void _syncFields() {
    if (_iban.text.replaceAll(' ', '').toUpperCase() != _transfer.payerIban) {
      _iban.text = _transfer.payerIban;
    }
    if (_account.text != _transfer.payerAccount) {
      _account.text = _transfer.payerAccount;
    }
  }

  Future<void> _pickFile() async {
    final l10n = AppLocalizations.of(context)!;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'heic', 'pdf'],
    );
    if (file == null || !mounted) {
      return;
    }
    final bytes = await readPickedBytes(file);
    if (!mounted) {
      return;
    }
    if (bytes == null) {
      _snack(l10n.walletTransferReceiptUnreadable);
      return;
    }
    _transfer.attachReceipt(
      WalletTransferReceipt.file(
        bytes: bytes,
        name: file.name,
        contentType: _contentType(file.name, bytes),
      ),
    );
  }

  /// Asks the paired phone for the receipt: its page offers the camera, the
  /// photo library and its files, and a PDF arrives as it is.
  Future<void> _fromPhone() async {
    final l10n = AppLocalizations.of(context)!;
    final amount = widget.viewModel.transferAmount ?? 0;
    final attachmentId = await showCompanionCaptureSheet(
      context,
      prompt: l10n.walletTransferReceiptPhonePrompt(formatWalletMoney(amount)),
      acceptDocuments: true,
    );
    if (attachmentId == null || !mounted) {
      return;
    }
    final repository = CompanionScope.maybeOf(context)?.repository;
    final preview = repository == null
        ? null
        : await repository.downloadCapture(attachmentId);
    if (!mounted) {
      return;
    }
    final bytes = switch (preview) {
      Ok(value: final value) => value,
      _ => null,
    };
    _transfer.attachReceipt(
      WalletTransferReceipt.fromPhone(
        attachmentId: attachmentId,
        contentType: bytes == null ? '' : _contentType('', bytes),
        previewBytes: bytes,
      ),
    );
  }

  Future<void> _send() async {
    setState(() => _triedToSend = true);
    if (!_transfer.canSend) {
      return;
    }
    await _transfer.send(
      amount: widget.viewModel.transferAmountText(),
      recordAsExpense: widget.viewModel.recordAsExpense,
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    // A till asks its paired phone; the app on a phone picks the file itself.
    final onPhone =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final hasPhone = !onPhone && CompanionScope.maybeOf(context) != null;

    return ListenableBuilder(
      listenable: _transfer,
      builder: (context, _) {
        final transfer = _transfer;
        final account = transfer.account;
        final sending = transfer.isSending;
        final error = transfer.error;
        final receipt = transfer.receipt;
        final progress = transfer.progress;

        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    spacing.md,
                    spacing.md,
                    spacing.md,
                    0,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (error != null) ...[
                        PointyInlineMessage.error(
                          message: walletExceptionMessage(l10n, error),
                          compact: true,
                        ),
                        SizedBox(height: spacing.sm),
                      ],
                      if (account != null)
                        WalletTransferSendTo(
                          account: account,
                          amount: widget.viewModel.transferAmount ?? 0,
                          channel: transfer.channel,
                          onChannel: transfer.selectChannel,
                          enabled: !sending,
                        ),
                      SizedBox(height: spacing.lg),
                      Text(
                        l10n.walletTransferFromTitle,
                        style: textTheme.titleSmall,
                      ),
                      Text(
                        l10n.walletTransferFromHint,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                      if (transfer.savedPayers.isNotEmpty) ...[
                        SizedBox(height: spacing.sm),
                        Wrap(
                          spacing: spacing.xs,
                          runSpacing: spacing.xs,
                          children: [
                            for (final payer in transfer.savedPayers)
                              _SavedPayerChip(
                                payer: payer,
                                selected:
                                    payer.iban == transfer.payerIban &&
                                    payer.bank == transfer.payerBank,
                                onTap: sending
                                    ? null
                                    : () => transfer.useSavedPayer(payer),
                              ),
                          ],
                        ),
                      ],
                      SizedBox(height: spacing.sm),
                      BankPickerField(
                        label: l10n.walletTransferPayerBank,
                        selectedSlug: transfer.payerBank,
                        enabled: !sending,
                        onChanged: transfer.setPayerBank,
                        errorText: _triedToSend && transfer.payerBank.isEmpty
                            ? l10n.walletTransferPayerBankRequired
                            : null,
                      ),
                      SizedBox(height: spacing.sm),
                      TextField(
                        controller: _iban,
                        enabled: !sending,
                        textDirection: TextDirection.ltr,
                        textCapitalization: TextCapitalization.characters,
                        autocorrect: false,
                        onChanged: transfer.setPayerIban,
                        decoration: InputDecoration(
                          labelText: l10n.walletTransferIban,
                          hintText: 'LY…',
                          prefixIcon: const Icon(
                            Icons.account_balance_outlined,
                          ),
                          helperText: l10n.walletTransferPayerIbanHint,
                          errorText:
                              (_triedToSend ||
                                      transfer.payerIban.length >= 25) &&
                                  !transfer.ibanValid
                              ? l10n.walletTransferIbanInvalid
                              : null,
                        ),
                      ),
                      SizedBox(height: spacing.sm),
                      TextField(
                        controller: _account,
                        enabled: !sending,
                        textDirection: TextDirection.ltr,
                        keyboardType: TextInputType.number,
                        onChanged: transfer.setPayerAccount,
                        decoration: InputDecoration(
                          labelText: l10n.walletTransferAccountNumber,
                          prefixIcon: const Icon(Icons.numbers),
                          errorText: _triedToSend && !transfer.accountValid
                              ? l10n.walletTransferAccountInvalid
                              : null,
                        ),
                      ),
                      SizedBox(height: spacing.lg),
                      Text(
                        l10n.walletTransferReceiptTitle,
                        style: textTheme.titleSmall,
                      ),
                      Text(
                        l10n.walletTransferReceiptHint,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                      SizedBox(height: spacing.sm),
                      if (receipt != null)
                        WalletReceiptTile(
                          receipt: receipt,
                          onRemove: sending ? null : transfer.removeReceipt,
                        )
                      else
                        Wrap(
                          spacing: spacing.sm,
                          runSpacing: spacing.xs,
                          children: [
                            if (hasPhone)
                              FilledButton.tonalIcon(
                                onPressed: sending ? null : _fromPhone,
                                icon: const Icon(Icons.phone_iphone),
                                label: Text(
                                  l10n.walletTransferReceiptFromPhone,
                                ),
                              ),
                            OutlinedButton.icon(
                              onPressed: sending ? null : _pickFile,
                              icon: const Icon(Icons.upload_file),
                              label: Text(l10n.walletTransferReceiptFromDevice),
                            ),
                          ],
                        ),
                      if (_triedToSend && receipt == null)
                        Padding(
                          padding: EdgeInsets.only(top: spacing.xs),
                          child: Text(
                            l10n.walletTransferReceiptRequired,
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.danger,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (progress != null)
                PointyProgressBar(value: progress > 0 ? progress : null),
              Padding(
                padding: EdgeInsets.all(spacing.md),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: sending
                          ? null
                          : widget.viewModel.backToTopUpForm,
                      child: Text(l10n.walletTransferBack),
                    ),
                    SizedBox(width: spacing.sm),
                    FilledButton.icon(
                      onPressed: sending ? null : _send,
                      icon: sending
                          ? const SizedBox.square(
                              dimension: 16,
                              child: PointySpinner(strokeWidth: 2),
                            )
                          : const Icon(Icons.send),
                      label: Text(
                        sending
                            ? l10n.walletTransferSending(
                                ((progress ?? 0) * 100).round(),
                              )
                            : l10n.walletTransferSend,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SavedPayerChip extends StatelessWidget {
  const _SavedPayerChip({
    required this.payer,
    required this.selected,
    required this.onTap,
  });

  final WalletPayerAccount payer;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bank = bankForSlug(payer.bank);
    return ChoiceChip(
      selected: selected,
      onSelected: onTap == null ? null : (_) => onTap!(),
      avatar: bank == null ? null : BankLogo(bank: bank, size: 22),
      label: Text(
        '${bank?.arabicName ?? payer.bank} · ${ltrIsolated(LibyanIban.masked(payer.iban))}',
      ),
    );
  }
}

/// A receipt's type from its bytes: a PDF says so in its first five; a photo
/// is whatever the name says, and the server decides for itself either way.
String _contentType(String name, List<int> bytes) {
  if (bytes.length >= 5 &&
      bytes[0] == 0x25 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x44 &&
      bytes[3] == 0x46 &&
      bytes[4] == 0x2D) {
    return 'application/pdf';
  }
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.heic')) return 'image/heic';
  return 'image/jpeg';
}
