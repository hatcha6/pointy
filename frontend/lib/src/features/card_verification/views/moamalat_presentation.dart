import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/moamalat.dart';
import '../../../shared/design/design.dart';

/// The link's state as the supervisor reads it: label, icon, colour.
({String label, IconData icon, Color color}) moamalatStatePresentation(
  BuildContext context,
  MoamalatStatus status,
) {
  final l10n = AppLocalizations.of(context)!;
  final colors = context.pointyColors;
  if (status.switchedOff) {
    return (
      label: l10n.moamalatStateSwitchedOff,
      icon: Icons.pause_circle_outline,
      color: colors.mutedInk,
    );
  }
  return switch (status.state) {
    MoamalatLinkState.alive when status.atRisk => (
      label: l10n.moamalatStateAtRisk,
      icon: Icons.wifi_tethering_error,
      color: colors.warning,
    ),
    MoamalatLinkState.alive => (
      label: l10n.moamalatStateAlive,
      icon: Icons.verified_outlined,
      color: colors.success,
    ),
    MoamalatLinkState.needsReauth => (
      label: l10n.moamalatStateNeedsReauth,
      icon: Icons.lock_clock_outlined,
      color: colors.danger,
    ),
    MoamalatLinkState.unlinked => (
      label: l10n.moamalatStateUnlinked,
      icon: Icons.link_off,
      color: colors.mutedInk,
    ),
  };
}

/// A refused link step in Arabic. Moamalat's own words win when it sent
/// some (a wrong password, a wrong code).
String moamalatFailureText(AppLocalizations l10n, MoamalatLinkFailure failure) {
  if (failure.detail.trim().isNotEmpty) {
    return failure.detail.trim();
  }
  return switch (failure.code) {
    'switched_off' => l10n.moamalatErrorSwitchedOff,
    'credentials_required' => l10n.moamalatErrorCredentialsRequired,
    'login_refused' => l10n.moamalatErrorLoginRefused,
    'code_refused' => l10n.moamalatErrorCodeRefused,
    'code_required' => l10n.moamalatErrorCodeRequired,
    'challenge_expired' => l10n.moamalatErrorChallengeExpired,
    'no_merchant' => l10n.moamalatErrorNoMerchant,
    'unknown_merchant' => l10n.moamalatErrorUnknownMerchant,
    'not_linked' => l10n.moamalatErrorNotLinked,
    'forbidden' => l10n.moamalatErrorForbidden,
    _ => l10n.moamalatErrorUnreachable,
  };
}
