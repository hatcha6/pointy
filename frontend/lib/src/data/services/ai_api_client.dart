import 'dart:convert';

import '../models/ai_chat.dart';
import 'api_session.dart';

/// Talks to the on-prem AI endpoints. Chat replies stream as SSE
/// (Django proxies the relay, which proxies OpenRouter); conversation history
/// is plain JSON. Gating happens server-side on the shop's AI entitlement.
class AiApiClient {
  const AiApiClient(this._session);

  final PosApiSession _session;

  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    final body = <String, Object?>{
      'message': message,
      'conversation_id': ?conversationId,
      if (attachments.isNotEmpty)
        'attachments': attachments.map((a) => a.toJson()).toList(),
    };
    await for (final event in _session.openEventStream(
      'ai/chat/',
      body: body,
    )) {
      final parsed = _parseEvent(event);
      if (parsed != null) {
        yield parsed;
      }
    }
  }

  AiChatEvent? _parseEvent(SseEvent event) {
    Map<String, Object?> data = const {};
    if (event.data.isNotEmpty) {
      try {
        final decoded = jsonDecode(event.data);
        if (decoded is Map<String, Object?>) {
          data = decoded;
        }
      } on FormatException {
        data = const {};
      }
    }
    switch (event.event) {
      case 'delta':
        return AiChatDelta((data['text'] as String?) ?? '');
      case 'reasoning':
        return AiChatReasoning((data['text'] as String?) ?? '');
      case 'tool':
        return AiChatToolActivity(
          name: (data['name'] as String?) ?? '',
          resource: data['resource'] as String?,
          label: data['label'] as String?,
          phase: (data['phase'] as String?) ?? 'start',
          ok: data['ok'] as bool?,
        );
      case 'done':
        final limits = data['usage_limits'];
        return AiChatDone(
          conversationId: (data['conversation_id'] as num?)?.toInt() ?? 0,
          messageId: (data['message_id'] as num?)?.toInt(),
          userMessageId: (data['user_message_id'] as num?)?.toInt(),
          model: (data['model'] as String?) ?? '',
          usage: limits is Map<String, Object?>
              ? AiUsage.fromJson(limits)
              : null,
        );
      case 'error':
        return AiChatError((data['detail'] as String?) ?? 'error');
      default:
        return null;
    }
  }

  Future<AiUsage> fetchUsage() async {
    final response = await _session.get('ai/usage/');
    _session.ensureSuccess(response, 'AI usage request failed with status');
    final decoded = _session.decodedBody(response);
    return AiUsage.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<List<AiConversationSummary>> fetchConversations({int page = 1}) async {
    final response = await _session.get(
      'ai/conversations/',
      query: {'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'AI conversations request failed with status',
    );
    return decodeListResponse(
      _session.decodedBody(response),
      AiConversationSummary.fromJson,
    );
  }

  Future<AiConversation> fetchConversation(int id) async {
    final response = await _session.get('ai/conversations/$id/');
    _session.ensureSuccess(
      response,
      'AI conversation request failed with status',
    );
    final decoded = _session.decodedBody(response);
    return AiConversation.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<void> deleteConversation(int id) async {
    final response = await _session.delete('ai/conversations/$id/');
    _session.ensureSuccess(
      response,
      'AI conversation delete failed with status',
    );
  }

  /// Deletes [messageId] and every message after it — the server-side half of an
  /// edit/retry rewind (the next prompt is rebuilt from the DB).
  Future<void> truncateConversation(int conversationId, int messageId) async {
    final response = await _session.post(
      'ai/conversations/$conversationId/truncate/',
      body: {'message_id': messageId},
    );
    _session.ensureSuccess(
      response,
      'AI conversation truncate failed with status',
    );
  }
}
