import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/conversation.dart';
import '../../../data/repositories/crm_repository.dart';

/// Drives the conversations inbox (the thread list). Mints a
/// [ConversationThreadViewModel] for each thread the user opens.
class ConversationsViewModel extends ChangeNotifier {
  ConversationsViewModel(this._repository);

  final CrmRepository _repository;

  List<Conversation> _conversations = const [];
  bool _isLoading = false;
  bool _hasLoadError = false;

  List<Conversation> get conversations => _conversations;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isEmpty => _conversations.isEmpty;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadConversations();
    switch (result) {
      case Ok<List<Conversation>>(value: final items):
        _conversations = items;
      case Error<List<Conversation>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  ConversationThreadViewModel threadViewModel(Conversation conversation) {
    return ConversationThreadViewModel(_repository, conversation);
  }
}

/// Drives one open thread: loads its messages, marks it read, and sends replies.
class ConversationThreadViewModel extends ChangeNotifier {
  ConversationThreadViewModel(this._repository, this._summary)
    : _conversation = _summary;

  final CrmRepository _repository;
  final Conversation _summary;
  Conversation _conversation;
  bool _isLoading = false;
  bool _hasLoadError = false;
  bool _isSending = false;

  Conversation get conversation => _conversation;
  List<ConversationMessage> get messages => _conversation.messages;
  String get title => _summary.title;
  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isSending => _isSending;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadConversation(_summary.id);
    switch (result) {
      case Ok<Conversation>(value: final full):
        _conversation = full;
      case Error<Conversation>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
    unawaited(_markRead());
  }

  Future<void> _markRead() async {
    if (_conversation.unreadCount == 0) return;
    await _repository.markRead(_summary.id);
  }

  Future<bool> sendReply(String body) async {
    final text = body.trim();
    if (text.isEmpty || _isSending) return false;
    _isSending = true;
    notifyListeners();

    final result = await _repository.reply(_summary.id, text);
    var ok = false;
    switch (result) {
      case Ok<ConversationMessage>(value: final message):
        _conversation = _conversation.copyWith(
          messages: [..._conversation.messages, message],
        );
        ok = true;
      case Error<ConversationMessage>():
        ok = false;
    }

    _isSending = false;
    notifyListeners();
    return ok;
  }
}
