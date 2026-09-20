import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_provider.dart';
import '../../../shared/design/design.dart';

/// Arabic wording and iconography for the resale providers.
///
/// The backend sends stable codes and nothing else — the same arrangement the
/// treasury component codes use — so every string a shop owner reads about an
/// integration is chosen here.
String integrationProviderName(
  IntegrationProviderKey key,
  AppLocalizations l10n,
) {
  return switch (key) {
    IntegrationProviderKey.hdbox => l10n.integrationProviderHdboxName,
    IntegrationProviderKey.lnet => l10n.integrationProviderLnetName,
    IntegrationProviderKey.qareeb => l10n.integrationProviderQareebName,
    IntegrationProviderKey.unknown => l10n.integrationProviderUnknownName,
  };
}

String integrationProviderTagline(
  IntegrationProviderKey key,
  AppLocalizations l10n,
) {
  return switch (key) {
    IntegrationProviderKey.hdbox => l10n.integrationProviderHdboxTagline,
    IntegrationProviderKey.lnet => l10n.integrationProviderLnetTagline,
    IntegrationProviderKey.qareeb => l10n.integrationProviderQareebTagline,
    IntegrationProviderKey.unknown => l10n.integrationProviderUnknownTagline,
  };
}

IconData integrationProviderIcon(IntegrationProviderKey key) {
  return switch (key) {
    IntegrationProviderKey.hdbox => Icons.live_tv_outlined,
    IntegrationProviderKey.lnet => Icons.router_outlined,
    IntegrationProviderKey.qareeb => Icons.confirmation_number_outlined,
    IntegrationProviderKey.unknown => Icons.extension_outlined,
  };
}

/// Asset path for a provider's brand mark. Missing files are fine — see
/// [IntegrationProviderLogo].
String integrationProviderLogoAsset(IntegrationProviderKey key) =>
    'assets/integrations/${integrationProviderKeyToJson(key)}.png';

String integrationBlockedReasonText(String code, AppLocalizations l10n) {
  return switch (code) {
    IntegrationBlockedReason.portalUnreachable =>
      l10n.integrationBlockedPortalUnreachable,
    IntegrationBlockedReason.awaitingAccess =>
      l10n.integrationBlockedAwaitingAccess,
    IntegrationBlockedReason.driverInProgress =>
      l10n.integrationBlockedDriverInProgress,
    _ => l10n.integrationBlockedAwaitingAccess,
  };
}

String integrationErrorText(String code, AppLocalizations l10n) {
  return switch (code) {
    IntegrationErrorCode.notConfigured => l10n.integrationErrorNotConfigured,
    IntegrationErrorCode.unavailable => l10n.integrationErrorUnavailable,
    IntegrationErrorCode.unreachable => l10n.integrationErrorUnreachable,
    IntegrationErrorCode.unauthorized => l10n.integrationErrorUnauthorized,
    IntegrationErrorCode.notFound => l10n.integrationErrorNotFound,
    IntegrationErrorCode.providerError => l10n.integrationErrorProviderError,
    _ => l10n.integrationErrorUnexpected,
  };
}

String integrationCapabilityLabel(String code, AppLocalizations l10n) {
  return switch (code) {
    IntegrationCapability.balance => l10n.integrationCapabilityBalance,
    IntegrationCapability.lookup => l10n.integrationCapabilityLookup,
    IntegrationCapability.recharge => l10n.integrationCapabilityRecharge,
    _ => code,
  };
}

String integrationFieldLabel(String field, AppLocalizations l10n) {
  return switch (field) {
    IntegrationField.baseUrl => l10n.integrationFieldBaseUrl,
    IntegrationField.username => l10n.integrationFieldUsername,
    IntegrationField.password => l10n.integrationFieldPassword,
    _ => field,
  };
}

/// The provider's own status word, in Arabic.
///
/// HD Box answers in English ("Active", "On hold", "Soon to expire") and that
/// wording reaches the till, the card history and the subscriber record. It
/// was passed through verbatim at first on the theory that a cashier might be
/// asked to read it back over the phone — but an English word sitting in an
/// Arabic screen reads as a bug, and the card number is what anyone actually
/// quotes. Unknown values fall through unchanged rather than vanishing, so a
/// state we have not seen still says *something*.
String providerStatusLabel(String raw, AppLocalizations l10n) {
  final normalized = raw.trim().toLowerCase();
  return switch (normalized) {
    'active' => l10n.integrationStatusActive,
    'on hold' || 'onhold' => l10n.integrationStatusOnHold,
    'soon to expire' || 'soon_to_expire' => l10n.integrationStatusSoonToExpire,
    'inactive' => l10n.integrationStatusInactive,
    'lock' || 'locked' => l10n.integrationStatusLocked,
    'suspend' || 'suspended' => l10n.integrationStatusSuspended,
    'expire' || 'expired' => l10n.integrationStatusExpired,
    _ => raw.trim(),
  };
}

/// A provider's brand mark, or a themed icon when there is no artwork.
///
/// Brand marks are drawn for a light background and ship with a transparent
/// one — HD Box's is black type on nothing, which disappears entirely in dark
/// mode. So the mark always sits on a light chip rather than being tinted or
/// inverted: it stays the artwork the provider published, and it stays legible
/// in both themes. The icon fallback is themed normally, because that one is
/// ours to colour.
class IntegrationProviderLogo extends StatelessWidget {
  const IntegrationProviderLogo({
    super.key,
    required this.providerKey,
    this.size = 48,
    this.aspectRatio = 1,
  });

  final IntegrationProviderKey providerKey;

  /// Height of the chip. Width is [size] × [aspectRatio].
  final double size;

  /// Square in a list, so a column of providers lines up whatever shape each
  /// mark is. Wider inline, where a landscape mark squeezed into a square
  /// loses a third of its height to letterboxing and stops being readable.
  final double aspectRatio;

  /// Light enough for black artwork in either theme, warm enough not to read
  /// as a hole punched in the surface.
  static const Color _chip = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final radius = BorderRadius.circular(size <= 28 ? 6 : PointyRadii.card);

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        height: size,
        width: size * aspectRatio,
        child: Image.asset(
          integrationProviderLogoAsset(providerKey),
          fit: BoxFit.contain,
          // A provider with no artwork yet is the normal case, not a bug.
          errorBuilder: (context, error, stackTrace) => DecoratedBox(
            decoration: BoxDecoration(
              color: colors.primaryStrong.withValues(alpha: 0.10),
            ),
            child: Icon(
              integrationProviderIcon(providerKey),
              color: colors.primaryStrong,
            ),
          ),
          frameBuilder: (context, child, frame, wasSynchronous) {
            // Only artwork gets the chip. Wrapping the fallback too would put
            // a white square behind a themed icon.
            return DecoratedBox(
              decoration: const BoxDecoration(color: _chip),
              child: Padding(
                padding: EdgeInsets.all(size * 0.12),
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }
}
