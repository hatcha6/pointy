enum PrintAuditDocumentType { saleOrder, purchaseOrder, paymentReceipt }

/// Which money table a `payment_receipt` audit points at: a customer money-in
/// [Payment] or a supplier money-out SupplierPayment.
enum PrintAuditPaymentKind { customer, supplier }

enum PrintAuditAction { print, share }

enum PrintAuditStatus { requested, completed, canceled, failed }

class PrintAuditEvent {
  const PrintAuditEvent({
    required this.id,
    required this.documentType,
    required this.action,
    required this.status,
    required this.documentNumber,
    required this.printerEndpoint,
    required this.metadata,
    this.saleOrderId,
    this.purchaseOrderId,
    this.printJobId,
    this.userId,
    this.username,
    this.agentId,
    this.agentIdentifier,
    this.deviceName = '',
    this.printerName = '',
    this.message = '',
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final PrintAuditDocumentType documentType;
  final PrintAuditAction action;
  final PrintAuditStatus status;
  final int? saleOrderId;
  final int? purchaseOrderId;
  final String documentNumber;
  final int? printJobId;
  final int? userId;
  final String? username;
  final int? agentId;
  final String? agentIdentifier;
  final String deviceName;
  final String printerName;
  final Map<String, Object?> printerEndpoint;
  final String message;
  final Map<String, Object?> metadata;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  DateTime? get performedAt {
    if (status == PrintAuditStatus.requested) {
      return createdAt;
    }
    return updatedAt ?? createdAt;
  }

  factory PrintAuditEvent.fromJson(Map<String, Object?> json) {
    return PrintAuditEvent(
      id: _intFromJson(json['id']),
      documentType: _documentTypeFromJson(json['document_type']),
      action: _actionFromJson(json['action']),
      status: _statusFromJson(json['status']),
      saleOrderId: _nullableIntFromJson(json['sale_order']),
      purchaseOrderId: _nullableIntFromJson(json['purchase_order']),
      documentNumber: json['document_number']?.toString() ?? '',
      printJobId: _nullableIntFromJson(json['print_job']),
      userId: _nullableIntFromJson(json['user']),
      username: json['username']?.toString(),
      agentId: _nullableIntFromJson(json['agent']),
      agentIdentifier: json['agent_identifier']?.toString(),
      deviceName: json['device_name']?.toString() ?? '',
      printerName: json['printer_name']?.toString() ?? '',
      printerEndpoint: _mapFromJson(json['printer_endpoint']),
      message: json['message']?.toString() ?? '',
      metadata: _mapFromJson(json['metadata']),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class PrintAuditEventDraft {
  const PrintAuditEventDraft({
    required this.documentType,
    required this.documentId,
    required this.action,
    this.status = PrintAuditStatus.requested,
    this.paymentKind,
    this.agentId,
    this.printerEndpoint = const {},
    this.deviceName = '',
    this.printerName = '',
    this.message = '',
    this.metadata = const {},
    this.printJobId,
  });

  final PrintAuditDocumentType documentType;
  final int documentId;
  final PrintAuditAction action;
  final PrintAuditStatus status;

  /// Required for [PrintAuditDocumentType.paymentReceipt]: tells the backend
  /// whether [documentId] is a customer or supplier payment.
  final PrintAuditPaymentKind? paymentKind;
  final String? agentId;
  final Map<String, Object?> printerEndpoint;
  final String deviceName;
  final String printerName;
  final String message;
  final Map<String, Object?> metadata;
  final int? printJobId;

  Map<String, Object?> toJson() {
    return {
      'document_type': printAuditDocumentTypeToJson(documentType),
      'document_id': documentId,
      'action': printAuditActionToJson(action),
      'status': printAuditStatusToJson(status),
      if (paymentKind != null)
        'payment_kind': printAuditPaymentKindToJson(paymentKind!),
      if (agentId != null && agentId!.isNotEmpty) 'agent_id': agentId,
      if (printerEndpoint.isNotEmpty) 'printer_endpoint': printerEndpoint,
      if (deviceName.isNotEmpty) 'device_name': deviceName,
      if (printerName.isNotEmpty) 'printer_name': printerName,
      if (message.isNotEmpty) 'message': message,
      if (metadata.isNotEmpty) 'metadata': metadata,
      if (printJobId != null) 'print_job': printJobId,
    };
  }
}

class PrintAuditEventReportDraft {
  const PrintAuditEventReportDraft({
    required this.status,
    this.message = '',
    this.metadata = const {},
  });

  final PrintAuditStatus status;
  final String message;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() {
    return {
      'status': printAuditStatusToJson(status),
      if (message.isNotEmpty) 'message': message,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

List<PrintAuditEvent> printAuditEventsFromResponse(Object? decoded) {
  final items = decoded is Map<String, Object?> && decoded['results'] is List
      ? decoded['results'] as List<Object?>
      : decoded is List<Object?>
      ? decoded
      : const <Object?>[];

  return items
      .whereType<Map<String, Object?>>()
      .map(PrintAuditEvent.fromJson)
      .toList(growable: false);
}

String printAuditDocumentTypeToJson(PrintAuditDocumentType type) {
  return switch (type) {
    PrintAuditDocumentType.saleOrder => 'sale_order',
    PrintAuditDocumentType.purchaseOrder => 'purchase_order',
    PrintAuditDocumentType.paymentReceipt => 'payment_receipt',
  };
}

String printAuditPaymentKindToJson(PrintAuditPaymentKind kind) {
  return switch (kind) {
    PrintAuditPaymentKind.customer => 'customer',
    PrintAuditPaymentKind.supplier => 'supplier',
  };
}

String printAuditActionToJson(PrintAuditAction action) {
  return switch (action) {
    PrintAuditAction.print => 'print',
    PrintAuditAction.share => 'share',
  };
}

String printAuditStatusToJson(PrintAuditStatus status) {
  return switch (status) {
    PrintAuditStatus.requested => 'requested',
    PrintAuditStatus.completed => 'completed',
    PrintAuditStatus.canceled => 'canceled',
    PrintAuditStatus.failed => 'failed',
  };
}

PrintAuditDocumentType _documentTypeFromJson(Object? value) {
  return switch (value?.toString()) {
    'purchase_order' || 'purchaseOrder' => PrintAuditDocumentType.purchaseOrder,
    'payment_receipt' ||
    'paymentReceipt' => PrintAuditDocumentType.paymentReceipt,
    _ => PrintAuditDocumentType.saleOrder,
  };
}

PrintAuditAction _actionFromJson(Object? value) {
  return switch (value?.toString()) {
    'share' => PrintAuditAction.share,
    _ => PrintAuditAction.print,
  };
}

PrintAuditStatus _statusFromJson(Object? value) {
  return switch (value?.toString()) {
    'completed' || 'printed' || 'shared' => PrintAuditStatus.completed,
    'canceled' || 'cancelled' => PrintAuditStatus.canceled,
    'failed' => PrintAuditStatus.failed,
    _ => PrintAuditStatus.requested,
  };
}

Map<String, Object?> _mapFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return {
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return const {};
}

int _intFromJson(Object? value) {
  if (value is int) {
    return value;
  }
  return int.parse((value ?? 0).toString());
}

int? _nullableIntFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is Map<String, Object?>) {
    return _nullableIntFromJson(value['id']);
  }
  return int.tryParse(value.toString());
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}
