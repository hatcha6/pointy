enum PrintTransportKind { serial, bluetooth, wifi, system, usb, fake }

enum PrinterOutputMode { escPos, pdfA4 }

/// Page geometry for the PDF/document output path (the [PrinterOutputMode.pdfA4]
/// mode used by system / Windows-driver printers). [a4] renders the full-page
/// invoice; the roll widths render a compact, thermal-style receipt at that
/// width so a receipt printer driven through its own PDF driver (e.g. the
/// Xprinter N160II) prints a proper receipt instead of gibberish from the
/// ESC/POS commands its driver doesn't understand.
enum PdfPageSize { a4, roll58, roll70, roll80 }

/// Receipt roll width in millimetres for a [PdfPageSize], or null for [a4]
/// (the full-page document has no fixed narrow width).
int? pdfPageSizeReceiptWidthMm(PdfPageSize size) {
  return switch (size) {
    PdfPageSize.a4 => null,
    PdfPageSize.roll58 => 58,
    PdfPageSize.roll70 => 70,
    PdfPageSize.roll80 => 80,
  };
}

PdfPageSize pdfPageSizeFromJson(Object? value) {
  return switch (value?.toString()) {
    'roll58' || 'mm58' || '58' => PdfPageSize.roll58,
    'roll70' || 'mm70' || '70' => PdfPageSize.roll70,
    'roll80' || 'mm80' || '80' => PdfPageSize.roll80,
    _ => PdfPageSize.a4,
  };
}

String pdfPageSizeToJson(PdfPageSize size) => size.name;

enum BarcodeLabelPrinterLanguage { auto, zpl, tspl, epl, cpcl }

/// How the receipt should be terminated. Cheap printers without a cutter
/// should use [none] (feed only).
enum ReceiptCutMode { partial, full, none }

ReceiptCutMode receiptCutModeFromJson(Object? value) {
  return switch (value?.toString()) {
    'full' => ReceiptCutMode.full,
    'none' || 'feed' => ReceiptCutMode.none,
    _ => ReceiptCutMode.partial,
  };
}

enum PrinterRole { posReceipt, kitchen }

PrinterRole printerRoleFromJson(Object? value) {
  return switch (value?.toString()) {
    'pos_receipt' || 'posReceipt' => PrinterRole.posReceipt,
    'kitchen' => PrinterRole.kitchen,
    _ => PrinterRole.posReceipt,
  };
}

String printerRoleToJson(PrinterRole role) {
  return switch (role) {
    PrinterRole.posReceipt => 'pos_receipt',
    PrinterRole.kitchen => 'kitchen',
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
    this.outputMode = PrinterOutputMode.escPos,
    this.pdfPageSize = PdfPageSize.a4,
    this.capabilityProfile = 'default',
    this.cutMode = ReceiptCutMode.partial,
    this.feedLines = 2,
    this.compactReceipt = false,
    this.barcodeLabelLanguage = BarcodeLabelPrinterLanguage.auto,
    this.labelWidthMm = 40,
    this.labelHeightMm = 30,
    this.labelGapMm = 2,
    this.labelDpi = 203,
  });

  final PrintTransportKind kind;
  final String name;
  final String address;
  final int baudRate;
  final int port;
  final int paperWidthMm;
  final String codeTable;
  final int timeoutMs;
  final PrinterOutputMode outputMode;

  /// PDF page geometry for the document output path. Ignored by the thermal
  /// (ESC/POS) path, which sizes itself from [paperWidthMm].
  final PdfPageSize pdfPageSize;

  /// ESC/POS capability profile name (esc_pos_utils_plus), so quirky printer
  /// models can use their vendor profile instead of the generic one.
  final String capabilityProfile;
  final ReceiptCutMode cutMode;

  /// Blank lines fed before cutting/tearing.
  final int feedLines;

  /// Dense/compact receipt layout: tighter line spacing, no double-height
  /// headings, and trimmed blank space so a slip uses less paper. Honoured by
  /// both output paths — the ESC/POS thermal encoder and the PDF/document
  /// renderer (A4 and receipt rolls alike) — so output stays cohesive whichever
  /// printer this endpoint drives.
  final bool compactReceipt;
  final BarcodeLabelPrinterLanguage barcodeLabelLanguage;
  final int labelWidthMm;
  final int labelHeightMm;
  final int labelGapMm;
  final int labelDpi;

  bool get usesThermalReceipt => outputMode == PrinterOutputMode.escPos;

  bool get usesDocumentInvoice => outputMode == PrinterOutputMode.pdfA4;

  /// A document-mode printer set to a receipt roll width — the PDF is rendered
  /// as a compact receipt at [pdfPageSize] rather than a full A4 page.
  bool get usesReceiptStylePdf =>
      outputMode == PrinterOutputMode.pdfA4 && pdfPageSize != PdfPageSize.a4;

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
      outputMode: _outputModeFromJson(
        json['output_mode'] ?? json['printer_type'] ?? json['layout'],
        fallback: _defaultOutputModeForKind(
          _transportKindFromJson(json['kind'] ?? json['transport']),
        ),
      ),
      pdfPageSize: pdfPageSizeFromJson(
        json['pdf_page_size'] ?? json['pdf_page_format'],
      ),
      capabilityProfile:
          json['capability_profile']?.toString().trim().isNotEmpty == true
              ? json['capability_profile']!.toString().trim()
              : 'default',
      cutMode: receiptCutModeFromJson(json['cut_mode']),
      feedLines: _intFromJson(json['feed_lines'], fallback: 2),
      compactReceipt: _boolFromJson(
        json['compact_receipt'] ?? json['compact'] ?? json['dense_receipt'],
        fallback: false,
      ),
      barcodeLabelLanguage: barcodeLabelPrinterLanguageFromJson(
        json['barcode_label_language'] ?? json['label_language'],
      ),
      labelWidthMm: _intFromJson(
        json['label_width_mm'] ?? json['barcode_label_width_mm'],
        fallback: 40,
      ),
      labelHeightMm: _intFromJson(
        json['label_height_mm'] ?? json['barcode_label_height_mm'],
        fallback: 30,
      ),
      labelGapMm: _intFromJson(
        json['label_gap_mm'] ?? json['barcode_label_gap_mm'],
        fallback: 2,
      ),
      labelDpi: _intFromJson(
        json['label_dpi'] ?? json['barcode_label_dpi'],
        fallback: 203,
      ),
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
      'output_mode': outputMode.name,
      'pdf_page_size': pdfPageSizeToJson(pdfPageSize),
      'capability_profile': capabilityProfile,
      'cut_mode': cutMode.name,
      'feed_lines': feedLines,
      'compact_receipt': compactReceipt,
      'barcode_label_language': barcodeLabelPrinterLanguageToJson(
        barcodeLabelLanguage,
      ),
      'label_width_mm': labelWidthMm,
      'label_height_mm': labelHeightMm,
      'label_gap_mm': labelGapMm,
      'label_dpi': labelDpi,
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
    PrinterOutputMode? outputMode,
    PdfPageSize? pdfPageSize,
    String? capabilityProfile,
    ReceiptCutMode? cutMode,
    int? feedLines,
    bool? compactReceipt,
    BarcodeLabelPrinterLanguage? barcodeLabelLanguage,
    int? labelWidthMm,
    int? labelHeightMm,
    int? labelGapMm,
    int? labelDpi,
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
      outputMode: outputMode ?? this.outputMode,
      pdfPageSize: pdfPageSize ?? this.pdfPageSize,
      capabilityProfile: capabilityProfile ?? this.capabilityProfile,
      cutMode: cutMode ?? this.cutMode,
      feedLines: feedLines ?? this.feedLines,
      compactReceipt: compactReceipt ?? this.compactReceipt,
      barcodeLabelLanguage: barcodeLabelLanguage ?? this.barcodeLabelLanguage,
      labelWidthMm: labelWidthMm ?? this.labelWidthMm,
      labelHeightMm: labelHeightMm ?? this.labelHeightMm,
      labelGapMm: labelGapMm ?? this.labelGapMm,
      labelDpi: labelDpi ?? this.labelDpi,
    );
  }
}

