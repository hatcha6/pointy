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

/// Sticker geometry for the PDF/document barcode-label path — how a label prints
/// on a printer driven through its own PDF/graphics driver (rather than raw
/// label-language commands). [sticker] is a die-cut label of the media size the
/// endpoint already carries ([PrinterEndpoint.labelWidthMm] ×
/// [PrinterEndpoint.labelHeightMm], the sticker as loaded in the printer);
/// [roll50]/[roll70]/[roll80] are continuous label rolls at that width; [a4]
/// tiles the sticker into a grid on a full sheet.
enum BarcodeLabelPdfSize { sticker, roll50, roll70, roll80, a4 }

/// Continuous-roll width in millimetres for a [BarcodeLabelPdfSize], or null
/// when the size is not a roll ([sticker] takes its width from the endpoint's
/// die-cut media; [a4] is a tiled sheet with no single sticker width).
double? barcodeLabelPdfRollWidthMm(BarcodeLabelPdfSize size) {
  return switch (size) {
    BarcodeLabelPdfSize.roll50 => 50,
    BarcodeLabelPdfSize.roll70 => 70,
    BarcodeLabelPdfSize.roll80 => 80,
    BarcodeLabelPdfSize.sticker || BarcodeLabelPdfSize.a4 => null,
  };
}

BarcodeLabelPdfSize barcodeLabelPdfSizeFromJson(Object? value) {
  return switch (value?.toString()) {
    'roll50' || 'mm50' || '50' => BarcodeLabelPdfSize.roll50,
    'roll70' || 'mm70' || '70' => BarcodeLabelPdfSize.roll70,
    'roll80' || 'mm80' || '80' => BarcodeLabelPdfSize.roll80,
    'a4' || 'A4' => BarcodeLabelPdfSize.a4,
    // 'label40x22' is the pre-2026-08 fixed sticker size; it now means "the
    // die-cut media this endpoint is configured for".
    _ => BarcodeLabelPdfSize.sticker,
  };
}

String barcodeLabelPdfSizeToJson(BarcodeLabelPdfSize size) => size.name;

/// Quarter-turn clockwise rotation (0–3 → 0°/90°/180°/270°) applied when a
/// barcode sticker is laid out through the PDF/document path, so labels feed the
/// right way up on printers whose native orientation is landscape.
int barcodeLabelRotationFromJson(Object? value) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    return 0;
  }
  // Tolerate degrees (90/180/270 → multiples of 90) as well as quarter-turns
  // (0–3); anything else wraps back into the 0–3 range.
  final quarters = (parsed >= 90 && parsed % 90 == 0) ? parsed ~/ 90 : parsed;
  return ((quarters % 4) + 4) % 4;
}

