import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// Arabic for the SMS error codes the backend and the relay report.
///
/// The server sends stable codes (`monthly_limit`, `provider_credit`, …) on a
/// failed message and on a refused send, and every sentence a shop reads about
/// them is chosen here — so the settings page's test send, the gateway's last
/// error and the invoice's "send as message" all say the same thing. Null for
/// a code this build has no words for; the caller then shows the server's own.
String? messagingErrorMessage(String code, AppLocalizations l10n) {
  return switch (code.trim()) {
    'not_entitled' || 'unauthorized' => l10n.messagingErrorNotEntitled,
    'service_disabled' => l10n.messagingErrorServiceDisabled,
    'monthly_limit' => l10n.messagingErrorMonthlyLimit,
    'rate_limited' => l10n.messagingErrorRateLimited,
    'template_not_configured' ||
    'unknown_kind' => l10n.messagingErrorTemplateNotConfigured,
    'template_required' => l10n.messagingErrorTemplateRequired,
    'invalid_phone' || 'bad_number' => l10n.messagingErrorInvalidPhone,
    'provider_credit' => l10n.messagingErrorProviderCredit,
    'provider_unauthorized' => l10n.messagingErrorProviderUnauthorized,
    'provider_rejected' => l10n.messagingErrorProviderRejected,
    'provider_error' || 'outcome_unknown' => l10n.messagingErrorOutcomeUnknown,
    'sms_unconfigured' ||
    'relay_unconfigured' ||
    'no_gateway' => l10n.messagingErrorSmsUnconfigured,
    'relay_unreachable' => l10n.messagingErrorRelayUnreachable,
    'driver_error' || 'relay_error' => l10n.messagingErrorDriverError,
    'delivery_failed' => l10n.messagingErrorDeliveryFailed,
    _ => null,
  };
}

/// The one sentence for a failed send: the code's own when it has one, else
/// the server's words, else [fallback]. A provider rejection keeps the
/// provider's reason on a second line — it is the only clue to what in the
/// text was refused.
String messagingFailureMessage(
  AppLocalizations l10n, {
  String code = '',
  String detail = '',
  required String fallback,
}) {
  final mapped = messagingErrorMessage(code, l10n);
  final reason = detail.trim();
  if (mapped == null) {
    return reason.isNotEmpty ? reason : fallback;
  }
  if (code.trim() == 'provider_rejected' && reason.isNotEmpty) {
    return '$mapped\n$reason';
  }
  return mapped;
}
