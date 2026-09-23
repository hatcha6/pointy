/// What the server will let this user run, and the vocabulary for asking.
///
/// The client used to keep its own list of report tiles and its own list of
/// periods, both hard-coded, and both able to drift from what the backend could
/// actually resolve — which is how a "Detailed" control shipped that the server
/// had never read. The catalogue is now fetched: the server names the reports,
/// the presets, the granularities and the comparison windows, and the screen
/// renders exactly those.
library;

import 'report_run.dart';

class ReportPeriodPresetOption {
  const ReportPeriodPresetOption(this.key);

  final String key;

  static const today = 'today';
  static const yesterday = 'yesterday';
  static const week = 'week';
  static const month = 'month';
  static const lastMonth = 'last_month';
  static const quarter = 'quarter';
  static const lastQuarter = 'last_quarter';
  static const year = 'year';
  static const lastYear = 'last_year';
  static const custom = 'custom';
}

class ReportGranularityOption {
  static const summary = 'summary';
  static const daily = 'daily';
  static const detailed = 'detailed';
}

class ReportComparisonOption {
  static const none = 'none';
  static const previousPeriod = 'previous_period';
  static const previousYear = 'previous_year';
}

class ReportCatalogEntry {
  const ReportCatalogEntry({
    required this.key,
    required this.type,
    required this.category,
    this.headline = const [],
    this.requiredParams = const [],
    this.pointInTime = false,
  });

  final String key;
  final ReportRunType type;
  final String category;

  /// Figures the report leads with, in the order it wants them read.
  final List<String> headline;

  /// Parameters the report cannot be built without — a statement needs a party.
  final List<String> requiredParams;

  /// True when the report states a position at a moment rather than activity
  /// over a window, so the period picker means "as at" rather than "between".
  final bool pointInTime;

  bool get needsCustomer => requiredParams.contains('customer_id');
  bool get needsSupplier => requiredParams.contains('supplier_id');

  /// One article's identifier — the serial or IMEI a unit ledger is about.
  bool get needsUnitCode => requiredParams.contains('code');

  factory ReportCatalogEntry.fromJson(Map<String, Object?> json) {
    return ReportCatalogEntry(
      key: json['key'] as String? ?? '',
      type: reportRunTypeFromJson(json['key'] as String?),
      category: json['category'] as String? ?? '',
      headline: _stringList(json['headline']),
      requiredParams: _stringList(json['required_params']),
      pointInTime: json['point_in_time'] as bool? ?? false,
    );
  }
}

class ReportCatalog {
  const ReportCatalog({
    required this.reports,
    required this.presets,
    required this.granularities,
    required this.comparisons,
    required this.fiscalYearStartMonth,
    required this.canManagePeriodLock,
    this.monthEndSnapshotDay = 1,
    this.booksLockedThrough,
  });

  final List<ReportCatalogEntry> reports;
  final List<String> presets;
  final List<String> granularities;
  final List<String> comparisons;
  final int fiscalYearStartMonth;
  final bool canManagePeriodLock;
  final int monthEndSnapshotDay;
  final DateTime? booksLockedThrough;

  static const empty = ReportCatalog(
    reports: [],
    presets: [],
    granularities: [],
    comparisons: [],
    fiscalYearStartMonth: 1,
    canManagePeriodLock: false,
  );

  ReportCatalogEntry? entryFor(ReportRunType type) {
    for (final entry in reports) {
      if (entry.type == type) {
        return entry;
      }
    }
    return null;
  }

