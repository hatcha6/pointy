import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_provider.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/integrations_view_model.dart';
import 'integration_presentation.dart';

/// Confirms this Pointy as a device the provider knows. Resolves true once
/// the provider trusts it.
///
/// Qareeb answers a password login from a machine it has not seen with "use
/// a one-time code instead", and asking for the code needs the text of a
/// captcha picture. So it is a short conversation with the owner, done once
/// per installation: read the picture, receive a text, type the code.
Future<bool?> showIntegrationVerificationSheet({
  required BuildContext context,
  required IntegrationProvider provider,
  required IntegrationsViewModel viewModel,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showAdaptiveFormSurface<bool>(
    context: context,
    title: l10n.integrationVerifyTitle(
      integrationProviderName(provider.key, l10n),
    ),
    builder: (sheetContext) => IntegrationVerificationForm(
      onStart: () => viewModel.startVerification(provider.key),
      onSend: (challengeRef, answer) => viewModel.sendVerificationCode(
        provider.key,
        challengeRef: challengeRef,
        answer: answer,
      ),
      onConfirm: (code) =>
          viewModel.confirmVerification(provider.key, code: code),
    ),
  );
}

enum _Stage { picture, code }

/// Public and callback-driven, so the preview harness and widget tests can
/// walk every step without a backend.
class IntegrationVerificationForm extends StatefulWidget {
  const IntegrationVerificationForm({
    super.key,
    required this.onStart,
    required this.onSend,
    required this.onConfirm,
  });

  final Future<IntegrationVerificationChallenge?> Function() onStart;
  final Future<IntegrationVerificationStep?> Function(
    String challengeRef,
    String answer,
  )
  onSend;
  final Future<IntegrationVerificationStep?> Function(String code) onConfirm;

  @override
  State<IntegrationVerificationForm> createState() =>
      _IntegrationVerificationFormState();
}

class _IntegrationVerificationFormState
    extends State<IntegrationVerificationForm> {
  final _answer = TextEditingController();
  final _code = TextEditingController();
  _Stage _stage = _Stage.picture;
  IntegrationVerificationChallenge? _challenge;
  Uint8List? _picture;
  int? _expiresIn;
  bool _busy = false;
  String _errorCode = '';

  @override
  void initState() {
    super.initState();
    unawaited(_newPicture());
  }

  @override
  void dispose() {
    _answer.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _newPicture() async {
    setState(() {
      _busy = true;
      _errorCode = '';
      _stage = _Stage.picture;
      _answer.clear();
    });
    final challenge = await widget.onStart();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _challenge = challenge;
      _picture = _decode(challenge?.imageDataUrl ?? '');
      if (challenge == null) {
        _errorCode = IntegrationErrorCode.unreachable;
      } else if (!challenge.ok) {
        _errorCode = challenge.errorCode;
      }
    });
  }

  Future<void> _send() async {
    final challenge = _challenge;
    final answer = _answer.text.trim();
    if (challenge == null || answer.isEmpty) return;
    setState(() {
      _busy = true;
      _errorCode = '';
    });
    final step = await widget.onSend(challenge.challengeRef, answer);
    if (!mounted) return;
    if (step != null && step.ok) {
      setState(() {
        _busy = false;
        _stage = _Stage.code;
        _expiresIn = step.expiresInMinutes;
      });
      return;
    }
    // A wrong reading spends the picture: the provider issues a new one.
    setState(
      () => _errorCode = step?.errorCode ?? IntegrationErrorCode.unreachable,
    );
    final keepError = _errorCode;
    await _newPicture();
    if (mounted) setState(() => _errorCode = keepError);
  }

  Future<void> _confirm() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _errorCode = '';
    });
    final step = await widget.onConfirm(code);
    if (!mounted) return;
    if (step != null && step.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _errorCode = step?.errorCode ?? IntegrationErrorCode.unreachable;
    });
  }

  static Uint8List? _decode(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (!dataUrl.startsWith('data:') || comma < 0) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final colors = context.pointyColors;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
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
                    _stage == _Stage.picture
                        ? l10n.integrationVerifyPictureIntro
                        : l10n.integrationVerifyCodeIntro,
                    style: textTheme.bodyMedium?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                  SizedBox(height: spacing.md),
                  if (_errorCode.isNotEmpty) ...[
                    PointyInlineMessage.error(
                      message: integrationErrorText(_errorCode, l10n),
                      compact: true,
                    ),
                    SizedBox(height: spacing.sm),
                  ],
                  if (_stage == _Stage.picture) ..._pictureStep(l10n, spacing),
                  if (_stage == _Stage.code) ..._codeStep(l10n, spacing),
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
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: Text(l10n.integrationCancel),
                ),
                SizedBox(width: spacing.sm),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : (_stage == _Stage.picture ? _send : _confirm),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : Icon(
                          _stage == _Stage.picture
                              ? Icons.sms_outlined
                              : Icons.verified_user_outlined,
                        ),
                  label: Text(
                    _stage == _Stage.picture
                        ? l10n.integrationVerifySendCode
                        : l10n.integrationVerifyConfirm,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _pictureStep(AppLocalizations l10n, AdaptiveSpacing spacing) {
    final colors = context.pointyColors;
    final picture = _picture;
    return [
      Container(
        height: 96,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // White whatever the theme: the picture is drawn for paper.
          color: const Color(0xFFFFFFFF),
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(PointyRadii.card),
        ),
        child: picture == null
            ? (_busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.image_not_supported_outlined,
                      color: colors.mutedInk,
                    ))
            : Image.memory(picture, fit: BoxFit.contain, gaplessPlayback: true),
      ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: TextButton.icon(
          onPressed: _busy ? null : _newPicture,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.integrationVerifyNewPicture),
        ),
      ),
      TextField(
        controller: _answer,
        enabled: !_busy && picture != null,
        textDirection: TextDirection.ltr,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: l10n.integrationVerifyPictureLabel,
          helperText: (_challenge?.helpText ?? '').isEmpty
              ? null
              : _challenge!.helpText,
          prefixIcon: const Icon(Icons.text_fields),
        ),
        onSubmitted: (_) => _send(),
      ),
    ];
  }

  List<Widget> _codeStep(AppLocalizations l10n, AdaptiveSpacing spacing) {
    return [
      TextField(
        controller: _code,
        enabled: !_busy,
        autofocus: true,
        textDirection: TextDirection.ltr,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: l10n.integrationVerifyCodeLabel,
          helperText: _expiresIn == null
              ? null
              : l10n.integrationVerifyCodeExpires(_expiresIn!),
          prefixIcon: const Icon(Icons.pin_outlined),
        ),
        onSubmitted: (_) => _confirm(),
      ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: TextButton.icon(
          onPressed: _busy ? null : _newPicture,
          icon: const Icon(Icons.restart_alt),
          label: Text(l10n.integrationVerifyStartAgain),
        ),
      ),
    ];
  }
}
