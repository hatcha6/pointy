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
  const JobAssetLink({
    required this.id,
    required this.asset,
    this.assetDetails,
  });

  final int id;
  final int asset;
  final CustomerAsset? assetDetails;

  factory JobAssetLink.fromJson(Map<String, Object?> json) {
    return JobAssetLink(
      id: json['id'] as int,
      asset: _intFromJson(json['asset']),
      assetDetails: json['asset_details'] is Map<String, Object?>
          ? CustomerAsset.fromJson(
              json['asset_details'] as Map<String, Object?>,
            )
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

/// Where a job stands with money. Derived on the server from the linked order,
/// so it can never drift from what the customer actually owes.
enum JobSettlementState {
  notInvoiced,
  depositPaid,
  creditOpen,
  settled;

  static JobSettlementState fromJson(Object? value) {
    return switch (value?.toString()) {
      'deposit_paid' => JobSettlementState.depositPaid,
      'credit_open' => JobSettlementState.creditOpen,
      'settled' => JobSettlementState.settled,
      _ => JobSettlementState.notInvoiced,
    };
  }

  bool get isSettled => this == JobSettlementState.settled;
  bool get owesMoney =>
      this == JobSettlementState.depositPaid ||
      this == JobSettlementState.creditOpen;
}

/// Whether the shop still physically holds the customer's property. Separate
/// from payment on purpose: a repaired car is paid for days before it is
/// collected, and the shop is answerable for it the whole time.
enum JobCustodyState {
  withShop,
  released;

  static JobCustodyState fromJson(Object? value) {
    return value?.toString() == 'released'
        ? JobCustodyState.released
        : JobCustodyState.withShop;
  }
}

/// Why a repair ended without the work being done. Every value is a decline:
/// the job is over, but the shop still holds the item until it is handed back.
/// A job cancelled because it was opened by mistake has no reason at all.
enum JobDeclineReason {
  price('price'),
  declined('declined'),
  cannotRepair('cannot_repair'),
  noResponse('no_response');

  const JobDeclineReason(this.apiValue);

  final String apiValue;

  static JobDeclineReason? fromJson(Object? value) {
    final raw = value?.toString();
    for (final reason in values) {
      if (reason.apiValue == raw) {
        return reason;
      }
    }
    return null;
  }
}

/// Priced work on a job — a diagnosis fee, an oil change, a screen swap.
///
/// Distinct from [JobMaterial]: a service holds no stock, so it has no cost,
/// no consumption and nothing to reverse.
class JobServiceLine {
  const JobServiceLine({
    required this.id,
    required this.variant,
    required this.productName,
    required this.variantName,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    this.note = '',
    this.createdAt,
  });

  final int id;
  final int variant;
  final String productName;
  final String variantName;
  final double quantity;
  final double unitPrice;
  final double lineTotal;
  final String note;
  final DateTime? createdAt;

  factory JobServiceLine.fromJson(Map<String, Object?> json) {
    return JobServiceLine(
      id: json['id'] as int,
      variant: _intFromJson(json['variant']),
      productName: json['product_name']?.toString() ?? '',
      variantName: json['variant_name']?.toString() ?? '',
      quantity: _qtyFromJson(json['quantity']),
      unitPrice: _moneyFromJson(json['unit_price']),
      lineTotal: _moneyFromJson(json['line_total']),
      note: json['note']?.toString() ?? '',
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
    required this.assignedEmployeeName,
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
    this.services = const [],
    this.servicesTotal = 0,
    this.settlementState = JobSettlementState.notInvoiced,
    this.custodyState = JobCustodyState.withShop,
    this.isOnHold = false,
    this.holdReason = '',
    this.heldSeconds = 0,
    this.onHoldSince,
    this.handedOverAt,
    this.handedOverTo = '',
    this.cancelReason,
    this.cancelNote = '',
    this.cancelledByName = '',
    this.declineFee,
    this.isDeclined = false,
    this.awaitingHandBack = false,
    this.createdByName = '',
    this.orderBalanceDue,
    this.orderAmountPaid,
    this.orderSaleType = '',
    this.currentStageDetails,
    this.nextStage,
    this.customer,
    this.assignedTo,
    this.assignedEmployee,
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
  final int? assignedEmployee;
  final String assignedEmployeeName;
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
  final List<JobServiceLine> services;
  final double servicesTotal;
  final JobSettlementState settlementState;
  final JobCustodyState custodyState;
  final bool isOnHold;
  final String holdReason;
  final int heldSeconds;
  final DateTime? onHoldSince;
  final DateTime? handedOverAt;
  final String handedOverTo;

  /// Why the job ended unfinished — set only for a decline. A plain cancel
  /// keeps its free text in [cancelNote] and has no reason.
  final JobDeclineReason? cancelReason;
  final String cancelNote;
  final String cancelledByName;

  /// The diagnosis fee a declined job still bills; null means nothing is owed.
  final double? declineFee;
  final bool isDeclined;

  /// A declined job whose item is still on the shop's shelf.
  final bool awaitingHandBack;

  /// Who took the item in at the counter.
  final String createdByName;
  final double? orderBalanceDue;
  final double? orderAmountPaid;
  final String orderSaleType;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isOpen => status == OperationsJobStatus.open;

  /// Everything billable on this job: parts plus services. The free-text labour
  /// amount is typed at invoice time and is not part of this.
  double get billableTotal => materialsTotal + servicesTotal;

  /// Whether the next stage would hand the customer's property back — the cue
  /// for the board to show a "collect" action rather than a plain "advance".
  bool get nextStageReleasesCustody => nextStage?.releasesCustody ?? false;

  /// Whether the shop may not release this item yet.
  bool get blockedOnPayment =>
      nextStage?.requiresSettlement == true && !settlementState.isSettled;

  /// A declined job's diagnosis fee that has not been billed yet — the one
  /// thing standing between the customer and their item.
  bool get owesDeclineFee =>
      isDeclined && (declineFee ?? 0) > 0 && order == null;

  factory OperationsJob.fromJson(Map<String, Object?> json) {
    final assetsJson = (json['assets'] as List<Object?>?) ?? const [];
    final materialsJson = (json['materials'] as List<Object?>?) ?? const [];
    final eventsJson = (json['stage_events'] as List<Object?>?) ?? const [];
    final servicesJson = (json['services'] as List<Object?>?) ?? const [];

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
      assignedEmployee: _nullableIntFromJson(json['assigned_employee']),
      assignedEmployeeName: json['assigned_employee_name']?.toString() ?? '',
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
      services: servicesJson
          .whereType<Map<String, Object?>>()
          .map(JobServiceLine.fromJson)
          .toList(growable: false),
      servicesTotal: _moneyFromJson(json['services_total']),
      settlementState: JobSettlementState.fromJson(json['settlement_state']),
      custodyState: JobCustodyState.fromJson(json['custody_state']),
      isOnHold: json['is_on_hold'] == true,
      holdReason: json['hold_reason']?.toString() ?? '',
      heldSeconds: _intFromJson(json['held_seconds']),
      onHoldSince: _dateTimeFromJson(json['on_hold_since']),
      handedOverAt: _dateTimeFromJson(json['handed_over_at']),
      handedOverTo: json['handed_over_to']?.toString() ?? '',
      cancelReason: JobDeclineReason.fromJson(json['cancel_reason']),
      cancelNote: json['cancel_note']?.toString() ?? '',
      cancelledByName: json['cancelled_by_name']?.toString() ?? '',
      declineFee: _nullableMoneyFromJson(json['decline_fee']),
      isDeclined: json['is_declined'] == true,
      awaitingHandBack: json['awaiting_hand_back'] == true,
      createdByName: json['created_by_name']?.toString() ?? '',
      orderBalanceDue: _nullableMoneyFromJson(json['order_balance_due']),
      orderAmountPaid: _nullableMoneyFromJson(json['order_amount_paid']),
      orderSaleType: json['order_sale_type']?.toString() ?? '',
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
  const JobInvoiceDraft({
    required this.laborTotal,
    required this.payments,
    this.onCredit = false,
    this.dueDate,
    this.acknowledgeOverQuote = false,
  });

  final double laborTotal;
  final List<JobInvoicePayment> payments;

  /// آجل: book the balance against the customer instead of demanding it now.
  /// This is what makes a deposit (a partial payment) or a pay-later repair
  /// possible; a standard sale must still be paid in full.
  final bool onCredit;
  final DateTime? dueDate;

  /// Set only after the cashier has confirmed a total above the price the
  /// customer approved. The server refuses the invoice otherwise.
  final bool acknowledgeOverQuote;

  Map<String, Object?> toJson() {
    return {
      'labor_total': laborTotal.toStringAsFixed(2),
      'sale_type': onCredit ? 'credit' : 'standard',
      if (dueDate != null)
        'valid_until':
            '${dueDate!.year.toString().padLeft(4, '0')}-'
            '${dueDate!.month.toString().padLeft(2, '0')}-'
            '${dueDate!.day.toString().padLeft(2, '0')}',
      if (acknowledgeOverQuote) 'acknowledge_over_quote': true,
      'payments': payments
          .map((payment) => payment.toJson())
          .toList(growable: false),
    };
  }
}

/// Adding priced work to a job.
class JobServiceDraft {
  const JobServiceDraft({
    required this.variant,
    this.quantity = 1,
    this.note = '',
  });

  final int variant;
  final double quantity;
  final String note;

  Map<String, Object?> toJson() {
    return {
      'variant': variant,
      'quantity': quantity.toStringAsFixed(3),
      if (note.trim().isNotEmpty) 'note': note.trim(),
    };
  }
}

/// The customer said no: why, anything worth writing down, and what the
/// diagnosis costs them. A fee of zero (or none) means nothing is owed.
class JobDeclineDraft {
  const JobDeclineDraft({required this.reason, this.note = '', this.fee});

  final JobDeclineReason reason;
  final String note;
  final double? fee;

  Map<String, Object?> toJson() {
    final normalizedNote = note.trim();
    final owed = fee;
    return {
      'reason': reason.apiValue,
      if (normalizedNote.isNotEmpty) 'note': normalizedNote,
      'fee': owed == null || owed <= 0 ? null : owed.toStringAsFixed(2),
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
