import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_provider.dart';
import '../../../shared/responsive/responsive.dart';
import 'integration_presentation.dart';

/// How loudly the trigger is drawn.
enum IntegrationActionEmphasis {
  /// Alone in a pane header, where it is the only thing to press.
  filled,

  /// Among the plain icons of an app bar, where a filled button would outrank
  /// the screen's own primary action.
  ///
  /// Outlined rather than tonal: [FilledButtonThemeData] is shared by
  /// `FilledButton` and `FilledButton.tonal`, and this app's theme pins a
  /// background colour on it — so the tonal variant comes out identical to
  /// the filled one and the distinction would be invisible.
  outlined,
}

/// One entry point into a provider flow, named after the provider.
///
/// A single connected provider gets its own named button — "شحن HD Box", with
/// that provider's mark — because naming the thing is faster to hit than a
/// generic verb and it says which account is about to be spent. More than one
/// collapses into a menu rather than a row of buttons, so a header does not
/// grow a control every time a provider is added. Either way the mark and the
/// name are what the person reads; the menu just defers them by a tap.
///
/// Shared by the till (charge a customer's card) and the expenses screen
/// (record money paid into our own float). Those are two different verbs over
/// the same set of providers, so the wording is the caller's to supply and
/// every other decision is made here — once, for both.
class IntegrationActionButton extends StatelessWidget {
  const IntegrationActionButton({
    super.key,
    required this.providers,
    required this.onSelected,
    required this.icon,
    required this.menuLabel,
    required this.labelFor,
    this.emphasis = IntegrationActionEmphasis.filled,
    this.buttonKey,
    this.enabled = true,
  });

  /// Connected providers, by backend key. Empty draws nothing at all — a
  /// grocer must not be able to tell this feature shipped.
  final List<String> providers;

  final void Function(String providerKey) onSelected;

  /// Stands in for the brand mark on the menu trigger, which speaks for every
  /// provider at once and so can carry none of them.
  final IconData icon;

  /// What that trigger says when there is no single provider to name.
  final String menuLabel;

  /// The label for one named provider, given its display name.
  final String Function(String providerName) labelFor;

  final IntegrationActionEmphasis emphasis;

  /// Identifies the trigger itself rather than this wrapper, so a test or the
  /// screenshot harness can find the control the user actually presses.
  final Key? buttonKey;

  final bool enabled;

  bool _isCompact(BuildContext context) =>
      AppBreakpoints.of(context).index < AppBreakpoint.tablet.index;

  @override
  Widget build(BuildContext context) {
    if (providers.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final compact = _isCompact(context);

    if (providers.length == 1) {
      final providerKey = integrationProviderKeyFromJson(providers.first);
      return _trigger(
        compact: compact,
        label: labelFor(integrationProviderName(providerKey, l10n)),
        // The provider's own mark, on a light chip so a brand drawn for a
        // light background survives dark mode. Wider than tall because these
        // marks are: forced square at this size it letterboxes into an
        // unreadable smudge.
        leading: IntegrationProviderLogo(
          providerKey: providerKey,
          size: 22,
          aspectRatio: 1.5,
        ),
        onPressed: enabled ? () => onSelected(providers.first) : null,
      );
    }

    return MenuAnchor(
      builder: (context, controller, child) => _trigger(
        compact: compact,
        label: menuLabel,
        leading: Icon(icon),
        // Says there is a choice behind this before it is pressed. The
        // single-provider button has no arrow because it has no menu.
        trailing: true,
        onPressed: enabled
            ? (controller.isOpen ? controller.close : controller.open)
            : null,
      ),
      menuChildren: [
        for (final provider in providers)
          _menuItem(integrationProviderKeyFromJson(provider), provider, l10n),
      ],
    );
  }

  Widget _menuItem(
    IntegrationProviderKey providerKey,
    String provider,
    AppLocalizations l10n,
  ) {
    return MenuItemButton(
      onPressed: () => onSelected(provider),
      // Square here: a column of providers should line up whatever shape each
      // mark is.
      leadingIcon: IntegrationProviderLogo(providerKey: providerKey, size: 24),
      child: Text(integrationProviderName(providerKey, l10n)),
    );
  }

  Widget _trigger({
    required bool compact,
    required String label,
    required Widget leading,
    required VoidCallback? onPressed,
    bool trailing = false,
  }) {
    if (compact) {
      // No room for a label beside the other actions, so the name moves into
      // the tooltip and the generic icon carries the rest. The brand mark is
      // dropped rather than shrunk: at icon size these marks are a smudge.
      return switch (emphasis) {
        IntegrationActionEmphasis.filled => IconButton.filled(
          key: buttonKey,
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
        IntegrationActionEmphasis.outlined => IconButton(
          key: buttonKey,
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      };
    }
    final Widget content = trailing
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              const SizedBox(width: 2),
              const Icon(Icons.arrow_drop_down, size: 20),
            ],
          )
        : Text(label);
    return switch (emphasis) {
      IntegrationActionEmphasis.filled => FilledButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: leading,
        label: content,
      ),
      IntegrationActionEmphasis.outlined => OutlinedButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: leading,
        label: content,
      ),
    };
  }
}