/// Command language used for barcode-label printing.
///
/// [escPos] covers receipt-protocol printers that double as label printers
/// (e.g. the HPRT LPQ58/LPQ80 switched to `Protocol: ESC/POS`). They ignore
/// the dedicated label languages entirely, so labels are drawn with ESC/POS
/// text plus a native `GS k` barcode.
enum BarcodeLabelPrinterLanguage { auto, zpl, tspl, epl, cpcl, escPos }

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
    this.labelPdfSize = BarcodeLabelPdfSize.sticker,
    this.labelPdfOffsetXMm = 0,
    this.labelPdfOffsetYMm = 0,
    this.labelPdfPitchMm = 0,
    this.labelRotationQuarterTurns = 0,
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

  /// Sticker geometry for barcode labels printed through the PDF/document path
  /// (a system/driver printer). Ignored by the raw label-language thermal path,
  /// which sizes itself from [labelWidthMm]/[labelHeightMm].
  final BarcodeLabelPdfSize labelPdfSize;

  /// Distance in millimetres from where the printer starts printing (the left
  /// edge of its head) to the left edge of the sticker. A label roll narrower
  /// than the head — or simply loaded off-centre — sits some way in from that
  /// origin, and a page that starts at the origin lands to the left of the
  /// sticker, half of it printing off the label. The PDF page is widened by
  /// this much so the artwork reaches the label. PDF/document path only.
  final int labelPdfOffsetXMm;

  /// Distance in millimetres from where the printer starts printing down the
  /// feed to the sticker's leading edge. A label printer that seeks the gap
  /// still has its own top-of-form offset, so the page is padded by this much
  /// at the top to push the artwork onto the sticker. PDF/document path only.
  final int labelPdfOffsetYMm;

  /// The label pitch in millimetres: the distance from one sticker's leading
  /// edge to the next, i.e. the sticker plus the gap after it. A run of labels
  /// is laid out as one continuous strip at this spacing, so registration comes
  /// from the artwork rather than from the printer's feed. 0 falls back to the
  /// sticker height (continuous media with no gap).
  /// PDF/document path only.
  final double labelPdfPitchMm;

  /// Quarter-turn clockwise rotation (0–3) for the PDF barcode-label layout.
  final int labelRotationQuarterTurns;

  bool get usesThermalReceipt => outputMode == PrinterOutputMode.escPos;

  bool get usesDocumentInvoice => outputMode == PrinterOutputMode.pdfA4;

  /// A document-mode printer set to a receipt roll width — the PDF is rendered
  /// as a compact receipt at [pdfPageSize] rather than a full A4 page.
  bool get usesReceiptStylePdf =>
      outputMode == PrinterOutputMode.pdfA4 && pdfPageSize != PdfPageSize.a4;

  /// Whether this names an actual device. The out-of-the-box config is a
  /// serial port nobody chose, and that must not read as a printer.
  bool get isConfigured {
    final trimmedName = name.trim();
    final trimmedAddress = address.trim();
    if (kind == PrintTransportKind.system || usesDocumentInvoice) {
      return true;
    }
    if (kind == PrintTransportKind.fake) {
      return trimmedName.isNotEmpty || trimmedAddress.isNotEmpty;
    }
    if (trimmedAddress.isEmpty) {
      return false;
    }
    return kind != PrintTransportKind.serial ||
        trimmedName.isNotEmpty ||
        trimmedAddress != '/dev/tty.usbserial';
  }

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
      labelPdfSize: barcodeLabelPdfSizeFromJson(
        json['label_pdf_size'] ?? json['barcode_label_pdf_size'],
      ),
      labelPdfOffsetXMm: _intFromJson(
        json['label_pdf_offset_x_mm'] ?? json['barcode_label_offset_x_mm'],
        fallback: 0,
      ),
      labelPdfOffsetYMm: _intFromJson(
        json['label_pdf_offset_y_mm'] ?? json['barcode_label_offset_y_mm'],
        fallback: 0,
      ),
      labelPdfPitchMm: _doubleFromJson(
        json['label_pdf_pitch_mm'] ?? json['label_pdf_feed_mm'],
        fallback: 0,
      ),
      labelRotationQuarterTurns: barcodeLabelRotationFromJson(
        json['label_rotation_quarter_turns'] ??
            json['label_rotation'] ??
            json['label_rotation_degrees'],
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
      'label_pdf_size': barcodeLabelPdfSizeToJson(labelPdfSize),
      'label_pdf_offset_x_mm': labelPdfOffsetXMm,
      'label_pdf_offset_y_mm': labelPdfOffsetYMm,
      'label_pdf_pitch_mm': labelPdfPitchMm,
      'label_rotation_quarter_turns': labelRotationQuarterTurns,
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
    BarcodeLabelPdfSize? labelPdfSize,
    int? labelPdfOffsetXMm,
    int? labelPdfOffsetYMm,
    double? labelPdfPitchMm,
    int? labelRotationQuarterTurns,
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
      labelPdfSize: labelPdfSize ?? this.labelPdfSize,
      labelPdfOffsetXMm: labelPdfOffsetXMm ?? this.labelPdfOffsetXMm,
      labelPdfOffsetYMm: labelPdfOffsetYMm ?? this.labelPdfOffsetYMm,
      labelPdfPitchMm: labelPdfPitchMm ?? this.labelPdfPitchMm,
      labelRotationQuarterTurns:
          labelRotationQuarterTurns ?? this.labelRotationQuarterTurns,
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
    'escpos' ||
    'esc_pos' ||
    'escPos' ||
    'esc/pos' ||
    'ESC/POS' ||
    'thermal' ||
    'receipt' => BarcodeLabelPrinterLanguage.escPos,
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
    BarcodeLabelPrinterLanguage.escPos => 'escpos',
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
    'normal' => PrinterOutputMode.pdfA4,
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
    PrintTransportKind.fake => PrinterOutputMode.escPos,
  };
}

bool _boolFromJson(Object? value, {required bool fallback}) {
  if (value is bool) {
    return value;
  }
  return value == null ? fallback : value.toString() == 'true';
}

double _doubleFromJson(Object? value, {required double fallback}) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

int _intFromJson(Object? value, {required int fallback}) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}
