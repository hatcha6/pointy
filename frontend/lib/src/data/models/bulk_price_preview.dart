/// What the server says a bulk price spec would do — see
/// `POST bulk-price-changes/preview/` — and the history of applied changes.
library;

double? _decimal(Object? raw) => switch (raw) {
  null => null,
  num value => value.toDouble(),
  String value => double.tryParse(value),
  _ => null,
};

int _int(Object? raw) => switch (raw) {
  int value => value,
  num value => value.toInt(),
  String value => int.tryParse(value) ?? 0,
  _ => 0,
};

enum BulkPriceFlag {
  belowCost('below_cost'),
  raisedToCost('raised_to_cost'),
  noCost('no_cost'),
  zero('zero'),
  bigChange('big_change'),
  foreign('foreign');

  const BulkPriceFlag(this.apiValue);
  final String apiValue;

  bool get isWarning => this != foreign;

  static BulkPriceFlag? fromApi(Object? raw) {
    for (final flag in values) {
      if (flag.apiValue == raw) return flag;
    }
    return null;
  }
}

/// Which slice of the preview the list shows.
enum BulkPricePreviewView {
  changed('changed'),
  increased('increased'),
  decreased('decreased'),
  warnings('warnings'),
  unchanged('unchanged'),
  all('all');

  const BulkPricePreviewView(this.apiValue);
  final String apiValue;
}

class BulkPriceSummary {
  const BulkPriceSummary({
    required this.matched,
    required this.changed,
    required this.unchanged,
    required this.increased,
    required this.decreased,
    required this.productsChanged,
    required this.packsChanged,
    required this.averageChangePercent,
    required this.warnings,
    required this.flagCounts,
    required this.stepCounts,
  });

  factory BulkPriceSummary.fromJson(Map<String, dynamic> json) {
    final flags = <BulkPriceFlag, int>{};
    final rawFlags = json['flags'];
    if (rawFlags is Map) {
      rawFlags.forEach((key, value) {
        final flag = BulkPriceFlag.fromApi(key);
        if (flag != null) flags[flag] = _int(value);
      });
    }
    return BulkPriceSummary(
      matched: _int(json['matched']),
      changed: _int(json['changed']),
      unchanged: _int(json['unchanged']),
      increased: _int(json['increased']),
      decreased: _int(json['decreased']),
      productsChanged: _int(json['products_changed']),
      packsChanged: _int(json['packs_changed']),
      averageChangePercent: _decimal(json['average_change_percent']),
      warnings: _int(json['warnings']),
      flagCounts: flags,
      stepCounts: [
        for (final count in (json['step_counts'] as List?) ?? const [])
          _int(count),
      ],
    );
  }

  final int matched;
  final int changed;
  final int unchanged;
  final int increased;
  final int decreased;
  final int productsChanged;
  final int packsChanged;
  final double? averageChangePercent;
  final int warnings;
  final Map<BulkPriceFlag, int> flagCounts;

  /// How many rows each step (by index) applied to.
  final List<int> stepCounts;

  int countFor(BulkPricePreviewView view) => switch (view) {
    BulkPricePreviewView.changed => changed,
    BulkPricePreviewView.increased => increased,
    BulkPricePreviewView.decreased => decreased,
    BulkPricePreviewView.warnings => warnings,
    BulkPricePreviewView.unchanged => unchanged,
    BulkPricePreviewView.all => matched,
  };
}

class BulkPricePackChange {
  const BulkPricePackChange({
    required this.label,
    required this.oldPrice,
    required this.newPrice,
  });

  final String label;
  final double oldPrice;
  final double newPrice;
}

class BulkPricePreviewRow {
  const BulkPricePreviewRow({
    required this.variantId,
    required this.productId,
    required this.productName,
    required this.variantName,
    required this.sku,
    required this.oldPrice,
    required this.newPrice,
    required this.deltaPercent,
    required this.appliedSteps,
    required this.flags,
    required this.packs,
    this.cost,
    this.oldMarkup,
    this.newMarkup,
  });

  factory BulkPricePreviewRow.fromJson(Map<String, dynamic> json) {
    return BulkPricePreviewRow(
      variantId: _int(json['variant_id']),
      productId: _int(json['product_id']),
      productName: '${json['product_name'] ?? ''}',
      variantName: '${json['variant_name'] ?? ''}',
      sku: '${json['sku'] ?? ''}',
      oldPrice: _decimal(json['old_price']) ?? 0,
      newPrice: _decimal(json['new_price']) ?? 0,
      deltaPercent: _decimal(json['delta_percent']),
      appliedSteps: [
        for (final index in (json['applied_steps'] as List?) ?? const [])
          _int(index),
      ],
      flags: {
        for (final raw in (json['flags'] as List?) ?? const [])
          ?BulkPriceFlag.fromApi(raw),
      },
      packs: [
        for (final pack in (json['packs'] as List?) ?? const [])
          if (pack is Map)
            BulkPricePackChange(
              label: '${pack['label'] ?? ''}',
              oldPrice: _decimal(pack['old_price']) ?? 0,
              newPrice: _decimal(pack['new_price']) ?? 0,
            ),
      ],
      cost: _decimal(json['cost']),
      oldMarkup: _decimal(json['old_markup']),
      newMarkup: _decimal(json['new_markup']),
    );
  }

