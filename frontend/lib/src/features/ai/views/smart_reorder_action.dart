import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../shared/design/pointy_theme_extensions.dart';
import '../../../shared/navigation/app_navigation.dart';

/// Whether the "Smart Reorder" entry should be offered: the shop has an active
/// AI entitlement (the assistant destination is reachable) AND the user may
/// create purchase orders (the action this flow ultimately performs).
bool canSmartReorder(
  AppNavigation navigation,
  AuthorizationCapabilities capabilities,
) {
  return navigation.isDestinationAvailable(AppNavigationDestination.aiAssistant) &&
      capabilities.canCreatePurchaseOrder;
}

/// A labeled AppBar action that kicks off AI-driven smart reordering. Hidden
/// entirely when [canSmartReorder] is false, so callers can drop it into an
/// `actions:` list unconditionally.
///
/// Tapping it opens the AI chat with an auto-sent seed prompt. The assistant
/// calls the `reorder_plan` tool, chooses the best supplier per item from its
/// ranked candidates, and creates one draft purchase order per supplier —
/// deep-linking each back into the app.
class SmartReorderAction extends StatelessWidget {
  const SmartReorderAction({
    super.key,
    required this.navigation,
    required this.capabilities,
    required this.from,
  });

  final AppNavigation navigation;
  final AuthorizationCapabilities capabilities;

  /// The screen the user launched from, for navigation analytics/back-stack.
  final AppNavigationDestination from;

  @override
  Widget build(BuildContext context) {
    if (!canSmartReorder(navigation, capabilities)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 4),
      child: TextButton.icon(
        onPressed: () => launchSmartReorder(
          context,
          navigation: navigation,
          capabilities: capabilities,
          from: from,
        ),
        icon: const Icon(Icons.auto_awesome, size: 18),
        label: Text(l10n.smartReorderButton),
        style: TextButton.styleFrom(foregroundColor: colors.primaryStrong),
      ),
    );
  }
}

/// Opens the AI chat with an auto-sent smart-reorder seed prompt. Safe to call
/// directly (e.g. from an overflow menu item).
void launchSmartReorder(
  BuildContext context, {
  required AppNavigation navigation,
  required AuthorizationCapabilities capabilities,
  required AppNavigationDestination from,
}) {
  if (!canSmartReorder(navigation, capabilities)) {
    return;
  }
  final l10n = AppLocalizations.of(context)!;
  navigation.openAiChat(
    context,
    seedPrompt: l10n.smartReorderSeed,
    autoSend: true,
    from: from,
  );
}
