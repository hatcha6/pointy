import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_presentation.dart';
import 'wallet_rows.dart';
import 'wallet_top_up_sheet.dart';

/// What the transfer sheet came to.
enum _VoucherSheetResult { moved, topUpFirst }

/// The one-tap amounts offered, when the wallet holds them. Cards cost tens
/// of dinars, so these are larger than the SMS sheet's.
const _quickAmounts = [50.0, 100.0, 200.0, 500.0];

/// Move money from the main wallet into the voucher balance, which every
/// «كروت دفتر» card the till sells is paid from. The sheet says what the
/// wallet holds and what the voucher balance will hold after; a wallet with
/// nothing in it is sent to top up first. True once the money moved.
Future<bool> showVoucherAllocationSheet({
  required BuildContext context,
  required WalletViewModel wallet,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  wallet.spending.beginAllocation();
  if (wallet.overview == null && !wallet.isLoading) {
    unawaited(wallet.load());
  }
  final moved = <double>[];
  final result = await showAdaptiveFormSurface<_VoucherSheetResult>(
    context: context,
    title: l10n.walletVouchersAllocateTitle,
    builder: (_) => VoucherAllocationForm(wallet: wallet, onMoved: moved.add),
  );
  if (!context.mounted) {
    return result == _VoucherSheetResult.moved;
  }
  switch (result) {
    case _VoucherSheetResult.moved:
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.walletVouchersAllocateDone(
              formatWalletMoney(moved.firstOrNull ?? 0),
            ),
          ),
        ),
      );
      return true;
    case _VoucherSheetResult.topUpFirst:
      await showWalletTopUpSheet(context: context, viewModel: wallet);
      return false;
    case null:
      return false;
  }
}

class VoucherAllocationForm extends StatefulWidget {
  const VoucherAllocationForm({super.key, required this.wallet, this.onMoved});

  final WalletViewModel wallet;

  /// Told the amount once it moved, before the sheet closes.
  final ValueChanged<double>? onMoved;

  @override
  State<VoucherAllocationForm> createState() => _VoucherAllocationFormState();
}

