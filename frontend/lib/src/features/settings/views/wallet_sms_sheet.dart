import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_presentation.dart';
import 'wallet_top_up_sheet.dart';

/// What the transfer sheet came to.
enum _SmsSheetResult { moved, topUpFirst }

/// The one-tap amounts offered, when the wallet holds them.
const _quickAmounts = [5.0, 10.0, 20.0, 50.0];

/// Move money from the main wallet into the SMS balance, which every message
/// is then paid from. The sheet says what the wallet holds, what a message
/// costs and how many messages the amount pays for; a wallet that cannot pay
/// for one message is sent to top up first. True once the money moved.
Future<bool> showSmsAllocationSheet({
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
  final result = await showAdaptiveFormSurface<_SmsSheetResult>(
    context: context,
    title: l10n.walletSmsAllocateTitle,
    builder: (_) => SmsAllocationForm(wallet: wallet, onMoved: moved.add),
  );
  if (!context.mounted) {
    return result == _SmsSheetResult.moved;
  }
  switch (result) {
    case _SmsSheetResult.moved:
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.walletSmsAllocateDone(
              formatWalletMoney(moved.firstOrNull ?? 0),
            ),
          ),
        ),
      );
      return true;
    case _SmsSheetResult.topUpFirst:
      await showWalletTopUpSheet(context: context, viewModel: wallet);
      return false;
    case null:
      return false;
  }
}

class SmsAllocationForm extends StatefulWidget {
  const SmsAllocationForm({super.key, required this.wallet, this.onMoved});

  final WalletViewModel wallet;

  /// Told the amount once it moved, before the sheet closes.
  final ValueChanged<double>? onMoved;

  @override
  State<SmsAllocationForm> createState() => _SmsAllocationFormState();
}

class _SmsAllocationFormState extends State<SmsAllocationForm> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();

  /// Once a submit was refused, every keystroke re-checks the amount, so the
  /// error goes the moment it is fixed (and the message count comes back).
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
    _amount.text = walletAmountText(amount, 3);
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
    final ok = await widget.wallet.spending.allocateToSms(amount);
    if (ok && mounted) {
      widget.onMoved?.call(amount);
      Navigator.of(context).pop(_SmsSheetResult.moved);
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
        final sms = overview.sms;
        final price = sms?.price ?? 0;
        final balance = overview.balance ?? 0;
        final busy = wallet.spending.isAllocating;
        final error = wallet.spending.allocationError;
        final typed = parseWalletAmount(_amount.text);
        final canAffordOne = price > 0 && balance + 0.0005 >= price;
        final quick = [
          for (final amount in _quickAmounts)
            if (amount >= price && amount <= balance) amount,
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
                          l10n.walletSmsAllocateIntro(formatWalletMoney(price)),
                          style: textTheme.bodyMedium?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                        SizedBox(height: spacing.sm),
                        _BalanceLine(
                          icon: Icons.account_balance_wallet_outlined,
                          text: l10n.walletSmsAllocateAvailable(
                            formatWalletMoney(balance),
                          ),
                        ),
                        if (sms != null) ...[
                          SizedBox(height: spacing.xs),
                          _BalanceLine(
                            icon: Icons.sms_outlined,
                            text:
                                '${l10n.walletSmsBalanceTitle}: '
                                '${formatWalletMoney(sms.balance)}',
                          ),
                        ],
                        SizedBox(height: spacing.md),
                        if (!canAffordOne)
                          PointyDetailCallout(
                            icon: Icons.account_balance_wallet_outlined,
                            tone: PointyCalloutTone.warning,
                            title: l10n.walletSpendTopUpFirstTitle,
                            message: l10n.walletSpendTopUpFirstMessage,
                            trailing: overview.canTopUp
                                ? TextButton(
                                    onPressed: () => Navigator.of(
                                      context,
                                    ).pop(_SmsSheetResult.topUpFirst),
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
                            key: const ValueKey('sms_allocation_amount'),
                            controller: _amount,
                            autofocus: true,
                            enabled: !busy,
                            autovalidateMode: _checking
                                ? AutovalidateMode.always
                                : AutovalidateMode.disabled,
                            // Typed left to right, shown on the right like the
                            // rest of the Arabic form (the top-up field does
                            // the same).
                            textDirection: TextDirection.ltr,
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [WalletAmountFormatter(3)],
                            style: PointyTypography.numeric(
                              (textTheme.headlineSmall ?? const TextStyle())
                                  .copyWith(fontWeight: FontWeight.w800),
                            ),
                            decoration: InputDecoration(
                              labelText: l10n.walletSmsAllocateAmountLabel,
                              prefixIcon: const Icon(Icons.payments_outlined),
                              suffixText: currencySymbol,
                              helperText: typed == null || typed <= 0
                                  ? null
                                  : l10n.walletSmsMessagesLeft(
                                      sms?.messagesFor(typed) ?? 0,
                                    ),
                            ),
                            onFieldSubmitted: (_) => _submit(),
                            validator: (value) {
                              final amount = parseWalletAmount(value ?? '');
                              if (amount == null || amount <= 0) {
                                return l10n.walletTopUpAmountRequired;
                              }
                              if (amount + 0.0005 < price) {
                                return l10n.walletSmsAllocateTooLittle(
                                  formatWalletMoney(price),
                                );
                              }
                              if (amount > balance + 0.0005) {
                                return l10n.walletSmsAllocateTooMuch;
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
                                  label: Text(l10n.walletSmsAllocateAll),
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
                        key: const ValueKey('sms_allocation_confirm'),
                        onPressed: busy || !canAffordOne ? null : _submit,
                        icon: busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: PointySpinner(strokeWidth: 2),
                              )
                            : const Icon(Icons.swap_horiz),
                        label: Text(
                          typed != null && typed > 0
                              ? l10n.walletSmsAllocateConfirm(
                                  formatWalletMoney(typed),
                                )
                              : l10n.walletSmsAllocateButton,
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

class _BalanceLine extends StatelessWidget {
  const _BalanceLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: colors.mutedInk),
        SizedBox(width: spacing.xs),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
