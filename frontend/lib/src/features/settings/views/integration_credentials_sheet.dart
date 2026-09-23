import 'dart:async';

import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_provider.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/integrations_view_model.dart';
import 'integration_amount_list_field.dart';
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
  late final TextEditingController _pin;
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
    _pin = TextEditingController();
    for (final setting in widget.provider.settings) {
      _settings[setting.key] = TextEditingController(text: setting.asText);
    }
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _pin.dispose();
    for (final controller in _settings.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// What the owner typed, as the backend's own shape. Only sent when it
  /// differs from what was loaded, so saving a URL never rewrites a
  /// commission somebody set months ago.
  ///
  /// A cleared box is "leave it alone", which is what the validator has always
  /// told the owner — but the blank was being *sent*, and the server refuses a
  /// blank as out of range. So emptying a field to move on from it failed the
  /// whole save with a message about a number nobody had typed. The one
  /// exception is a list, where empty is a real answer: no quick-picks.
  Map<String, Object?> _changedSettings() {
    final changed = <String, Object?>{};
    for (final setting in widget.provider.settings) {
      final text = _settings[setting.key]?.text.trim() ?? '';
      if (text == setting.asText.trim()) continue;
      if (setting.isAmountList) {
        changed[setting.key] = _splitAmounts(text);
        continue;
      }
      if (text.isEmpty) continue;
      changed[setting.key] = text;
    }
    return changed;
  }

  /// A bound as a plain number: a percentage is not money and must not be
  /// rendered with a currency.
  static String _plain(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  /// Amounts as the owner separated them — comma, Arabic comma, or space.
  static List<String> _splitAmounts(String raw) => raw
      .split(RegExp(r'[،,\s]+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  bool _shows(String field) => widget.provider.fields.contains(field);

  final Map<String, TextEditingController> _settings = {};

  String? _validateSetting(IntegrationSetting setting, String? raw) {
    final l10n = AppLocalizations.of(context)!;
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null; // blank means "leave it alone"
    if (setting.isAmountList) {
      final parts = _splitAmounts(text);
      final bad = parts.any((part) {
        final value = double.tryParse(part);
        return value == null || value <= 0;
      });
      return bad ? l10n.integrationSettingInvalidAmounts : null;
    }
    final value = double.tryParse(text);
    // The declared bounds, not a percentage's. A money threshold's ceiling is
    // a typo guard in the hundreds of thousands, and assuming 100 here would
    // have refused every float a real agency runs.
    final min = setting.minimum ?? 0;
    final max = setting.maximum ?? double.infinity;
    if (value == null || value < min || value > max) {
      // Both bounds are optional in the catalog, so a setting may legally
      // declare a floor and no ceiling. Saying "between 0 and Infinity" is
      // how that would otherwise reach a shopkeeper.
      return max.isFinite
          ? l10n.integrationSettingOutOfRange(_plain(min), _plain(max))
          : l10n.integrationSettingAtLeast(_plain(min));
    }
    return null;
  }

  /// Opens the add/remove dialog for an ``amount_list`` setting and, if the
  /// owner confirmed a change, writes it back into that setting's controller
  /// in the SAME delimited shape [_changedSettings] already knows how to
  /// read — so saving this field needs no code of its own beyond what
  /// every other setting already has.
  Future<void> _manageAmountList(
    IntegrationSetting setting,
    String title,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = _settings[setting.key];
    if (controller == null) return;
    final updated = await showIntegrationAmountListDialog(
      context: context,
      title: title,
      description: l10n.integrationAmountListDialogDescription,
      initialAmounts: _splitAmounts(controller.text),
    );
    if (updated == null || !mounted) return;
    setState(() => controller.text = updated.join('، '));
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
        pin: _shows(IntegrationField.pin) ? _pin.text.trim() : null,
        settings: _changedSettings(),
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
      // The sheet leaves the keyboard to its content, and a form that ignored
      // it had its lower fields and its Save button hidden under the keys.
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The fields scroll; the actions stay pinned beneath them. A tall
            // provider (LNET's three credentials and three settings) used to
            // overflow the sheet with nothing to scroll, cutting Save off.
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  spacing.md,
                  spacing.md,
                  spacing.md,
                  0,
                ),
                child: _fields(context, l10n, spacing, account),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(spacing.md),
              child: _actions(l10n, spacing),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fields(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
    IntegrationAccount? account,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          integrationProviderTagline(widget.provider.key, l10n),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: context.pointyColors.mutedInk),
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
          ),
          SizedBox(height: spacing.sm),
        ],
        if (_shows(IntegrationField.username)) ...[
          Builder(
            builder: (context) {
              final copy = integrationUsernameCopy(widget.provider.key, l10n);
              return TextFormField(
                controller: _username,
                textDirection: TextDirection.ltr,
                keyboardType: copy.isPhone
                    ? TextInputType.phone
                    : TextInputType.text,
                decoration: InputDecoration(
                  labelText: copy.label,
                  hintText: copy.hint,
                  prefixIcon: Icon(copy.icon),
                ),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? copy.required : null,
              );
            },
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
        if (_shows(IntegrationField.pin)) ...[
          // Optional: some agency accounts ask for a PIN on every
          // purchase and most do not. The provider says which, per sale.
          PointyPasswordField(
            controller: _pin,
            labelText: l10n.integrationFieldPin,
            textDirection: TextDirection.ltr,
            helperText: (account?.hasSecret(IntegrationField.pin) ?? false)
                ? l10n.integrationPinStoredHint
                : l10n.integrationPinHint,
          ),
          SizedBox(height: spacing.sm),
        ],
        // The shop's own commercial terms, rendered from whatever the
        // backend declares. Below the credentials because these always
        // have a working default: a shop can connect without reading
        // this section at all, and only opens it when its deal differs.
        if (widget.provider.settings.isNotEmpty) ...[
          SizedBox(height: spacing.sm),
          Text(
            l10n.integrationSettingsHeading,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SizedBox(height: spacing.sm),
          for (final setting in widget.provider.settings) ...[
            Builder(
              builder: (context) {
                final copy = integrationSettingLabel(setting.key, l10n);
                if (setting.isAmountList) {
                  // A list of amounts, added and removed one at a time —
                  // never a text field asking the owner to type them
                  // delimited by a comma and get the separator right.
                  return IntegrationAmountListField(
                    label: copy.label,
                    helper: copy.hint,
                    icon: copy.icon,
                    amounts: _splitAmounts(_settings[setting.key]?.text ?? ''),
                    enabled: !_isSaving,
                    onManage: () =>
                        unawaited(_manageAmountList(setting, copy.label)),
                  );
                }
                return TextFormField(
                  controller: _settings[setting.key],
                  textDirection: TextDirection.ltr,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: copy.label,
                    helperText: copy.hint,
                    helperMaxLines: 2,
                    prefixIcon: Icon(copy.icon),
                  ),
                  validator: (value) => _validateSetting(setting, value),
                );
              },
            ),
            SizedBox(height: spacing.sm),
          ],
        ],
      ],
    );
  }

  Widget _actions(AppLocalizations l10n, AdaptiveSpacing spacing) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
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
    );
  }
}
