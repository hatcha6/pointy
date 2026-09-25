import 'dart:async';

import 'package:http/http.dart' as http;

import '../../../data/services/api_error_detail.dart';
import '../../../data/services/api_session.dart';

/// Why a sign-in did not go through, as far as the app can tell.
///
/// Until this existed every failure was one message — "check the username
/// and password" — including a relay that had lost the device's ticket, a
/// shop whose server was not connected to the relay, and a phone with no
/// internet. A cashier outside the shop retyped a correct password against a
/// server that was never reached, and support heard "wrong password".
enum LoginFailure {
  /// The backend refused the username/password pair.
  invalidCredentials,

  /// The backend knows the account and it is disabled.
  accountDisabled,

  /// The backend's sign-in throttle, per address or per username.
  tooManyAttempts,

  /// The relay no longer holds this device's ticket and could not mint one
  /// from its refresh token: the device has to pair again on the shop's LAN.
  relayRejected,

  /// The relay refused because the shop's remote-access subscription is off.
  relaySubscriptionInactive,

  /// The relay is up, but the shop's server is not connected to it.
  relayConnectorOffline,

  /// The relay answered with some other failure of its own — a request that
  /// timed out on the tunnel, a bad gateway, its rate limit.
  relayUnavailable,

  /// The relay itself could not be reached from this device.
  relayUnreachable,

  /// The shop's server could not be reached on the LAN.
  serverUnreachable,

  /// The backend answered, but not with a sign-in.
  serverError,
}

extension LoginFailureKind on LoginFailure {
  /// A failure of the way to the server rather than of the sign-in itself —
  /// the kind worth showing before the person even types, since no password
  /// will get past it.
  bool get isConnectionProblem => switch (this) {
    LoginFailure.relayRejected ||
    LoginFailure.relaySubscriptionInactive ||
    LoginFailure.relayConnectorOffline ||
    LoginFailure.relayUnavailable ||
    LoginFailure.relayUnreachable ||
    LoginFailure.serverUnreachable => true,
    LoginFailure.invalidCredentials ||
    LoginFailure.accountDisabled ||
    LoginFailure.tooManyAttempts ||
    LoginFailure.serverError => false,
  };
}

/// Reads [error] — what the sign-in call threw — into a [LoginFailure].
///
/// [viaRelay] says which route the session was on: a transport failure on
/// the relay is the phone's own internet, on the LAN it is the shop's server.
LoginFailure classifyLoginFailure(Object error, {required bool viaRelay}) {
  if (error is PosApiException) {
    return _classifyApiFailure(error);
  }
  if (_isTransportFailure(error)) {
    return viaRelay
        ? LoginFailure.relayUnreachable
        : LoginFailure.serverUnreachable;
  }
  return LoginFailure.serverError;
}

LoginFailure _classifyApiFailure(PosApiException error) {
  if (error.fromRelay) {
    return switch (error.statusCode) {
      401 => LoginFailure.relayRejected,
      402 => LoginFailure.relaySubscriptionInactive,
      503 when _mentions(error, 'connector offline') =>
        LoginFailure.relayConnectorOffline,
      _ => LoginFailure.relayUnavailable,
    };
  }
  return switch (error.statusCode) {
    // The backend's own refusal of the pair — a validation error, so 400.
    400 when _mentions(error, 'disabled') => LoginFailure.accountDisabled,
    400 => LoginFailure.invalidCredentials,
    429 => LoginFailure.tooManyAttempts,
    _ => LoginFailure.serverError,
  };
}

bool _mentions(PosApiException error, String fragment) {
  final detail = apiErrorDetail(error).toLowerCase();
  if (detail.contains(fragment)) {
    return true;
  }
  // The relay's bodies name their reason under `error`, not `detail`.
  final decoded = error.decodedBody;
  final relayError = decoded is Map ? decoded['error'] : null;
  return relayError is String && relayError.toLowerCase().contains(fragment);
}

/// Whether [error] is the connection failing rather than the server
/// answering. Matched by name for the `dart:io` types, since this file must
/// also compile for the web build.
bool _isTransportFailure(Object error) {
  if (error is TimeoutException || error is http.ClientException) {
    return true;
  }
  final typeName = error.runtimeType.toString();
  return typeName.contains('SocketException') ||
      typeName.contains('HandshakeException') ||
      typeName.contains('TlsException') ||
      typeName.contains('HttpException');
}
