import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_code_step.dart';
import 'wallet_method_picker.dart';
import 'wallet_payer_dialog.dart';
import 'wallet_presentation.dart';
import 'wallet_top_up_outcome.dart';

/// Top up the Daftar wallet: pick an amount and a way to pay, press pay, then
/// either give the payer's number in a dialog and type the code the provider
/// texts them, or pay on the gateway's page in the browser and watch the sheet
/// turn into the verdict by itself. Closing it while a bank-card payer is
/// still paying loses nothing: the relay credits whatever the gateway proves,
/// and the shop's backend books it.
Future<void> showWalletTopUpSheet({
  required BuildContext context,
  required WalletViewModel viewModel,
}) async {
  final l10n = AppLocalizations.of(context)!;
  viewModel.beginTopUp();
  await showAdaptiveFormSurface<void>(
    context: context,
    title: l10n.walletTopUpSheetTitle,
    builder: (sheetContext) => WalletTopUpFlow(viewModel: viewModel),
  );
  viewModel.endTopUp();
}

class WalletTopUpFlow extends StatefulWidget {
  const WalletTopUpFlow({super.key, required this.viewModel});

  final WalletViewModel viewModel;

  @override
  State<WalletTopUpFlow> createState() => _WalletTopUpFlowState();
}

class _WalletTopUpFlowState extends State<WalletTopUpFlow> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  // What the owner typed in the payer dialog, so it opens again filled in:
  // after a refused number, or after "change details" on the code step.
  final _payer = WalletPayerDraft();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Coming back from the browser is the moment a verdict is most likely
    // waiting; ask at once instead of at the next tick.
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(widget.viewModel.checkActiveTopUp()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _amount.dispose();
    super.dispose();
  }

  double? get _enteredAmount =>
      double.tryParse(_amount.text.trim().replaceAll(',', '.'));

  /// Pay: a method that needs the payer's number asks for it in a dialog,
  /// which starts the payment; a bank card goes straight to its page.
  Future<void> _continue() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final amount = _enteredAmount;
    final method = widget.viewModel.selectedMethod;
    if (amount == null || method == null) {
      return;
    }
    if (!walletMethodNeedsPayer(method)) {
      await widget.viewModel.startTopUp(amount);
      return;
    }
    await showWalletPayerDialog(
      context: context,
      viewModel: widget.viewModel,
      method: method,
      amount: amount,
      draft: _payer,
    );
  }

  void _pickQuickAmount(double amount) {
    setState(() => _amount.text = formatWalletBound(amount));
    _formKey.currentState?.validate();
  }

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        final stage = viewModel.topUpStage;
        final child = switch (stage) {
          WalletTopUpStage.form || WalletTopUpStage.starting => _TopUpForm(
            formKey: _formKey,
            amount: _amount,
            viewModel: viewModel,
            onQuickAmount: _pickQuickAmount,
            onContinue: _continue,
            onCancel: _close,
          ),
          WalletTopUpStage.awaitingCode || WalletTopUpStage.confirmingCode =>
            WalletCodeStep(viewModel: viewModel),
          WalletTopUpStage.awaitingPayment => WalletAwaitingPayment(
            viewModel: viewModel,
            onClose: _close,
          ),
          _ => WalletTopUpVerdict(
            viewModel: viewModel,
            onClose: _close,
            onTryAgain: viewModel.beginTopUp,
          ),
        };
        // One key per screen, not per stage: the form stays put while it
        // starts, and the code step while it confirms.
        final screen = switch (stage) {
          WalletTopUpStage.starting => WalletTopUpStage.form,
          WalletTopUpStage.confirmingCode => WalletTopUpStage.awaitingCode,
          _ => stage,
        };
        return AnimatedSwitcher(
          duration: PointyMotion.fast,
          child: KeyedSubtree(key: ValueKey(screen), child: child),
        );
      },
    );
  }
}

