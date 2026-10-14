/// The shop's Moamalat merchant link: live card verification
/// (`apps.payments.moamalat`, `TOKEN_CUSTODY_DESIGN.md`).
library;

enum MoamalatLinkState {
  unlinked,
  alive,
  needsReauth;

  static MoamalatLinkState fromJson(Object? value) => switch (value) {
    'alive' => MoamalatLinkState.alive,
    'needs_reauth' => MoamalatLinkState.needsReauth,
    _ => MoamalatLinkState.unlinked,
  };
}

DateTime? _time(Object? value) =>
    value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;

String _text(Object? value) => value is String ? value : '';

int _int(Object? value) => value is num ? value.toInt() : 0;

/// The relay's copy of the token — the second keepalive.
class MoamalatRelayCopy {
  const MoamalatRelayCopy({
    this.holdsCopy = false,
    this.inStep = false,
    this.state = '',
    this.lastOkAt,
    this.checkedAt,
    this.error = '',
  });

  factory MoamalatRelayCopy.fromJson(Map<String, Object?> json) =>
      MoamalatRelayCopy(
        holdsCopy: json['holds_copy'] == true,
        inStep: json['in_step'] == true,
        state: _text(json['state']),
        lastOkAt: _time(json['last_ok_at']),
        checkedAt: _time(json['checked_at']),
        error: _text(json['error']),
      );

  final bool holdsCopy;

  /// The relay holds this very token (not an older one).
  final bool inStep;
  final String state;
  final DateTime? lastOkAt;
  final DateTime? checkedAt;
  final String error;
}

/// `GET /moamalat/status/`. A cashier gets the first five fields only.
class MoamalatStatus {
  const MoamalatStatus({
    this.state = MoamalatLinkState.unlinked,
    this.atRisk = false,
    this.switchedOff = false,
    this.canManage = false,
    this.username = '',
    this.mid = '',
    this.merchantName = '',
    this.linkedAt,
    this.linkedBy = '',
    this.lastOkAt,
    this.lastError = '',
    this.diedAt,
    this.deathSource = '',
    this.lastFetchAt,
    this.pendingCount = 0,
    this.pendingOverdueCount = 0,
    this.relay = const MoamalatRelayCopy(),
  });

  factory MoamalatStatus.fromJson(Map<String, Object?> json) {
    final relay = json['relay'];
    return MoamalatStatus(
      state: MoamalatLinkState.fromJson(json['state']),
      atRisk: json['at_risk'] == true,
      switchedOff: json['switched_off'] == true,
      canManage: json['can_manage'] == true,
      username: _text(json['username']),
      mid: _text(json['mid']),
      merchantName: _text(json['merchant_name']),
      linkedAt: _time(json['linked_at']),
      linkedBy: _text(json['linked_by']),
      lastOkAt: _time(json['last_ok_at']),
      lastError: _text(json['last_error']),
      diedAt: _time(json['died_at']),
      deathSource: _text(json['death_source']),
      lastFetchAt: _time(json['last_fetch_at']),
      pendingCount: _int(json['pending_count']),
      pendingOverdueCount: _int(json['pending_overdue_count']),
      relay: relay is Map
          ? MoamalatRelayCopy.fromJson(relay.cast<String, Object?>())
          : const MoamalatRelayCopy(),
    );
  }

  final MoamalatLinkState state;
  final bool atRisk;
  final bool switchedOff;
  final bool canManage;
  final String username;
  final String mid;
  final String merchantName;
  final DateTime? linkedAt;
  final String linkedBy;
  final DateTime? lastOkAt;
  final String lastError;
  final DateTime? diedAt;

  /// `backend` or `relay`: who saw the token die.
  final String deathSource;
  final DateTime? lastFetchAt;
  final int pendingCount;
  final int pendingOverdueCount;
  final MoamalatRelayCopy relay;

  bool get isLinked => state != MoamalatLinkState.unlinked;
}

class MoamalatMerchant {
  const MoamalatMerchant({
    required this.mid,
    required this.name,
    this.owner = false,
  });

  factory MoamalatMerchant.fromJson(Map<String, Object?> json) =>
      MoamalatMerchant(
        mid: _text(json['mid']),
        name: _text(json['name']),
        owner: json['owner'] == true,
      );

  final String mid;
  final String name;
  final bool owner;
}

/// The answer to the OTP: linked, and the merchants this account may use.
class MoamalatLinked {
  const MoamalatLinked({required this.status, required this.merchants});

  factory MoamalatLinked.fromJson(Map<String, Object?> json) {
    final merchants = json['merchants'];
    final status = json['status'];
    return MoamalatLinked(
      status: status is Map
          ? MoamalatStatus.fromJson(status.cast<String, Object?>())
          : const MoamalatStatus(),
      merchants: merchants is List
          ? merchants
                .whereType<Map>()
                .map(
                  (m) => MoamalatMerchant.fromJson(m.cast<String, Object?>()),
                )
                .toList()
          : const [],
    );
  }

  final MoamalatStatus status;
  final List<MoamalatMerchant> merchants;
}

/// A swipe the terminal took that no payment has claimed yet.
class MoamalatSwipe {
  const MoamalatSwipe({
    required this.rrn,
    required this.terminalId,
    required this.amount,
    required this.at,
    this.cardMask = '',
  });

  factory MoamalatSwipe.fromJson(Map<String, Object?> json) => MoamalatSwipe(
    rrn: _text(json['rrn']),
    terminalId: _text(json['terminal_id']),
    amount: double.tryParse(_text(json['amount'])) ?? 0,
    at: _time(json['transaction_at']) ?? DateTime.now(),
    cardMask: _text(json['card_mask']),
  );

  final String rrn;
  final String terminalId;
  final double amount;
  final DateTime at;
  final String cardMask;
}

/// `POST /moamalat/watch/`: is the fast loop on, and what has the terminal
/// taken for this amount lately.
class MoamalatWatch {
  const MoamalatWatch({
    this.state = MoamalatLinkState.unlinked,
    this.watching = false,
    this.atRisk = false,
    this.swipes = const [],
  });

  factory MoamalatWatch.fromJson(Map<String, Object?> json) {
    final rows = json['transactions'];
    return MoamalatWatch(
      state: MoamalatLinkState.fromJson(json['state']),
      watching: json['watching'] == true,
      atRisk: json['at_risk'] == true,
      swipes: rows is List
          ? rows
                .whereType<Map>()
                .map((r) => MoamalatSwipe.fromJson(r.cast<String, Object?>()))
                .toList()
          : const [],
    );
  }

  final MoamalatLinkState state;
  final bool watching;
  final bool atRisk;
  final List<MoamalatSwipe> swipes;
}

/// A link step Moamalat or the backend refused: a stable [code] and, when
/// Moamalat said something, its own (Arabic) words in [detail].
class MoamalatLinkFailure implements Exception {
  const MoamalatLinkFailure(this.code, [this.detail = '']);

  final String code;
  final String detail;

  @override
  String toString() => 'MoamalatLinkFailure($code)';
}
