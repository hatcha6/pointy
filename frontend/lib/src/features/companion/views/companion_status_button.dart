import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/repositories/companion_repository.dart';
import '../../../shared/design/design.dart';
import '../companion_bridge.dart';
import 'companion_pairing_sheet.dart';

/// The till's one visible sign that a phone is (or is not) lending its camera.
///
/// It is deliberately always present rather than appearing only once a phone
/// pairs: in ambient mode a paired phone can put a scan into the open cart, so
/// the cashier must be able to see at a glance that something is listening —
/// and reach the pause switch in one tap.
class CompanionStatusButton extends StatelessWidget {
  const CompanionStatusButton({
    super.key,
    required this.bridge,
    required this.repository,
  });

  final CompanionBridge? bridge;
  final CompanionRepository? repository;

  @override
  Widget build(BuildContext context) {
    final bridge = this.bridge;
    final repository = this.repository;
    final l10n = AppLocalizations.of(context)!;
    // Absent before sign-in, and in previews and widget tests: render nothing
    // rather than make every app bar null-check the scope itself.
    if (bridge == null || repository == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<CompanionStatus>(
      valueListenable: bridge.status,
      builder: (context, status, _) {
        final colors = context.pointyColors;
        final (icon, tint, label) = switch (status) {
          CompanionStatus(isPaused: true) => (
            Icons.pause_circle_outline,
            colors.warning,
            l10n.companionPausedNotice,
          ),
          CompanionStatus(state: CompanionLinkState.live) => (
            Icons.smartphone,
            colors.success,
            l10n.companionStatusConnected,
          ),
          CompanionStatus(state: CompanionLinkState.polling) => (
            Icons.smartphone,
            colors.warning,
            l10n.companionStatusPolling,
          ),
          CompanionStatus(state: CompanionLinkState.connecting) => (
            Icons.sync,
            colors.mutedInk,
            l10n.companionStatusConnecting,
          ),
          _ => (
            Icons.add_a_photo_outlined,
            colors.mutedInk,
            l10n.companionStatusIdle,
          ),
        };
        return IconButton(
          tooltip: '${l10n.companionOpenSheetTooltip} — $label',
          icon: Icon(icon, color: tint),
          onPressed: () => showCompanionPairingSheet(
            context,
            repository: repository,
            bridge: bridge,
          ),
        );
      },
    );
  }
}