  factory ReportCatalog.fromJson(Map<String, Object?> json) {
    return ReportCatalog(
      reports: [
        for (final item in (json['reports'] as List? ?? const []))
          // A report the server offers and this build cannot name is left out,
          // never shown as another report. The fallback to the sales summary
          // turned every newer server report into a second "sales summary"
          // tile — and, the sales summary being the default selection, a tile
          // that always looked selected.
          if (item is Map &&
              reportRunTypeFromKey(item['key'] as String?) != null)
            ReportCatalogEntry.fromJson(item.cast<String, Object?>()),
      ],
      presets: _stringList(json['presets']),
      granularities: _stringList(json['granularities']),
      comparisons: _stringList(json['comparisons']),
      fiscalYearStartMonth: json['fiscal_year_start_month'] as int? ?? 1,
      monthEndSnapshotDay: json['month_end_snapshot_day'] as int? ?? 1,
      canManagePeriodLock: json['can_manage_period_lock'] as bool? ?? false,
      booksLockedThrough: _dateOrNull(json['books_locked_through']),
    );
  }
}

/// The accounting calendar: the month the financial year opens on, how far the
/// books are closed, and who may move either.
class PeriodLockState {
  const PeriodLockState({
    this.lockedThrough,
    this.fiscalYearStartMonth = 1,
    this.monthEndSnapshotDay = 1,
    this.canManage = false,
    this.canOverride = false,
  });

  final DateTime? lockedThrough;
  final int fiscalYearStartMonth;

  /// The day the closed month is snapshotted on; 0 means the shop takes no
  /// automatic snapshot.
  final int monthEndSnapshotDay;
  final bool canManage;
  final bool canOverride;

  factory PeriodLockState.fromJson(Map<String, Object?> json) {
    return PeriodLockState(
      lockedThrough: _dateOrNull(json['locked_through']),
      fiscalYearStartMonth: json['fiscal_year_start_month'] as int? ?? 1,
      monthEndSnapshotDay: json['month_end_snapshot_day'] as int? ?? 1,
      canManage: json['can_manage'] as bool? ?? false,
      canOverride: json['can_override'] as bool? ?? false,
    );
  }
}

/// The answer to "are September's numbers still what I reported?".
class ReportVerification {
  const ReportVerification({
    required this.runId,
    required this.matches,
    required this.changedFigures,
    required this.storedSummary,
    required this.currentSummary,
  });

  final int runId;
  final bool matches;
  final List<String> changedFigures;
  final Map<String, Object?> storedSummary;
  final Map<String, Object?> currentSummary;

  factory ReportVerification.fromJson(Map<String, Object?> json) {
    return ReportVerification(
      runId: json['run_id'] as int? ?? 0,
      matches: json['matches'] as bool? ?? false,
      changedFigures: _stringList(json['changed_figures']),
      storedSummary: _map(json['stored_summary']),
      currentSummary: _map(json['current_summary']),
    );
  }
}

/// A row in the run history — deliberately without the payload.
class ReportRunSummary {
  const ReportRunSummary({
    required this.id,
    required this.type,
    required this.status,
    required this.createdAt,
    this.periodStart = '',
    this.periodEnd = '',
    this.figuresChecksum = '',
    this.requestedByUsername,
    this.rowCount = 0,
    this.truncated = false,
    this.params = const {},
  });

  final int id;
  final ReportRunType type;
  final ReportRunStatus status;
  final DateTime createdAt;
  final String periodStart;
  final String periodEnd;
  final String figuresChecksum;
  final String? requestedByUsername;
  final int rowCount;
  final bool truncated;
  final Map<String, Object?> params;

  factory ReportRunSummary.fromJson(Map<String, Object?> json) {
    return ReportRunSummary(
      id: json['id'] as int? ?? 0,
      type: reportRunTypeFromJson(json['report_type'] as String?),
      status: reportRunStatusFromJson(json['status'] as String?),
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      periodStart: json['period_start'] as String? ?? '',
      periodEnd: json['period_end'] as String? ?? '',
      figuresChecksum: json['figures_checksum'] as String? ?? '',
      requestedByUsername: json['requested_by_username'] as String?,
      rowCount: json['row_count'] as int? ?? 0,
      truncated: json['truncated'] as bool? ?? false,
      params: _map(json['params']),
    );
  }
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return [
    for (final item in value)
      if (item != null) item.toString(),
  ];
}

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, Object?>();
  }
  return const {};
}

DateTime? _dateOrNull(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
}
