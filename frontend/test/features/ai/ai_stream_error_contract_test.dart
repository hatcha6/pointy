import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:http/http.dart' as http;
import 'package:pointy_frontend/src/data/services/ai_api_client.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

/// The relay call now happens *inside* the stream, so a refusal arrives as an
/// `error` event rather than an HTTP status. The status has to survive that
/// move, or the quota / not-enabled screens silently become a generic error.
void main() {
  final client = AiApiClient(
    PosApiSession(baseUrl: 'http://localhost:8000/api/', client: _NoClient()),
  );
  AiChatEvent? parse(String data) =>
      client.parseEvent(SseEvent(event: 'error', data: data));

  test('a relay refusal carries the status the UI acts on', () {
    final event =
        parse(
              '{"detail":"AI usage limit reached.","status":429,'
              '"scope":"five_hour"}',
            )!
            as AiChatError;

    expect(event.statusCode, 429);
    expect(event.detail, 'AI usage limit reached.');
  });

  test('not-entitled arrives as 403, the same code the HTTP path returned', () {
    final event =
        parse('{"detail":"AI is not enabled for this shop.","status":403}')!
            as AiChatError;
    expect(event.statusCode, 403);
  });

  test('an in-band model failure has no status', () {
    // A mid-stream failure is not an HTTP condition and must not be dressed as
    // one — it maps to the generic AI error, not to "not entitled".
    final event = parse('{"detail":"ai stream failed"}')! as AiChatError;
    expect(event.statusCode, isNull);
  });

  test('a status sent as text is still understood', () {
    final event = parse('{"detail":"x","status":"429"}')! as AiChatError;
    expect(event.statusCode, 429);
  });
}

class _NoClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError('parsing only');
}
