enum FraudFindingStatus {
  active,
  resolved,
  reviewed,
  dismissed;

  static FraudFindingStatus fromJson(Object? value) {
    return switch (value?.toString()) {
      'resolved' => FraudFindingStatus.resolved,
      'reviewed' => FraudFindingStatus.reviewed,
      'dismissed' => FraudFindingStatus.dismissed,
      _ => FraudFindingStatus.active,
    };
  }
}

enum FraudFindingSeverity {
  info,
  warning,
  critical;

  static FraudFindingSeverity fromJson(Object? value) {
    return switch (value?.toString()) {
      'critical' => FraudFindingSeverity.critical,
      'info' => FraudFindingSeverity.info,
      _ => FraudFindingSeverity.warning,
    };
  }
}

class FraudFinding {
  const FraudFinding({
    required this.id,
    required this.ruleCode,
    required this.status,
    required this.severity,
    required this.riskScore,
    this.targetUserLabel = '',
    this.targetUsername = '',
    this.headline = '',
    this.ruleTitle = '',
    this.amount = '',
    this.evidence = const {},
    this.metrics = const {},
    this.peerMetrics = const {},
    this.patternCount = 1,
    this.occurrenceCount = 1,
    this.windowStart,
    this.windowEnd,
    this.firstDetectedAt,
    this.lastDetectedAt,
    this.reviewedByUsername = '',
    this.reviewedAt,
    this.resolutionNote = '',
  });

  final int id;
  final String ruleCode;
  final FraudFindingStatus status;
  final FraudFindingSeverity severity;
  final int riskScore;
  final String targetUserLabel;
  final String targetUsername;
  final String headline;
  final String ruleTitle;
  final String amount;
  final Map<String, Object?> evidence;
  final Map<String, Object?> metrics;
  final Map<String, Object?> peerMetrics;
  final int patternCount;
  final int occurrenceCount;
  final DateTime? windowStart;
  final DateTime? windowEnd;
  final DateTime? firstDetectedAt;
  final DateTime? lastDetectedAt;
  final String reviewedByUsername;
  final DateTime? reviewedAt;
  final String resolutionNote;

  String get displayLabel => targetUserLabel.trim().isNotEmpty
      ? targetUserLabel.trim()
      : targetUsername;

  factory FraudFinding.fromJson(Map<String, Object?> json) {
    final summary = _mapFromJson(json['summary']);
    return FraudFinding(
      id: _intFromJson(json['id']),
      ruleCode: json['rule_code']?.toString() ?? '',
      status: FraudFindingStatus.fromJson(json['status']),
      severity: FraudFindingSeverity.fromJson(json['severity']),
      riskScore: _intFromJson(json['risk_score']),
      targetUserLabel: json['target_user_label']?.toString() ?? '',
      targetUsername: json['target_username']?.toString() ?? '',
      headline: summary['headline']?.toString() ?? '',
      ruleTitle: summary['rule_title']?.toString() ?? '',
      amount: summary['amount']?.toString() ?? '',
      evidence: _mapFromJson(json['evidence']),
      metrics: _mapFromJson(json['metrics']),
      peerMetrics: _mapFromJson(json['peer_metrics']),
      patternCount: _intFromJson(json['pattern_count'], fallback: 1),
      occurrenceCount: _intFromJson(json['occurrence_count'], fallback: 1),
      windowStart: _dateFromJson(json['window_start']),
      windowEnd: _dateFromJson(json['window_end']),
      firstDetectedAt: _dateFromJson(json['first_detected_at']),
      lastDetectedAt: _dateFromJson(json['last_detected_at']),
      reviewedByUsername: json['reviewed_by_username']?.toString() ?? '',
      reviewedAt: _dateFromJson(json['reviewed_at']),
      resolutionNote: json['resolution_note']?.toString() ?? '',
    );
  }
}

class FraudFindingPage {
  const FraudFindingPage({required this.findings, required this.hasMore});

  final List<FraudFinding> findings;
  final bool hasMore;

  factory FraudFindingPage.fromAny(Object? decoded) {
    if (decoded is Map) {
      final map = decoded.map((key, value) => MapEntry(key.toString(), value));
      final results = map['results'];
      return FraudFindingPage(
        findings: results is List
            ? results
                  .whereType<Map>()
                  .map(
                    (row) => FraudFinding.fromJson(
                      row.map((key, value) => MapEntry(key.toString(), value)),
                    ),
                  )
                  .toList(growable: false)
            : const [],
        hasMore: map['next'] != null,
      );
    }
    return const FraudFindingPage(findings: [], hasMore: false);
  }
}

Map<String, Object?> _mapFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}

int _intFromJson(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _dateFromJson(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
}
