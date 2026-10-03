import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_presentation.dart';

/// What the owner typed about the payer, kept by the top-up sheet as plain
/// text so the dialog opens again filled in — after a refused number, or
/// after "change details" on the code step. The dialog's own controllers
/// start from it; they are never handed in, because a controller disposed by
/// its caller after `showDialog` returns is still in use by the closing
/// dialog (see PointyTextEntryDialog).
class WalletPayerDraft {
  String phone = '';
  String card = '';
  String birthYear = '';
}

/// Asks for what the method needs to know about the payer — the phone its
/// wallet is registered to (and Sadad's birth year), or the wallet card
/// number — once the owner has chosen the method and the amount and pressed
/// pay. Sending it starts the payment: the provider texts the code.
///
/// It stays open, with the reason beside the fields, while the answer is
/// about the payer (a number Dafa refused, a provider that turned it away);
/// a refusal about the amount or the method closes it, and the form says why.
Future<void> showWalletPayerDialog({
  required BuildContext context,
  required WalletViewModel viewModel,
  required WalletTopUpMethod method,
  required double amount,
  required WalletPayerDraft draft,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => WalletPayerDialog(
      viewModel: viewModel,
      method: method,
      amount: amount,
      draft: draft,
    ),
  );
}

/// Whether [method] asks anything of the payer before the payment starts.
bool walletMethodNeedsPayer(WalletTopUpMethod method) =>
    method.payer != WalletPayer.none || method.needsBirthYear;

class WalletPayerDialog extends StatefulWidget {
  const WalletPayerDialog({
    super.key,
    required this.viewModel,
    required this.method,
    required this.amount,
    required this.draft,
  });

  final WalletViewModel viewModel;
  final WalletTopUpMethod method;
  final double amount;
  final WalletPayerDraft draft;

  @override
  State<WalletPayerDialog> createState() => _WalletPayerDialogState();
}

