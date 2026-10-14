import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../view_models/moamalat_link_view_model.dart';
import 'moamalat_presentation.dart';

/// Username + password, then the OTP texted to the merchant's phone. The
/// password field is cleared the moment it is sent: nothing keeps it.
class MoamalatLinkForm extends StatefulWidget {
  const MoamalatLinkForm({
    super.key,
    required this.viewModel,
    this.initialUsername = '',
  });

  final MoamalatLinkViewModel viewModel;
  final String initialUsername;

  @override
  State<MoamalatLinkForm> createState() => _MoamalatLinkFormState();
}

class _MoamalatLinkFormState extends State<MoamalatLinkForm> {
  late final _username = TextEditingController(text: widget.initialUsername);
  final _password = TextEditingController();
  final _code = TextEditingController();

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final password = _password.text;
    _password.clear();
    await widget.viewModel.startLink(
      username: _username.text.trim(),
      password: password,
    );
  }

  Future<void> _verify() async {
    if (await widget.viewModel.verify(_code.text.trim())) {
      _code.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final viewModel = widget.viewModel;
    final failure = viewModel.failure;
    final busy = viewModel.isBusy;
    final awaitingCode = viewModel.step == MoamalatLinkStep.code;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          awaitingCode ? l10n.moamalatCodeHint : l10n.moamalatLinkHint,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: context.pointyColors.mutedInk,
          ),
        ),
        const SizedBox(height: 12),
        if (!awaitingCode) ...[
          TextField(
            controller: _username,
            enabled: !busy,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: l10n.moamalatUsernameLabel,
              prefixIcon: const Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          PointyPasswordField(
            controller: _password,
            labelText: l10n.moamalatPasswordLabel,
            enabled: !busy,
            textInputAction: TextInputAction.send,
            onFieldSubmitted: (_) => _send(),
            helperText: l10n.moamalatPasswordNotStored,
          ),
        ] else
          TextField(
            controller: _code,
            enabled: !busy,
            autofocus: true,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _verify(),
            decoration: InputDecoration(
              labelText: l10n.moamalatCodeLabel,
              prefixIcon: const Icon(Icons.sms_outlined),
            ),
          ),
        if (failure != null) ...[
          const SizedBox(height: 12),
          PointyInlineMessage.error(
            message: moamalatFailureText(l10n, failure),
            compact: true,
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: [
            if (awaitingCode)
              TextButton(
                onPressed: busy ? null : viewModel.cancelCode,
                child: Text(l10n.cancelButton),
              ),
            FilledButton.icon(
              onPressed: busy ? null : (awaitingCode ? _verify : _send),
              icon: Icon(awaitingCode ? Icons.link : Icons.send_outlined),
              label: Text(
                awaitingCode
                    ? l10n.moamalatVerifyAction
                    : l10n.moamalatSendCodeAction,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
