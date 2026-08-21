part of 'pos_view_model.dart';

/// Local persistence of the in-progress sale sessions (active + parked carts).
///
/// A debounced snapshot is written on every change once a scope (the signed-in
/// user id) is known, and restored on launch so a crash or restart never loses
/// a sale. Discount/preview state is intentionally not persisted — it is
/// recomputed from the server after restore.
extension PosSessionPersistence on PosViewModel {
  static const _snapshotVersion = 1;

  /// How long a pre-checkout snapshot write may take before the sale goes ahead
  /// without it. Local WAL-mode SQLite answers in single-digit milliseconds; a
  /// disk that has stopped answering must not hold up the cashier.
  static const _persistNowDeadline = Duration(seconds: 2);

  /// True once there is at least one non-empty cart worth saving.
  bool get _hasPersistableContent =>
      _saleSessions.any((session) => session.cart.isNotEmpty);

  /// Restores the persisted sessions for [scope] (the user id), replacing the
  /// in-memory state when a non-empty snapshot exists. Safe to call repeatedly;
  /// only re-runs when the scope changes (e.g. a different cashier signs in).
  Future<void> restorePersistedSessions(String scope) async {
    if (_sessionsRestored && _persistScope == scope) {
      return;
    }
    final scopeChanged = _persistScope != null && _persistScope != scope;
    _persistScope = scope;
    _sessionsRestored = true;
    if (scopeChanged) {
      // Different user on this device — never inherit the previous cart.
      _resetSaleSessions();
      _notifyChanged();
    }

    final raw = await _sessionStorage.load(scope);
    if (raw == null || raw.isEmpty) {
      return;
    }
    final restored = _decodeSnapshot(raw);
    if (restored == null || restored.sessions.every((s) => s.cart.isEmpty)) {
      return;
    }

    _saleSessions
      ..clear()
      ..addAll(restored.sessions);
    _nextSaleSessionId = restored.nextSessionId;
    _nextSaleSessionNumber = restored.nextSessionNumber;
    _activeSaleSessionId =
        restored.sessions.any((s) => s.id == restored.activeSessionId)
        ? restored.activeSessionId
        : restored.sessions.first.id;
    _notifyChanged();
    // Discount totals were not persisted — reconcile them with the server.
    unawaited(refreshDiscountPreview());
  }

  void _schedulePersist() {
    final scope = _persistScope;
    if (scope == null) {
      return;
    }
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_flushPersist(scope));
    });
  }

  /// Writes the snapshot now instead of on the 500ms debounce, and reports
  /// whether it landed.
  ///
  /// Called immediately before a checkout POST. The idempotency key minted for
  /// that request has to be on disk *before* the request leaves: mains power in
  /// these shops is not dependable, and a cut in the window between the sale
  /// committing on the backend and the till reading the response otherwise
  /// loses the key — the cart is restored on the next launch (that is the whole
  /// point of this file), the cashier presses checkout again, a fresh key is
  /// minted, and the same sale is billed and stocked twice.
  ///
  /// Best-effort and bounded by design: a storage failure or a stalled write is
  /// reported to the caller, never thrown and never waited on indefinitely. A
  /// till that cannot write its scratch state must still be able to take the
  /// customer's money.
  Future<bool> persistNow() async {
    final scope = _persistScope;
    if (scope == null) {
      return false;
    }
    _persistDebounce?.cancel();
    try {
      await _flushPersist(scope).timeout(_persistNowDeadline);
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _flushPersist(String scope) async {
    if (_hasPersistableContent) {
      await _sessionStorage.save(scope, _serializeSessions());
    } else {
      await _sessionStorage.clear(scope);
    }
  }

  String _serializeSessions() {
    return jsonEncode({
      'version': _snapshotVersion,
      'activeSessionId': _activeSaleSessionId,
      'nextSessionId': _nextSaleSessionId,
      'nextSessionNumber': _nextSaleSessionNumber,
      'sessions': [
        for (final session in _saleSessions)
          {
            'id': session.id,
            'number': session.number,
            'updatedAt': session.updatedAt.toIso8601String(),
            'couponCode': session.couponCode,
            'printInvoiceAfterPayment': session.printInvoiceAfterPayment,
            'shareInvoiceAfterPayment': session.shareInvoiceAfterPayment,
            'customer': session.selectedCustomer?.toJson(),
            'cart': [for (final line in session.cart) line.toJson()],
            // Restored with the cart so a checkout the till never saw the
            // answer to is retried under its original key — see [persistNow].
            'checkoutAttempts': session.checkoutAttemptsToJson(),
          },
      ],
    });
  }

  _PosSessionSnapshot? _decodeSnapshot(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      final map = decoded.cast<String, Object?>();
      final sessionsJson = map['sessions'];
      if (sessionsJson is! List) {
        return null;
      }
      final sessions = <_PosSaleSession>[];
      for (final item in sessionsJson) {
        if (item is! Map) {
          continue;
        }
        final sessionMap = item.cast<String, Object?>();
        final session = _PosSaleSession(
          id: (sessionMap['id'] as num?)?.toInt() ?? 0,
          number: (sessionMap['number'] as num?)?.toInt() ?? 0,
        );
        session.couponCode = sessionMap['couponCode']?.toString() ?? '';
        session.printInvoiceAfterPayment =
            sessionMap['printInvoiceAfterPayment'] == true;
        session.shareInvoiceAfterPayment =
            sessionMap['shareInvoiceAfterPayment'] == true;
        session.restoreCheckoutAttempts(sessionMap['checkoutAttempts']);
        final customerJson = sessionMap['customer'];
        if (customerJson is Map) {
          session.selectedCustomer = Customer.fromJson(
            customerJson.cast<String, Object?>(),
          );
        }
        final cartJson = sessionMap['cart'];
        if (cartJson is List) {
          for (final lineJson in cartJson) {
            if (lineJson is! Map) {
              continue;
            }
            try {
              session.cart.add(
                CartLine.fromJson(lineJson.cast<String, Object?>()),
              );
            } on FormatException {
              // Skip a corrupt line rather than dropping the whole cart.
            }
          }
        }
        sessions.add(session);
      }
      if (sessions.isEmpty) {
        return null;
      }
      int fallbackMaxId = 0;
      int fallbackMaxNumber = 0;
      for (final session in sessions) {
        if (session.id > fallbackMaxId) {
          fallbackMaxId = session.id;
        }
        if (session.number > fallbackMaxNumber) {
          fallbackMaxNumber = session.number;
        }
      }
      return _PosSessionSnapshot(
        sessions: sessions,
        activeSessionId:
            (map['activeSessionId'] as num?)?.toInt() ?? sessions.first.id,
        nextSessionId:
            (map['nextSessionId'] as num?)?.toInt() ?? fallbackMaxId + 1,
        nextSessionNumber:
            (map['nextSessionNumber'] as num?)?.toInt() ??
            fallbackMaxNumber + 1,
      );
    } on FormatException {
      return null;
    }
  }
}

class _PosSessionSnapshot {
  _PosSessionSnapshot({
    required this.sessions,
    required this.activeSessionId,
    required this.nextSessionId,
    required this.nextSessionNumber,
  });

  final List<_PosSaleSession> sessions;
  final int activeSessionId;
  final int nextSessionId;
  final int nextSessionNumber;
}
