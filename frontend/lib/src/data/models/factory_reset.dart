/// What a factory reset would take, counted before anyone is asked to confirm.
///
/// The screen exists to answer one question — *how much of my shop is this?* —
/// and the only honest answer is the shop's own numbers. A dialog that says
/// "all data will be deleted" is a sentence; "1,842 products, 6,301 invoices,
/// 412 customers" is a decision.
class FactoryResetPreview {
  const FactoryResetPreview({
    required this.counts,
    required this.usersRemoved,
    required this.adminUsername,
    required this.shopName,
    this.lastVerifiedBackupAt,
  });

  /// Keyed by the server's summary names (`products`, `orders`, `customers`,
  /// …). Unknown keys are kept rather than dropped: a server that learns to
  /// count something new should not need a client release to say so.
  final Map<String, int> counts;

  /// Accounts that will be deleted — everyone except the administrator.
  final int usersRemoved;

  /// The one account that survives.
  final String adminUsername;

  /// What the owner has to type to confirm. Comes from the server so the two
  /// sides can never disagree about the spelling.
  final String shopName;

  /// When a verified backup was last completed, or null if there has never
  /// been one — which is the loudest thing this screen can say.
  final DateTime? lastVerifiedBackupAt;

  bool get hasVerifiedBackup => lastVerifiedBackupAt != null;

  /// Total rows across the counted headlines. Zero means there is nothing to
  /// lose, and the screen says so rather than staging a scary confirmation.
  int get totalCounted =>
      counts.values.fold(0, (sum, value) => sum + value) + usersRemoved;

  static FactoryResetPreview fromJson(Map<String, Object?> json) {
    final rawCounts = json['counts'];
    final counts = <String, int>{};
    if (rawCounts is Map) {
      for (final entry in rawCounts.entries) {
        final value = entry.value;
        if (value is num) counts[entry.key.toString()] = value.toInt();
      }
    }
    final backupAt = json['last_verified_backup_at'];
    return FactoryResetPreview(
      counts: counts,
      usersRemoved: switch (json['users_removed']) {
        final num value => value.toInt(),
        _ => 0,
      },
      adminUsername: json['admin_username']?.toString() ?? '',
      shopName: json['shop_name']?.toString() ?? '',
      lastVerifiedBackupAt: backupAt is String
          ? DateTime.tryParse(backupAt)?.toLocal()
          : null,
    );
  }
}

/// What a completed reset reports back.
class FactoryResetOutcome {
  const FactoryResetOutcome({required this.counts, required this.usersRemoved});

  final Map<String, int> counts;
  final int usersRemoved;

  static FactoryResetOutcome fromJson(Map<String, Object?> json) {
    final preview = FactoryResetPreview.fromJson(json);
    return FactoryResetOutcome(
      counts: preview.counts,
      usersRemoved: preview.usersRemoved,
    );
  }
}
