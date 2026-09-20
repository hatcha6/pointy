import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_provider.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/integrations_view_model.dart';
import 'integration_presentation.dart';

/// Credentials for one resale provider. Resolves true when they were saved.
Future<bool?> showIntegrationCredentialsSheet({
  required BuildContext context,
  required IntegrationProvider provider,
  required IntegrationsViewModel viewModel,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showAdaptiveFormSurface<bool>(
    context: context,
    title: integrationProviderName(provider.key, l10n),
    builder: (sheetContext) => IntegrationCredentialsForm(
      provider: provider,
      onSubmit: (draft) => viewModel.saveCredentials(provider.key, draft),
    ),
  );
}

/// The credentials form, driven by whatever fields the backend declares for
/// this provider.
///
/// Rendering from `provider.fields` rather than from a hand-written layout is
/// what makes a new provider a backend change: the day LNET ships an API, its
/// catalog entry names the same three fields and this form already draws them.
///
/// Public, and takes a plain callback rather than the view model, so the
/// preview harness and widget tests can drive it directly.
class IntegrationCredentialsForm extends StatefulWidget {
  const IntegrationCredentialsForm({
    super.key,
    required this.provider,
    required this.onSubmit,
  });

  final IntegrationProvider provider;
  final Future<bool> Function(IntegrationCredentialsDraft draft) onSubmit;

  @override
  State<IntegrationCredentialsForm> createState() =>
      _IntegrationCredentialsFormState();
}

class _IntegrationCredentialsFormState
    extends State<IntegrationCredentialsForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _baseUrl;
  late final TextEditingController _username;
  late final TextEditingController _password;
  bool _isSaving = false;

  IntegrationAccount? get _account => widget.provider.account;

  @override
  void initState() {
    super.initState();
    final account = _account;
    _baseUrl = TextEditingController(
      text: (account?.baseUrl.isNotEmpty ?? false)
          ? account!.baseUrl
          : widget.provider.defaultBaseUrl,
    );
    _username = TextEditingController(text: account?.username ?? '');
    _password = TextEditingController();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  bool _shows(String field) => widget.provider.fields.contains(field);

  /// http:// means the password crosses the wire in clear. HD Box offers
  /// nothing else today, so this warns rather than blocks — but it warns every
  /// time, because "it is only the TV system" is how a reused password leaks.
  bool get _isInsecure {
    final url = _baseUrl.text.trim().toLowerCase();
    return url.startsWith('http://');
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSaving = true);
    final saved = await widget.onSubmit(
      IntegrationCredentialsDraft(
        baseUrl: _shows(IntegrationField.baseUrl) ? _baseUrl.text.trim() : null,
        username: _shows(IntegrationField.username)
            ? _username.text.trim()
            : null,
        password: _shows(IntegrationField.password) ? _password.text : null,
      ),
    );
    if (!mounted) return;
    setState(() => _isSaving = false);
    if (saved) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final account = _account;

    return Form(
      key: _formKey,
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              integrationProviderTagline(widget.provider.key, l10n),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.pointyColors.mutedInk,
              ),
            ),
            SizedBox(height: spacing.md),
            if (_shows(IntegrationField.baseUrl)) ...[
              TextFormField(
                controller: _baseUrl,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: l10n.integrationFieldBaseUrl,
                  hintText: l10n.integrationFieldBaseUrlHint,
                  prefixIcon: const Icon(Icons.dns_outlined),
                ),
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: spacing.sm),
            ],
            if (_shows(IntegrationField.username)) ...[
              TextFormField(
                controller: _username,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: l10n.integrationFieldUsername,
                  prefixIcon: const Icon(Icons.person_outline),
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? l10n.integrationUsernameRequired
                    : null,
              ),
              SizedBox(height: spacing.sm),
            ],
            if (_shows(IntegrationField.password)) ...[
              PointyPasswordField(
                controller: _password,
                labelText: l10n.integrationFieldPassword,
                textDirection: TextDirection.ltr,
                helperText: (account?.hasPassword ?? false)
                    ? l10n.integrationPasswordStoredHint
                    : null,
                // Blank is legitimate on a re-save: the form never received the
                // stored password, so it cannot resend one.
                validator: (value) {
                  if ((account?.hasPassword ?? false)) return null;
                  return (value ?? '').isEmpty
                      ? l10n.integrationPasswordRequired
                      : null;
                },
              ),
              SizedBox(height: spacing.sm),
            ],
            if (_isInsecure) ...[
              PointyInlineMessage.warning(
                message: l10n.integrationInsecureTransportWarning,
                compact: true,
              ),
              SizedBox(height: spacing.sm),
            ],
            PointyInlineMessage(
              message: l10n.integrationBalanceCurrencyNote,
              icon: Icons.info_outline,
              compact: true,
            ),
            SizedBox(height: spacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _isSaving
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: Text(l10n.integrationCancel),
                ),
                SizedBox(width: spacing.sm),
                FilledButton.icon(
                  onPressed: _isSaving ? null : _save,
                  icon: _isSaving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(l10n.integrationSave),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
