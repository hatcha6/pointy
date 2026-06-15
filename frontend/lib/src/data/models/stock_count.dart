import 'stock_count_line.dart';

enum StockCountStatus { inProgress, applied, cancelled, unknown }

enum StockCountScope { full, category }

StockCountStatus stockCountStatusFromJson(Object? value) {
  switch (value?.toString()) {
    case 'in_progress':
      return StockCountStatus.inProgress;
    case 'applied':
      return StockCountStatus.applied;
    case 'cancelled':
      return StockCountStatus.cancelled;
    default:
      return StockCountStatus.unknown;
  }
}

StockCountScope stockCountScopeFromJson(Object? value) {
  return value?.toString() == 'category'
      ? StockCountScope.category
      : StockCountScope.full;
}

class StockCount {
  const StockCount({
    required this.id,
    required this.countNumber,
    required this.status,
    required this.scope,
    required this.expectedLineCount,
    required this.countedLineCount,
    required this.varianceLineCount,
    this.categoryId,
    this.categoryName = '',
    this.note = '',
    this.ownerName = '',
    this.appliedByName = '',
    this.appliedAt,
    this.cancelledAt,
    this.createdAt,
    this.lines = const [],
  });

  final int id;
  final String countNumber;
  final StockCountStatus status;
  final StockCountScope scope;
  final int expectedLineCount;
  final int countedLineCount;
  final int varianceLineCount;
  final int? categoryId;
  final String categoryName;
  final String note;
  final String ownerName;
  final String appliedByName;
  final DateTime? appliedAt;
  final DateTime? cancelledAt;
  final DateTime? createdAt;
  final List<StockCountLine> lines;

  bool get isInProgress => status == StockCountStatus.inProgress;

  double get progress {
    if (expectedLineCount <= 0) {
      return countedLineCount > 0 ? 1 : 0;
    }
    final ratio = countedLineCount / expectedLineCount;
    return ratio.clamp(0, 1).toDouble();
  }

  factory StockCount.fromJson(Map<String, Object?> json) {
    final rawLines = json['lines'];
    return StockCount(
      id: _intFromJson(json['id']),
      countNumber: json['count_number']?.toString() ?? '',
      status: stockCountStatusFromJson(json['status']),
      scope: stockCountScopeFromJson(json['scope']),
      expectedLineCount: _intFromJson(json['expected_line_count']),
      countedLineCount: _intFromJson(json['counted_line_count']),
      varianceLineCount: _intFromJson(json['variance_line_count']),
      categoryId: json['category'] == null
          ? null
          : _intFromJson(json['category']),
      categoryName: json['category_name']?.toString() ?? '',
      note: json['note']?.toString() ?? '',
      ownerName: json['owner_name']?.toString() ?? '',
      appliedByName: json['applied_by_name']?.toString() ?? '',
      appliedAt: _dateTimeFromJson(json['applied_at']),
      cancelledAt: _dateTimeFromJson(json['cancelled_at']),
      createdAt: _dateTimeFromJson(json['created_at']),
      lines: rawLines is List<Object?>
          ? rawLines
                .whereType<Map<String, Object?>>()
                .map(StockCountLine.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

class StockCountPage {
  const StockCountPage({required this.counts, required this.hasMore});

  final List<StockCount> counts;
  final bool hasMore;

  factory StockCountPage.fromJson(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final results = decoded['results'];
      final counts = results is List<Object?>
          ? results
                .whereType<Map<String, Object?>>()
                .map(StockCount.fromJson)
                .toList(growable: false)
          : const <StockCount>[];
      return StockCountPage(counts: counts, hasMore: decoded['next'] != null);
    }
    if (decoded is List<Object?>) {
      return StockCountPage(
        counts: decoded
            .whereType<Map<String, Object?>>()
            .map(StockCount.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    return const StockCountPage(counts: [], hasMore: false);
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
