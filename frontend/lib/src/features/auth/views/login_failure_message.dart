import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../view_models/login_failure.dart';

/// The sentence the login screen shows for [failure].
String loginFailureMessage(LoginFailure failure, AppLocalizations l10n) {
  return switch (failure) {
    LoginFailure.invalidCredentials => l10n.loginError,
    LoginFailure.accountDisabled => l10n.loginErrorAccountDisabled,
    LoginFailure.tooManyAttempts => l10n.loginErrorTooManyAttempts,
    LoginFailure.relayRejected => l10n.loginErrorRelayRejected,
    LoginFailure.relaySubscriptionInactive =>
      l10n.loginErrorRelaySubscriptionInactive,
    LoginFailure.relayConnectorOffline => l10n.loginErrorRelayConnectorOffline,
    LoginFailure.relayUnavailable => l10n.loginErrorRelayUnavailable,
    LoginFailure.relayUnreachable => l10n.loginErrorRelayUnreachable,
    LoginFailure.serverUnreachable => l10n.loginErrorServerUnreachable,
    LoginFailure.serverError => l10n.loginErrorServer,
  };
}