class _TopUpForm extends StatelessWidget {
  const _TopUpForm({
    required this.formKey,
    required this.amount,
    required this.viewModel,
    required this.onQuickAmount,
    required this.onContinue,
    required this.onCancel,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController amount;
  final WalletViewModel viewModel;
  final ValueChanged<double> onQuickAmount;
  final VoidCallback onContinue;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final overview = viewModel.overview;
    final options = overview?.topUpOptions;
    final starting = viewModel.topUpStage == WalletTopUpStage.starting;
    final error = viewModel.topUpError;
    final minimum = options?.minAmount ?? 0;
    final maximum = options?.maxAmount ?? 0;
    final method = viewModel.selectedMethod;
    final byCode = method?.confirmsWithCode ?? false;

    return Form(
      key: formKey,
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
                    if (overview?.testMode ?? false) ...[
                      PointyInlineMessage.warning(
                        message: l10n.walletTestModeHint,
                        compact: true,
                      ),
                      SizedBox(height: spacing.sm),
                    ],
                    if (error != null) ...[
                      PointyInlineMessage.error(
                        message: walletExceptionMessage(l10n, error),
                        compact: true,
                      ),
                      SizedBox(height: spacing.sm),
                    ],
                    _AmountField(
                      controller: amount,
                      enabled: !starting,
                      options: options,
                      onSubmitted: onContinue,
                    ),
                    if ((options?.quickAmounts ?? const []).isNotEmpty) ...[
                      SizedBox(height: spacing.sm),
                      Wrap(
                        spacing: spacing.xs,
                        runSpacing: spacing.xs,
                        children: [
                          for (final quick in options!.quickAmounts)
                            if (quick >= minimum && quick <= maximum)
                              ActionChip(
                                label: Text(
                                  formatWalletMoney(quick),
                                  style: PointyTypography.numeric(
                                    const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                onPressed: starting
                                    ? null
                                    : () => onQuickAmount(quick),
                              ),
                        ],
                      ),
                    ],
                    SizedBox(height: spacing.md),
                    Text(
                      l10n.walletTopUpMethodTitle,
                      style: textTheme.titleSmall,
                    ),
                    SizedBox(height: spacing.xs),
                    WalletMethodPicker(
                      methods: viewModel.methods,
                      selectedKey: method?.key,
                      enabled: !starting,
                      onSelected: viewModel.selectMethod,
                    ),
                    SizedBox(height: spacing.sm),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: viewModel.recordAsExpense,
                      onChanged: starting ? null : viewModel.setRecordAsExpense,
                      title: Text(l10n.walletTopUpRecordExpense),
                      subtitle: Text(
                        l10n.walletRecordExpensesSubtitle(
                          overview?.settings.effectiveCategoryName ?? '',
                        ),
                      ),
                    ),
                    SizedBox(height: spacing.xs),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          byCode ? Icons.sms_outlined : Icons.lock_outline,
                          size: 16,
                          color: colors.mutedInk,
                        ),
                        SizedBox(width: spacing.xs),
                        Expanded(
                          child: Text(
                            byCode
                                ? l10n.walletTopUpCodeNote
                                : l10n.walletTopUpBrowserNote,
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.mutedInk,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(spacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: starting ? null : onCancel,
                    child: Text(l10n.walletTopUpCancel),
                  ),
                  SizedBox(width: spacing.sm),
                  FilledButton.icon(
                    onPressed: starting || method == null ? null : onContinue,
                    icon: starting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: PointySpinner(strokeWidth: 2),
                          )
                        // A code method continues to the payer dialog; a
                        // bank card leaves for the browser.
                        : Icon(
                            byCode ? Icons.arrow_forward : Icons.open_in_new,
                          ),
                    label: Text(switch ((starting, byCode)) {
                      (true, true) => l10n.walletTopUpSendingCode,
                      (true, false) => l10n.walletTopUpStarting,
                      (false, _) => l10n.walletTopUpContinue,
                    }),
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

class _AmountField extends StatelessWidget {
  const _AmountField({
    required this.controller,
    required this.enabled,
    required this.options,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final WalletTopUpOptions? options;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    final options = this.options;
    final minimum = options?.minAmount ?? 0;
    final maximum = options?.maxAmount ?? 0;

    return TextFormField(
      controller: controller,
      autofocus: true,
      enabled: enabled,
      // Digits are typed left to right, but the amount sits on the right
      // beside its icon and label, like the rest of the Arabic form. `right`,
      // not `end`: with an LTR field "end" would still mean the left.
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [WalletAmountFormatter(options?.maxDecimals ?? 2)],
      style: PointyTypography.numeric(
        (textTheme.headlineSmall ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
      decoration: InputDecoration(
        labelText: l10n.walletTopUpAmountLabel,
        prefixIcon: const Icon(Icons.payments_outlined),
        suffixText: currencySymbol,
        helperText: options == null
            ? null
            : l10n.walletTopUpAmountHint(
                formatWalletMoney(minimum),
                formatWalletMoney(maximum),
              ),
      ),
      onFieldSubmitted: (_) => onSubmitted(),
      validator: (value) {
        final parsed = double.tryParse(
          (value ?? '').trim().replaceAll(',', '.'),
        );
        if (parsed == null || parsed <= 0) {
          return l10n.walletTopUpAmountRequired;
        }
        if (options != null && parsed < minimum) {
          return l10n.walletTopUpAmountTooSmall(formatWalletMoney(minimum));
        }
        if (options != null && parsed > maximum) {
          return l10n.walletTopUpAmountTooLarge(formatWalletMoney(maximum));
        }
        return null;
      },
    );
  }
}
