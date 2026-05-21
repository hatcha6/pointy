part of 'pos_view_model.dart';

extension PosRegisterSessionActions on PosViewModel {
  Future<void> loadCurrentRegisterSession() {
    final inFlight = _registerSessionLoadFuture;
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<void> future;
    future = _loadCurrentRegisterSession().whenComplete(() {
      if (identical(_registerSessionLoadFuture, future)) {
        _registerSessionLoadFuture = null;
      }
    });
    _registerSessionLoadFuture = future;
    return future;
  }

  Future<void> _loadCurrentRegisterSession() async {
    _isLoadingRegisterSession = true;
    _hasRegisterSessionError = false;
    _notifyChanged();

    final result = await _registerSessionRepository.loadCurrentSession();
    switch (result) {
      case Ok<RegisterSession?>():
        _availableRegisterSession = result.value;
      case Error<RegisterSession?>():
        _availableRegisterSession = null;
        _hasRegisterSessionError = true;
    }

    _isLoadingRegisterSession = false;
    _notifyChanged();
  }

  Future<bool> startRegisterSession({required double openingCash}) async {
    if (_isStartingRegisterSession) {
      return false;
    }

    _isStartingRegisterSession = true;
    _hasRegisterSessionError = false;
    _notifyChanged();

    final result = await _registerSessionRepository.startSession(
      openingCash: openingCash,
    );
    switch (result) {
      case Ok<RegisterSession>():
        _activateRegisterSession(result.value);
        await loadCatalog();
        _isStartingRegisterSession = false;
        _notifyChanged();
        return true;
      case Error<RegisterSession>():
        _hasRegisterSessionError = true;
        _isStartingRegisterSession = false;
        _notifyChanged();
        return false;
    }
  }

  Future<void> resumeRegisterSession() async {
    final session = _availableRegisterSession;
    if (session == null) {
      return;
    }

    _activateRegisterSession(session);
    _notifyChanged();
    await loadCatalog();
  }

  Future<bool> closeActiveRegisterSession({
    required double closingCash,
    required int count025,
    required int count050,
    required int count075,
    required int count100,
  }) async {
    final session = _activeRegisterSession;
    if (session == null || _isClosingRegisterSession) {
      return false;
    }

    _isClosingRegisterSession = true;
    _hasRegisterSessionError = false;
    _notifyChanged();

    final result = await _registerSessionRepository.closeSession(
      sessionId: session.id,
      draft: RegisterSessionCloseDraft(
        closingCash: closingCash,
        count025: count025,
        count050: count050,
        count075: count075,
        count100: count100,
      ),
    );
    switch (result) {
      case Ok<RegisterSession>():
        _activeRegisterSession = null;
        _availableRegisterSession = null;
        _cart.clear();
        _variants = [];
        _isClosingRegisterSession = false;
        _notifyChanged();
        await loadCurrentRegisterSession();
        return true;
      case Error<RegisterSession>():
        _hasRegisterSessionError = true;
        _isClosingRegisterSession = false;
        _notifyChanged();
        return false;
    }
  }

  Future<bool> createActiveRegisterCashMovement({
    required RegisterCashMovementType movementType,
    required double amount,
    required String reason,
  }) async {
    final session = _activeRegisterSession;
    if (session == null || _isCreatingCashMovement) {
      return false;
    }

    _isCreatingCashMovement = true;
    _hasRegisterSessionError = false;
    _notifyChanged();

    final result = await _registerSessionRepository.createCashMovement(
      sessionId: session.id,
      movementType: movementType,
      draft: RegisterCashMovementDraft(amount: amount, reason: reason),
    );
    switch (result) {
      case Ok<RegisterCashMovement>():
        _isCreatingCashMovement = false;
        _notifyChanged();
        return true;
      case Error<RegisterCashMovement>():
        _hasRegisterSessionError = true;
        _isCreatingCashMovement = false;
        _notifyChanged();
        return false;
    }
  }

  void _activateRegisterSession(RegisterSession session) {
    _activeRegisterSession = session;
    _availableRegisterSession = null;
    _cart.clear();
  }
}
