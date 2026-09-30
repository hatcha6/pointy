import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_presentation.dart';

/// Top up the Daftar wallet: pick an amount, pay on the gateway's page in the
/// browser, and watch the sheet turn into the verdict by itself. Closing it
/// while the payer is still paying loses nothing: the relay credits whatever
/// the gateway approves, and the shop's backend books it.
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

  Future<void> _continue() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final amount = _enteredAmount;
    if (amount == null) {
      return;
    }
    await widget.viewModel.startTopUp(amount);
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
        final child = switch (viewModel.topUpStage) {
          WalletTopUpStage.form || WalletTopUpStage.starting => _TopUpForm(
            formKey: _formKey,
            amount: _amount,
            viewModel: viewModel,
            onQuickAmount: _pickQuickAmount,
            onContinue: _continue,
            onCancel: _close,
          ),
          WalletTopUpStage.awaitingPayment => _AwaitingPayment(
            viewModel: viewModel,
            onClose: _close,
          ),
          _ => _TopUpVerdict(
            viewModel: viewModel,
            onClose: _close,
            onTryAgain: viewModel.beginTopUp,
          ),
        };
        return AnimatedSwitcher(
          duration: PointyMotion.fast,
          child: KeyedSubtree(
            key: ValueKey(
              viewModel.topUpStage == WalletTopUpStage.starting
                  ? WalletTopUpStage.form
                  : viewModel.topUpStage,
            ),
            child: child,
          ),
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
                    TextFormField(
                      controller: amount,
                      autofocus: true,
                      enabled: !starting,
                      // Digits are typed left to right, but the amount sits on
                      // the right beside its icon and label, like the rest of
                      // the Arabic form. `right`, not `end`: with an LTR field
                      // "end" would still mean the left.
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [_TwoDecimalsFormatter()],
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
                      onFieldSubmitted: (_) => onContinue(),
                      validator: (value) {
                        final parsed = double.tryParse(
                          (value ?? '').trim().replaceAll(',', '.'),
                        );
                        if (parsed == null || parsed <= 0) {
                          return l10n.walletTopUpAmountRequired;
                        }
                        if (options != null && parsed < minimum) {
                          return l10n.walletTopUpAmountTooSmall(
                            formatWalletMoney(minimum),
                          );
                        }
                        if (options != null && parsed > maximum) {
                          return l10n.walletTopUpAmountTooLarge(
                            formatWalletMoney(maximum),
                          );
                        }
                        return null;
                      },
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
                    const _LocalBankCardMethod(),
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
                          Icons.lock_outline,
                          size: 16,
                          color: colors.mutedInk,
                        ),
                        SizedBox(width: spacing.xs),
                        Expanded(
                          child: Text(
                            l10n.walletTopUpBrowserNote,
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
                    onPressed: starting ? null : onContinue,
                    icon: starting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: PointySpinner(strokeWidth: 2),
                          )
                        : const Icon(Icons.open_in_new),
                    label: Text(
                      starting
                          ? l10n.walletTopUpStarting
                          : l10n.walletTopUpContinue,
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

/// The one method today. Drawn as a selected card so Sadad and Adfali can sit
/// beside it later without the form changing shape.
class _LocalBankCardMethod extends StatelessWidget {
  const _LocalBankCardMethod();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        border: Border.all(color: colors.primaryStrong.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.sm),
        child: Row(
          children: [
            Icon(Icons.credit_card, color: colors.primaryStrong),
            SizedBox(width: spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.walletMethodLocalBankCards,
                    style: textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    l10n.walletMethodLocalBankCardsHint,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.check_circle, color: colors.primaryStrong),
          ],
        ),
      ),
    );
  }
}

class _AwaitingPayment extends StatelessWidget {
  const _AwaitingPayment({required this.viewModel, required this.onClose});

  final WalletViewModel viewModel;
  final VoidCallback onClose;

