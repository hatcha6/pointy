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

/// A payment's state in a provider's own report (`verified`, `cancelled`…),
/// or null for one this build has no words for. Shared by the till's line
/// history and the screen that records website payments as sales.
String? integrationPaymentStatusLabel(String code, AppLocalizations l10n) {
  return switch (code) {
    'verified' => l10n.portalPaymentsProviderStatusVerified,
    'pending' => l10n.portalPaymentsProviderStatusPending,
    'cancelled' => l10n.portalPaymentsProviderStatusCancelled,
    'cancel_request' => l10n.portalPaymentsProviderStatusCancelRequest,
    'rejected' => l10n.portalPaymentsProviderStatusRejected,
    _ => null,
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

/// What the credentials form asks for as the login, per provider.
///
/// Qareeb's login IS the agency's phone number, and calling it a username in
/// front of an owner holding the app's own login screen in mind would make
/// them guess. Everyone else logs in with a username.
({String label, String hint, String required, IconData icon, bool isPhone})
integrationUsernameCopy(IntegrationProviderKey key, AppLocalizations l10n) {
  return switch (key) {
    IntegrationProviderKey.qareeb => (
      label: l10n.integrationFieldPhone,
      hint: l10n.integrationFieldPhoneHint,
      required: l10n.integrationPhoneRequired,
      icon: Icons.phone_iphone_outlined,
      isPhone: true,
    ),
    _ => (
      label: l10n.integrationFieldUsername,
      hint: '',
      required: l10n.integrationUsernameRequired,
      icon: Icons.person_outline,
      isPhone: false,
    ),
  };
}

/// The provider's own word for a profile, in Arabic.
String integrationProfileKindLabel(String kind, AppLocalizations l10n) {
  return switch (kind) {
    'individual' => l10n.integrationProfileKindIndividual,
    'store_employee' => l10n.integrationProfileKindStoreEmployee,
    'store' || 'store_owner' => l10n.integrationProfileKindStore,
    _ => '',
  };
}

/// What a cashier is being asked to type, per provider.
///
/// HD Box identifies a subscriber by a card number on a physical card; LNET by
/// the phone number, username or contract the line was sold under. Asking for
/// "the card number" in front of an LNET customer who has no card is the kind
/// of small wrongness that makes a cashier distrust the screen.
({String label, String hint, String prompt}) integrationSubscriberPrompt(
  IntegrationProviderKey key,
  AppLocalizations l10n,
) {
  return switch (key) {
    IntegrationProviderKey.lnet => (
      label: l10n.rechargeSearchLabelLine,
      hint: l10n.rechargeSearchHintLine,
      prompt: l10n.rechargeIdlePromptLine,
    ),
    _ => (
      label: l10n.rechargeSearchLabel,
      hint: l10n.rechargeSearchHint,
      prompt: l10n.rechargeIdlePrompt,
    ),
  };
}

/// Arabic for one of the ways a portal can be searched.
///
/// Stable codes in, Arabic out, like every other string on this screen. The
/// picker these label sits in front of the search box and is the difference
/// between one round trip to the provider and three.
({String label, IconData icon}) integrationSearchModeLabel(
  IntegrationSearchMode mode,
  AppLocalizations l10n,
) {
  return switch (mode) {
    IntegrationSearchMode.phone => (
      label: l10n.rechargeSearchByPhone,
      icon: Icons.phone_iphone_outlined,
    ),
    IntegrationSearchMode.username => (
      label: l10n.rechargeSearchByUsername,
      icon: Icons.person_outline,
    ),
    IntegrationSearchMode.contract => (
      label: l10n.rechargeSearchByContract,
      icon: Icons.description_outlined,
    ),
  };
}

/// Arabic wording for a declared provider setting.
///
/// Keyed on the stable code like every other provider string, so a new setting
/// is a backend change plus one line here — never a schema the client has to
/// learn.
({String label, String hint, IconData icon}) integrationSettingLabel(
  String key,
  AppLocalizations l10n,
) {
  return switch (key) {
    IntegrationSettingKey.commissionPercent => (
      label: l10n.integrationSettingCommission,
      hint: l10n.integrationSettingCommissionHint,
      icon: Icons.percent_outlined,
    ),
    IntegrationSettingKey.denominations => (
      label: l10n.integrationSettingDenominations,
      hint: l10n.integrationSettingDenominationsHint,
      icon: Icons.apps_outlined,
    ),
    IntegrationSettingKey.lowBalanceThreshold => (
      label: l10n.integrationSettingLowBalance,
      hint: l10n.integrationSettingLowBalanceHint,
      icon: Icons.battery_alert_outlined,
    ),
    _ => (label: key, hint: '', icon: Icons.tune_outlined),
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
    // Its own message because it is the one failure a shop can fix itself,
    // and the fix is a different screen from "try again".
    IntegrationErrorCode.insufficientFloat =>
      l10n.integrationErrorInsufficientFloat,
    // Not a failure at all: a write went out and nobody knows what it did.
    IntegrationErrorCode.indeterminate => l10n.integrationErrorIndeterminate,
    IntegrationErrorCode.deviceVerificationRequired =>
      l10n.integrationErrorDeviceVerification,
    IntegrationErrorCode.attestationRequired =>
      l10n.integrationErrorAttestation,
    IntegrationErrorCode.outOfStock => l10n.integrationErrorOutOfStock,
    IntegrationErrorCode.pinRequired => l10n.integrationErrorPinRequired,
    IntegrationErrorCode.verificationRejected =>
      l10n.integrationErrorVerificationRejected,
    IntegrationErrorCode.busy => l10n.integrationErrorBusy,
    IntegrationErrorCode.profileMismatch =>
      l10n.integrationErrorProfileMismatch,
    _ => l10n.integrationErrorUnexpected,
  };
}

String integrationCapabilityLabel(String code, AppLocalizations l10n) {
  return switch (code) {
    IntegrationCapability.balance => l10n.integrationCapabilityBalance,
    IntegrationCapability.lookup => l10n.integrationCapabilityLookup,
    IntegrationCapability.recharge => l10n.integrationCapabilityRecharge,
    IntegrationCapability.vouchers => l10n.integrationCapabilityVouchers,
    IntegrationCapability.profiles => l10n.integrationCapabilityProfiles,
    _ => code,
  };
}

String integrationFieldLabel(String field, AppLocalizations l10n) {
  return switch (field) {
    IntegrationField.baseUrl => l10n.integrationFieldBaseUrl,
    IntegrationField.username => l10n.integrationFieldUsername,
    IntegrationField.password => l10n.integrationFieldPassword,
    IntegrationField.pin => l10n.integrationFieldPin,
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

  /// Marks that are a whole app tile already — Qareeb's is its orange app
  /// icon. Those fill the box: a white chip around a tile reads as a frame
  /// around a picture of a frame.
  static bool _isTile(IntegrationProviderKey key) =>
      key == IntegrationProviderKey.qareeb;

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
            if (_isTile(providerKey)) {
              return child;
            }
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
