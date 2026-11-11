import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../session/session_store.dart';

/// A refusal from the relay: its HTTP status, its machine `code` (e.g.
/// `wrong_code`, `price_changed`) and whatever else it said (`attempts_left`,
/// `retry_at`, the order…).
class RelayApiException implements Exception {
  const RelayApiException({
    required this.status,
    required this.code,
    this.message = '',
    this.body = const {},
  });

  final int status;
  final String code;
  final String message;
  final Map<String, dynamic> body;

  /// The relay could not be reached, or did not answer in time.
  bool get isNetwork => status == 0;

  @override
  String toString() => 'RelayApiException($status, $code: $message)';
}

/// The relay's customer API: JSON in, JSON out, the session's Bearer token on
/// every signed-in call. An expired access token is refreshed once, for every
/// caller waiting on it, and the call repeated.
class RelayApi {
  RelayApi({
    required this.baseUrl,
    required this.sessions,
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final SessionStore sessions;
  final http.Client _client;
  final Duration timeout;
  Future<bool?>? _refreshing;

  /// Called when the session ended under the app (refresh refused): the app
  /// goes back to signed-out.
  void Function()? onSignedOut;

  /// The relay's own path, without a closing slash.
  late final String _root = baseUrl.path.replaceAll(RegExp(r'/$'), '');

  Uri resolve(String path, [Map<String, String>? query]) {
    return baseUrl.replace(path: '$_root$path', queryParameters: query);
  }

  /// [withSession] sends the session when there is one, for a public route
  /// whose answer can depend on who asks; signed out, it goes without.
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
    bool signedIn = false,
    bool withSession = false,
    Map<String, String>? headers,
  }) => _send(
    'GET',
    path,
    query: query,
    signedIn: signedIn,
    withSession: withSession,
    headers: headers,
  );

  /// [bearer] sends that access token as it is, whatever session is stored
  /// (or none): the sign-out that follows a session already forgotten here.
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    bool signedIn = false,
    bool withSession = false,
    String? bearer,
  }) => _send(
    'POST',
    path,
    body: body ?? const {},
    signedIn: signedIn,
    withSession: withSession,
    headers: bearer == null ? null : {'Authorization': 'Bearer $bearer'},
  );

  Future<Map<String, dynamic>> put(
    String path, {
    Object? body,
    bool signedIn = false,
  }) => _send('PUT', path, body: body ?? const {}, signedIn: signedIn);

  Future<Map<String, dynamic>> delete(String path, {bool signedIn = true}) =>
      _send('DELETE', path, signedIn: signedIn);

  /// A raw GET for callers that read headers (the catalog's ETag).
  Future<http.Response> getRaw(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    try {
      return await _client
          .get(resolve(path, query), headers: headers)
          .timeout(timeout);
    } on Exception {
      throw const RelayApiException(status: 0, code: 'network');
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool signedIn = false,
    bool withSession = false,
    Map<String, String>? headers,
    bool retried = false,
  }) async {
    final request = http.Request(method, resolve(path, query));
    request.headers['Accept'] = 'application/json';
    if (headers != null) {
      request.headers.addAll(headers);
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    var sentSession = false;
    if (signedIn || withSession) {
      final session = await sessions.read();
      if (session == null) {
        if (signedIn) {
          throw const RelayApiException(status: 401, code: 'unauthorized');
        }
      } else {
        request.headers['Authorization'] = 'Bearer ${session.accessToken}';
        sentSession = true;
      }
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      ).timeout(timeout);
    } on Exception {
      throw const RelayApiException(status: 0, code: 'network');
    }
    final decoded = _decode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }
    final code = decoded['code'] as String? ?? 'http_${response.statusCode}';
    if (sentSession &&
        !retried &&
        response.statusCode == 401 &&
        code == 'token_expired') {
      // A public route asked once more without a session that could not be
      // renewed: it was signed out, and is answered as anyone.
      final renewed = await _refresh();
      if (renewed == null) {
        // The relay could not be reached to renew the session: that is a
        // connection problem to try again, not a customer to sign in again.
        throw const RelayApiException(status: 0, code: 'network');
      }
      if (renewed || (withSession && !signedIn)) {
        return _send(
          method,
          path,
          query: query,
          body: body,
          signedIn: signedIn,
          withSession: withSession,
          headers: headers,
          retried: true,
        );
      }
    }
    throw RelayApiException(
      status: response.statusCode,
      code: code,
      message: decoded['error'] as String? ?? '',
      body: decoded,
    );
  }

  /// One refresh at a time: every call that hit an expired token waits on the
  /// same one. True when renewed, false when the session is over, null when
  /// the relay could not be asked.
  Future<bool?> _refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool?> _doRefresh() async {
    final session = await sessions.read();
    if (session == null) {
      return false;
    }
    try {
      final answer = await post(
        '/v1/customers/auth/refresh',
        body: {'refresh_token': session.refreshToken},
      );
      await sessions.write(session.rotated(answer));
      return true;
    } on RelayApiException catch (error) {
      if (error.status == 401) {
        await sessions.clear();
        onSignedOut?.call();
        return false;
      }
      // Unreachable, or busy (a 5xx): the session may well still be good.
      return error.isNetwork || error.status >= 500 || error.status == 429
          ? null
          : false;
    }
  }

  static Map<String, dynamic> _decode(String raw) {
    if (raw.trim().isEmpty) {
      return const {};
    }
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }
}
