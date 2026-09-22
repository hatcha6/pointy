import 'stock_count.dart';

class StockCountStartDraft {
  const StockCountStartDraft({
    required this.scope,
    this.categoryId,
    this.note = '',
  });

  final StockCountScope scope;
  final int? categoryId;
  final String note;

  Map<String, Object?> toJson() {
    return {
      'scope': scope == StockCountScope.category ? 'category' : 'full',
      if (scope == StockCountScope.category && categoryId != null)
        'category': categoryId,
      if (note.trim().isNotEmpty) 'note': note.trim(),
    };
  }
}

enum StockCountEntryMode { add, replace }

class StockCountLineDraft {
  const StockCountLineDraft({
    required this.variantId,
    required this.countedQuantity,
    this.mode = StockCountEntryMode.replace,
    this.batchId,
    this.unitCode = '',
  });

  final int variantId;
  final double countedQuantity;
  final StockCountEntryMode mode;

  /// The unit the counter counted **in** — a carton, a box — or blank for the
  /// product's base unit. The server converts once, at the edge, and stores
  /// base units like every other quantity in the app.
  final String unitCode;

  /// Which lot was counted. A batch-tracked variant is counted one lot at a
  /// time — the counter is standing in one room counting the packs of one lot
  /// on one shelf — and the backend refuses a line that does not say which.
  final int? batchId;

  Map<String, Object?> toJson() {
    return {
      'variant': variantId,
      // Sent as a string so the backend Decimal field never sees float noise.
      'counted_quantity': countedQuantity.toStringAsFixed(3),
      'mode': mode == StockCountEntryMode.add ? 'add' : 'replace',
      if (batchId != null) 'batch': batchId,
      if (unitCode.isNotEmpty) 'unit': unitCode,
    };
  }
}

/// One identifier read off a shelf during a count.
///
/// For a serialized variant the count *is* this loop: nobody types a number,
/// because "4" is not an answer to which four.
class StockCountScanResult {
  const StockCountScanResult({
    required this.id,
    required this.code,
    required this.created,
    required this.known,
    this.unitId,
    this.variantId,
    this.variantName = '',
  });

  final int id;
  final String code;

  /// False when this identifier had already been scanned in this count.
  /// Scanning the same handset twice is one handset.
  final bool created;

  /// Whether the shop has ever held an article with this identifier.
  final bool known;
  final int? unitId;
  final int? variantId;
  final String variantName;

  factory StockCountScanResult.fromJson(Map<String, Object?> json) {
    return StockCountScanResult(
      id: (json['id'] as num?)?.toInt() ?? 0,
      code: json['code'] as String? ?? '',
      created: json['created'] == true,
      known: json['known'] == true,
      unitId: (json['unit'] as num?)?.toInt(),
      variantId: (json['variant'] as num?)?.toInt(),
      variantName: json['variant_name'] as String? ?? '',
    );
  }
}

/// What a scanned count found, once the counter has stopped scanning.
class StockCountScanReconciliation {
  const StockCountScanReconciliation({
    required this.expected,
    required this.scanned,
    required this.missing,
    required this.unknown,
    required this.relocated,
    required this.resurrected,
    required this.lots,
  });

  final int expected;
  final int scanned;

  /// Expected but not scanned — lost or stolen, and a write-off proposal.
  final List<StockCountFinding> missing;

  /// Scanned but unrecognised — never received, or returned and never
  /// restocked. An opening-identification proposal.
  final List<StockCountFinding> unknown;

  /// Standing in this room, recorded in another branch: a transfer nobody
  /// wrote down.
  final List<StockCountFinding> relocated;

  /// Written off, and here it is.
  final List<StockCountFinding> resurrected;

  /// Per-lot variance for the batch lines of this count.
  final List<StockCountLotFinding> lots;

  bool get isClean =>
      missing.isEmpty &&
      unknown.isEmpty &&
      relocated.isEmpty &&
      resurrected.isEmpty &&
      lots.every((row) => row.variance == 0);

  factory StockCountScanReconciliation.fromJson(Map<String, Object?> json) {
    List<StockCountFinding> rows(String key) {
      final raw = json[key];
      if (raw is! List) {
        return const [];
      }
      return raw
          .whereType<Map<String, Object?>>()
          .map(StockCountFinding.fromJson)
          .toList(growable: false);
    }

    final rawLots = json['lots'];
    return StockCountScanReconciliation(
      expected: (json['expected'] as num?)?.toInt() ?? 0,
      scanned: (json['scanned'] as num?)?.toInt() ?? 0,
      missing: rows('missing'),
      unknown: rows('unknown'),
      relocated: rows('relocated'),
      resurrected: rows('resurrected'),
      lots: rawLots is List
          ? rawLots
                .whereType<Map<String, Object?>>()
                .map(StockCountLotFinding.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

class StockCountFinding {
  const StockCountFinding({
    required this.code,
    this.id,
    this.unitId,
    this.variantName = '',
    this.detail = '',
  });

  final String code;
  final int? id;
  final int? unitId;
  final String variantName;

  /// Whatever distinguishes this row: the branch it was recorded in, the
  /// status it was in, or the value it carried.
  final String detail;

  factory StockCountFinding.fromJson(Map<String, Object?> json) {
    return StockCountFinding(
      code: json['code'] as String? ?? '',
      id: (json['id'] as num?)?.toInt(),
      unitId: (json['unit'] as num?)?.toInt(),
      variantName: json['variant_name'] as String? ?? '',
      detail:
          (json['warehouse_name'] as String?) ??
          (json['status'] as String?) ??
          (json['value'] as String?) ??
          '',
    );
  }
}

class StockCountLotFinding {
  const StockCountLotFinding({
    required this.lineId,
    required this.batchId,
    required this.batchCode,
    required this.variantName,
    required this.remaining,
    required this.counted,
    required this.variance,
    required this.newHere,
  });

  final int lineId;
  final int batchId;
  final String batchCode;
  final String variantName;
  final double remaining;
  final double counted;
  final double variance;

  /// A lot found in a warehouse that has no balance for it: stock that walked
  /// between branches without paperwork, and worth surfacing by name.
  final bool newHere;

  factory StockCountLotFinding.fromJson(Map<String, Object?> json) {
    double number(Object? value) =>
        value == null ? 0 : double.tryParse('$value') ?? 0;
    return StockCountLotFinding(
      lineId: (json['line'] as num?)?.toInt() ?? 0,
      batchId: (json['batch'] as num?)?.toInt() ?? 0,
      batchCode: json['batch_code'] as String? ?? '',
      variantName: json['variant_name'] as String? ?? '',
      remaining: number(json['remaining']),
      counted: number(json['counted']),
      variance: number(json['variance']),
      newHere: json['new_here'] == true,
    );
  }
}
