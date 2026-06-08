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
        _trackRegisterSessionStarted(result.value, openingCash: openingCash);
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
    _trackRegisterSessionResumed(session);
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
        _trackRegisterSessionClosed(result.value);
        _activeRegisterSession = null;
        _availableRegisterSession = null;
        _resetSaleSessions();
        _products = [];
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
        _trackRegisterCashMovement(result.value, session);
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
    _resetSaleSessions();
  }

  void _trackRegisterSessionStarted(
    RegisterSession session, {
    required double openingCash,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'pos.register_session.started',
      sessionId: 'register:${session.id}',
      entityType: 'register_session',
      entityId: session.id,
      attributes: {
        'register_session_id': session.id,
        'session_number': session.sessionNumber,
        'status': session.status,
        'source': 'register_session_gate',
      },
      metrics: {'opening_cash': openingCash},
    );
  }

  void _trackRegisterSessionResumed(RegisterSession session) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'pos.register_session.resumed',
      sessionId: 'register:${session.id}',
      entityType: 'register_session',
      entityId: session.id,
      attributes: {
        'register_session_id': session.id,
        'session_number': session.sessionNumber,
        'status': session.status,
        'source': 'register_session_gate',
      },
      metrics: {'opening_cash': session.openingCash},
    );
  }

  void _trackRegisterSessionClosed(RegisterSession session) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'pos.register_session.closed',
      sessionId: 'register:${session.id}',
      entityType: 'register_session',
      entityId: session.id,
      attributes: {
        'register_session_id': session.id,
        'session_number': session.sessionNumber,
        'status': session.status,
        'source': 'register_session_close_sheet',
        'has_cash_variance': session.hasCashVariance,
      },
      metrics: {
        'opening_cash': session.openingCash,
        if (session.closingCash != null) 'closing_cash': session.closingCash!,
        'expected_cash': session.expectedCash,
        'denomination_total': session.denominationTotal,
        if (session.cashVariance != null)
          'cash_variance': session.cashVariance!,
        'count_025': session.count025,
        'count_050': session.count050,
        'count_075': session.count075,
        'count_100': session.count100,
      },
    );
  }

  void _trackRegisterCashMovement(
    RegisterCashMovement movement,
    RegisterSession session,
  ) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'pos.register_cash_movement.created',
      sessionId: 'register:${session.id}',
      entityType: 'register_cash_movement',
      entityId: movement.id,
      attributes: {
        'register_session_id': session.id,
        'session_number': session.sessionNumber,
        'movement_type': movement.movementType.toJson(),
        'reason_present': movement.reason.trim().isNotEmpty,
        'source': 'register_cash_movement_sheet',
      },
      metrics: {'amount': movement.amount},
    );
  }
}
