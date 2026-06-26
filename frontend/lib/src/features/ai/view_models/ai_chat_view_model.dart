import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/ai_chat.dart';
import '../../../data/repositories/ai_chat_repository.dart';
import '../ai_attachment_picker.dart';

/// How the last turn failed. The screen maps each kind to localized copy so no
/// user-facing text lives in the view model.
enum AiChatErrorKind {
  network,
  server,
  notEntitled,
  rateLimited,
  tooManyImages,
  aiError,
}

/// Drives the AI assistant screen: holds the active conversation, streams the
/// assistant reply token-by-token (appending deltas in place), manages pending
/// attachments + usage limits, and lists past conversations for the history
/// pane. The relay auto-routes the model, so there is no tier to track.
class AiChatViewModel extends ChangeNotifier {
  AiChatViewModel(
    this._repository, {
    AiAttachmentPicker? picker,
    this.maxImages = 5,
  }) : _picker = picker ?? AiAttachmentPicker();

  final AiChatRepository _repository;
  final AiAttachmentPicker _picker;

  /// Image cap enforced client-side (the relay enforces it too, remotely).
  final int maxImages;

  final List<AiMessage> _messages = [];
  final List<AiAttachment> _pendingAttachments = [];
  List<AiConversationSummary> _conversations = const [];
  int? _conversationId;
  AiUsage? _usage;
  bool _isStreaming = false;
  bool _isLoadingHistory = false;
  bool _imageLimitReached = false;
  AiChatErrorKind? _errorKind;
  // The assistant turn whose ask_user question is awaiting the user's answer.
  AiMessage? _pendingMessage;

  List<AiMessage> get messages => _messages;
  List<AiAttachment> get pendingAttachments => _pendingAttachments;
  List<AiConversationSummary> get conversations => _conversations;
  int? get conversationId => _conversationId;
  AiUsage? get usage => _usage;
  bool get isStreaming => _isStreaming;
  bool get isLoadingHistory => _isLoadingHistory;
  bool get hasMessages => _messages.isNotEmpty;

  /// The assistant turn currently receiving deltas, if any. The screen listens
  /// to just this message for a throttled scroll-follow, so token growth never
  /// rebuilds the whole conversation.
  AiMessage? get streamingMessage {
    if (!_isStreaming || _messages.isEmpty) {
      return null;
    }
    final last = _messages.last;
    return last.isStreaming ? last : null;
  }
  bool get hasPendingAttachments => _pendingAttachments.isNotEmpty;
  AiChatErrorKind? get errorKind => _errorKind;

  /// The question the assistant is currently asking the user, if any. The screen
  /// renders its card and locks the composer until it's answered or skipped.
  AiPendingQuestion? get pendingQuestion => _pendingMessage?.pendingQuestion;
  bool get hasPendingQuestion => _pendingMessage?.hasPendingQuestion ?? false;

  int get _pendingImageCount =>
      _pendingAttachments.where((a) => a.isImage).length;

  /// Whether another image may still be attached to this prompt.
  bool get canAddImage => _pendingImageCount < maxImages;

  /// Set when the user tries to exceed [maxImages]; the screen reads it to show
  /// a notice, then calls [acknowledgeImageLimit].
  bool get imageLimitReached => _imageLimitReached;

  void startNewConversation() {
    if (_isStreaming) {
      return;
    }
    _messages.clear();
    _pendingAttachments.clear();
    _conversationId = null;
    _errorKind = null;
    _pendingMessage = null;
    notifyListeners();
  }

  Future<void> loadHistory() async {
    _isLoadingHistory = true;
    notifyListeners();
    final result = await _repository.loadConversations();
    if (result is Ok<List<AiConversationSummary>>) {
      _conversations = result.value;
    }
    _isLoadingHistory = false;
    notifyListeners();
  }

  Future<void> loadUsage() async {
    final result = await _repository.loadUsage();
    if (result is Ok<AiUsage>) {
      _usage = result.value;
      notifyListeners();
    }
  }

  Future<void> openConversation(int id) async {
    if (_isStreaming) {
      return;
    }
    final result = await _repository.loadConversation(id);
    switch (result) {
      case Ok<AiConversation>(value: final conversation):
        _messages
          ..clear()
          ..addAll(conversation.messages);
        _pendingAttachments.clear();
        _conversationId = conversation.id;
        _errorKind = null;
        // Re-open an unanswered question from history so it can be answered after
        // a reload — the last awaiting turn, if any.
        _pendingMessage = null;
        for (final message in _messages) {
          if (message.hasPendingQuestion) {
            _pendingMessage = message;
          }
        }
      case Error<AiConversation>():
        _errorKind = AiChatErrorKind.network;
    }
    notifyListeners();
  }

