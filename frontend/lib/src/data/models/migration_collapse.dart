/// The "collapse serialized products" proposal, as the review screen reads it.
///
/// A shop whose old POS had no way to track a handset worked around it by
/// creating one product per phone. This is what the server proposes to make of
/// that: a dozen products, a few dozen variants, and one identified article per
/// row — shown, argued with, and only then agreed to.
library;

import 'migration.dart' show MigrationStage;

/// Headline counts. The sentence the whole screen exists to say:
/// «340 صنفًا ← 12 منتجًا · 31 خيارًا · 340 وحدة».
class CollapseStats {
  const CollapseStats({
    required this.sourceProducts,
    required this.products,
    required this.variants,
    required this.units,
    required this.unitsInStock,
    required this.unitsSold,
    required this.kept,
    required this.needsReview,
    required this.edited,
  });

  final int sourceProducts;
  final int products;
  final int variants;
  final int units;
  final int unitsInStock;
  final int unitsSold;

  /// Rows that stay ordinary products — anything the parser could not read, and
  /// anything the shop's own invoices say is not one product per article.
  final int kept;
  final int needsReview;
  final int edited;

  static const empty = CollapseStats(
    sourceProducts: 0,
    products: 0,
    variants: 0,
    units: 0,
    unitsInStock: 0,
    unitsSold: 0,
    kept: 0,
    needsReview: 0,
    edited: 0,
  );

  bool get isEmpty => units == 0;

  factory CollapseStats.fromJson(Map<String, Object?> json) {
    if (json.isEmpty) return empty;
    return CollapseStats(
      sourceProducts: _int(json['source_products']),
      products: _int(json['products']),
      variants: _int(json['variants']),
      units: _int(json['units']),
      unitsInStock: _int(json['units_in_stock']),
      unitsSold: _int(json['units_sold']),
      kept: _int(json['kept']),
      needsReview: _int(json['needs_review']),
      edited: _int(json['edited']),
    );
  }
}

/// One proposed product: what it will be called and what it would hold.
class CollapseCluster {
  const CollapseCluster({
    required this.stemKey,
    required this.stem,
    required this.variants,
    required this.units,
    required this.unitsInStock,
    required this.unitsSold,
    required this.needsReview,
    required this.optionValues,
    required this.optionLabels,
  });

  final String stemKey;
  final String stem;
  final int variants;
  final int units;
  final int unitsInStock;
  final int unitsSold;
  final int needsReview;

  /// `{"storage": ["128GB", "256GB"], "colour": ["black", "blue"]}`
  final Map<String, List<String>> optionValues;

  /// The same values as a shop reads them — «أزرق», not «blue».
  final Map<String, List<String>> optionLabels;

  /// What to show: the labels when the server sent them, the keys otherwise.
  List<String> get displayOptions => [
    for (final axis
        in (optionLabels.isEmpty ? optionValues : optionLabels).entries)
      ...axis.value,
  ];

  factory CollapseCluster.fromJson(Map<String, Object?> json) {
    Map<String, List<String>> lists(Object? raw) {
      final options = <String, List<String>>{};
      if (raw is Map) {
        raw.forEach((key, value) {
          options['$key'] = [
            if (value is List)
              for (final item in value) '$item',
          ];
        });
      }
      return options;
    }

    return CollapseCluster(
      stemKey: _str(json['stem_key']),
      stem: _str(json['stem']),
      variants: _int(json['variants']),
      units: _int(json['units']),
      unitsInStock: _int(json['units_in_stock']),
      unitsSold: _int(json['units_sold']),
      needsReview: _int(json['needs_review']),
      optionValues: lists(json['option_values']),
      optionLabels: lists(json['option_labels']),
    );
  }
}

/// One legacy product, and what the collapse proposes to make of it.
class CollapseCandidate {
  const CollapseCandidate({
    required this.id,
    required this.sourceKey,
    required this.sourceName,
    required this.decision,
    required this.stem,
    required this.stemKey,
    required this.identifier,
    required this.identifierKind,
    required this.options,
    required this.optionLabels,
    required this.attributes,
    required this.unitStatus,
    required this.unitCost,
    required this.listPrice,
    required this.soldPrice,
    required this.acquiredAt,
    required this.soldAt,
    required this.confidence,
    required this.reasons,
    required this.edited,
    required this.needsReview,
  });

  final int id;
  final String sourceKey;
  final String sourceName;

  /// collapse | keep
  final String decision;
  final String stem;
  final String stemKey;
  final String identifier;
  final String identifierKind;
  final Map<String, String> options;
  final Map<String, String> optionLabels;
  final Map<String, Object?> attributes;

  /// in_stock | sold
  final String unitStatus;
  final double unitCost;
  final double? listPrice;
  final double? soldPrice;
  final DateTime? acquiredAt;
  final DateTime? soldAt;
  final double confidence;

  /// Machine codes the client turns into sentences.
  final List<String> reasons;
  final bool edited;
  final bool needsReview;

  bool get isCollapsing => decision == 'collapse';
  bool get isSold => unitStatus == 'sold';

