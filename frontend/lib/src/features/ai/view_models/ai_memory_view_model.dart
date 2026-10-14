import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/ai_memory.dart';
import '../../../data/repositories/ai_chat_repository.dart';

/// The memory screen: what the assistant remembers that this user can see,
/// with editing and deleting where the server allows it.
class AiMemoryViewModel extends ChangeNotifier {
  AiMemoryViewModel(this._repository);

  final AiChatRepository _repository;

  List<AiMemory> _memories = const [];
  bool _isLoading = false;
  bool _failed = false;

  List<AiMemory> get shopMemories =>
      _memories.where((m) => m.isShop).toList(growable: false);
  List<AiMemory> get personalMemories =>
      _memories.where((m) => !m.isShop).toList(growable: false);
  bool get isEmpty => _memories.isEmpty;
  bool get isLoading => _isLoading;
  bool get failed => _failed;

  Future<void> load() async {
    _isLoading = true;
    _failed = false;
    notifyListeners();
    final result = await _repository.loadMemories();
    switch (result) {
      case Ok(:final value):
        _memories = value;
      case Error():
        _failed = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Saves an edited memory; false when the server refused it.
  Future<bool> update(AiMemory memory, String content) async {
    final text = content.trim();
    if (text.isEmpty || text == memory.content) {
      return text.isNotEmpty;
    }
    final result = await _repository.updateMemory(memory.id, text);
    if (result case Ok(:final value)) {
      _memories = [for (final m in _memories) m.id == memory.id ? value : m];
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<bool> delete(AiMemory memory) async {
    final result = await _repository.deleteMemory(memory.id);
    if (result is Ok) {
      _memories = _memories.where((m) => m.id != memory.id).toList();
      notifyListeners();
      return true;
    }
    return false;
  }
}