  final int variantId;
  final int productId;
  final String productName;
  final String variantName;
  final String sku;
  final double oldPrice;
  final double newPrice;
  final double? deltaPercent;
  final List<int> appliedSteps;
  final Set<BulkPriceFlag> flags;
  final List<BulkPricePackChange> packs;

  /// Present only for readers who may see cost.
  final double? cost;
  final double? oldMarkup;
  final double? newMarkup;

  bool get priceChanged => (newPrice - oldPrice).abs() >= 0.0001;
  bool get increased => newPrice > oldPrice + 0.0001;
}

class BulkPricePreview {
  const BulkPricePreview({
    required this.fingerprint,
    required this.summary,
    required this.costVisible,
    required this.view,
    required this.count,
    required this.rows,
  });

  factory BulkPricePreview.fromJson(Map<String, dynamic> json) {
    final view = BulkPricePreviewView.values.firstWhere(
      (candidate) => candidate.apiValue == json['view'],
      orElse: () => BulkPricePreviewView.changed,
    );
    return BulkPricePreview(
      fingerprint: '${json['fingerprint'] ?? ''}',
      summary: BulkPriceSummary.fromJson(
        (json['summary'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      costVisible: json['cost_visible'] == true,
      view: view,
      count: _int(json['count']),
      rows: [
        for (final row in (json['rows'] as List?) ?? const [])
          if (row is Map) BulkPricePreviewRow.fromJson(row.cast()),
      ],
    );
  }

  final String fingerprint;
  final BulkPriceSummary summary;
  final bool costVisible;
  final BulkPricePreviewView view;

  /// Rows in [view] in total; [rows] is one page of them.
  final int count;
  final List<BulkPricePreviewRow> rows;

  BulkPricePreview withMoreRows(BulkPricePreview page) => BulkPricePreview(
    fingerprint: fingerprint,
    summary: summary,
    costVisible: costVisible,
    view: view,
    count: count,
    rows: [...rows, ...page.rows],
  );

  bool get hasMore => rows.length < count;
}

class BulkPriceOptions {
  const BulkPriceOptions({required this.costVisible, required this.maxSteps});

  factory BulkPriceOptions.fromJson(Map<String, dynamic> json) =>
      BulkPriceOptions(
        costVisible: json['cost_visible'] == true,
        maxSteps: _int(json['max_steps']) == 0 ? 20 : _int(json['max_steps']),
      );

  final bool costVisible;
  final int maxSteps;
}

class BulkPriceRevertSummary {
  const BulkPriceRevertSummary({required this.restored, required this.skipped});

  final int restored;
  final int skipped;
}

class BulkPriceChangeRecord {
  const BulkPriceChangeRecord({
    required this.id,
    required this.createdAt,
    required this.createdByName,
    required this.changed,
    required this.increased,
    required this.decreased,
    required this.stepCount,
    this.revertedAt,
    this.revertedByName,
    this.revert,
  });

  factory BulkPriceChangeRecord.fromJson(Map<String, dynamic> json) {
    final summary = (json['summary'] as Map?)?.cast<String, dynamic>() ?? {};
    final spec = (json['spec'] as Map?)?.cast<String, dynamic>() ?? {};
    final revert = (json['revert_summary'] as Map?)?.cast<String, dynamic>();
    final revertedAt = DateTime.tryParse('${json['reverted_at'] ?? ''}');
    return BulkPriceChangeRecord(
      id: _int(json['id']),
      createdAt:
          DateTime.tryParse('${json['created_at'] ?? ''}')?.toLocal() ??
          DateTime.now(),
      createdByName: json['created_by_name'] as String?,
      changed: _int(summary['changed']),
      increased: _int(summary['increased']),
      decreased: _int(summary['decreased']),
      stepCount: ((spec['steps'] as List?) ?? const []).length,
      revertedAt: revertedAt?.toLocal(),
      revertedByName: json['reverted_by_name'] as String?,
      revert: revertedAt == null || revert == null
          ? null
          : BulkPriceRevertSummary(
              restored: _int(revert['restored']),
              skipped: _int(revert['skipped']) + _int(revert['missing']),
            ),
    );
  }

  final int id;
  final DateTime createdAt;
  final String? createdByName;
  final int changed;
  final int increased;
  final int decreased;
  final int stepCount;
  final DateTime? revertedAt;
  final String? revertedByName;
  final BulkPriceRevertSummary? revert;

  bool get isReverted => revertedAt != null;
}

/// Why an apply or undo was refused, in the terms the screen explains.
enum BulkPriceFailure { stale, nothingToApply, alreadyReverted, other }

class BulkPriceException implements Exception {
  const BulkPriceException(this.failure);

  final BulkPriceFailure failure;

  @override
  String toString() => 'BulkPriceException($failure)';
}
