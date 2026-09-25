import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../../core/app_version.dart';
import '../models/analytics_event.dart' show generateAnalyticsEventId;
import '../../core/server_state.dart';

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
    this.traceId = '',
  });

  final String method;
  final String path;
  final Duration duration;
  final int? statusCode;
  final int requestSizeBytes;
  final int responseSizeBytes;
  final String errorMessage;

  /// The `X-Request-ID` this request carried, so the client's own row can be
  /// joined to the backend rows it caused.
  final String traceId;

  bool get failed => statusCode == null || statusCode! >= 400;
}

class PosApiException implements Exception {
  const PosApiException({
    required this.message,
    required this.statusCode,
    required this.responseBody,
    this.fromRelay = false,
  });

  final String message;
  final int statusCode;
  final String responseBody;

  /// True when the relay answered this itself and the request never reached
  /// the shop's backend — see [relayErrorOf].
  final bool fromRelay;

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

/// The `error` the relay answered with on its own, or null when [response]
/// came from the shop's backend (or is not JSON at all).
///
/// The two speak differently, and the difference is the whole diagnosis. The
/// relay writes `{"error": "..."}` for what it refuses before forwarding — a
/// ticket it does not hold, a lapsed subscription, a connector that is not
/// connected — while Django answers with `detail`. Without telling them apart
/// a phone outside the shop reported every one of those as a wrong password.
String? relayErrorOf(http.Response response) {
  if (response.statusCode < 400) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(response.bodyBytes));
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded.containsKey('detail')) {
    return null;
  }
  final error = decoded['error'];
  return error is String && error.trim().isNotEmpty ? error.trim() : null;
}

/// Whether the relay itself answered [response] — see [relayErrorOf].
bool isRelayError(http.Response response) => relayErrorOf(response) != null;

