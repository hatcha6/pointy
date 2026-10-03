import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_presentation.dart';

/// The code step: the provider texted the payer a code, the owner types it
/// here. A wrong code is said in place with the tries left; "change details"
/// goes back to the form and calls this payment off.
class WalletCodeStep extends StatefulWidget {
  const WalletCodeStep({super.key, required this.viewModel});

  final WalletViewModel viewModel;

  @override
  State<WalletCodeStep> createState() => _WalletCodeStepState();
}

class _WalletCodeStepState extends State<WalletCodeStep> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final code = WalletPayerRules.code(_code.text);
    if (code == null) {
      return;
    }
    await widget.viewModel.confirmCode(code);
    if (mounted && widget.viewModel.codeError != null) {
      // The owner types the code again: clear it and keep the keyboard up.
      _code.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final viewModel = widget.viewModel;
    final topUp = viewModel.activeTopUp;
    final confirming = viewModel.topUpStage == WalletTopUpStage.confirmingCode;
    final error = viewModel.codeError;
    final method = walletMethodLabel(topUp?.method ?? '', l10n);
    final payer = topUp?.payerHint ?? '';

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          spacing.md,
          spacing.md,
          spacing.md,
          spacing.md + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (topUp != null)
              Center(
                child: WalletMethodMark(methodKey: topUp.method, size: 48),
              ),
            SizedBox(height: spacing.sm),
            Text(
              l10n.walletCodeTitle,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
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
            ],
            SizedBox(height: spacing.xs),
            Text(
              payer.isEmpty
                  ? l10n.walletCodeSent(method)
                  : l10n.walletCodeSentTo(method, ltrIsolated(payer)),
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
            SizedBox(height: spacing.md),
            TextFormField(
              controller: _code,
              autofocus: true,
              enabled: !confirming,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              maxLength: 8,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-9٠-٩۰-۹]')),
              ],
              style: PointyTypography.numeric(
                (textTheme.headlineSmall ?? const TextStyle()).copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 8,
                ),
              ),
              decoration: InputDecoration(
                labelText: l10n.walletCodeLabel,
                counterText: '',
              ),
              validator: (value) => WalletPayerRules.code(value ?? '') == null
                  ? l10n.walletCodeRequired
                  : null,
              onFieldSubmitted: (_) => _confirm(),
            ),
            if (error != null) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.error(
                message: _codeErrorText(l10n, error),
                compact: true,
              ),
            ],
            if ((topUp?.testMode ?? false) ||
                (viewModel.overview?.testMode ?? false)) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.warning(
                message: l10n.walletCodeTestHint,
                compact: true,
              ),
            ],
            SizedBox(height: spacing.md),
            FilledButton.icon(
              onPressed: confirming ? null : _confirm,
              icon: confirming
                  ? const SizedBox.square(
                      dimension: 16,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_outlined),
              label: Text(
                confirming ? l10n.walletCodeConfirming : l10n.walletCodeConfirm,
              ),
            ),
            SizedBox(height: spacing.xs),
            TextButton(
              onPressed: confirming ? null : viewModel.changeDetails,
              child: Text(l10n.walletCodeChangeDetails),
            ),
            if (topUp != null && topUp.invoiceNo.isNotEmpty)
              SelectableText(
                l10n.walletTopUpInvoice(walletInvoiceText(topUp.invoiceNo)),
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
          ],
        ),
      ),
    );
  }

  String _codeErrorText(AppLocalizations l10n, WalletException error) {
    final message = walletExceptionMessage(l10n, error);
    final left = error.attemptsLeft;
    if (error.code == 'otp_rejected' && left != null) {
      return '$message ${l10n.walletCodeAttemptsLeft(left)}';
    }
    return message;
  }
}
