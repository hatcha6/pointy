import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/portal_payment.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../settings/views/integration_presentation.dart';

/// Arabic wording, tone and icon for a website payment and its refusals.
///
/// The server sends stable codes (`apps.integrations.portal_sales`) and
/// nothing a person reads, so every such sentence is chosen here.
String portalPaymentStateLabel(
  PortalPaymentState state,
  AppLocalizations l10n,
) {
  return switch (state) {
    PortalPaymentState.recorded => l10n.portalPaymentsStateRecorded,
    PortalPaymentState.released => l10n.portalPaymentsStateReleased,
    PortalPaymentState.pendingSale => l10n.portalPaymentsStatePendingSale,
    PortalPaymentState.unrecorded => l10n.portalPaymentsStateUnrecorded,
    PortalPaymentState.notVerified => l10n.portalPaymentsStateNotVerified,
    PortalPaymentState.otherOperator => l10n.portalPaymentsStateOtherOperator,
    PortalPaymentState.unsupported => l10n.portalPaymentsStateUnsupported,
    PortalPaymentState.unknown => l10n.portalPaymentsStateUnknown,
  };
}

Color portalPaymentStateColor(
  PortalPaymentState state,
  PointySemanticColors colors,
) {
  return switch (state) {
    PortalPaymentState.recorded => colors.success,
    // Money nobody has accounted for: the thing this screen exists to clear.
    PortalPaymentState.unrecorded ||
    PortalPaymentState.released => colors.danger,
    PortalPaymentState.pendingSale => colors.warning,
    PortalPaymentState.notVerified ||
    PortalPaymentState.otherOperator ||
    PortalPaymentState.unsupported ||
    PortalPaymentState.unknown => colors.mutedInk,
  };
}

IconData portalPaymentStateIcon(PortalPaymentState state) {
  return switch (state) {
    PortalPaymentState.recorded => Icons.check_circle_outline,
    PortalPaymentState.unrecorded => Icons.error_outline,
    PortalPaymentState.released => Icons.replay_outlined,
    PortalPaymentState.pendingSale => Icons.link_outlined,
    PortalPaymentState.notVerified => Icons.hourglass_empty_outlined,
    PortalPaymentState.otherOperator => Icons.person_outline,
    PortalPaymentState.unsupported ||
    PortalPaymentState.unknown => Icons.help_outline,
  };
}

/// The provider's own state for a payment, in Arabic when it is one we know.
String portalPaymentProviderStatusLabel(
  PortalPayment payment,
  AppLocalizations l10n,
) {
  return integrationPaymentStatusLabel(payment.providerStatus, l10n) ??
      (payment.providerStatusLabel.isEmpty
          ? payment.providerStatus
          : payment.providerStatusLabel);
}

/// Why a payment cannot be recorded as a sale, or null when it can.
String? portalPaymentWhyNot(PortalPayment payment, AppLocalizations l10n) {
  return switch (payment.state) {
    PortalPaymentState.notVerified => l10n.portalPaymentsWhyNotVerified(
      portalPaymentProviderStatusLabel(payment, l10n),
    ),
    PortalPaymentState.otherOperator => l10n.portalPaymentsWhyOtherOperator(
      payment.operatorName,
    ),
    PortalPaymentState.unsupported ||
    PortalPaymentState.unknown => l10n.portalPaymentsWhyUnsupported,
    _ => null,
  };
}

/// A refusal, or any failure, as one sentence a manager can act on.
String portalPaymentFailureMessage(Exception failure, AppLocalizations l10n) {
  if (failure is! PortalPaymentRefusal) {
    return l10n.portalPaymentsErrorGeneric;
  }
  return switch (failure.code) {
    'already_recorded' => l10n.portalPaymentsErrorAlreadyRecorded,
    'pending_sale' => l10n.portalPaymentsErrorPendingSale,
    'not_verified' => l10n.portalPaymentsErrorNotVerified,
    'payment_not_confirmed' ||
    'payment_not_found' => l10n.portalPaymentsErrorNotConfirmed,
    'provider_unavailable' => l10n.portalPaymentsErrorProviderUnavailable,
    'register_session_not_found' => l10n.portalPaymentsErrorSessionNotFound,
    'session_closed_before_payment' => l10n.portalPaymentsErrorClosedBefore,
    'period_locked' => l10n.portalPaymentsErrorPeriodLocked,
    'price_changed' => l10n.portalPaymentsErrorPriceChanged(
      formatMoney(failure.total ?? 0),
    ),
    'customer_required' => l10n.portalPaymentsCustomerRequired,
    'invalid_amount_paid' => l10n.portalPaymentsErrorAmountPaid,
    'payment_method_required' => l10n.portalPaymentsErrorMethodRequired,
    'not_this_sale' => l10n.portalPaymentsErrorNotThisSale,
    'other_operator' => l10n.portalPaymentsStateOtherOperator,
    'unsupported' ||
    'unsupported_provider' => l10n.portalPaymentsWhyUnsupported,
    'sale_refused' ||
    'credit_limit_exceeded' => l10n.portalPaymentsErrorSaleRefused,
    _ => l10n.portalPaymentsErrorGeneric,
  };
}
