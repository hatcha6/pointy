import 'dart:async';

import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_provider.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/integrations_view_model.dart';
import 'integration_presentation.dart';

/// Which of a provider login's profiles Pointy buys as. Resolves true when a
/// choice was saved.
///
/// One Qareeb login can be a person and an employee of several shops, each
/// with its own wallet. Whatever the till sells is paid from the chosen one,
/// and the till refuses to buy while the login is acting as any other rather
/// than paying from the wrong shop's float.
Future<bool?> showIntegrationProfileSheet({
  required BuildContext context,
  required IntegrationProvider provider,
  required IntegrationsViewModel viewModel,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showAdaptiveFormSurface<bool>(
    context: context,
    title: l10n.integrationProfileTitle(
      integrationProviderName(provider.key, l10n),
    ),
    builder: (sheetContext) => IntegrationProfileForm(
      load: () => viewModel.loadProfiles(provider.key),
      choose: (profileId) => viewModel.chooseProfile(provider.key, profileId),
    ),
  );
}

/// Public and callback-driven, for the preview harness and widget tests.
class IntegrationProfileForm extends StatefulWidget {
  const IntegrationProfileForm({
    super.key,
    required this.load,
    required this.choose,
  });

  final Future<IntegrationProfileList?> Function() load;
  final Future<bool> Function(String profileId) choose;

  @override
  State<IntegrationProfileForm> createState() => _IntegrationProfileFormState();
}

class _IntegrationProfileFormState extends State<IntegrationProfileForm> {
  IntegrationProfileList? _list;
  bool _loading = true;
  bool _saving = false;
  String _selected = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final list = await widget.load();
    if (!mounted) return;
    setState(() {
      _list = list;
      _loading = false;
      _selected = list == null
          ? ''
          : (list.chosen.isNotEmpty
                ? list.chosen
                : list.profiles
                          .where((profile) => profile.isCurrent)
                          .map((profile) => profile.profileId)
                          .firstOrNull ??
                      '');
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await widget.choose(_selected);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final list = _list;

    Widget body;
    if (_loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: PointyLoadingArea(),
      );
    } else if (list == null || !list.ok) {
      body = PointyInlineMessage.error(
        message: integrationErrorText(
          list?.errorCode ?? IntegrationErrorCode.unreachable,
          l10n,
        ),
      );
    } else if (list.profiles.isEmpty) {
      body = PointyInlineMessage(message: l10n.integrationProfileNone);
    } else {
      final chosen = list.profiles
          .where((profile) => profile.profileId == _selected)
          .firstOrNull;
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // groupValue/onChanged on the tile rather than a RadioGroup: the
          // same shape the rest of the app uses, and one the Flutter 3.19
          // compat build can take unchanged.
          for (final profile in list.profiles)
            RadioListTile<String>(
              value: profile.profileId,
              // ignore: deprecated_member_use
              groupValue: _selected,
              // ignore: deprecated_member_use
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _selected = value);
                    },
              contentPadding: EdgeInsets.zero,
              title: Text(
                profile.name.isEmpty ? profile.profileId : profile.name,
              ),
              subtitle: Text(
                [
                  integrationProfileKindLabel(profile.kind, l10n),
                  if (profile.isCurrent) l10n.integrationProfileActiveNow,
                ].where((part) => part.isNotEmpty).join(' · '),
              ),
            ),
          // Choosing a profile the login is not acting as is allowed — the
          // owner may switch it in the provider's own app next — but it is
          // said out loud, because until then the till will refuse to sell.
          if (chosen != null && !chosen.isCurrent) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.warning(
              message: l10n.integrationProfileNotActiveWarning,
              compact: true,
            ),
          ],
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(spacing.md, spacing.md, spacing.md, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.integrationProfileIntro,
                  style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
                ),
                SizedBox(height: spacing.md),
                body,
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
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).pop(false),
                child: Text(l10n.integrationCancel),
              ),
              SizedBox(width: spacing.sm),
              FilledButton.icon(
                onPressed: _saving || _loading || !(list?.ok ?? false)
                    ? null
                    : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: PointySpinner(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(l10n.integrationSave),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