  /// Reflect a (re)named conversation in the local history immediately — update
  /// the matching summary, or prepend a fresh one for a just-created conversation
  /// so its AI title shows without waiting for a history refetch. The enclosing
  /// stream loop notifies listeners once it finishes.
  void _applyConversationTitle(int? conversationId, String title) {
    if (conversationId == null || conversationId == 0 || title.isEmpty) {
      return;
    }
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index >= 0) {
      final existing = _conversations[index];
      if (existing.title == title) {
        return;
      }
      _conversations = [..._conversations]..[index] = AiConversationSummary(
        id: existing.id,
        title: title,
        messageCount: existing.messageCount,
        updatedAt: existing.updatedAt,
      );
    } else {
      _conversations = [
        AiConversationSummary(
          id: conversationId,
          title: title,
          messageCount: _messages.length,
          updatedAt: DateTime.now(),
        ),
        ..._conversations,
      ];
    }
  }

  Future<void> deleteConversation(int id) async {
    final result = await _repository.deleteConversation(id);
    if (result is Ok<bool>) {
      _conversations = _conversations
          .where((conversation) => conversation.id != id)
          .toList(growable: false);
      if (_conversationId == id) {
        startNewConversation();
      } else {
        notifyListeners();
      }
    }
  }

  Future<void> addImage({required bool fromCamera}) async {
    if (_isStreaming) {
      return;
    }
    if (!canAddImage) {
      _flagImageLimit();
      return;
    }
    final attachment = await _picker.pickImage(fromCamera: fromCamera);
    if (attachment == null) {
      return;
    }
    _pendingAttachments.add(attachment);
    notifyListeners();
  }

  Future<void> addFiles() async {
    if (_isStreaming) {
      return;
    }
    final picked = await _picker.pickFiles();
    if (picked.isEmpty) {
      return;
    }
    var rejectedImage = false;
    for (final attachment in picked) {
      if (attachment.isImage && !canAddImage) {
        rejectedImage = true;
        continue;
      }
      _pendingAttachments.add(attachment);
    }
    if (rejectedImage) {
      _imageLimitReached = true;
    }
    notifyListeners();
  }

  void removeAttachment(AiAttachment attachment) {
    _pendingAttachments.remove(attachment);
    notifyListeners();
  }

  void acknowledgeImageLimit() {
    _imageLimitReached = false;
  }

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    final attachments = List<AiAttachment>.unmodifiable(_pendingAttachments);
    if ((trimmed.isEmpty && attachments.isEmpty) || _isStreaming) {
      return;
    }

    _errorKind = null;
    _pendingAttachments.clear();
    final userMessage = AiMessage(
      role: AiMessageRole.user,
      content: trimmed,
      attachments: attachments,
    );
    _messages.add(userMessage);
    final assistant = AiMessage(
      role: AiMessageRole.assistant,
      content: '',
      isStreaming: true,
    );
    _messages.add(assistant);
    _isStreaming = true;
    notifyListeners();

    await _drive(
      _repository.streamChat(
        conversationId: _conversationId,
        message: trimmed,
        attachments: attachments,
      ),
      assistant,
      userMessage: userMessage,
    );
  }

  /// Queue a freshly-recorded voice clip and send it right away, bundled with
  /// any images/files already attached, as a turn with no typed text.
  Future<void> sendRecordedAudio(AiAttachment audio) async {
    if (_isStreaming) {
      return;
    }
    _pendingAttachments.add(audio);
    notifyListeners();
    await sendMessage('');
  }

  /// Answer the pending ask_user question and resume the agentic turn: a fresh
  /// assistant bubble streams the model's continuation. [declined] resumes with a
  /// skip instead of answers, so a flow never deadlocks on an ignored question.
  Future<void> submitAnswer(List<AiAnswer> answers, {bool declined = false}) async {
    final pending = _pendingMessage;
    final question = pending?.pendingQuestion;
    final conversationId = _conversationId;
    final messageId = question?.messageId;
    if (pending == null ||
        question == null ||
        conversationId == null ||
        messageId == null ||
        _isStreaming) {
      return;
    }

    _errorKind = null;
    pending.resolveQuestion(declined ? const [] : answers);
    _pendingMessage = null;
    final assistant = AiMessage(
      role: AiMessageRole.assistant,
      content: '',
      isStreaming: true,
    );
    _messages.add(assistant);
    _isStreaming = true;
    notifyListeners();

    await _drive(
      _repository.resumeChat(
        conversationId: conversationId,
        messageId: messageId,
        toolCallId: question.toolCallId,
        answers: declined ? const [] : answers,
        declined: declined,
      ),
      assistant,
    );
  }

  /// Dismiss the pending question without answering — resumes the AI with a
  /// "declined" result so it can proceed (or ask differently).
  Future<void> skipQuestion() => submitAnswer(const [], declined: true);

  /// Consume a chat/resume SSE stream into [assistant], finalize the turn, and
  /// drop an empty bubble. Shared by the initial send and the resume so a resumed
  /// turn can itself stream tools, text, or another ask_user question.
  Future<void> _drive(
    Stream<AiChatEvent> stream,
    AiMessage assistant, {
    AiMessage? userMessage,
  }) async {
    await for (final event in stream) {
      switch (event) {
        // Deltas/reasoning/tool updates notify *the message*, not the view
        // model, so a streamed token rebuilds only its own bubble — never the
        // app bar, composer, or settled messages above it.
        case AiChatDelta(:final text):
          assistant.appendContent(text);
        case AiChatReasoning(:final text):
          assistant.appendReasoning(text);
        case AiChatDone(
          :final conversationId,
          :final userMessageId,
          :final usage,
          :final title,
          :final sources,
          :final webSearched,
        ):
          if (conversationId != 0) {
            _conversationId = conversationId;
          }
          if (userMessageId != null && userMessage != null) {
            userMessage.id = userMessageId;
          }
          if (usage != null) {
            _usage = usage;
          }
          if (title.isNotEmpty) {
            _applyConversationTitle(_conversationId, title);
          }
          if (webSearched || sources.isNotEmpty) {
            assistant.attachSources(sources, webSearched: webSearched);
          }
        case AiChatAskUser(
          :final conversationId,
          :final messageId,
          :final toolCallId,
          :final questions,
        ):
          if (conversationId != 0) {
            _conversationId = conversationId;
          }
          assistant.id = messageId;
          assistant.attachQuestion(
            AiPendingQuestion(
              toolCallId: toolCallId,
              messageId: messageId,
              questions: questions,
            ),
          );
          _pendingMessage = assistant;
        case AiChatToolActivity(
          :final name,
          :final resource,
          :final label,
          :final ok,
          :final mutates,
          :final arguments,
          :final output,
        ):
          if (event.isStart) {
            assistant.startToolRun(
              AiToolRun(name: name, resource: resource, label: label, mutates: mutates),
            );
          } else {
            assistant.finishToolRun(
              name: name,
              resource: resource,
              ok: ok,
              arguments: arguments,
              output: output,
            );
          }
        case AiChatError(:final statusCode):
          _errorKind = _errorKindFor(statusCode);
      }
    }

    assistant.markStreamingComplete();
    _isStreaming = false;
    // Drop an empty assistant bubble if the turn failed before any output — but
    // keep it if it ran tools or is asking a question (meaningful activity).
    if (assistant.content.isEmpty &&
        assistant.reasoning.isEmpty &&
        assistant.toolRuns.isEmpty &&
        assistant.pendingQuestion == null) {
      _messages.remove(assistant);
    }
    notifyListeners();

    // A rate-limit rejection carries a reset time in the usage snapshot; refresh
    // it so the ring can show when the window reopens.
    if (_errorKind == AiChatErrorKind.rateLimited) {
      unawaited(loadUsage());
    }
  }

  /// Regenerate the answer for [message]: rewinds to it (dropping it and every
  /// later turn, on the server too) then resends the same text.
  Future<void> retry(AiMessage message) async {
    if (_isStreaming || !message.isUser) {
      return;
    }
    final text = message.content;
    if (!await _rewindTo(message)) {
      return;
    }
    await sendMessage(text);
  }

  /// Rewind to [message] for editing: drops it and every later turn (server-side
  /// too) and returns its text for the composer. Null if it couldn't rewind.
  Future<String?> rewindForEdit(AiMessage message) async {
    if (_isStreaming || !message.isUser) {
      return null;
    }
    final text = message.content;
    if (!await _rewindTo(message)) {
      return null;
    }
    return text;
  }

  /// Removes [message] and everything after it, locally and on the server. The
  /// server rebuilds context from the DB, so a local-only drop would leak the
  /// removed turns back into the next prompt. Returns false without changing
  /// anything if the server truncation fails.
  Future<bool> _rewindTo(AiMessage message) async {
    final index = _messages.indexOf(message);
    if (index < 0) {
      return false;
    }
    final id = message.id;
    final conversationId = _conversationId;
    if (id != null && conversationId != null) {
      final result = await _repository.truncateConversation(conversationId, id);
      if (result is! Ok<bool>) {
        _errorKind = AiChatErrorKind.network;
        notifyListeners();
        return false;
      }
    }
    _messages.removeRange(index, _messages.length);
    // If the rewind dropped a turn that was awaiting an answer, the question goes
    // with it (the server truncates the paused turn too), so clear pending state.
    if (_pendingMessage != null && !_messages.contains(_pendingMessage)) {
      _pendingMessage = null;
    }
    _errorKind = null;
    notifyListeners();
    return true;
  }

  void _flagImageLimit() {
    _imageLimitReached = true;
    notifyListeners();
  }

  AiChatErrorKind _errorKindFor(int? statusCode) {
    if (statusCode == 429) {
      return AiChatErrorKind.rateLimited;
    }
    if (statusCode == 403 || statusCode == 402) {
      return AiChatErrorKind.notEntitled;
    }
    if (statusCode == 422) {
      return AiChatErrorKind.tooManyImages;
    }
    if (statusCode != null) {
      return AiChatErrorKind.server;
    }
    return AiChatErrorKind.aiError;
  }
}
