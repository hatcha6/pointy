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

  Future<OnboardingStatus> fetchOnboardingStatus() async {
    final response = await _session.get('setup/status/', timeout: authTimeout);
    _session.ensureSuccess(
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
    final response = await _session.post(
      'auth/login/',
      body: {'username': username, 'password': password},
      includeCsrf: false,
      timeout: authTimeout,
    );
    _session.ensureSuccess(response, 'Login failed with status');
    return _decodeUserResponse(response);
  }

  Future<void> logout() async {
    final response = await _session.post('auth/logout/', timeout: authTimeout);
    _session.ensureSuccess(response, 'Logout failed with status');
    _session.clearAuthState();
  }

  Future<PosUser?> fetchCurrentUser() async {
    final response = await _session.get('auth/me/', timeout: authTimeout);
    if (response.statusCode == 401 || response.statusCode == 403) {
      return null;
    }

    _session.ensureSuccess(response, 'Current user request failed with status');
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
    return PosUser.fromJson(userJson);
  }
}
