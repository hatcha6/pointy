import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_provider.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';

/// The whole setup of a provider that asks for no credential — «كروت دفتر»,
/// which the company buys with its own account: one switch that puts its
/// cards on the till, or takes them off.
class IntegrationEnableSwitch extends StatelessWidget {
  const IntegrationEnableSwitch({
    super.key,
    required this.provider,
    required this.isBusy,
    this.onChanged,
  });

  final IntegrationProvider provider;
  final bool isBusy;

  /// Null while it cannot change: switched off for every shop.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final enabled = provider.isEnabled;
    final onChanged = this.onChanged;
    // A Material, not a coloured box: the tile paints its ink on it.
    return Material(
      color: enabled
          ? Color.alphaBlend(
              colors.primary.withValues(alpha: 0.06),
              colors.surface,
            )
          : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        side: BorderSide(
          color: enabled ? colors.primary.withValues(alpha: 0.35) : colors.line,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile.adaptive(
        key: ValueKey(
          'integration_enable_${integrationProviderKeyToJson(provider.key)}',
        ),
        value: enabled,
        onChanged: isBusy || onChanged == null ? null : onChanged,
        contentPadding: const EdgeInsetsDirectional.only(start: 12, end: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PointyRadii.chip),
        ),
        secondary: isBusy
            ? const SizedBox.square(
                dimension: 20,
                child: PointySpinner(strokeWidth: 2),
              )
            : Icon(
                enabled ? Icons.storefront : Icons.storefront_outlined,
                color: enabled ? colors.primaryStrong : colors.mutedInk,
              ),
        title: Text(
          l10n.integrationEnableTitle,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          enabled
              ? l10n.integrationEnableOnHint
              : l10n.integrationEnableOffHint,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
      ),
    );
  }
}
