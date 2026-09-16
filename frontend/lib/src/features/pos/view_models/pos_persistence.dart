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

  /// How many times the snapshot read is attempted before the till gives up on
  /// it for this sign-in, and how long it waits between tries.
  ///
  /// A read that fails is not the same as a scope with nothing saved: the
  /// invoices are still on the disk, and the only thing that can destroy them
  /// is this till writing over them. So a failed read leaves persistence shut
  /// off rather than replacing the snapshot with an empty cart.
  static const _loadAttempts = 3;
  static const _loadRetryBackoff = Duration(milliseconds: 100);

  /// Restores the persisted sessions for [scope] (the user id), replacing the
  /// in-memory state when a non-empty snapshot exists. Safe to call repeatedly;
  /// only re-runs when the scope changes (e.g. a different cashier signs in) or
  /// when an earlier attempt could not read the disk.
  Future<void> restorePersistedSessions(String scope) async {
    if (_persistScope == scope && _persistScopeLoaded) {
      return;
    }
    final scopeChanged = _persistScope != null && _persistScope != scope;
    _persistScope = scope;
    // Hold back every write for this scope until its snapshot has been read —
    // including the one the reset below would otherwise schedule, which would
    // clear the incoming cashier's held invoices before anyone had looked at
    // them.
    _persistScopeLoaded = false;
    _persistDebounce?.cancel();
    if (scopeChanged) {
      // Different user on this device — never inherit the previous cart.
      _resetSaleSessions();
      _notifyChanged();
    }

    final String? raw;
    try {
      raw = await _readSnapshot(scope);
    } on Object catch (error) {
      // Leave the snapshot alone and persistence off: it is the only copy of
      // that work, and the next sign-in gets another go at reading it.
      debugPrint('POS snapshot unreadable for scope $scope: $error');
      return;
    }
    if (_persistScope != scope) {
      // Someone else signed in while the disk was answering. That restore owns
      // the state now; this one must not write anything into it.
      return;
    }

    final restored = (raw == null || raw.isEmpty) ? null : _decodeSnapshot(raw);
    final hasSaleToRestore =
        restored != null && restored.sessions.any((s) => s.cart.isNotEmpty);
    if (hasSaleToRestore) {
      _adoptSnapshot(restored);
    }
    // The disk has answered, so what is in memory is now the whole truth for
    // this cashier and is safe to write back.
    _persistScopeLoaded = true;
    _notifyChanged();
    if (hasSaleToRestore) {
      // Discount totals were not persisted — reconcile them with the server.
      unawaited(refreshDiscountPreview());
    }
  }

  Future<String?> _readSnapshot(String scope) async {
    Object lastError = StateError('no read attempted');
    for (var attempt = 0; attempt < _loadAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_loadRetryBackoff * attempt);
        if (_persistScope != scope) {
          return null;
        }
      }
      try {
        return await _sessionStorage.load(scope);
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw lastError;
  }

  /// Installs [restored] as the open invoices, carrying over anything the
  /// cashier rang up while the disk was still answering.
  ///
  /// The till is usable the moment it draws, which on a contended disk is well
  /// before the snapshot comes back — long enough to scan a few items into.
  /// Those items are the newest thing in the shop and memory holds the only
  /// copy, so they become their own invoice instead of being dropped.
  void _adoptSnapshot(_PosSessionSnapshot restored) {
    final rungUpMeanwhile = [
      for (final session in _saleSessions)
        if (session.cart.isNotEmpty) session,
    ];

    _saleSessions
      ..clear()
      ..addAll(restored.sessions);
    _nextSaleSessionId = restored.nextSessionId;
    _nextSaleSessionNumber = restored.nextSessionNumber;
    _activeSaleSessionId =
        restored.sessions.any((s) => s.id == restored.activeSessionId)
        ? restored.activeSessionId
        : restored.sessions.first.id;

    for (final session in rungUpMeanwhile) {
      // Renumbered onto the restored series so no two open invoices can end up
      // sharing an id. Checkout attempts are deliberately not carried: a cart
      // built in this window has no committed sale to replay against.
      final adopted = _createSaleSession()
        ..selectedCustomer = session.selectedCustomer
        ..couponCode = session.couponCode
        ..printInvoiceAfterPayment = session.printInvoiceAfterPayment
        ..shareInvoiceAfterPayment = session.shareInvoiceAfterPayment;
      adopted.cart.addAll(session.cart);
      _saleSessions.add(adopted);
      // Whatever the cashier has in their hands right now is what they are
      // working on — not the invoice the disk just handed back.
      _activeSaleSessionId = adopted.id;
    }
  }

  void _schedulePersist() {
    final scope = _persistScope;
    if (scope == null || !_persistScopeLoaded) {
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
  ///
  /// [overwriteUnread] lets the caller write even when this scope's snapshot
  /// has not been read back yet, which everywhere else means "leave the disk
  /// alone, that file is the only copy of the cashier's work". Only checkout
  /// asks for it: billing a customer twice is worse than losing held invoices
  /// the cashier can already see are missing, so the idempotency key wins that
  /// tie. Nothing else should.
  Future<bool> persistNow({bool overwriteUnread = false}) async {
    final scope = _persistScope;
    if (scope == null) {
      return false;
    }
    if (!_persistScopeLoaded && !overwriteUnread) {
      return false;
    }
    _persistDebounce?.cancel();
    // Whatever was on the disk has just been superseded; stop holding back the
    // debounced writes that follow this sale.
    _persistScopeLoaded = true;
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
        final updatedAt = DateTime.tryParse(
          sessionMap['updatedAt']?.toString() ?? '',
        );
        if (updatedAt != null) {
          // Kept so the invoice the cashier was last on is still the one the
          // till returns to after the next checkout.
          session.updatedAt = updatedAt;
        }
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
