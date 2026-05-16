import 'register_session.dart';

class RegisterSessionPage {
  const RegisterSessionPage({required this.sessions, required this.hasMore});

  final List<RegisterSession> sessions;
  final bool hasMore;

  factory RegisterSessionPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(RegisterSession.fromJson)
        .toList(growable: false);

    return RegisterSessionPage(
      sessions: results,
      hasMore: json['next'] != null,
    );
  }
}