  Future<void> _copyLink(BuildContext context) async {
    final url = viewModel.checkoutUrl;
    if (url == null) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: url));
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.walletAwaitingLinkCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final topUp = viewModel.activeTopUp;

    return SingleChildScrollView(
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: SizedBox.square(
              dimension: 44,
              child: PointySpinner(strokeWidth: 3),
            ),
          ),
          SizedBox(height: spacing.md),
          Text(
            l10n.walletAwaitingTitle,
            textAlign: TextAlign.center,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          if (topUp != null) ...[
            SizedBox(height: spacing.xs),
            Text(
              formatWalletMoney(topUp.amount),
              textAlign: TextAlign.center,
              style: PointyTypography.numeric(
                (textTheme.headlineSmall ?? const TextStyle()).copyWith(
                  fontWeight: FontWeight.w800,
                  color: colors.primaryStrong,
                ),
              ),
            ),
            Text(
              l10n.walletTopUpInvoice(walletInvoiceText(topUp.invoiceNo)),
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
          SizedBox(height: spacing.md),
          Text(
            l10n.walletAwaitingMessage,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium,
          ),
          if (viewModel.checkoutOpenFailed) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.warning(
              message: l10n.walletCheckoutOpenFailed,
              compact: true,
            ),
          ],
          SizedBox(height: spacing.md),
          FilledButton.icon(
            onPressed: viewModel.openCheckout,
            icon: const Icon(Icons.open_in_new),
            label: Text(l10n.walletAwaitingOpenAgain),
          ),
          SizedBox(height: spacing.xs),
          OutlinedButton.icon(
            onPressed: () => _copyLink(context),
            icon: const Icon(Icons.copy_outlined),
            label: Text(l10n.walletAwaitingCopyLink),
          ),
          SizedBox(height: spacing.md),
          Text(
            l10n.walletAwaitingCloseHint,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          TextButton(onPressed: onClose, child: Text(l10n.walletClose)),
        ],
      ),
    );
  }
}

class _TopUpVerdict extends StatelessWidget {
  const _TopUpVerdict({
    required this.viewModel,
    required this.onClose,
    required this.onTryAgain,
  });

  final WalletViewModel viewModel;
  final VoidCallback onClose;
  final VoidCallback onTryAgain;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final topUp = viewModel.activeTopUp;
    final overview = viewModel.overview;

    late final IconData icon;
    late final Color tone;
    late final String title;
    final lines = <String>[];
    var success = false;
    switch (viewModel.topUpStage) {
      case WalletTopUpStage.paid:
        success = true;
        icon = Icons.check_circle;
        tone = colors.success;
        title = l10n.walletPaidTitle;
        if (topUp != null) {
          lines.add(l10n.walletPaidMessage(formatWalletMoney(topUp.amount)));
        }
        final balance = overview?.balance;
        if (balance != null) {
          lines.add(l10n.walletNewBalance(formatWalletMoney(balance)));
        }
        if (topUp?.isBookedAsExpense ?? false) {
          lines.add(
            l10n.walletPaidBooked(
              overview?.settings.effectiveCategoryName ?? '',
            ),
          );
        }
      case WalletTopUpStage.canceled:
        icon = Icons.cancel_outlined;
        tone = colors.mutedInk;
        title = l10n.walletCanceledTitle;
        lines.add(l10n.walletCanceledMessage);
      case WalletTopUpStage.failed when topUp?.errorCode == 'amount_mismatch':
        icon = Icons.pending_actions_outlined;
        tone = colors.warning;
        title = l10n.walletReviewTitle;
        lines.add(l10n.walletReviewMessage);
      case WalletTopUpStage.failed:
        icon = Icons.error_outline;
        tone = colors.danger;
        title = l10n.walletFailedTitle;
        lines.add(l10n.walletFailedMessage);
      default:
        icon = Icons.help_outline;
        tone = colors.warning;
        title = l10n.walletUnconfirmedTitle;
        lines.add(l10n.walletUnconfirmedMessage);
    }

    return SingleChildScrollView(
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(icon, size: 56, color: tone),
          SizedBox(height: spacing.sm),
          Text(
            title,
            textAlign: TextAlign.center,
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: spacing.sm),
          for (final line in lines)
            Padding(
              padding: EdgeInsets.only(bottom: spacing.xs),
              child: Text(
                line,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium,
              ),
            ),
          // The reference on a line of its own, selectable: it is what support
          // matches against the gateway when a payment needs looking into.
          if (topUp != null && topUp.invoiceNo.isNotEmpty)
            SelectableText(
              l10n.walletTopUpInvoice(walletInvoiceText(topUp.invoiceNo)),
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          if (topUp?.testMode ?? false) ...[
            SizedBox(height: spacing.xs),
            Center(
              child: PointyStatusPill(
                label: l10n.walletTestModePill,
                icon: Icons.science_outlined,
                color: colors.warning,
              ),
            ),
          ],
          SizedBox(height: spacing.md),
          if (success)
            FilledButton(onPressed: onClose, child: Text(l10n.walletDone))
          else ...[
            if (viewModel.topUpStage != WalletTopUpStage.unconfirmed)
              FilledButton.icon(
                onPressed: onTryAgain,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.walletTryAgain),
              ),
            TextButton(onPressed: onClose, child: Text(l10n.walletClose)),
          ],
        ],
      ),
    );
  }
}

/// Digits with at most two decimals — the gateway's own rule — accepting a
/// comma for the decimal point.
class _TwoDecimalsFormatter extends TextInputFormatter {
  static final _pattern = RegExp(r'^\d{0,7}([.,]\d{0,2})?$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.text.isEmpty || _pattern.hasMatch(newValue.text)
        ? newValue
        : oldValue;
  }
}
