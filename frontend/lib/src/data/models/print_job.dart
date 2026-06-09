import 'printer_config.dart';

enum PrintJobStatus { pending, claimed, printing, completed, failed, canceled }

class PrintJob {
  const PrintJob({
    required this.id,
    required this.status,
    required this.jobType,
    required this.payload,
    this.saleOrderId,
    this.receiptNumber,
    this.claimedBy,
    this.endpoint,
    this.errorMessage,
    this.leaseExpiresAt,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final PrintJobStatus status;
  final String jobType;
  final Map<String, Object?> payload;
  final int? saleOrderId;
  final String? receiptNumber;
  final String? claimedBy;
  final PrinterEndpoint? endpoint;
  final String? errorMessage;
  final DateTime? leaseExpiresAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory PrintJob.fromJson(Map<String, Object?> json) {
    final endpointJson = json['printer_endpoint'] ?? json['endpoint'];
    return PrintJob(
      id: _intFromJson(json['id']),
      status: _statusFromJson(json['status']),
      jobType: json['job_type']?.toString() ?? json['type']?.toString() ?? '',
      payload: _payloadFromJson(json['payload']),
      saleOrderId: _nullableIntFromJson(
        json['sale_order'] ?? json['order'] ?? json['order_id'],
      ),
      receiptNumber: json['receipt_number']?.toString(),
      claimedBy: json['claimed_by']?.toString(),
      endpoint: endpointJson is Map<String, Object?>
          ? PrinterEndpoint.fromJson(endpointJson)
          : null,
      errorMessage: json['error_message']?.toString(),
      leaseExpiresAt: _dateTimeFromJson(json['lease_expires_at']),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class PrintJobReportDraft {
  const PrintJobReportDraft({
    required this.status,
    required this.agentId,
    this.message,
    this.errorMessage,
    this.endpoint,
  });

  final PrintJobStatus status;
  final String agentId;
  final String? message;
  final String? errorMessage;
  final PrinterEndpoint? endpoint;

  Map<String, Object?> toJson() {
    return {
      'status': _statusToJson(status),
      'agent_id': agentId,
      if (message != null) 'message': message,
      if (errorMessage != null) 'error_message': errorMessage,
      if (endpoint != null) 'printer_endpoint': endpoint!.toJson(),
    };
  }
}

List<PrintJob> printJobsFromResponse(Object? decoded) {
  final items = decoded is Map<String, Object?> && decoded['results'] is List
      ? decoded['results'] as List<Object?>
      : decoded is List<Object?>
      ? decoded
      : const <Object?>[];

  return items
      .whereType<Map<String, Object?>>()
      .map(PrintJob.fromJson)
      .toList(growable: false);
}

PrintJobStatus _statusFromJson(Object? value) {
  return switch (value?.toString()) {
    'queued' => PrintJobStatus.pending,
    'claimed' => PrintJobStatus.claimed,
    'printing' => PrintJobStatus.printing,
    'printed' || 'completed' => PrintJobStatus.completed,
    'failed' => PrintJobStatus.failed,
    'canceled' || 'cancelled' => PrintJobStatus.canceled,
    _ => PrintJobStatus.pending,
  };
}

String _statusToJson(PrintJobStatus status) {
  return switch (status) {
    PrintJobStatus.pending => 'queued',
    PrintJobStatus.claimed => 'claimed',
    PrintJobStatus.printing => 'printing',
    PrintJobStatus.completed => 'completed',
    PrintJobStatus.failed => 'failed',
    PrintJobStatus.canceled => 'canceled',
  };
}

Map<String, Object?> _payloadFromJson(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
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
