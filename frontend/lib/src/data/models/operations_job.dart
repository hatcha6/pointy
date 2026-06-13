import 'customer_asset.dart';
import 'sale_order.dart' show PaymentMethod;
import 'workflow.dart';

enum OperationsJobStatus {
  open,
  completed,
  cancelled;

  static OperationsJobStatus fromJson(Object? value) {
    return switch (value?.toString()) {
      'completed' => OperationsJobStatus.completed,
      'cancelled' => OperationsJobStatus.cancelled,
      _ => OperationsJobStatus.open,
    };
  }

  String toJson() => name;
}

enum OperationsJobPriority {
  low,
  normal,
  high,
  urgent;

  static OperationsJobPriority fromJson(Object? value) {
    return switch (value?.toString()) {
      'low' => OperationsJobPriority.low,
      'high' => OperationsJobPriority.high,
      'urgent' => OperationsJobPriority.urgent,
      _ => OperationsJobPriority.normal,
    };
  }

  String toJson() => name;
}

enum OperationsJobType {
  repair('repair'),
  production('production'),
  kitchen('kitchen'),
  workOrder('work_order');

  const OperationsJobType(this.apiValue);

  final String apiValue;

  static OperationsJobType fromJson(Object? value) {
    return switch (value?.toString()) {
      'production' => OperationsJobType.production,
      'kitchen' => OperationsJobType.kitchen,
      'work_order' => OperationsJobType.workOrder,
      _ => OperationsJobType.repair,
    };
  }

  String toJson() => apiValue;
}

class JobAssetLink {
  const JobAssetLink({required this.id, required this.asset, this.assetDetails});

  final int id;
  final int asset;
  final CustomerAsset? assetDetails;

  factory JobAssetLink.fromJson(Map<String, Object?> json) {
    return JobAssetLink(
      id: json['id'] as int,
      asset: _intFromJson(json['asset']),
      assetDetails: json['asset_details'] is Map<String, Object?>
          ? CustomerAsset.fromJson(json['asset_details'] as Map<String, Object?>)
          : null,
    );
  }
}

class JobMaterial {
  const JobMaterial({
    required this.id,
    required this.variant,
    required this.productName,
    required this.variantName,
    this.unit = 'piece',
    required this.quantity,
    required this.unitCost,
    required this.unitPrice,
    required this.lineTotal,
    required this.isConsumed,
    this.consumedAt,
    this.reversedAt,
    this.createdAt,
  });

  final int id;
  final int variant;
  final String productName;
  final String variantName;
  final String unit;
  final double quantity;
  final double unitCost;
  final double unitPrice;
  final double lineTotal;
  final bool isConsumed;
  final DateTime? consumedAt;
  final DateTime? reversedAt;
  final DateTime? createdAt;

  bool get isReversed => reversedAt != null;

