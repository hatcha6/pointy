import 'dart:convert';

import 'package:http/http.dart' as http;

class PosApiException implements Exception {
  const PosApiException({
    required this.message,
    required this.statusCode,
    required this.responseBody,
  });

  final String message;
  final int statusCode;
  final String responseBody;

  Object? get decodedBody {
    try {
      return jsonDecode(responseBody);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => message;
}

class PosApiSession {
  PosApiSession({required this.client, required this.baseUrl});

  final http.Client client;
  final String baseUrl;
  final Map<String, String> _cookies = {};
  String? _csrfToken;

  Uri uri(String path, {Map<String, String>? queryParameters}) {
    final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse(
      '$baseUrl/$normalizedPath',
    ).replace(queryParameters: queryParameters);
  }

  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    final response = await client.get(
      uri(path, queryParameters: query),
      headers: headers(),
    );
    captureResponseState(response);
    return response;
  }

  Future<http.Response> post(
    String path, {
    Object? body,
    bool includeCsrf = true,
  }) async {
    final response = await client.post(
      uri(path),
      headers: headers(includeCsrf: includeCsrf),
      body: body == null ? null : jsonEncode(body),
    );
    captureResponseState(response);
    return response;
  }

  Future<http.Response> patch(String path, {required Object body}) async {
    final response = await client.patch(
      uri(path),
      headers: headers(includeCsrf: true),
      body: jsonEncode(body),
    );
    captureResponseState(response);
    return response;
  }

  Map<String, String> headers({bool includeCsrf = false}) {
    return {
      'Content-Type': 'application/json',
      if (_cookies.isNotEmpty)
        'Cookie': _cookies.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; '),
      if (includeCsrf && _csrfToken != null) 'X-CSRFToken': _csrfToken!,
    };
  }

  void captureResponseState(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) {
      return;
    }

    for (final cookie in setCookie.split(',')) {
      final firstPart = cookie.split(';').first.trim();
      final separator = firstPart.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      final name = firstPart.substring(0, separator);
      final value = firstPart.substring(separator + 1);
      _cookies[name] = value;
      if (name == 'csrftoken') {
        _csrfToken = value;
      }
    }
  }

  void updateCsrfToken(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      _csrfToken = decoded['csrf_token']?.toString() ?? _csrfToken;
    }
  }

  void clearAuthState() {
    _cookies.clear();
    _csrfToken = null;
  }

  String body(http.Response response) => utf8.decode(response.bodyBytes);

  Object? decodedBody(http.Response response) => jsonDecode(body(response));

  void ensureSuccess(http.Response response, String message) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('$message ${response.statusCode}');
    }
  }

  void throwApiException(http.Response response, String message) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PosApiException(
        message: '$message ${response.statusCode}',
        statusCode: response.statusCode,
        responseBody: body(response),
      );
    }
  }
}

List<T> decodeListResponse<T>(
  Object? decoded,
  T Function(Map<String, Object?> json) fromJson,
) {
  final items = decoded is Map<String, Object?> && decoded['results'] is List
      ? decoded['results'] as List<Object?>
      : decoded is List<Object?>
      ? decoded
      : const <Object?>[];

  return items
      .whereType<Map<String, Object?>>()
      .map(fromJson)
      .toList(growable: false);
}

List<Map<String, Object?>> resultsFromDecoded(Object? decoded) {
  if (decoded is Map<String, Object?>) {
    final results = decoded['results'];
    if (results is List<Object?>) {
      return results.whereType<Map<String, Object?>>().toList(growable: false);
    }
    return [decoded];
  }
  if (decoded is List<Object?>) {
    return decoded.whereType<Map<String, Object?>>().toList(growable: false);
  }
  return [];
}
