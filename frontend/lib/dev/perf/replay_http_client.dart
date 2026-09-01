// Dev-only: record-and-replay HTTP client for the frontend performance sweep.
//
// Recording wraps the real client and stores every response keyed by method,
// path and sorted query. Replay serves those responses back without a network,
// so the whole app can be driven headlessly under `flutter test` against real
// backend payloads (real list sizes, real product graphs) instead of hand-made
// fakes. Never imported by `lib/main.dart`; safe to delete.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// One captured HTTP exchange.
class RecordedResponse {
  const RecordedResponse({
    required this.status,
    required this.headers,
    required this.bodyBytes,
  });

  final int status;
  final Map<String, String> headers;
  final List<int> bodyBytes;

  Map<String, Object?> toJson() => {
    'status': status,
    'headers': headers,
    'body_base64': base64Encode(bodyBytes),
  };

  factory RecordedResponse.fromJson(Map<String, Object?> json) {
    return RecordedResponse(
      status: json['status'] as int,
      headers: Map<String, String>.from(json['headers'] as Map),
      bodyBytes: base64Decode(json['body_base64'] as String),
    );
  }
}

/// Header names worth keeping: everything the session layer reads back.
const _keptHeaders = {'content-type', 'etag', 'set-cookie', 'x-pointy-catalog-version', 'x-pointy-discounts-version'};

/// Request keys that are volatile between runs (dates, pagination cursors,
/// version tokens) fall back to a looser match at replay time.
const _volatileQueryParams = {
  'date_from',
  'date_to',
  'from',
  'to',
  'since',
  'until',
  'start',
  'end',
  'start_date',
  'end_date',
  'as_of',
  'cursor',
  'timestamp',
  'ts',
  '_',
};

class PerfFixtureStore {
  PerfFixtureStore([Map<String, List<RecordedResponse>>? entries])
    : entries = entries ?? {};

  final Map<String, List<RecordedResponse>> entries;

  static String keyFor(String method, Uri uri) {
    return '${method.toUpperCase()} ${_normalizedPath(uri)}${_sortedQuery(uri)}';
  }

  static String _normalizedPath(Uri uri) {
    final path = uri.path;
    final index = path.indexOf('/api/');
    return index >= 0 ? path.substring(index) : path;
  }

  static bool _isVolatile(String name) {
    if (_volatileQueryParams.contains(name)) {
      return true;
    }
    const fragments = ['date', 'after', 'before', 'since', 'until', '_at'];
    return fragments.any(name.contains);
  }

  static String _sortedQuery(Uri uri, {bool dropVolatile = false}) {
    final keys = uri.queryParametersAll.keys.toList()..sort();
    final parts = <String>[];
    for (final key in keys) {
      if (dropVolatile && _isVolatile(key)) {
        continue;
      }
      for (final value in uri.queryParametersAll[key]!) {
        parts.add('$key=$value');
      }
    }
    return parts.isEmpty ? '' : '?${parts.join('&')}';
  }

  static PerfFixtureStore load(File file) {
    final store = PerfFixtureStore();
    store.merge(file);
    return store;
  }

