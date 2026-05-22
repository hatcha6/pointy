import 'dart:convert';

import 'package:http/http.dart' as http;

typedef ApiPerformanceRecorder =
    void Function(ApiRequestPerformance performance);

class ApiRequestPerformance {
  const ApiRequestPerformance({
    required this.method,
    required this.path,
    required this.duration,
    this.statusCode,
    this.requestSizeBytes = 0,
    this.responseSizeBytes = 0,
    this.errorMessage = '',
  });

  final String method;
  final String path;
  final Duration duration;
  final int? statusCode;
  final int requestSizeBytes;
  final int responseSizeBytes;
  final String errorMessage;

  bool get failed => statusCode == null || statusCode! >= 400;
}

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
  ApiPerformanceRecorder? performanceRecorder;
  final Map<String, String> _cookies = {};
  String? _csrfToken;

  Uri uri(String path, {Map<String, String>? queryParameters}) {
    final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse(
      '$baseUrl/$normalizedPath',
    ).replace(queryParameters: queryParameters);
  }

  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    return _send(
      method: 'GET',
      path: path,
      request: () =>
          client.get(uri(path, queryParameters: query), headers: headers()),
    );
  }

  Future<http.Response> post(
    String path, {
    Object? body,
    bool includeCsrf = true,
  }) async {
    final encodedBody = body == null ? null : jsonEncode(body);
    return _send(
      method: 'POST',
      path: path,
      requestSizeBytes: _encodedSize(encodedBody),
      request: () => client.post(
        uri(path),
        headers: headers(includeCsrf: includeCsrf),
        body: encodedBody,
      ),
    );
  }

  Future<http.Response> patch(String path, {required Object body}) async {
    final encodedBody = jsonEncode(body);
    return _send(
      method: 'PATCH',
      path: path,
      requestSizeBytes: _encodedSize(encodedBody),
      request: () => client.patch(
        uri(path),
        headers: headers(includeCsrf: true),
        body: encodedBody,
      ),
    );
  }

  Future<http.Response> delete(String path) async {
    return _send(
      method: 'DELETE',
      path: path,
      request: () =>
          client.delete(uri(path), headers: headers(includeCsrf: true)),
    );
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

  Future<http.Response> _send({
    required String method,
    required String path,
    required Future<http.Response> Function() request,
    int requestSizeBytes = 0,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await request();
      stopwatch.stop();
      captureResponseState(response);
      _recordPerformance(
        method: method,
        path: path,
        duration: stopwatch.elapsed,
        statusCode: response.statusCode,
        requestSizeBytes: requestSizeBytes,
        responseSizeBytes: response.bodyBytes.length,
      );
      return response;
    } on Exception catch (exception) {
      stopwatch.stop();
      _recordPerformance(
        method: method,
        path: path,
        duration: stopwatch.elapsed,
        requestSizeBytes: requestSizeBytes,
        errorMessage: exception.toString(),
      );
      rethrow;
    }
  }

  void _recordPerformance({
    required String method,
    required String path,
    required Duration duration,
    int? statusCode,
    int requestSizeBytes = 0,
    int responseSizeBytes = 0,
    String errorMessage = '',
  }) {
    if (path.startsWith('analytics-events/')) {
      return;
    }
    performanceRecorder?.call(
      ApiRequestPerformance(
        method: method,
        path: path,
        duration: duration,
        statusCode: statusCode,
        requestSizeBytes: requestSizeBytes,
        responseSizeBytes: responseSizeBytes,
        errorMessage: errorMessage,
      ),
    );
  }

  int _encodedSize(String? value) {
    if (value == null) {
      return 0;
    }
    return utf8.encode(value).length;
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