BarcodeLabelPrinterLanguage barcodeLabelPrinterLanguageFromJson(Object? value) {
  return switch (value?.toString()) {
    'auto' => BarcodeLabelPrinterLanguage.auto,
    'zpl' || 'ZPL' => BarcodeLabelPrinterLanguage.zpl,
    'tspl' || 'tspl2' || 'TSPL' || 'TSPL2' => BarcodeLabelPrinterLanguage.tspl,
    'epl' || 'epl2' || 'EPL' || 'EPL2' => BarcodeLabelPrinterLanguage.epl,
    'cpcl' || 'CPCL' => BarcodeLabelPrinterLanguage.cpcl,
    'esc_pos' ||
    'escPos' ||
    'thermal' ||
    'receipt' =>
      BarcodeLabelPrinterLanguage.auto,
    _ => BarcodeLabelPrinterLanguage.auto,
  };
}

String barcodeLabelPrinterLanguageToJson(BarcodeLabelPrinterLanguage language) {
  return switch (language) {
    BarcodeLabelPrinterLanguage.auto => 'auto',
    BarcodeLabelPrinterLanguage.zpl => 'zpl',
    BarcodeLabelPrinterLanguage.tspl => 'tspl',
    BarcodeLabelPrinterLanguage.epl => 'epl',
    BarcodeLabelPrinterLanguage.cpcl => 'cpcl',
  };
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
    'system' || 'pdf' || 'document' => PrintTransportKind.system,
    'usb' => PrintTransportKind.usb,
    'fake' => PrintTransportKind.fake,
    _ => PrintTransportKind.serial,
  };
}

PrinterOutputMode _outputModeFromJson(
  Object? value, {
  required PrinterOutputMode fallback,
}) {
  return switch (value?.toString()) {
    'pdfA4' ||
    'pdf_a4' ||
    'a4' ||
    'document' ||
    'normal' =>
      PrinterOutputMode.pdfA4,
    'escPos' || 'esc_pos' || 'thermal' || 'receipt' => PrinterOutputMode.escPos,
    _ => fallback,
  };
}

PrinterOutputMode _defaultOutputModeForKind(PrintTransportKind kind) {
  return switch (kind) {
    PrintTransportKind.system => PrinterOutputMode.pdfA4,
    PrintTransportKind.serial ||
    PrintTransportKind.bluetooth ||
    PrintTransportKind.wifi ||
    PrintTransportKind.usb ||
    PrintTransportKind.fake =>
      PrinterOutputMode.escPos,
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