  factory JobMaterial.fromJson(Map<String, Object?> json) {
    return JobMaterial(
      id: json['id'] as int,
      variant: _intFromJson(json['variant']),
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      unit: json['unit']?.toString() ?? 'piece',
      quantity: _qtyFromJson(json['quantity']),
      unitCost: _moneyFromJson(json['unit_cost']),
      unitPrice: _moneyFromJson(json['unit_price']),
      lineTotal: _moneyFromJson(json['line_total']),
      isConsumed: json['is_consumed'] == true,
      consumedAt: _dateTimeFromJson(json['consumed_at']),
      reversedAt: _dateTimeFromJson(json['reversed_at']),
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class JobStageEvent {
  const JobStageEvent({
    required this.id,
    required this.toStage,
    required this.toStageName,
    required this.fromStageName,
    required this.changedByName,
    required this.note,
    this.fromStage,
    this.changedBy,
    this.createdAt,
  });

  final int id;
  final int? fromStage;
  final String fromStageName;
  final int toStage;
  final String toStageName;
  final int? changedBy;
  final String changedByName;
  final String note;
  final DateTime? createdAt;

  factory JobStageEvent.fromJson(Map<String, Object?> json) {
    return JobStageEvent(
      id: json['id'] as int,
      fromStage: _nullableIntFromJson(json['from_stage']),
      fromStageName: json['from_stage_name']?.toString() ?? '',
      toStage: _intFromJson(json['to_stage']),
      toStageName: json['to_stage_name']?.toString() ?? '',
      changedBy: _nullableIntFromJson(json['changed_by']),
      changedByName: json['changed_by_name']?.toString() ?? '',
      note: json['note']?.toString() ?? '',
      createdAt: _dateTimeFromJson(json['created_at']),
    );
  }
}

class OperationsJob {
  const OperationsJob({
    required this.id,
    required this.jobNumber,
    required this.jobType,
    required this.workflowTemplate,
    required this.currentStage,
    required this.status,
    required this.customerName,
    required this.customerPhone,
    required this.assignedToName,
    required this.priority,
    required this.symptoms,
    required this.diagnosis,
    required this.technicianNotes,
    required this.warrantyDays,
    required this.outputVariantName,
    required this.salesChannelName,
    required this.orderReceiptNumber,
    required this.publicToken,
    required this.assets,
    required this.materials,
    required this.stageEvents,
    required this.materialsTotal,
    this.currentStageDetails,
    this.nextStage,
    this.customer,
    this.assignedTo,
    this.dueAt,
    this.completedAt,
    this.cancelledAt,
    this.quotedPrice,
    this.approvedPrice,
    this.bom,
    this.outputVariant,
    this.outputQuantity,
    this.outputUnitCost,
    this.outputReceivedAt,
    this.salesChannel,
    this.order,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String jobNumber;
  final OperationsJobType jobType;
  final int workflowTemplate;
  final int currentStage;
  final WorkflowStage? currentStageDetails;
  final WorkflowStage? nextStage;
  final OperationsJobStatus status;
  final int? customer;
  final String customerName;
  final String customerPhone;
  final int? assignedTo;
  final String assignedToName;
  final OperationsJobPriority priority;
  final DateTime? dueAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String symptoms;
  final String diagnosis;
  final String technicianNotes;
  final double? quotedPrice;
  final double? approvedPrice;
  final int warrantyDays;
  final int? bom;
  final int? outputVariant;
  final String outputVariantName;
  final int? outputQuantity;
  final double? outputUnitCost;
  final DateTime? outputReceivedAt;
  final int? salesChannel;
  final String salesChannelName;
  final int? order;
  final String orderReceiptNumber;
  final String publicToken;
  final List<JobAssetLink> assets;
  final List<JobMaterial> materials;
  final List<JobStageEvent> stageEvents;
  final double materialsTotal;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isOpen => status == OperationsJobStatus.open;

  factory OperationsJob.fromJson(Map<String, Object?> json) {
    final assetsJson = (json['assets'] as List<Object?>?) ?? const [];
    final materialsJson = (json['materials'] as List<Object?>?) ?? const [];
    final eventsJson = (json['stage_events'] as List<Object?>?) ?? const [];

    return OperationsJob(
      id: json['id'] as int,
      jobNumber: json['job_number']?.toString() ?? '',
      jobType: OperationsJobType.fromJson(json['job_type']),
      workflowTemplate: _intFromJson(json['workflow_template']),
      currentStage: _intFromJson(json['current_stage']),
      currentStageDetails: json['current_stage_details'] is Map<String, Object?>
          ? WorkflowStage.fromJson(
              json['current_stage_details'] as Map<String, Object?>,
            )
          : null,
      nextStage: json['next_stage'] is Map<String, Object?>
          ? WorkflowStage.fromJson(json['next_stage'] as Map<String, Object?>)
          : null,
      status: OperationsJobStatus.fromJson(json['status']),
      customer: _nullableIntFromJson(json['customer']),
      customerName: json['customer_name']?.toString() ?? '',
      customerPhone: json['customer_phone']?.toString() ?? '',
      assignedTo: _nullableIntFromJson(json['assigned_to']),
      assignedToName: json['assigned_to_name']?.toString() ?? '',
      priority: OperationsJobPriority.fromJson(json['priority']),
      dueAt: _dateTimeFromJson(json['due_at']),
      completedAt: _dateTimeFromJson(json['completed_at']),
      cancelledAt: _dateTimeFromJson(json['cancelled_at']),
      symptoms: json['symptoms']?.toString() ?? '',
      diagnosis: json['diagnosis']?.toString() ?? '',
      technicianNotes: json['technician_notes']?.toString() ?? '',
      quotedPrice: _nullableMoneyFromJson(json['quoted_price']),
      approvedPrice: _nullableMoneyFromJson(json['approved_price']),
      warrantyDays: _intFromJson(json['warranty_days']),
      bom: _nullableIntFromJson(json['bom']),
      outputVariant: _nullableIntFromJson(json['output_variant']),
      outputVariantName: json['output_variant_name']?.toString() ?? '',
      outputQuantity: _nullableIntFromJson(json['output_quantity']),
      outputUnitCost: _nullableMoneyFromJson(json['output_unit_cost']),
      outputReceivedAt: _dateTimeFromJson(json['output_received_at']),
      salesChannel: _nullableIntFromJson(json['sales_channel']),
      salesChannelName: json['sales_channel_name']?.toString() ?? '',
      order: _nullableIntFromJson(json['order']),
      orderReceiptNumber: json['order_receipt_number']?.toString() ?? '',
      publicToken: json['public_token']?.toString() ?? '',
      assets: assetsJson
          .whereType<Map<String, Object?>>()
          .map(JobAssetLink.fromJson)
          .toList(growable: false),
      materials: materialsJson
          .whereType<Map<String, Object?>>()
          .map(JobMaterial.fromJson)
          .toList(growable: false),
      stageEvents: eventsJson
          .whereType<Map<String, Object?>>()
          .map(JobStageEvent.fromJson)
          .toList(growable: false),
      materialsTotal: _moneyFromJson(json['materials_total']),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class OperationsJobPage {
  const OperationsJobPage({required this.jobs, required this.hasMore});

  final List<OperationsJob> jobs;
  final bool hasMore;

  factory OperationsJobPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(OperationsJob.fromJson)
        .toList(growable: false);

    return OperationsJobPage(jobs: results, hasMore: json['next'] != null);
  }
}

class OperationsJobDraft {
  const OperationsJobDraft({
    required this.workflowTemplate,
    this.customer,
    this.assetIds = const [],
    this.assignedToId,
    this.priority = OperationsJobPriority.normal,
    this.dueAt,
    this.symptoms = '',
    this.quotedPrice,
    this.warrantyDays,
    this.bom,
    this.batches,
  });

  final int workflowTemplate;
  final int? customer;
  final List<int> assetIds;
  final int? assignedToId;
  final OperationsJobPriority priority;
  final DateTime? dueAt;
  final String symptoms;
  final double? quotedPrice;
  final int? warrantyDays;
  final int? bom;
  final int? batches;

  Map<String, Object?> toJson() {
    final normalizedSymptoms = symptoms.trim();
    return {
      'workflow_template': workflowTemplate,
      if (customer != null) 'customer': customer,
      if (assetIds.isNotEmpty) 'asset_ids': assetIds,
      if (assignedToId != null) 'assigned_to_id': assignedToId,
      'priority': priority.toJson(),
      if (dueAt != null) 'due_at': dueAt!.toUtc().toIso8601String(),
      if (normalizedSymptoms.isNotEmpty) 'symptoms': normalizedSymptoms,
      if (quotedPrice != null) 'quoted_price': quotedPrice!.toStringAsFixed(2),
      if (warrantyDays != null) 'warranty_days': warrantyDays,
      if (bom != null) 'bom': bom,
      if (batches != null) 'batches': batches,
    };
  }
}

class JobInvoicePayment {
  const JobInvoicePayment({required this.method, required this.amount});

  final PaymentMethod method;
  final double amount;

  Map<String, Object?> toJson() {
    return {'method': method.apiValue, 'amount': amount.toStringAsFixed(2)};
  }
}

class JobInvoiceDraft {
  const JobInvoiceDraft({required this.laborTotal, required this.payments});

  final double laborTotal;
  final List<JobInvoicePayment> payments;

  Map<String, Object?> toJson() {
    return {
      'labor_total': laborTotal.toStringAsFixed(2),
      'payments': payments
          .map((payment) => payment.toJson())
          .toList(growable: false),
    };
  }
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse((value ?? 0).toString()) ?? 0;
}

int? _nullableIntFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  return int.tryParse(value.toString());
}

double _moneyFromJson(Object? value) {
  return double.tryParse((value ?? 0).toString()) ?? 0;
}

double? _nullableMoneyFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value.toString());
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

double _qtyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}