  /// Every `*.json` in [directory] merged into one store, so feature areas
  /// can record their own fixture files without touching each other's.
  static PerfFixtureStore loadDirectory(Directory directory) {
    final store = PerfFixtureStore();
    if (!directory.existsSync()) {
      return store;
    }
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      store.merge(file);
    }
    return store;
  }

  void merge(File file) {
    if (!file.existsSync()) {
      return;
    }
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    for (final entry in raw.entries) {
      final list = entries.putIfAbsent(entry.key, () => []);
      for (final item in entry.value as List) {
        list.add(RecordedResponse.fromJson(item as Map<String, Object?>));
      }
    }
  }

  /// Only the keys recorded since [baseline] was taken — what a recording run
  /// should write to its own file (not the merged store it started from).
  PerfFixtureStore diff(Map<String, int> baseline) {
    final result = PerfFixtureStore();
    for (final entry in entries.entries) {
      final before = baseline[entry.key] ?? 0;
      if (entry.value.length > before) {
        result.entries[entry.key] = entry.value.sublist(before);
      }
    }
    return result;
  }

  Map<String, int> snapshot() => {
    for (final entry in entries.entries) entry.key: entry.value.length,
  };

  void save(File file) {
    file.parent.createSync(recursive: true);
    final encoded = <String, Object?>{
      for (final entry in entries.entries)
        entry.key: [for (final item in entry.value) item.toJson()],
    };
    file.writeAsStringSync(jsonEncode(encoded));
  }

  void record(String method, Uri uri, RecordedResponse response) {
    final list = entries.putIfAbsent(keyFor(method, uri), () => []);
    // Re-recording runs accumulate: keep one copy of an identical answer.
    for (final existing in list) {
      if (existing.status == response.status &&
          existing.bodyBytes.length == response.bodyBytes.length &&
          _sameBytes(existing.bodyBytes, response.bodyBytes)) {
        return;
      }
    }
    list.add(response);
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// Exact key first; then the same path ignoring volatile params; then any
  /// recording of the same path; null when nothing was ever recorded for it.
  RecordedResponse? lookup(String method, Uri uri) {
    final exact = entries[keyFor(method, uri)];
    if (exact != null && exact.isNotEmpty) {
      return _preferred(exact);
    }
    final upperMethod = method.toUpperCase();
    final path = _normalizedPath(uri);
    final loose = '$upperMethod $path${_sortedQuery(uri, dropVolatile: true)}';
    final prefix = '$upperMethod $path';
    List<RecordedResponse>? fallback;
    for (final entry in entries.entries) {
      final key = entry.key;
      if (key == loose ||
          (key.startsWith(prefix) &&
              _looseKey(key) == loose)) {
        return _preferred(entry.value);
      }
      if (key == prefix || key.startsWith('$prefix?')) {
        fallback ??= entry.value;
      }
    }
    return fallback == null ? null : _preferred(fallback);
  }

  static String _looseKey(String key) {
    final space = key.indexOf(' ');
    final method = key.substring(0, space);
    final rest = key.substring(space + 1);
    final question = rest.indexOf('?');
    if (question < 0) {
      return key;
    }
    final path = rest.substring(0, question);
    final query = rest.substring(question + 1).split('&').where((part) {
      final name = part.split('=').first;
      return !_isVolatile(name);
    }).toList();
    return query.isEmpty ? '$method $path' : '$method $path?${query.join('&')}';
  }

  /// The last successful recording wins: the same GET before and after login
  /// records a 401 then a 200, and replay should behave as the signed-in app.
  static RecordedResponse _preferred(List<RecordedResponse> list) {
    for (final item in list.reversed) {
      if (item.status >= 200 && item.status < 300) {
        return item;
      }
    }
    return list.last;
  }
}

/// Forwards to [inner] and records every exchange into [store].
class RecordingHttpClient extends http.BaseClient {
  RecordingHttpClient(this.inner, this.store);

  final http.Client inner;
  final PerfFixtureStore store;
  int recorded = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    final bytes = await response.stream.toBytes();
    final headers = <String, String>{
      for (final entry in response.headers.entries)
        if (_keptHeaders.contains(entry.key.toLowerCase()))
          entry.key.toLowerCase(): entry.value,
    };
    store.record(
      request.method,
      request.url,
      RecordedResponse(
        status: response.statusCode,
        headers: headers,
        bodyBytes: bytes,
      ),
    );
    recorded += 1;
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => inner.close();
}

/// Serves recorded responses; unknown requests get a 404 and are listed in
/// [misses] so fixture gaps are visible in the report.
class ReplayHttpClient extends http.BaseClient {
  ReplayHttpClient(this.store, {this.latency = Duration.zero});

  final PerfFixtureStore store;

  /// Artificial round-trip so loading states are actually on screen long
  /// enough to be measured (an instant reply would skip them entirely).
  final Duration latency;

  final List<String> misses = [];
  int hits = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Drain the body so multipart/streamed requests finish cleanly.
    await request.finalize().drain<void>();
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    final recorded = store.lookup(request.method, request.url);
    if (recorded == null) {
      final key = PerfFixtureStore.keyFor(request.method, request.url);
      if (!misses.contains(key)) {
        misses.add(key);
      }
      final body = utf8.encode('{"detail":"perf fixture missing: $key"}');
      return http.StreamedResponse(
        http.ByteStream.fromBytes(body),
        404,
        contentLength: body.length,
        request: request,
        headers: const {'content-type': 'application/json'},
      );
    }
    hits += 1;
    return http.StreamedResponse(
      http.ByteStream.fromBytes(recorded.bodyBytes),
      recorded.status,
      contentLength: recorded.bodyBytes.length,
      request: request,
      headers: recorded.headers,
    );
  }
}
