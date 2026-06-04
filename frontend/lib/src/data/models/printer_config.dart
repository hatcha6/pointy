enum PrintTransportKind { serial, bluetooth, wifi, fake }

enum PrinterRole { posReceipt }

PrinterRole printerRoleFromJson(Object? value) {
  return switch (value?.toString()) {
    'pos_receipt' || 'posReceipt' => PrinterRole.posReceipt,
    _ => PrinterRole.posReceipt,
  };
}

String printerRoleToJson(PrinterRole role) {
  return switch (role) {
    PrinterRole.posReceipt => 'pos_receipt',
  };
}

class PrinterEndpoint {
  const PrinterEndpoint({
    required this.kind,
    required this.name,
    this.address = '',
    this.baudRate = 9600,
    this.port = 9100,
    this.paperWidthMm = 80,
    this.codeTable = 'CP864',
    this.timeoutMs = 5000,
  });

  final PrintTransportKind kind;
  final String name;
  final String address;
  final int baudRate;
  final int port;
  final int paperWidthMm;
  final String codeTable;
  final int timeoutMs;

  factory PrinterEndpoint.fromJson(Map<String, Object?> json) {
    return PrinterEndpoint(
      kind: _transportKindFromJson(json['kind'] ?? json['transport']),
      name: json['name']?.toString() ?? '',
      address: json['address']?.toString() ?? json['path']?.toString() ?? '',
      baudRate: _intFromJson(json['baud_rate'], fallback: 9600),
      port: _intFromJson(json['port'], fallback: 9100),
      paperWidthMm: _intFromJson(
        json['paper_width_mm'] ?? json['paper_width'],
        fallback: 80,
      ),
      codeTable: json['code_table']?.toString() ?? 'CP864',
      timeoutMs: _intFromJson(json['timeout_ms'], fallback: 5000),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'kind': kind.name,
      'name': name,
      'address': address,
      'baud_rate': baudRate,
      'port': port,
      'paper_width_mm': paperWidthMm,
      'code_table': codeTable,
      'timeout_ms': timeoutMs,
    };
  }

  PrinterEndpoint copyWith({
    PrintTransportKind? kind,
    String? name,
    String? address,
    int? baudRate,
    int? port,
    int? paperWidthMm,
    String? codeTable,
    int? timeoutMs,
  }) {
    return PrinterEndpoint(
      kind: kind ?? this.kind,
      name: name ?? this.name,
      address: address ?? this.address,
      baudRate: baudRate ?? this.baudRate,
      port: port ?? this.port,
      paperWidthMm: paperWidthMm ?? this.paperWidthMm,
      codeTable: codeTable ?? this.codeTable,
      timeoutMs: timeoutMs ?? this.timeoutMs,
    );
  }
}

class PrinterConfig {
  const PrinterConfig({
    required this.endpoint,
    this.isEnabled = true,
    this.autoClaimJobs = true,
    this.agentId = 'pointy-local-agent',
  });

  final PrinterEndpoint endpoint;
  final bool isEnabled;
  final bool autoClaimJobs;
  final String agentId;

  factory PrinterConfig.defaultConfig() {
    return const PrinterConfig(
      endpoint: PrinterEndpoint(
        kind: PrintTransportKind.serial,
        name: '',
        address: '/dev/tty.usbserial',
      ),
    );
  }

  factory PrinterConfig.fromJson(Map<String, Object?> json) {
    final endpointJson = json['endpoint'];
    return PrinterConfig(
      endpoint: endpointJson is Map<String, Object?>
          ? PrinterEndpoint.fromJson(endpointJson)
          : PrinterEndpoint.fromJson(json),
      isEnabled: _boolFromJson(json['is_enabled'], fallback: true),
      autoClaimJobs: _boolFromJson(json['auto_claim_jobs'], fallback: true),
      agentId: json['agent_id']?.toString() ?? 'pointy-local-agent',
    );
  }

  Map<String, Object?> toJson() {
    return {
      'endpoint': endpoint.toJson(),
      'is_enabled': isEnabled,
      'auto_claim_jobs': autoClaimJobs,
      'agent_id': agentId,
    };
  }

  PrinterConfig copyWith({
    PrinterEndpoint? endpoint,
    bool? isEnabled,
    bool? autoClaimJobs,
    String? agentId,
  }) {
    return PrinterConfig(
      endpoint: endpoint ?? this.endpoint,
      isEnabled: isEnabled ?? this.isEnabled,
      autoClaimJobs: autoClaimJobs ?? this.autoClaimJobs,
      agentId: agentId ?? this.agentId,
    );
  }
}

PrintTransportKind _transportKindFromJson(Object? value) {
  return switch (value?.toString()) {
    'bluetooth' => PrintTransportKind.bluetooth,
    'wifi' || 'network' => PrintTransportKind.wifi,
    'fake' => PrintTransportKind.fake,
    _ => PrintTransportKind.serial,
  };
}

bool _boolFromJson(Object? value, {required bool fallback}) {
  if (value is bool) {
    return value;
  }
  return value == null ? fallback : value.toString() == 'true';
}

int _intFromJson(Object? value, {required int fallback}) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}
