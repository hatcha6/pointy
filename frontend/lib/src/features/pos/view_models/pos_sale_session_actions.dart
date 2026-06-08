part of 'pos_view_model.dart';

extension PosSaleSessionActions on PosViewModel {
  void startNewSaleSession() {
    if (!canStartNewSaleSession) {
      return;
    }

    final session = _createSaleSession();
    _saleSessions.add(session);
    _activeSaleSessionId = session.id;
    _notifyChanged();
  }

  void switchSaleSession(int sessionId) {
    if (_isCheckingOut || sessionId == _activeSaleSessionId) {
      return;
    }
    if (!_saleSessions.any((session) => session.id == sessionId)) {
      return;
    }

    _activeSaleSessionId = sessionId;
    _notifyChanged();
  }

  void discardSaleSession(int sessionId) {
    if (_isCheckingOut || sessionId == _activeSaleSessionId) {
      return;
    }

    final index = _saleSessions.indexWhere(
      (session) => session.id == sessionId,
    );
    if (index == -1) {
      return;
    }

    final removedSession = _saleSessions.removeAt(index);
    if (removedSession.cart.isNotEmpty) {
      _trackCartCleared(
        List<CartLine>.of(removedSession.cart),
        source: 'sale_session_discard_button',
      );
    }
    _ensureActiveSaleSession();
    _notifyChanged();
  }

  void _resetSaleSessions() {
    _nextSaleSessionId = 1;
    _nextSaleSessionNumber = 1;
    _saleSessions
      ..clear()
      ..add(_createSaleSession());
    _activeSaleSessionId = _saleSessions.single.id;
  }

  void _completeActiveSaleSessionCheckout() {
    final completedIndex = _saleSessions.indexWhere(
      (session) => session.id == _activeSaleSessionId,
    );
    if (completedIndex != -1) {
      _saleSessions.removeAt(completedIndex);
    }

    if (_saleSessions.isEmpty) {
      final session = _createSaleSession();
      _saleSessions.add(session);
      _activeSaleSessionId = session.id;
      return;
    }

    _activeSaleSessionId = _saleSessions.reduce((latest, session) {
      if (session.updatedAt.isAfter(latest.updatedAt)) {
        return session;
      }
      return latest;
    }).id;
  }

  void _ensureActiveSaleSession() {
    if (_saleSessions.any((session) => session.id == _activeSaleSessionId)) {
      return;
    }
    if (_saleSessions.isEmpty) {
      final session = _createSaleSession();
      _saleSessions.add(session);
      _activeSaleSessionId = session.id;
      return;
    }
    _activeSaleSessionId = _saleSessions.last.id;
  }

  _PosSaleSession _createSaleSession() {
    return _PosSaleSession(
      id: _nextSaleSessionId++,
      number: _nextSaleSessionNumber++,
    );
  }

  void _touchActiveSaleSession() {
    _activeSaleSession.touch();
  }
}