class _WalletPayerDialogState extends State<WalletPayerDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _phone = TextEditingController(text: widget.draft.phone);
  late final _card = TextEditingController(text: widget.draft.card);
  late final _birthYear = TextEditingController(text: widget.draft.birthYear);
  WalletException? _error;

  /// Refusals the form answers, not this dialog: the amount, or the method
  /// itself, is what the owner has to change.
  static const _formErrors = {
    'invalid_amount',
    'amount_not_allowed',
    'unsupported_method',
    'method_unavailable',
    'topups_unconfigured',
    'wallet_unavailable',
    'not_configured',
    'forbidden',
  };

  @override
  void dispose() {
    _phone.dispose();
    _card.dispose();
    _birthYear.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final viewModel = widget.viewModel;
    if (viewModel.topUpStage == WalletTopUpStage.starting ||
        !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    widget.draft
      ..phone = _phone.text
      ..card = _card.text
      ..birthYear = _birthYear.text;
    setState(() => _error = null);
    final method = widget.method;
    await viewModel.startTopUp(
      widget.amount,
      userIdentifier: switch (method.payer) {
        WalletPayer.phone => _phone.text,
        WalletPayer.card => _card.text,
        WalletPayer.none => '',
      },
      birthYear: method.needsBirthYear ? _birthYear.text : '',
    );
    if (!mounted) {
      return;
    }
    final error = viewModel.topUpError;
    if (viewModel.topUpStage == WalletTopUpStage.form &&
        error != null &&
        !_formErrors.contains(error.code)) {
      // Said here, beside the fields; the form behind need not say it too,
      // nor after the owner gives up on this number.
      viewModel.dismissTopUpError();
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final method = widget.method;
    final name = walletMethodLabel(method.key, l10n);

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final starting =
            widget.viewModel.topUpStage == WalletTopUpStage.starting;
        final error = _error;
        return PopScope(
          // Once the payment is being started, its answer has to land
          // somewhere the owner can see: on this dialog.
          canPop: !starting,
          child: AdaptiveDialogSurface(
            size: AdaptiveModalSize.compact,
            child: AlertDialog(
              // Two fields plus the keyboard they raise on a phone is more
              // than a short screen holds; scroll rather than overflow.
              scrollable: true,
              icon: WalletMethodMark.of(method, size: 48),
              title: Text(l10n.walletPayerDialogTitle(name)),
              content: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.walletPayerDialogMessage(
                        name,
                        formatWalletMoney(widget.amount),
                      ),
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    WalletPayerFields(
                      method: method,
                      phone: _phone,
                      card: _card,
                      birthYear: _birthYear,
                      enabled: !starting,
                      onSubmitted: _submit,
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      PointyInlineMessage.error(
                        message: walletExceptionMessage(l10n, error),
                        compact: true,
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: starting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Text(l10n.walletTopUpCancel),
                ),
                FilledButton.icon(
                  onPressed: starting ? null : _submit,
                  icon: starting
                      ? const SizedBox.square(
                          dimension: 16,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : const Icon(Icons.sms_outlined),
                  label: Text(
                    starting
                        ? l10n.walletTopUpSendingCode
                        : l10n.walletTopUpSendCode,
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

/// What the method asks of the payer: the phone its wallet is registered to
/// (and Sadad's birth year), or the wallet card number.
class WalletPayerFields extends StatelessWidget {
  const WalletPayerFields({
    super.key,
    required this.method,
    required this.phone,
    required this.card,
    required this.birthYear,
    required this.enabled,
    required this.onSubmitted,
  });

  final WalletTopUpMethod method;
  final TextEditingController phone;
  final TextEditingController card;
  final TextEditingController birthYear;
  final bool enabled;
  final VoidCallback onSubmitted;

  static final _digits = FilteringTextInputFormatter.allow(
    RegExp('[0-9٠-٩۰-۹ +-]'),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final name = walletMethodLabel(method.key, l10n);

    final fields = <Widget>[
      if (method.payer == WalletPayer.phone)
        TextFormField(
          controller: phone,
          autofocus: true,
          enabled: enabled,
          // Digits typed left to right, sitting on the right like the rest
          // of the Arabic form; `right`, not `end`, in an LTR field.
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.right,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumber],
          inputFormatters: [_digits],
          textInputAction: method.needsBirthYear
              ? TextInputAction.next
              : TextInputAction.done,
          decoration: InputDecoration(
            labelText: l10n.walletPayerPhoneLabel(name),
            hintText: l10n.walletPayerPhoneHint,
            prefixIcon: const Icon(Icons.phone_iphone),
          ),
          validator: (value) => WalletPayerRules.phone(value ?? '') == null
              ? l10n.walletPayerPhoneInvalid
              : null,
          onFieldSubmitted: method.needsBirthYear ? null : (_) => onSubmitted(),
        ),
      if (method.payer == WalletPayer.card)
        TextFormField(
          controller: card,
          autofocus: true,
          enabled: enabled,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.right,
          keyboardType: TextInputType.number,
          inputFormatters: [_digits],
          decoration: InputDecoration(
            labelText: l10n.walletPayerCardLabel(name),
            prefixIcon: const Icon(Icons.credit_card),
          ),
          validator: (value) => WalletPayerRules.card(value ?? '') == null
              ? l10n.walletPayerCardInvalid
              : null,
          onFieldSubmitted: (_) => onSubmitted(),
        ),
      if (method.needsBirthYear)
        TextFormField(
          controller: birthYear,
          enabled: enabled,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.right,
          keyboardType: TextInputType.number,
          maxLength: 4,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[0-9٠-٩۰-۹]')),
          ],
          decoration: InputDecoration(
            labelText: l10n.walletPayerBirthYearLabel,
            prefixIcon: const Icon(Icons.cake_outlined),
            counterText: '',
          ),
          validator: (value) =>
              WalletPayerRules.birthYear(value ?? '', DateTime.now()) == null
              ? l10n.walletPayerBirthYearInvalid
              : null,
          onFieldSubmitted: (_) => onSubmitted(),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, field) in fields.indexed) ...[
          if (index > 0) SizedBox(height: spacing.sm),
          field,
        ],
      ],
    );
  }
}
