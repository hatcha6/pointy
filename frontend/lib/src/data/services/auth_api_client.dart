import 'package:http/http.dart' as http;

import '../models/onboarding.dart';
import '../models/password_policy.dart';
import '../models/pos_user.dart';
import 'api_session.dart';

class AuthApiClient {
  const AuthApiClient(this._session);

  final PosApiSession _session;

  /// How long the sign-in path waits before giving up.
  ///
  /// Sized against a person standing at a till, not against the network stack.
  /// Nothing here set a timeout, so these calls inherited the 60s default and
  /// in practice hit the operating system first: Windows retries an unanswered
  /// TCP SYN at 3s, 6s and 12s before failing, which is exactly the 21.0–21.1s
  /// wall these four endpoints all stopped at. A cashier stared at a spinner
  /// for 21 seconds to be told the shop's server is unreachable — something the
  /// app could have said in five.
  ///
  /// Short on purpose: sign-in carries no cart and changes nothing that a
  /// retry could double up, so failing early is free.
  static const Duration authTimeout = Duration(seconds: 5);

  /// The same calls through the relay: phone to relay to the shop's uplink
  /// to the backend and back. Field data put a single relay round trip from a
  /// shop with a poor uplink at about eight seconds, so the LAN's five-second
  /// wall failed a sign-in from outside the shop before the backend could
  /// answer — and the failure was reported as a wrong password.
  static const Duration relayAuthTimeout = Duration(seconds: 15);

  Duration get _timeout => _session.usesRelay ? relayAuthTimeout : authTimeout;

  Future<OnboardingStatus> fetchOnboardingStatus() async {
    final response = await _session.get('setup/status/', timeout: _timeout);
    _session.throwApiException(
      response,
      'Onboarding status request failed with status',
    );
    final decoded = _session.decodedBody(response) as Map<String, Object?>;
    return OnboardingStatus.fromJson(decoded);
  }

  Future<PosUser> createInitialAdmin(InitialAdminDraft draft) async {
    final response = await _session.post(
      'setup/admin/',
      body: draft.toJson(),
      includeCsrf: false,
    );
    _session.ensureSuccess(response, 'Initial admin setup failed with status');
    return _decodeUserResponse(response);
  }

  Future<PosUser> login({
    required String username,
    required String password,
  }) async {
    // The CSRF token rides along when the session holds one. A sign-in with
    // no session is not CSRF-checked and the header is ignored — but a
    // sign-in that still carries a live session cookie (the app reached the
    // login screen because a probe failed, not because the session ended) is
    // authenticated by that cookie first, and DRF then demands the token: a
    // sign-in without it was refused with 403, and shown as a wrong password.
    final response = await _session.post(
      'auth/login/',
      body: {'username': username, 'password': password},
      timeout: _timeout,
    );
    // Typed, not a bare message: the status and body are what tell a wrong
    // password from a relay that refused the ticket or a shop that is offline.
    _session.throwApiException(response, 'Login failed with status');
    return _decodeUserResponse(response);
  }

  Future<void> logout() async {
    final response = await _session.post('auth/logout/', timeout: _timeout);
    _session.ensureSuccess(response, 'Logout failed with status');
    _session.clearAuthState();
  }

  Future<PosUser?> fetchCurrentUser() async {
    final response = await _session.get('auth/me/', timeout: _timeout);
    // Signed out — as the backend says it, not the relay. A 401 of the relay's
    // own means the ticket is refused, and the session may be perfectly
    // alive behind it; treating that as "signed out" sent the phone to a
    // login screen on which no sign-in could ever succeed.
    if ((response.statusCode == 401 || response.statusCode == 403) &&
        !isRelayError(response)) {
      return null;
    }

    _session.throwApiException(
      response,
      'Current user request failed with status',
    );
    return _decodeUserResponse(response);
  }

  Future<PosUser> updateCurrentUser(CurrentUserProfileDraft draft) async {
    final response = await _session.patch('auth/me/', body: draft.toJson());
    _session.ensureSuccess(response, 'Current user update failed with status');
    return _decodeUserResponse(response);
  }

  Future<void> changePassword(PasswordChangeDraft draft) async {
    final response = await _session.post(
      'auth/password/change/',
      body: draft.toJson(),
    );
    // throwApiException, not ensureSuccess: the body carries which rule was
    // broken (and whether it was the *current* password that was wrong), and
    // that reason is the whole point of the form's feedback.
    _session.throwApiException(response, 'Password change failed with status');
  }

  Future<PasswordPolicy> fetchPasswordPolicy() async {
    final response = await _session.get('auth/password/policy/');
    _session.ensureSuccess(
      response,
      'Password policy request failed with status',
    );
    return PasswordPolicy.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  PosUser _decodeUserResponse(http.Response response) {
    final decoded = _session.decodedBody(response) as Map<String, Object?>;
    _session.updateCsrfToken(decoded);
    final userJson = decoded['user'] is Map<String, Object?>
        ? Map<String, Object?>.from(decoded['user'] as Map<String, Object?>)
        : Map<String, Object?>.from(decoded);
    // ai_available is a sibling of `user` in the auth payload; fold it onto the
    // user so capability computation can gate the AI assistant on it.
    if (decoded.containsKey('ai_available')) {
      userJson['ai_available'] = decoded['ai_available'];
    }
    // Same shape: the cashier customer-access shop flag rides alongside `user`.
    if (decoded.containsKey('allow_cashier_customer_access')) {
      userJson['allow_cashier_customer_access'] =
          decoded['allow_cashier_customer_access'];
    }
    // And the camera feature flag, so a shop with no DVR never renders a
    // camera surface — not even to discover it is empty.
    if (decoded.containsKey('surveillance_enabled')) {
      userJson['surveillance_enabled'] = decoded['surveillance_enabled'];
    }
    return PosUser.fromJson(userJson);
  }
}
