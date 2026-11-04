import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/remote_session.dart';
import '../../../data/repositories/user_repository.dart';

/// The remote sessions of one person: the signed-in person's own on «إعداداتي»
/// ([userId] null), or anyone's on their page in user management.
class RemoteSessionsViewModel extends ChangeNotifier {
  RemoteSessionsViewModel(this._userRepository, {this.userId});

  final UserRepository _userRepository;
  final int? userId;

  List<RemoteSession> _sessions = const [];
  bool _isLoading = false;
  bool _hasLoaded = false;
  bool _hasError = false;
  bool _hasRevokeError = false;
  final Set<int> _revoking = {};
  bool _disposed = false;

  List<RemoteSession> get sessions => _sessions;
  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  bool get hasError => _hasError;
  bool get hasRevokeError => _hasRevokeError;
  int get activeCount => _sessions.where((session) => session.isActive).length;
  bool isRevoking(int id) => _revoking.contains(id);

  Future<void> load() async {
    if (_isLoading) {
      return;
    }
    _isLoading = true;
    _hasError = false;
    _notify();
    final result = await _userRepository.loadRemoteSessions(userId: userId);
    switch (result) {
      case Ok<List<RemoteSession>>(value: final sessions):
        _sessions = List.unmodifiable(sessions);
        _hasLoaded = true;
      case Error<List<RemoteSession>>():
        _hasError = true;
    }
    _isLoading = false;
    _notify();
  }

  /// Ends one session. Answers whether it ended; on failure
  /// [hasRevokeError] says so until the next attempt.
  Future<bool> revoke(RemoteSession session) async {
    if (_revoking.contains(session.id)) {
      return false;
    }
    _revoking.add(session.id);
    _hasRevokeError = false;
    _notify();
    final result = await _userRepository.revokeRemoteSession(
      session.id,
      userId: userId,
    );
    _revoking.remove(session.id);
    final bool ended;
    switch (result) {
      case Ok<RemoteSession>(value: final updated):
        _sessions = List.unmodifiable([
          for (final item in _sessions) item.id == updated.id ? updated : item,
        ]);
        ended = true;
      case Error<RemoteSession>():
        _hasRevokeError = true;
        ended = false;
    }
    _notify();
    return ended;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
