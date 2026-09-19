import 'tracking_mode.dart';
import 'warehouse.dart';

/// Goods moving from one of the shop's places to another.
///
/// Two documents and a road between them: dispatching takes stock out of the
/// source and puts it in transit, and a receipt takes it off the road and puts
/// it at the destination. That is why a transfer has a *journey* rather than a
/// flag, and why the UI draws one.
class StockTransfer {
  const StockTransfer({
    required this.id,
    required this.transferNumber,
    required this.sourceId,
    required this.sourceName,
    required this.destinationId,
    required this.destinationName,
    required this.status,
    this.note = '',
    this.dispatchedAt,
    this.lines = const <StockTransferLine>[],
    this.cancelReason = '',
    this.cancelledByUsername = '',
    this.createdAt,
  });

  final int id;
  final String transferNumber;
  final int sourceId;
  final String sourceName;
  final int destinationId;
  final String destinationName;
  final StockTransferStatus status;
  final String note;
  final DateTime? dispatchedAt;
  final List<StockTransferLine> lines;
  final String cancelReason;
  final String cancelledByUsername;
  final DateTime? createdAt;

  bool get isDraft => status == StockTransferStatus.draft;
  bool get isCancelled => status == StockTransferStatus.cancelled;

  /// Still holding goods on the road. The state that needs somebody to do
  /// something, which is why the list leads with it.
  bool get isOnTheRoad =>
      status == StockTransferStatus.inTransit ||
      status == StockTransferStatus.partiallyReceived;

  double get totalQuantity =>
      lines.fold<double>(0, (sum, line) => sum + line.baseQuantity);

  double get receivedQuantity =>
      lines.fold<double>(0, (sum, line) => sum + line.receivedQuantity);

  double get outstandingQuantity =>
      lines.fold<double>(0, (sum, line) => sum + line.outstandingQuantity);

  /// How far along the journey is, 0..1. Drives the progress rail on the card.
  double get progress {
    final total = totalQuantity;
    if (total <= 0) return 0;
    return (receivedQuantity / total).clamp(0.0, 1.0);
  }

  factory StockTransfer.fromJson(Map<String, Object?> json) {
    DateTime? when(Object? value) =>
        value == null ? null : DateTime.tryParse('$value')?.toLocal();
    return StockTransfer(
      id: (json['id'] as num).toInt(),
      transferNumber: json['transfer_number']?.toString() ?? '',
      sourceId: (json['source'] as num?)?.toInt() ?? 0,
      sourceName: json['source_name']?.toString() ?? '',
      destinationId: (json['destination'] as num?)?.toInt() ?? 0,
      destinationName: json['destination_name']?.toString() ?? '',
      status: stockTransferStatusFromValue(json['status']?.toString()),
      note: json['note']?.toString() ?? '',
      dispatchedAt: when(json['dispatched_at']),
      createdAt: when(json['created_at']),
      cancelReason: json['cancel_reason']?.toString() ?? '',
      cancelledByUsername: json['cancelled_by_username']?.toString() ?? '',
      lines: (json['lines'] as List<Object?>? ?? const <Object?>[])
          .whereType<Map>()
          .map((row) => StockTransferLine.fromJson(row.cast<String, Object?>()))
          .toList(growable: false),
    );
  }
}

class StockTransferLine {
  const StockTransferLine({
    required this.id,
    required this.variantId,
    required this.variantName,
    required this.variantSku,
    required this.quantity,
    this.unit = '',
    this.unitFactor = 1,
    this.baseQuantity = 0,
    this.receivedQuantity = 0,
    this.outstandingQuantity = 0,
    this.trackingMode = TrackingMode.quantity,
  });

  final int id;
  final int variantId;
  final String variantName;
  final String variantSku;

  /// How closely this line's product is identified. The dispatch sheet asks
  /// for identifiers only when the answer says articles have names — a shop
  /// that sells Coca-Cola must not be able to tell this shipped.
  final TrackingMode trackingMode;

  /// In the line's own unit — two cartons, not twenty-four pieces.
  final double quantity;
  final String unit;
  final double unitFactor;

  /// In base units, which is what transit and the destination speak.
  final double baseQuantity;
  final double receivedQuantity;
  final double outstandingQuantity;

  bool get hasArrived => outstandingQuantity <= 0;

  factory StockTransferLine.fromJson(Map<String, Object?> json) {
    double number(Object? value) =>
        value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
    return StockTransferLine(
      id: (json['id'] as num?)?.toInt() ?? 0,
      variantId: (json['variant'] as num?)?.toInt() ?? 0,
      variantName: json['variant_name']?.toString() ?? '',
      variantSku: json['variant_sku']?.toString() ?? '',
      quantity: number(json['quantity']),
      unit: json['unit']?.toString() ?? '',
      unitFactor: number(json['unit_factor']),
      baseQuantity: number(json['base_quantity']),
      receivedQuantity: number(json['received_quantity']),
      outstandingQuantity: number(json['outstanding_quantity']),
      trackingMode: TrackingMode.fromWire(json['tracking_mode']),
    );
  }
}

enum StockTransferStatus {
  draft('draft'),
  inTransit('in_transit'),
  partiallyReceived('partially_received'),
  received('received'),
  cancelled('cancelled');

  const StockTransferStatus(this.wireValue);

  final String wireValue;
}

StockTransferStatus stockTransferStatusFromValue(String? value) {
  return StockTransferStatus.values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => StockTransferStatus.draft,
  );
}

/// One product and how much of it to send, while a transfer is being written.
class StockTransferDraftLine {
  const StockTransferDraftLine({
    required this.variantId,
    required this.variantName,
    required this.quantity,
    this.availableAtSource = 0,
    this.unit = '',
    this.unitFactor = 1,
  });

  final int variantId;
  final String variantName;
  final double quantity;

  /// What the source actually has. Shown beside the field so nobody types a
  /// number the shop floor cannot honour and finds out at dispatch.
  final double availableAtSource;
  final String unit;
  final double unitFactor;

  bool get exceedsSource => quantity * unitFactor > availableAtSource;

  Map<String, Object?> toJson() => <String, Object?>{
    'variant': variantId,
    'quantity': quantity.toString(),
    if (unit.isNotEmpty) 'unit': unit,
    'unit_factor': unitFactor.toString(),
  };

  StockTransferDraftLine copyWith({double? quantity}) {
    return StockTransferDraftLine(
      variantId: variantId,
      variantName: variantName,
      quantity: quantity ?? this.quantity,
      availableAtSource: availableAtSource,
      unit: unit,
      unitFactor: unitFactor,
    );
  }
}

/// Everything the composer knows before it is sent.
class StockTransferDraft {
  const StockTransferDraft({
    required this.source,
    required this.destination,
    required this.lines,
    this.note = '',
  });

  final Warehouse source;
  final Warehouse destination;
  final List<StockTransferDraftLine> lines;
  final String note;

  bool get isSendable =>
      lines.isNotEmpty &&
      source.id != destination.id &&
      lines.every((line) => line.quantity > 0);

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.id,
    'destination': destination.id,
    if (note.trim().isNotEmpty) 'note': note.trim(),
    'lines': lines.map((line) => line.toJson()).toList(growable: false),
  };
}
