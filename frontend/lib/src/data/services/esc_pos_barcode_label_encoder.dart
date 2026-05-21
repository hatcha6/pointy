import 'dart:convert';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

import '../models/barcode_label.dart';
import '../models/printer_config.dart';

class EscPosBarcodeLabelEncoder {
  const EscPosBarcodeLabelEncoder();

  Future<List<int>> encodeLabels({
    required List<BarcodeLabelPrintLine> lines,
    required PrinterEndpoint endpoint,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(_paperSize(endpoint.paperWidthMm), profile);
    final codeTable = endpoint.codeTable.trim().isEmpty
        ? 'CP864'
        : endpoint.codeTable.trim();
    final bytes = <int>[];
    bytes.addAll(generator.reset());

    for (final line in lines) {
      if (line.copies <= 0) {
        continue;
      }
      final barcodeValue = line.label.barcode.trim();
      if (barcodeValue.isEmpty) {
        throw ArgumentError('Barcode label requires a barcode.');
      }
      for (var index = 0; index < line.copies; index += 1) {
        bytes.addAll(_encodeLabel(generator, line.label, codeTable, endpoint));
      }
    }

    return bytes;
  }

  List<int> _encodeLabel(
    Generator generator,
    BarcodeLabelDraft label,
    String codeTable,
    PrinterEndpoint endpoint,
  ) {
    final barcodeValue = label.barcode.trim();
    final bytes = <int>[];
    bytes.addAll(generator.feed(1));
    for (final nameLine in _wrap(
      label.displayName,
      _charsPerLine(endpoint.paperWidthMm),
    )) {
      bytes.addAll(
        _text(
          generator,
          nameLine,
          styles: PosStyles(
            align: PosAlign.center,
            bold: true,
            codeTable: codeTable,
          ),
        ),
      );
    }
    bytes.addAll(
      _text(
        generator,
        'السعر ${_money(label.unitPrice)}',
        styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
      ),
    );
    bytes.addAll(generator.feed(1));
    bytes.addAll(
      generator.barcode(
        Barcode.code128('{B$barcodeValue'.split('')),
        width: endpoint.paperWidthMm <= 58 ? 2 : 3,
        height: 72,
        textPos: BarcodeText.below,
        align: PosAlign.center,
      ),
    );
    final sku = label.sku.trim();
    if (sku.isNotEmpty) {
      bytes.addAll(
        _text(
          generator,
          sku,
          styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
        ),
      );
    }
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut(mode: PosCutMode.partial));
    return bytes;
  }

  List<int> _text(
    Generator generator,
    String value, {
    required PosStyles styles,
    int linesAfter = 0,
  }) {
    try {
      return generator.text(value, styles: styles, linesAfter: linesAfter);
    } on ArgumentError {
      return [
        ...generator.setStyles(styles),
        ...generator.rawBytes(utf8.encode(value)),
        ...generator.emptyLines(linesAfter + 1),
      ];
    }
  }

  PaperSize _paperSize(int paperWidthMm) {
    if (paperWidthMm <= 58) {
      return PaperSize.mm58;
    }
    if (paperWidthMm <= 72) {
      return PaperSize.mm72;
    }
    return PaperSize.mm80;
  }

  int _charsPerLine(int paperWidthMm) {
    if (paperWidthMm <= 58) {
      return 28;
    }
    if (paperWidthMm <= 72) {
      return 36;
    }
    return 42;
  }

  List<String> _wrap(String value, int width) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length <= width) {
      return normalized.isEmpty ? const [] : [normalized];
    }
    final words = normalized.split(RegExp(r'\s+'));
    final lines = <String>[];
    var current = '';
    for (final word in words) {
      final next = current.isEmpty ? word : '$current $word';
      if (next.length > width && current.isNotEmpty) {
        lines.add(current);
        current = word;
      } else {
        current = next;
      }
    }
    if (current.isNotEmpty) {
      lines.add(current);
    }
    return lines;
  }

  String _money(double value) => '${value.toStringAsFixed(2)} د.ل';
}
