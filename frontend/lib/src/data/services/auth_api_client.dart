import 'package:http/http.dart' as http;

import '../models/onboarding.dart';
import '../models/pos_user.dart';
import 'api_session.dart';

class AuthApiClient {
  const AuthApiClient(this._session);

  final PosApiSession _session;

  Future<OnboardingStatus> fetchOnboardingStatus() async {
    final response = await _session.get('setup/status/');
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
    );
    _session.ensureSuccess(response, 'Login failed with status');
    return _decodeUserResponse(response);
  }

  Future<void> logout() async {
    final response = await _session.post('auth/logout/');
    _session.ensureSuccess(response, 'Logout failed with status');
    _session.clearAuthState();
  }

  Future<PosUser?> fetchCurrentUser() async {
    final response = await _session.get('auth/me/');
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
    _session.ensureSuccess(response, 'Password change failed with status');
  }

  PosUser _decodeUserResponse(http.Response response) {
    final decoded = _session.decodedBody(response) as Map<String, Object?>;
    _session.updateCsrfToken(decoded);
    final userJson = decoded['user'] is Map<String, Object?>
        ? decoded['user'] as Map<String, Object?>
        : decoded;
    return PosUser.fromJson(userJson);
  }
}