/// A 401 the relay answered: the ticket on the request is not one it holds.
bool isRelayTicketRejection(http.Response response) =>
    response.statusCode == 401 && isRelayError(response);

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
  PosApiSession({
    required this.client,
    required String baseUrl,
    this.requestTimeout = defaultRequestTimeout,
  }) : _baseUrl = _normalizeBaseUrl(baseUrl);

  /// How long a request may stay unanswered before it is abandoned.
  ///
  /// A backend that refuses the connection throws immediately, and everything
  /// downstream — the relay fallback, [onLocalTargetUnreachable], the screen's
  /// error state — is built to handle that. A backend that *accepts* the
  /// connection and then goes silent throws nothing at all: `dart:io` sets no
  /// read deadline, so the future never completes and the cashier watches a
  /// spinner through a sale. That is a wedged uvicorn, an AP roam that
  /// stranded a pooled connection, or a LAN dropping packets after the
  /// handshake — all routine in a shop. This bound turns that silence into the
  /// transport failure the rest of the app already knows how to handle.
  ///
  /// Matched to the relay's own `relayRequestTimeout` (60s) so a relayed
  /// request is never cut client-side before the relay itself would have
  /// answered with a 504.
  ///
  /// Abandoning the future does not close the socket — `package:http` has no
  /// per-request cancel — so the stranded connection lingers until the OS or
  /// the pool reaps it. That is the cheap half of the trade: the app is
  /// unblocked, and one dead socket per wedged request is survivable.
  static const Duration defaultRequestTimeout = Duration(seconds: 60);

  /// The deadline a genuinely long server-side job needs — a database backup,
  /// a legacy-data import, an attendance pull off the fingerprint device.
  static const Duration longRunningRequestTimeout = Duration(minutes: 10);

  final Duration requestTimeout;
  final http.Client client;
  ApiPerformanceRecorder? performanceRecorder;
  final Map<String, String> _cookies = {};
  String? _csrfToken;
  String _baseUrl;
  String _relayToken = '';
  ApiConnectionTarget? _fallbackTarget;

  /// Invoked when a request fails at the transport level while pointed at a
  /// local (LAN) target — the signal the on-prem backend has moved or the
  /// network flapped. Fired even when the relay then answered the request,
  /// because that leaves the whole session on the relay. The coordinator
  /// debounces this into a background re-discovery so the LAN target
  /// self-heals without an app restart.
  void Function()? onLocalTargetUnreachable;

  /// Invoked when the relay refuses the ticket a request carried — a 401 of
  /// the relay's own, never the backend's — before the request is given up on.
  /// Returns whether the session now holds a ticket the relay should accept
  /// (the coordinator mints one from the device's refresh token), in which
  /// case the request is sent once more.
  ///
  /// The relay rejects before forwarding, so a repeat is safe for any request,
  /// keyed or not. Until this existed a ticket the relay had lost — a restart,
  /// an evicted Redis key, a phone clock ahead of the relay's — turned every
  /// request into a 401 that read as "signed out", and the sign-in that
  /// followed failed on the same 401, reported as a wrong password.
  Future<bool> Function()? onRelayTicketRejected;

  /// LRU of (etag, body) per request URL for opt-in conditional GETs — the
  /// catalog/category/unit/modifier/notification list endpoints send ETags so
  /// unchanged polls come back as an empty 304 and the stored body is replayed
  /// as a normal 200. Sized for several paginated lists' worth of distinct
  /// URLs (each page/filter combination is one entry).
  static const int _conditionalCacheMaxEntries = 256;
  final LinkedHashMap<String, _ConditionalCacheEntry> _conditionalCache =
      LinkedHashMap();

  /// The backend's "what changed" counters, pushed on EVERY API response
  /// (X-Pointy-State). Caches key their entries on the domain they depend on,
  /// and screens listen for the domains they display, so an edit made anywhere
  /// reaches this device through whatever request it makes next — and through
  /// [ServerStateWatcher]'s poll when it makes none at all.
  ///
  /// Owned here because this is the one place every response passes through.
  /// Empty until the first response (or on a backend that publishes nothing),
  /// in which case every consumer falls back to the TTLs it already had.
  final ServerStateNotifier serverState = ServerStateNotifier();

  /// The composite catalog stamp. Kept as a named getter because it is what
  /// the POS scan/search caches key on; it is just one entry in [serverState].
  String? get catalogVersionToken =>
      serverState.versionOf(ServerStateDomain.catalog);

  /// Discounts twin of [catalogVersionToken]: advances on any discount-rule
  /// edit. The POS latches "no active rules" at a specific value and skips
  /// preview requests while it still matches.
  String? get discountsVersionToken =>
      serverState.versionOf(ServerStateDomain.discounts);

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
    final nextBaseUrl = _normalizeBaseUrl(baseUrl);
    final sameAddress = nextBaseUrl == _baseUrl;
    _baseUrl = nextBaseUrl;
    _relayToken = relayToken.trim();
    _fallbackTarget = fallbackTarget;
    if (sameAddress) {
      // Re-confirming the address we already talk to — a rediscovery that
      // found the same LAN server, a refreshed relay ticket. Its cached bodies,
      // shared reads and counters are still that server's; dropping them made
      // every such confirmation a full re-download of each screen. A different
      // installation behind the same address is the coordinator's to notice,
      // and it calls [forgetBackendState] for that.
      return;
    }
    forgetBackendState();
  }

  /// Drop everything this session learnt from its backend: cached bodies,
  /// reads in flight, and the state counters.
  void forgetBackendState() {
    _conditionalCache.clear();
    // New callers must not join requests still in flight to the old target.
    _inFlightGets.clear();
    // Counters belong to one backend. Carrying them across would make the new
    // server's first vector look unchanged when in truth we know nothing.
    serverState.reset();
  }

  /// In-flight GET coalescing: two widgets asking for the same URL at the same
  /// moment (the login fan-out, POS + purchasing sharing the catalog) share one
  /// request instead of hitting the server twice. Entries evict on completion
  /// and the whole map clears on every mutating request, so a GET issued after
  /// a write can never join a pre-write response (read-after-write stays
  /// honest) — coalescing only ever merges genuinely concurrent reads.
  final Map<String, Future<http.Response>> _inFlightGets = {};

  Future<http.Response> get(
    String path, {
    Map<String, String>? query,
    bool conditionalCache = false,
    Duration? timeout,
  }) {
    final key =
        '${conditionalCache ? 'c' : 'p'}:${uri(path, queryParameters: query)}';
    final pending = _inFlightGets[key];
    if (pending != null) {
      return pending;
    }
    late final Future<http.Response> future;
    future =
        _getOnce(
          path,
          query: query,
          conditionalCache: conditionalCache,
          timeout: timeout,
        ).whenComplete(() {
          // Evict only our own entry: a mutation may have cleared the map and
          // a fresh identical GET may already be registered under this key.
          if (identical(_inFlightGets[key], future)) {
            _inFlightGets.remove(key);
          }
        });
    _inFlightGets[key] = future;
    return future;
  }

  Future<http.Response> _getOnce(
    String path, {
    Map<String, String>? query,
    bool conditionalCache = false,
    Duration? timeout,
  }) async {
    if (!conditionalCache) {
      return _send(
        method: 'GET',
        path: path,
        timeout: timeout,
        request: () =>
            client.get(uri(path, queryParameters: query), headers: headers()),
      );
    }

    // Look the entry up once and hold the reference: eviction by a concurrent
    // request must not turn a 304 into an empty response.
    final cached =
        _conditionalCache[uri(path, queryParameters: query).toString()];
    final response = await _send(
      method: 'GET',
      path: path,
      timeout: timeout,
      request: () {
        final requestHeaders = headers();
        if (cached != null) {
          requestHeaders['If-None-Match'] = cached.etag;
        }
        // uri() is re-resolved per attempt so the relay-fallback retry inside
        // _send targets the switched base URL, same as the plain path above.
        return client.get(
          uri(path, queryParameters: query),
          headers: requestHeaders,
        );
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
    Duration? timeout,
  }) async {
    final encodedBody = body == null ? null : jsonEncode(body);
    return _send(
      method: 'POST',
      path: path,
      requestSizeBytes: _encodedSize(encodedBody),
      timeout: timeout,
      // Only a keyed POST can be safely repeated: the backend recognises the
      // key and returns the original outcome instead of recording a second one.
      replayable: (idempotencyKey?.trim() ?? '').isNotEmpty,
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

  /// Opens a GET whose body the caller consumes as a stream — for large
  /// downloads (the tracking export zip) that must never be buffered whole in
  /// app memory. Carries the same session/relay headers as [get], but skips
  /// the in-flight coalescing, conditional cache, and perf recording that all
  /// assume a fully-materialized [http.Response].
  Future<http.StreamedResponse> getStreamed(
    String path, {
    Map<String, String>? query,
  }) {
    final request = http.Request('GET', uri(path, queryParameters: query));
    request.headers.addAll(headers());
    return client.send(request);
  }

  /// Opens a POST whose body the caller consumes as a stream.
  ///
  /// The streaming counterpart of [post], for a response the server writes row
  /// by row (the report CSV export). Same headers as [post]; like [getStreamed]
  /// it skips the in-flight coalescing and perf recording that assume a
  /// fully-materialized [http.Response].
  Future<http.StreamedResponse> postStreamed(
    String path, {
    Object? body,
    Map<String, String>? query,
  }) {
    final request = http.Request('POST', uri(path, queryParameters: query));
    request.headers.addAll(headers(includeCsrf: true));
    if (body != null) {
      request.body = jsonEncode(body);
    }
    return client.send(request);
  }

  /// Opens a Server-Sent Events stream (POST) and yields parsed [SseEvent]s as
  /// they arrive. Used by the AI assistant for token-by-token replies. Carries
  /// the same session cookie / CSRF / relay-token headers as other requests, so
  /// it works over LAN and through the relay tunnel. On non-2xx it reads the
  /// (small) error body and throws [PosApiException]. Native platforms stream
  /// incrementally; web delivers the buffered body at once (same code path).
  /// Opens a Server-Sent Events stream (the AI assistant).
  ///
  /// Two deadlines, because a stream can fail in two ways and neither used to
  /// be bounded at all. [connectTimeout] covers "the server never answered" —
  /// the AI request travels backend -> relay -> model, and on a slow link the
  /// backend can sit on the relay call before a single byte comes back.
  /// [idleTimeout] covers "the connection died mid-stream": a dropped TCP
  /// connection that never sends FIN (a NAT or proxy quietly timing out, which
  /// is routine on a shop's link) leaves the socket open forever, and with no
  /// deadline the app waited on it forever — the chat bubble simply span.
  ///
  /// The server sends a `ping` as soon as the stream opens and between tool
  /// rounds, so [idleTimeout] measures silence, not thinking.
  Stream<SseEvent> openEventStream(
    String path, {
    Object? body,
    String method = 'POST',
    Map<String, String>? query,
    Duration connectTimeout = const Duration(seconds: 30),
    Duration idleTimeout = const Duration(seconds: 90),
  }) async* {
    final request = http.Request(method, uri(path, queryParameters: query));
    request.headers.addAll(headers(includeCsrf: method != 'GET'));
    if (body != null) {
      request.body = jsonEncode(body);
    }

    // Streams used to bypass _send entirely, so they were invisible: not one of
    // the 10,079 recorded HTTP requests in the field was an AI call, which is
    // why a chat that never answered left no trace at all.
    final stopwatch = Stopwatch()..start();
    var streamedBytes = 0;
    void record({int? statusCode, String errorMessage = ''}) {
      _recordPerformance(
        method: method,
        path: path,
        duration: stopwatch.elapsed,
        statusCode: statusCode,
        requestSizeBytes: _encodedSize(request.body),
        responseSizeBytes: streamedBytes,
        errorMessage: errorMessage,
      );
    }

    final http.StreamedResponse streamed;
    try {
      streamed = await client.send(request).timeout(connectTimeout);
    } on TimeoutException {
      record(errorMessage: 'stream connect timed out');
      throw PosApiException(
        // 0: there was no HTTP response at all, so this reads as a network
        // failure rather than a server one.
        statusCode: 0,
        responseBody: '',
        message:
            'Stream request timed out after ${connectTimeout.inSeconds}s '
            'with no response',
      );
    } on Exception catch (error) {
      record(errorMessage: error.toString());
      rethrow;
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final errorBody = await streamed.stream.bytesToString();
      record(statusCode: streamed.statusCode);
      throw PosApiException(
        message: 'Stream request failed with status ${streamed.statusCode}',
        statusCode: streamed.statusCode,
        responseBody: errorBody,
      );
    }

    final lines = streamed.stream
        .map((chunk) {
          streamedBytes += chunk.length;
          return chunk;
        })
        .timeout(
          idleTimeout,
          onTimeout: (sink) => sink.addError(
            PosApiException(
              message:
                  'Stream went quiet for ${idleTimeout.inSeconds}s and was '
                  'closed',
              statusCode: streamed.statusCode,
              responseBody: '',
            ),
          ),
        )
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    String? eventType;
    final dataLines = <String>[];
    var recorded = false;
    try {
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
        yield SseEvent(
          event: eventType ?? 'message',
          data: dataLines.join('\n'),
        );
      }
      record(statusCode: streamed.statusCode);
      recorded = true;
    } catch (error) {
      record(statusCode: streamed.statusCode, errorMessage: error.toString());
      recorded = true;
      rethrow;
    } finally {
      // A cancelled subscription (the user leaving the chat) unwinds here
      // without either branch running; the turn still deserves a row.
      if (!recorded) {
        record(
          statusCode: streamed.statusCode,
          errorMessage: 'stream cancelled',
        );
      }
    }
  }

  Future<http.Response> postMultipart(
    String path, {
    Map<String, String> fields = const {},
    List<ApiMultipartFile> files = const [],
    Duration? timeout,
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
      timeout: timeout,
      replayable: false,
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

  /// PUTs raw bytes, unencoded, for endpoints that take a file body.
  ///
  /// Everything else here JSON-encodes what it is given. A migration upload
  /// chunk is a slice of a database and must arrive byte for byte, so it goes
  /// out as `application/octet-stream` with no transformation and no retry — a
  /// replayed chunk would be appended twice, and the server's offset check
  /// exists precisely so a client never has to guess whether that happened.
  Future<http.Response> putBytes(
    String path, {
    required Uint8List bytes,
    Map<String, String>? queryParameters,
    Duration? timeout,
  }) async {
    final target = uri(path, queryParameters: queryParameters);
    return _send(
      method: 'PUT',
      path: path,
      requestSizeBytes: bytes.length,
      timeout: timeout,
      replayable: false,
      request: () {
        final requestHeaders = headers(includeCsrf: true);
        requestHeaders['Content-Type'] = 'application/octet-stream';
        return client.put(target, headers: requestHeaders, body: bytes);
      },
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

  /// Identifies this install on every request, authenticated or not.
  ///
  /// Backend telemetry used to take the device from the request's session, so a
  /// rejected request recorded nothing at all — which is why 5.1M unauthenticated
  /// ingest calls in the field could not be traced to a machine. Set once at
  /// startup from the analytics installation id.
  String _deviceId = '';
  String _clientPlatform = '';
  String _appVersion = '';
  String _registerSessionId = '';

  /// The trace id [_send] minted for the request it is about to issue.
  ///
  /// Handed over through a field rather than an argument because the headers
  /// are built inside a closure [_send] never sees. That is safe in spite of
  /// how it looks: [_send] assigns this and then calls the closure, which calls
  /// [headers] *synchronously*, with no `await` in between — so on Dart's
  /// single-threaded loop no other send can interleave between the two.
  String _pendingTraceId = '';

  /// The trace id carried by the request most recently issued, for the caller
  /// that also reports its timing.
  String get lastTraceId => _lastTraceId;
  String _lastTraceId = '';

  void describeClient({
    required String deviceId,
    required String platform,
    String appVersion = kAppVersion,
  }) {
    _deviceId = deviceId.trim();
    _clientPlatform = platform.trim();
    _appVersion = appVersion.trim();
  }

  /// Which register session this till is working in, or empty when none is
  /// open.
  ///
  /// Sent on every request so the backend can stamp it onto the events it
  /// records. The client is the one that knows: a cashier can close the drawer
  /// between an action and the row being written, and asking the database
  /// afterwards would answer about *then* rather than about the action.
  void describeRegisterSession(String? registerSessionId) {
    _registerSessionId = (registerSessionId ?? '').trim();
  }

  Map<String, String> headers({
    bool includeCsrf = false,
    String? idempotencyKey,
  }) {
    final normalizedIdempotencyKey = idempotencyKey?.trim() ?? '';
    // One id per request, on every request. The backend reads it into
    // `trace_id` and stamps it onto everything recorded while that request
    // runs, which is what turns "the sale row" and "the request that made it"
    // into one thing you can follow. It was empty on all 417,527 rows of the
    // last field export, so nothing could be followed anywhere.
    final traceId = _pendingTraceId.isNotEmpty
        ? _pendingTraceId
        : generateAnalyticsEventId();
    _pendingTraceId = '';
    _lastTraceId = traceId;
    return {
      'Content-Type': 'application/json',
      'X-Request-ID': traceId,
      if (_deviceId.isNotEmpty) 'X-Pointy-Device-Id': _deviceId,
      if (_clientPlatform.isNotEmpty) 'X-Pointy-Platform': _clientPlatform,
      if (_appVersion.isNotEmpty) 'X-Pointy-App-Version': _appVersion,
      if (_registerSessionId.isNotEmpty)
        'X-Pointy-Register-Session': _registerSessionId,
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
    serverState.apply(_readStateVector(response.headers));

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
    _inFlightGets.clear();
    serverState.reset();
  }

  /// Throw away every cached response body without touching the session.
  ///
  /// The permissions counter moving is the one change that cannot be answered
  /// by re-fetching: a permission that was just revoked would leave the data it
  /// used to authorise sitting readable in the conditional-GET cache, and an
  /// If-None-Match against it would even be answered 304. So that domain
  /// purges rather than refreshes.
  void purgeCachedResponses() {
    _conditionalCache.clear();
    _inFlightGets.clear();
  }

  /// The state vector a response carries. Older backends send only the two
  /// legacy single-value headers; folding them into the same map means there
  /// is one store of versions on the client rather than three.
  Map<String, String> _readStateVector(Map<String, String> headers) {
    final vector = Map<String, String>.of(
      parseServerStateHeader(headers['x-pointy-state']),
    );
    final catalogVersion = headers['x-pointy-catalog-version'];
    if (catalogVersion != null && catalogVersion.isNotEmpty) {
      vector.putIfAbsent(ServerStateDomain.catalog, () => catalogVersion);
    }
    final discountsVersion = headers['x-pointy-discounts-version'];
    if (discountsVersion != null && discountsVersion.isNotEmpty) {
      vector.putIfAbsent(ServerStateDomain.discounts, () => discountsVersion);
    }
    return vector;
  }

  Future<http.Response> _send({
    required String method,
    required String path,
    required Future<http.Response> Function() request,
    int requestSizeBytes = 0,
    Duration? timeout,
    bool replayable = true,
  }) async {
    final deadline = timeout ?? requestTimeout;
    // One id per attempt, and this send's own copy of it.
    //
    // `headers()` is what actually stamps the id on the wire, and it reads it
    // off a field because it is built inside a closure this method never sees.
    // That hand-over is safe — `request()` calls `headers()` synchronously,
    // with no `await` in between — but the field itself is shared, so a
    // concurrent send would overwrite it before this one records its timing.
    // Hence the local: it is assigned in the same synchronous step and cannot
    // be disturbed afterwards.
    var traceId = '';
    Future<http.Response> attemptOnce() {
      _pendingTraceId = generateAnalyticsEventId();
      traceId = _pendingTraceId;
      return request().timeout(deadline);
    }

    // One send, plus one repeat when the relay refused the ticket it carried
    // and a ticket it should accept has since been installed.
    Future<http.Response> attempt() async {
      final ticketUsed = _relayToken;
      final response = await attemptOnce();
      if (ticketUsed.isEmpty || !isRelayTicketRejection(response)) {
        return response;
      }
      if (!await _recoverRelayTicket(ticketUsed)) {
        return response;
      }
      return attemptOnce();
    }

    if (method != 'GET') {
      // A write is about to change server state: GETs issued from here on
      // must not join responses computed before it.
      _inFlightGets.clear();
    }
    final stopwatch = Stopwatch()..start();
    final bool wasLocal = !usesRelay;
    try {
      final response = await attempt();
      stopwatch.stop();
      captureResponseState(response);
      _recordPerformance(
        method: method,
        path: path,
        duration: stopwatch.elapsed,
        statusCode: response.statusCode,
        requestSizeBytes: requestSizeBytes,
        responseSizeBytes: response.bodyBytes.length,
        traceId: traceId,
      );
      return response;
    } on Exception catch (exception) {
      // Replay this one request on the relay only when both hold:
      //
      // - It failed without timing out (refused, reset, unreachable): the LAN
      //   path is broken. A timeout on the LAN is far more often a slow
      //   backend, and the relay reaches that very backend — replaying there
      //   doubled the wait and the load on a server already struggling.
      // - The server can recognise a repeat — a GET, or a write carrying an
      //   idempotency key. A reset can arrive after the request was sent, so
      //   "failed" never proves "not recorded"; anything else is surfaced so
      //   the cashier decides, rather than risk billing a customer twice.
      //
      // Either way the coordinator hears about a LAN failure (below) and
      // decides where the session lives from here: back on the LAN once it
      // answers, or on the relay with a probe running to find the way back.
      final replay = wasLocal && replayable && exception is! TimeoutException;
      if (replay && _fallbackTarget != null && _fallbackTarget!.isUsable) {
        final fallback = _fallbackTarget!;
        _fallbackTarget = null;
        configureConnectionTarget(
          baseUrl: fallback.baseUrl,
          relayToken: fallback.relayToken,
        );
        try {
          final response = await attempt();
          stopwatch.stop();
          captureResponseState(response);
          _recordPerformance(
            method: method,
            path: path,
            duration: stopwatch.elapsed,
            statusCode: response.statusCode,
            requestSizeBytes: requestSizeBytes,
            responseSizeBytes: response.bodyBytes.length,
            traceId: traceId,
          );
          // The relay rescued this request, but the session now lives there.
          // Until this call existed nothing ever brought it back: a till that
          // hit one LAN hiccup ran the rest of the day over the internet.
          onLocalTargetUnreachable?.call();
          return response;
        } on Exception {
          // Record the original failure below; it is usually the LAN failure
          // that caused routing to fall back.
        }
      } else if (replay && _fallbackTarget != null) {
        _fallbackTarget = null;
      }
      stopwatch.stop();
      _recordPerformance(
        method: method,
        path: path,
        duration: stopwatch.elapsed,
        requestSizeBytes: requestSizeBytes,
        errorMessage: exception.toString(),
        // Recorded even though this one failed. A timeout proves nothing about
        // what the server did, and the trace id is the only thing that can join
        // "the till gave up at 30s" to the row where the backend answered at
        // 32s — which is the difference between a lost sale and a slow one.
        traceId: traceId,
      );
      if (wasLocal) {
        onLocalTargetUnreachable?.call();
      }
      rethrow;
    }
  }

  /// Whether a request that the relay refused with [ticketUsed] may be sent
  /// again: a newer ticket is already installed (another request's recovery,
  /// or a scheduled refresh, beat this one to it), or the coordinator mints one
  /// now. Rejections of the same ticket coalesce on the coordinator's side.
  Future<bool> _recoverRelayTicket(String ticketUsed) async {
    if (_relayToken != ticketUsed) {
      return usesRelay;
    }
    final recover = onRelayTicketRejected;
    if (recover == null) {
      return false;
    }
    try {
      if (!await recover()) {
        return false;
      }
    } on Object {
      return false;
    }
    return usesRelay && _relayToken != ticketUsed;
  }

  void _recordPerformance({
    required String method,
    required String path,
    required Duration duration,
    int? statusCode,
    int requestSizeBytes = 0,
    int responseSizeBytes = 0,
    String errorMessage = '',
    String traceId = '',
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
        traceId: traceId,
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

  /// [decodedBody], except that a body which is not JSON yields `null`.
  ///
  /// Not every error body comes from Django. A proxy in front of it answers
  /// 413 and 502 with its own HTML, and Django's own last-resort 500 page
  /// opens with a newline — so decoding it throws `Unexpected character (at
  /// line 2, character 1)`. Thrown from a call that happens *before* the
  /// status code is read, that exception is all the caller ever sees: the
  /// status, the endpoint and the server's own explanation are all lost behind
  /// a parse error about a document nobody meant to parse. Use this wherever
  /// the body being read might be an error body.
  Object? decodedBodyOrNull(http.Response response) {
    try {
      return jsonDecode(body(response));
    } on FormatException {
      return null;
    }
  }

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
        fromRelay: isRelayError(response),
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
