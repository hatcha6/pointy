import '../../core/result.dart';
import '../models/ai_chat.dart';
import '../services/pos_api_service.dart';

/// Access to the AI assistant: a streamed chat reply plus [Result]-wrapped
/// conversation history. Transport failures on the stream are converted into
/// terminal [AiChatError] events so the view model never touches the service
/// layer or raw exceptions.
class AiChatRepository {
  const AiChatRepository(this._service);

  final PosApiService _service;

  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    try {
      yield* _service.streamAiChat(
        conversationId: conversationId,
        message: message,
        attachments: attachments,
      );
    } on PosApiException catch (exception) {
      yield AiChatError(exception.message, statusCode: exception.statusCode);
    } on Exception catch (exception) {
      yield AiChatError(exception.toString());
    }
  }

  Future<Result<AiUsage>> loadUsage() {
    return Result.guard(() => _service.fetchAiUsage());
  }

  Future<Result<List<AiConversationSummary>>> loadConversations({
    int page = 1,
  }) {
    return Result.guard(() => _service.fetchAiConversations(page: page));
  }

  Future<Result<AiConversation>> loadConversation(int id) {
    return Result.guard(() => _service.fetchAiConversation(id));
  }

  Future<Result<bool>> deleteConversation(int id) {
    return Result.guard(() async {
      await _service.deleteAiConversation(id);
      return true;
    });
  }

  Future<Result<bool>> truncateConversation(int conversationId, int messageId) {
    return Result.guard(() async {
      await _service.truncateAiConversation(conversationId, messageId);
      return true;
    });
  }
}
