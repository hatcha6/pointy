import 'query.dart';
import 'register_session.dart';

class RegisterSessionPage {
  const RegisterSessionPage({
    required this.sessions,
    required this.hasMore,
    this.nextCursor,
  });

  final List<RegisterSession> sessions;
  final bool hasMore;

  /// Opaque keyset cursor for the following page, when the feed paginates by
  /// cursor. Null on the last page (and on page-number endpoints).
  final String? nextCursor;

  factory RegisterSessionPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(RegisterSession.fromJson)
        .toList(growable: false);

    return RegisterSessionPage(
      sessions: results,
      hasMore: json['next'] != null,
      nextCursor: nextPageCursor(json['next']),
    );
  }
}