class _VoucherAllocationFormState extends State<VoucherAllocationForm> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();

  /// Once a submit was refused, every keystroke re-checks the amount, so the
  /// error goes the moment it is fixed.
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _amount.addListener(_redraw);
  }

  @override
  void dispose() {
    _amount
      ..removeListener(_redraw)
      ..dispose();
    super.dispose();
  }

  void _redraw() => setState(() {});

  void _pick(double amount) {
    _amount.text = walletAmountText(amount, 2);
    _formKey.currentState?.validate();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      setState(() => _checking = true);
      return;
    }
    final amount = parseWalletAmount(_amount.text);
    if (amount == null) {
      return;
    }
    final ok = await widget.wallet.spending.allocateToVouchers(amount);
    if (ok && mounted) {
      widget.onMoved?.call(amount);
      Navigator.of(context).pop(_VoucherSheetResult.moved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = widget.wallet;
    return ListenableBuilder(
      listenable: Listenable.merge([wallet, wallet.spending]),
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final spacing = AdaptiveSpacing.of(context);
        final colors = context.pointyColors;
        final textTheme = Theme.of(context).textTheme;
        final overview = wallet.overview;
        if (overview == null) {
          return Padding(
            padding: EdgeInsets.all(spacing.lg),
            child: const Center(
              child: SizedBox.square(dimension: 28, child: PointySpinner()),
            ),
          );
        }
        final vouchers = overview.vouchers;
        final balance = overview.balance ?? 0;
        final busy = wallet.spending.isAllocating;
        final error = wallet.spending.allocationError;
        final typed = parseWalletAmount(_amount.text);
        // A dirham is the least a transfer can move.
        final hasMoney = balance >= 0.01;
        final ready = vouchers?.configured ?? false;
        final quick = [
          for (final amount in _quickAmounts)
            if (amount <= balance) amount,
        ];

        return Form(
          key: _formKey,
          child: Padding(
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
                        Text(
                          l10n.walletVouchersAllocateIntro,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                        SizedBox(height: spacing.sm),
                        WalletBalanceLine(
                          icon: Icons.account_balance_wallet_outlined,
                          text: l10n.walletVouchersAllocateAvailable(
                            formatWalletMoney(balance),
                          ),
                        ),
                        if (vouchers != null) ...[
                          SizedBox(height: spacing.xs),
                          WalletBalanceLine(
                            icon: Icons.card_giftcard_outlined,
                            text: l10n.walletVouchersAllocateCurrent(
                              formatWalletMoney(vouchers.balance),
                            ),
                          ),
                        ],
                        SizedBox(height: spacing.md),
                        if (!ready)
                          PointyInlineMessage.warning(
                            message: l10n.walletVouchersNotReady,
                            compact: true,
                          )
                        else if (!hasMoney)
                          PointyDetailCallout(
                            icon: Icons.account_balance_wallet_outlined,
                            tone: PointyCalloutTone.warning,
                            title: l10n.walletSpendTopUpFirstTitle,
                            message: l10n.walletSpendTopUpFirstMessage,
                            trailing: overview.canTopUp
                                ? TextButton(
                                    onPressed: () => Navigator.of(
                                      context,
                                    ).pop(_VoucherSheetResult.topUpFirst),
                                    child: Text(l10n.walletTopUpButton),
                                  )
                                : null,
                          )
                        else ...[
                          if (error != null) ...[
                            PointyInlineMessage.error(
                              message: walletExceptionMessage(l10n, error),
                              compact: true,
                            ),
                            SizedBox(height: spacing.sm),
                          ],
                          TextFormField(
                            key: const ValueKey('voucher_allocation_amount'),
                            controller: _amount,
                            autofocus: true,
                            enabled: !busy,
                            autovalidateMode: _checking
                                ? AutovalidateMode.always
                                : AutovalidateMode.disabled,
                            // Typed left to right, shown on the right like the
                            // rest of the Arabic form.
                            textDirection: TextDirection.ltr,
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [WalletAmountFormatter(2)],
                            style: PointyTypography.numeric(
                              (textTheme.headlineSmall ?? const TextStyle())
                                  .copyWith(fontWeight: FontWeight.w800),
                            ),
                            decoration: InputDecoration(
                              labelText: l10n.walletVouchersAllocateAmountLabel,
                              prefixIcon: const Icon(Icons.payments_outlined),
                              suffixText: currencySymbol,
                              helperText: typed == null || typed <= 0
                                  ? null
                                  : l10n.walletVouchersAllocateAfter(
                                      formatWalletMoney(
                                        (vouchers?.balance ?? 0) + typed,
                                      ),
                                    ),
                            ),
                            onFieldSubmitted: (_) => _submit(),
                            validator: (value) {
                              final amount = parseWalletAmount(value ?? '');
                              if (amount == null || amount <= 0) {
                                return l10n.walletTopUpAmountRequired;
                              }
                              if (amount > balance + 0.0005) {
                                return l10n.walletVouchersAllocateTooMuch;
                              }
                              return null;
                            },
                          ),
                          SizedBox(height: spacing.sm),
                          Wrap(
                            spacing: spacing.xs,
                            runSpacing: spacing.xs,
                            children: [
                              for (final amount in quick)
                                ActionChip(
                                  label: Text(
                                    formatWalletMoney(amount),
                                    style: PointyTypography.numeric(
                                      const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  onPressed: busy ? null : () => _pick(amount),
                                ),
                              if (!quick.contains(balance))
                                ActionChip(
                                  avatar: const Icon(
                                    Icons.select_all,
                                    size: 18,
                                  ),
                                  label: Text(l10n.walletVouchersAllocateAll),
                                  onPressed: busy ? null : () => _pick(balance),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(spacing.md),
                  child: OverflowBar(
                    alignment: MainAxisAlignment.end,
                    spacing: spacing.sm,
                    overflowSpacing: spacing.xs,
                    overflowAlignment: OverflowBarAlignment.end,
                    children: [
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => Navigator.of(context).maybePop(),
                        child: Text(l10n.walletSpendCancel),
                      ),
                      FilledButton.icon(
                        key: const ValueKey('voucher_allocation_confirm'),
                        onPressed: busy || !hasMoney || !ready ? null : _submit,
                        icon: busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: PointySpinner(strokeWidth: 2),
                              )
                            : const Icon(Icons.swap_horiz),
                        label: Text(
                          typed != null && typed > 0
                              ? l10n.walletVouchersAllocateConfirm(
                                  formatWalletMoney(typed),
                                )
                              : l10n.walletVouchersAllocateButton,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
