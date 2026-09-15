import 'dart:convert';

/// One request, parsed once, in the shape handlers actually want.
///
/// The alternative — every handler re-splitting the path and re-decoding the
/// body — is where a sandbox quietly grows three slightly different ideas of
/// what `quantity` means.
class SandboxRequest {
  SandboxRequest({
    required this.method,
    required this.path,
    required this.url,
    required String rawBody,
  }) : segments = path.split('/').where((s) => s.isNotEmpty).toList(),
       body = _decode(rawBody);

  final String method;
  final String path;
  final Uri url;
  final List<String> segments;
  final Map<String, Object?> body;

  /// Matches a route pattern, capturing `{...}` segments.
  ///
  /// Returns null when the route does not match, so a handler reads as a list
  /// of guarded returns rather than a pile of nested segment-length checks.
  List<String>? on(String method, String pattern) {
    if (this.method != method) {
      return null;
    }
    final parts = pattern.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length != segments.length) {
      return null;
    }
    final captured = <String>[];
    for (final (index, part) in parts.indexed) {
      if (part.startsWith('{') && part.endsWith('}')) {
        captured.add(segments[index]);
        continue;
      }
      if (part != segments[index]) {
        return null;
      }
    }
    return captured;
  }

  String query(String name) => url.queryParameters[name]?.trim() ?? '';

  /// Money and quantities arrive as strings far more often than as numbers —
  /// the API speaks decimal strings — so one reader handles both.
  double money(Object? value) => double.tryParse(value?.toString() ?? '') ?? 0;

  double field(String key) => money(body[key]);

  int? id(String key) => int.tryParse(body[key]?.toString() ?? '');

  String text(String key) => body[key]?.toString() ?? '';

  List<Map<String, Object?>> rows(String key) =>
      (body[key] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .toList();

  static Map<String, Object?> _decode(String raw) {
    if (raw.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?> ? decoded : const {};
  }
}

/// A handler's answer: a status and a JSON body, or null for "not mine".
typedef SandboxReply = (int, Object?)?;

/// Wraps a list of rows the way DRF's pagination does.
Map<String, Object?> page(List<Object?> results) => {
  'count': results.length,
  'next': null,
  'previous': null,
  'results': results,
};
