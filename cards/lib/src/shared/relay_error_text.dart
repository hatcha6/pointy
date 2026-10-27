import '../../l10n/generated/app_localizations.dart';
import '../core/money.dart';
import '../data/api/relay_api.dart';
import 'money_text.dart';

/// What to tell the customer about a relay refusal, in their words.
String relayErrorText(AppLocalizations l10n, Object error) {
  if (error is! RelayApiException) {
    return l10n.errorGeneric;
  }
  final attempts = (error.body['attempts_left'] as num?)?.toInt() ?? 0;
  return switch (error.code) {
    'network' => l10n.errorNetwork,
    'invalid_phone' => l10n.errInvalidPhone,
    'wrong_code' => l10n.errWrongCode(attempts),
    'code_expired' => l10n.errCodeExpired,
    'too_many_attempts' => l10n.errTooManyAttempts,
    'account_blocked' => l10n.errAccountBlocked,
    'too_soon' => l10n.errTooSoon,
    'daily_limit' => l10n.errDailyLimit,
    'send_failed' => l10n.errSendFailed,
    'rate_limited' => l10n.errRateLimited,
    'unauthorized' ||
    'token_expired' ||
    'invalid_refresh' => l10n.errSignInRequired,
    'otp_rejected' => l10n.errOtpRejected(attempts),
    'otp_attempts_exceeded' => l10n.errTooManyAttempts,
    'declined' || 'payer_rejected' => l10n.errDeclined,
    'price_changed' => l10n.errPriceChanged(
      formatMoney(l10n, Money.parse(error.body['unit_price'] as String?)),
    ),
    'item_unavailable' || 'unknown_item' => l10n.errItemUnavailable,
    'payments_unavailable' ||
    'cards_unavailable' ||
    'customers_unconfigured' => l10n.errPaymentsUnavailable,
    'invalid_phone_number' ||
    'invalid_card_number' ||
    'invalid_birth_year' => l10n.errInvalidPayer,
    'gateway_rejected' ||
    'gateway_error' ||
    'gateway_busy' ||
    'method_unavailable' => l10n.errPaymentFailed,
    _ => error.isNetwork ? l10n.errorNetwork : l10n.errorGeneric,
  };
}

/// Whether [error] is a passing problem, worth simply trying again (no
/// connection, a busy gateway, too many requests at once), rather than a
/// refusal the customer has to act on (a wrong code, a declined payment).
/// The first feels gentler: a warning, not an error.
bool relayErrorIsPassing(Object error) {
  if (error is! RelayApiException) {
    return false;
  }
  return error.isNetwork ||
      const {
        'network',
        'rate_limited',
        'gateway_busy',
        'gateway_error',
        'payments_unavailable',
        'cards_unavailable',
        'send_failed',
      }.contains(error.code);
}