  String get optionsLabel =>
      optionLabels.values.where((v) => v.isNotEmpty).join(' / ');

  factory CollapseCandidate.fromJson(Map<String, Object?> json) {
    return CollapseCandidate(
      id: _int(json['id']),
      sourceKey: _str(json['source_key']),
      sourceName: _str(json['source_name']),
      decision: _str(json['decision'], fallback: 'keep'),
      stem: _str(json['stem']),
      stemKey: _str(json['stem_key']),
      identifier: _str(json['identifier']),
      identifierKind: _str(json['identifier_kind']),
      options: _stringMap(json['options']),
      optionLabels: _stringMap(json['option_labels']),
      attributes: _map(json['attributes']),
      unitStatus: _str(json['unit_status'], fallback: 'in_stock'),
      unitCost: _double(json['unit_cost']) ?? 0,
      listPrice: _double(json['list_price']),
      soldPrice: _double(json['sold_price']),
      acquiredAt: _dateOrNull(json['acquired_at']),
      soldAt: _dateOrNull(json['sold_at']),
      confidence: _double(json['confidence']) ?? 0,
      reasons: [
        if (json['reasons'] is List)
          for (final item in json['reasons'] as List) '$item',
      ],
      edited: json['edited'] as bool? ?? false,
      needsReview: json['needs_review'] as bool? ?? false,
    );
  }
}

class CollapseCandidatePage {
  const CollapseCandidatePage({
    required this.candidates,
    required this.hasMore,
  });

  final List<CollapseCandidate> candidates;
  final bool hasMore;

  static const empty = CollapseCandidatePage(candidates: [], hasMore: false);

  factory CollapseCandidatePage.fromAny(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      return CollapseCandidatePage(
        candidates: [
          for (final item in _list(decoded['results']))
            CollapseCandidate.fromJson(item),
        ],
        hasMore: decoded['next'] != null,
      );
    }
    if (decoded is List) {
      return CollapseCandidatePage(
        candidates: [
          for (final item in decoded)
            if (item is Map<String, Object?>) CollapseCandidate.fromJson(item),
        ],
        hasMore: false,
      );
    }
    return empty;
  }
}

/// The proposal itself: its state, its build timeline and its headline.
class CollapsePlan {
  const CollapsePlan({
    required this.id,
    required this.source,
    required this.status,
    required this.isEditable,
    required this.stages,
    required this.errorMessage,
    required this.assetTypeId,
    required this.assetTypeName,
    required this.warrantyDays,
    required this.stats,
    required this.lowConfidence,
    required this.builtAt,
    required this.approvedAt,
    required this.approvedByUsername,
  });

  final int id;
  final int source;

  /// queued | running | ready | failed | approved | applied | superseded
  final String status;
  final bool isEditable;

  /// What the build is doing right now — reading the catalogue, then the
  /// purchases and sales, then clustering. On a real export that is minutes,
  /// and a bare spinner for minutes is indistinguishable from a hang.
  final List<MigrationStage> stages;
  final String errorMessage;
  final int? assetTypeId;
  final String assetTypeName;
  final int warrantyDays;
  final CollapseStats stats;

  /// Below this, a row is shown first and flagged. The server decides it, so
  /// the two never disagree about what "needs a look" means.
  final double lowConfidence;
  final DateTime? builtAt;
  final DateTime? approvedAt;
  final String approvedByUsername;

  bool get isBuilding => status == 'queued' || status == 'running';
  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isApproved => status == 'approved';
  bool get isApplied => status == 'applied';
  bool get isSuperseded => status == 'superseded';

  /// An import run may name this plan.
  bool get isUsable => isApproved || isApplied;

  factory CollapsePlan.fromJson(Map<String, Object?> json) {
    final thresholds = _map(json['thresholds']);
    return CollapsePlan(
      id: _int(json['id']),
      source: _int(json['source']),
      status: _str(json['status'], fallback: 'queued'),
      isEditable: json['is_editable'] as bool? ?? false,
      stages: [
        if (json['stages'] is List)
          for (final item in json['stages'] as List)
            if (item is Map<String, Object?>) MigrationStage.fromJson(item),
      ],
      errorMessage: _str(json['error_message']),
      stats: CollapseStats.fromJson(_map(json['stats'])),
      assetTypeId: json['asset_type'] is num
          ? (json['asset_type'] as num).toInt()
          : null,
      assetTypeName: _str(json['asset_type_name']),
      warrantyDays: _int(json['warranty_days']),
      lowConfidence: _double(thresholds['low']) ?? 0.5,
      builtAt: _dateOrNull(json['built_at']),
      approvedAt: _dateOrNull(json['approved_at']),
      approvedByUsername: _str(json['approved_by_username']),
    );
  }
}

// --- tolerant parsing helpers ------------------------------------------------

String _str(Object? value, {String fallback = ''}) =>
    value == null ? fallback : '$value';

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

double? _double(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const {};

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return {for (final entry in value.entries) '${entry.key}': '${entry.value}'};
}

List<Map<String, Object?>> _list(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map<String, Object?>) item,
];

DateTime? _dateOrNull(Object? value) {
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}
