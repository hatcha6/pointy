import 'package:http/http.dart' as http;

import '../models/pos_user.dart';
import 'api_session.dart';

class AuthApiClient {
  const AuthApiClient(this._session);

  final PosApiSession _session;

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

  PosUser _decodeUserResponse(http.Response response) {
    final decoded = _session.decodedBody(response) as Map<String, Object?>;
    _session.updateCsrfToken(decoded);
    final userJson = decoded['user'] is Map<String, Object?>
        ? decoded['user'] as Map<String, Object?>
        : decoded;
    return PosUser.fromJson(userJson);
  }
}
