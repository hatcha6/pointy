import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

typedef ApiPerformanceRecorder =
    void Function(ApiRequestPerformance performance);

class ApiMultipartFile {
  const ApiMultipartFile({
    required this.fieldName,
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  final String fieldName;
  final String filename;
  final List<int> bytes;
  final String contentType;
}

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

/// One parsed Server-Sent Event: an `event:` name plus its raw `data:` payload.
class SseEvent {
  const SseEvent({required this.event, required this.data});

  final String event;
  final String data;
}

/// A previously seen response body paired with its ETag, replayed when the
/// server answers a revalidation with 304 Not Modified.
class _ConditionalCacheEntry {
  const _ConditionalCacheEntry({
    required this.etag,
    required this.bodyBytes,
    required this.headers,
  });

  final String etag;
  final Uint8List bodyBytes;
  final Map<String, String> headers;
}

class PosApiSession {
  PosApiSession({required this.client, required String baseUrl})
    : _baseUrl = _normalizeBaseUrl(baseUrl);

  final http.Client client;
  ApiPerformanceRecorder? performanceRecorder;
  final Map<String, String> _cookies = {};
  String? _csrfToken;
  String _baseUrl;
  String _relayToken = '';
  ApiConnectionTarget? _fallbackTarget;

  /// LRU of (etag, body) per request URL for opt-in conditional GETs — the
  /// catalog/category/unit/modifier/notification list endpoints send ETags so
  /// unchanged polls come back as an empty 304 and the stored body is replayed
  /// as a normal 200. Sized for several paginated lists' worth of distinct
  /// URLs (each page/filter combination is one entry).
  static const int _conditionalCacheMaxEntries = 256;
  final LinkedHashMap<String, _ConditionalCacheEntry> _conditionalCache =
      LinkedHashMap();

  /// The backend's catalog version, pushed on catalog/preview/checkout
  /// responses (X-Pointy-Catalog-Version). Client-side catalog caches key
  /// their entries on this token: any product/price/stock/discount change
  /// server-side advances it, instantly orphaning stale entries — the till
  /// learns within one interaction, no polling. Null until first seen (or on
  /// old backends), in which case caches fall back to their TTLs alone.
  String? get catalogVersionToken => _catalogVersionToken;
  String? _catalogVersionToken;

  /// Discounts twin of [catalogVersionToken] (X-Pointy-Discounts-Version):
  /// advances on any discount-rule edit. The POS latches "no active rules" at
  /// a specific value and skips preview requests while it still matches.
  String? get discountsVersionToken => _discountsVersionToken;
  String? _discountsVersionToken;

  String get baseUrl => _baseUrl;
  bool get usesRelay => _relayToken.isNotEmpty;

  Uri uri(String path, {Map<String, String>? queryParameters}) {
    final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse(
      '$baseUrl/$normalizedPath',
    ).replace(queryParameters: queryParameters);
  }

  Uri? resolveUri(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      return null;
    }
    if (uri.hasScheme) {
      return uri;
    }

    final baseUri = Uri.tryParse(baseUrl);
    if (baseUri == null) {
      return null;
    }
    final directoryBase = baseUri.path.endsWith('/')
        ? baseUri
        : baseUri.replace(path: '${baseUri.path}/');
    return directoryBase.resolveUri(uri);
  }

  void configureConnectionTarget({
    required String baseUrl,
    String relayToken = '',
    ApiConnectionTarget? fallbackTarget,
  }) {
    _baseUrl = _normalizeBaseUrl(baseUrl);
    _relayToken = relayToken.trim();
    _fallbackTarget = fallbackTarget;
    _conditionalCache.clear();
    _catalogVersionToken = null;
    _discountsVersionToken = null;
  }

  Future<http.Response> get(
    String path, {
    Map<String, String>? query,
    bool conditionalCache = false,
  }) async {
    if (!conditionalCache) {
      return _send(
        method: 'GET',
        path: path,
        request: () =>
            client.get(uri(path, queryParameters: query), headers: headers()),
      );
    }

    // Look the entry up once and hold the reference: eviction by a concurrent
    // request must not turn a 304 into an empty response.
    final cached = _conditionalCache[uri(path, queryParameters: query).toString()];
    final response = await _send(
      method: 'GET',
      path: path,
      request: () {
        final requestHeaders = headers();
        if (cached != null) {
          requestHeaders['If-None-Match'] = cached.etag;
        }
        // uri() is re-resolved per attempt so the relay-fallback retry inside
        // _send targets the switched base URL, same as the plain path above.
        return client.get(uri(path, queryParameters: query),
            headers: requestHeaders);
      },
    );

    final cacheKey = uri(path, queryParameters: query).toString();
    if (response.statusCode == 304 && cached != null) {
      _touchConditionalEntry(cacheKey, cached);
      return http.Response.bytes(
        cached.bodyBytes,
        200,
        headers: cached.headers,
        request: response.request,
      );
    }
    final etag = response.headers['etag'] ?? '';
    if (response.statusCode == 200 && etag.isNotEmpty) {
      _storeConditionalEntry(
        cacheKey,
        _ConditionalCacheEntry(
          etag: etag,
          bodyBytes: response.bodyBytes,
          headers: response.headers,
        ),
      );
    }
    return response;
  }

  void _touchConditionalEntry(String key, _ConditionalCacheEntry entry) {
    _conditionalCache.remove(key);
    _conditionalCache[key] = entry;
  }

  void _storeConditionalEntry(String key, _ConditionalCacheEntry entry) {
    _conditionalCache.remove(key);
    _conditionalCache[key] = entry;
    while (_conditionalCache.length > _conditionalCacheMaxEntries) {
      _conditionalCache.remove(_conditionalCache.keys.first);
    }
  }

  Future<http.Response> getUri(Uri uri, {String performancePath = 'resource'}) {
    return _send(
      method: 'GET',
      path: performancePath,
      request: () => client.get(uri, headers: headers()),
    );
  }

  Future<http.Response> post(
    String path, {
    Object? body,
    bool includeCsrf = true,
    String? idempotencyKey,
  }) async {
    final encodedBody = body == null ? null : jsonEncode(body);
    return _send(
      method: 'POST',
      path: path,
      requestSizeBytes: _encodedSize(encodedBody),
      request: () => client.post(
        uri(path),
        headers: headers(
          includeCsrf: includeCsrf,
          idempotencyKey: idempotencyKey,
        ),
        body: encodedBody,
      ),
    );
  }

  /// Opens a Server-Sent Events stream (POST) and yields parsed [SseEvent]s as
  /// they arrive. Used by the AI assistant for token-by-token replies. Carries
  /// the same session cookie / CSRF / relay-token headers as other requests, so
  /// it works over LAN and through the relay tunnel. On non-2xx it reads the
  /// (small) error body and throws [PosApiException]. Native platforms stream
  /// incrementally; web delivers the buffered body at once (same code path).
  Stream<SseEvent> openEventStream(String path, {Object? body}) async* {
    final request = http.Request('POST', uri(path));
    request.headers.addAll(headers(includeCsrf: true));
    if (body != null) {
      request.body = jsonEncode(body);
    }

    final streamed = await client.send(request);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final errorBody = await streamed.stream.bytesToString();
      throw PosApiException(
        message: 'Stream request failed with status ${streamed.statusCode}',
        statusCode: streamed.statusCode,
        responseBody: errorBody,
      );
    }

    final lines = streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    String? eventType;
    final dataLines = <String>[];
    await for (final line in lines) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          yield SseEvent(
            event: eventType ?? 'message',
            data: dataLines.join('\n'),
          );
        }
        eventType = null;
        dataLines.clear();
        continue;
      }
      if (line.startsWith(':')) {
        continue;
      }
      if (line.startsWith('event:')) {
        eventType = line.substring('event:'.length).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring('data:'.length).trim());
      }
    }
    if (dataLines.isNotEmpty) {
      yield SseEvent(event: eventType ?? 'message', data: dataLines.join('\n'));
    }
  }

  Future<http.Response> postMultipart(
    String path, {
    Map<String, String> fields = const {},
    List<ApiMultipartFile> files = const [],
  }) async {
    final requestSizeBytes =
        fields.entries.fold<int>(
          0,
          (total, entry) =>
              total + _encodedSize(entry.key) + _encodedSize(entry.value),
        ) +
        files.fold<int>(0, (total, file) => total + file.bytes.length);
    return _send(
      method: 'POST',
      path: path,
      requestSizeBytes: requestSizeBytes,
      request: () async {
        final request = http.MultipartRequest('POST', uri(path));
        request.fields.addAll(fields);
        final requestHeaders = headers(includeCsrf: true);
        requestHeaders.remove('Content-Type');
        request.headers.addAll(requestHeaders);
        for (final file in files) {
          request.files.add(
            http.MultipartFile.fromBytes(
              file.fieldName,
              file.bytes,
              filename: file.filename,
              contentType: MediaType.parse(file.contentType),
            ),
          );
        }
        return http.Response.fromStream(await client.send(request));
      },
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

  Future<http.Response> put(String path, {required Object body}) async {
    final encodedBody = jsonEncode(body);
    return _send(
      method: 'PUT',
      path: path,
      requestSizeBytes: _encodedSize(encodedBody),
      request: () => client.put(
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

  Map<String, String> headers({
    bool includeCsrf = false,
    String? idempotencyKey,
  }) {
    final normalizedIdempotencyKey = idempotencyKey?.trim() ?? '';
    return {
      'Content-Type': 'application/json',
      if (_cookies.isNotEmpty)
        'Cookie': _cookies.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; '),
      if (includeCsrf && _csrfToken != null) 'X-CSRFToken': _csrfToken!,
      if (_relayToken.isNotEmpty) 'X-Pointy-Relay-Token': _relayToken,
      if (normalizedIdempotencyKey.isNotEmpty)
        'Idempotency-Key': normalizedIdempotencyKey,
    };
  }

  void captureResponseState(http.Response response) {
    final catalogVersion = response.headers['x-pointy-catalog-version'];
    if (catalogVersion != null && catalogVersion.isNotEmpty) {
      _catalogVersionToken = catalogVersion;
    }
    final discountsVersion = response.headers['x-pointy-discounts-version'];
    if (discountsVersion != null && discountsVersion.isNotEmpty) {
      _discountsVersionToken = discountsVersion;
    }

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
    _conditionalCache.clear();
    _catalogVersionToken = null;
    _discountsVersionToken = null;
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
      if (_fallbackTarget != null && _fallbackTarget!.isUsable) {
        final fallback = _fallbackTarget!;
        _fallbackTarget = null;
        configureConnectionTarget(
          baseUrl: fallback.baseUrl,
          relayToken: fallback.relayToken,
        );
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
        } on Exception {
          // Record the original failure below; it is usually the LAN failure
          // that caused routing to fall back.
        }
      } else if (_fallbackTarget != null) {
        _fallbackTarget = null;
      }
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

class ApiConnectionTarget {
  const ApiConnectionTarget({
    required this.baseUrl,
    this.relayToken = '',
    this.relayTokenExpiresAt,
  });

  final String baseUrl;
  final String relayToken;
  final DateTime? relayTokenExpiresAt;

  bool get isUsable {
    if (relayToken.trim().isEmpty) {
      return true;
    }
    final expiresAt = relayTokenExpiresAt;
    if (expiresAt == null) {
      return true;
    }
    return DateTime.now().toUtc().isBefore(expiresAt.toUtc());
  }
}

String _normalizeBaseUrl(String value) {
  return value.trim().replaceFirst(RegExp(r'/+$'), '');
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
