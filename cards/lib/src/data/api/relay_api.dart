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
  Future<bool>? _refreshing;

  /// Called when the session ended under the app (refresh refused): the app
  /// goes back to signed-out.
  void Function()? onSignedOut;

  Uri resolve(String path, [Map<String, String>? query]) {
    return baseUrl.replace(
      path: '${baseUrl.path.replaceAll(RegExp(r'/$'), '')}$path',
      queryParameters: query,
    );
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
    bool signedIn = false,
    Map<String, String>? headers,
  }) => _send('GET', path, query: query, signedIn: signedIn, headers: headers);

  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    bool signedIn = false,
  }) => _send('POST', path, body: body ?? const {}, signedIn: signedIn);

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
    if (signedIn) {
      final session = await sessions.read();
      if (session == null) {
        throw const RelayApiException(status: 401, code: 'unauthorized');
      }
      request.headers['Authorization'] = 'Bearer ${session.accessToken}';
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
    if (signedIn &&
        !retried &&
        response.statusCode == 401 &&
        code == 'token_expired') {
      if (await _refresh()) {
        return _send(
          method,
          path,
          query: query,
          body: body,
          signedIn: signedIn,
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
  /// same one.
  Future<bool> _refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
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
      }
      return false;
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
