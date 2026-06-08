import 'dart:convert';
import 'dart:math' as math;

import '../models/barcode_label.dart';
import '../models/printer_config.dart';

class BarcodeLabelCommandEncoder {
  const BarcodeLabelCommandEncoder();

  Future<List<int>> encodeLabels({
    required List<BarcodeLabelPrintLine> lines,
    required PrinterEndpoint endpoint,
    BarcodeLabelPrinterLanguage? language,
  }) async {
    final resolvedLanguage = language ?? endpoint.barcodeLabelLanguage;
    if (resolvedLanguage == BarcodeLabelPrinterLanguage.auto) {
      throw ArgumentError('Barcode label language must be resolved first.');
    }

    final commands = StringBuffer();
    for (final line in lines) {
      if (line.copies <= 0) {
        continue;
      }
      final barcodeValue = line.label.barcode.trim();
      if (barcodeValue.isEmpty) {
        throw ArgumentError('Barcode label requires a barcode.');
      }
      commands.write(switch (resolvedLanguage) {
        BarcodeLabelPrinterLanguage.zpl => _zpl(line, endpoint),
        BarcodeLabelPrinterLanguage.tspl => _tspl(line, endpoint),
        BarcodeLabelPrinterLanguage.epl => _epl(line, endpoint),
        BarcodeLabelPrinterLanguage.cpcl => _cpcl(line, endpoint),
        BarcodeLabelPrinterLanguage.auto => '',
      });
    }
    return utf8.encode(commands.toString());
  }

  String _zpl(BarcodeLabelPrintLine line, PrinterEndpoint endpoint) {
    final layout = _NativeLabelLayout(endpoint);
    final label = line.label;
    final nameY = layout.mm(2);
    final detailY = nameY + layout.mm(10);
    final barcodeY = math.max(layout.mm(16), detailY + layout.mm(5));
    final barcodeHeight = math.max(
      layout.mm(8),
      math.min(layout.mm(14), layout.heightDots - barcodeY - layout.mm(7)),
    );
    final skuY = math.min(
      layout.heightDots - layout.mm(5),
      barcodeY + barcodeHeight + layout.mm(4),
    );

    final buffer = StringBuffer()
      ..writeln('^XA')
      ..writeln('^CI28')
      ..writeln('^PW${layout.widthDots}')
      ..writeln('^LL${layout.heightDots}')
      ..writeln('^LH0,0');
    for (final textLine in _textLines(label.displayName, layout.nameChars)) {
      buffer.writeln(
        '^FO${layout.marginDots},$nameY^A0N,${layout.nameFontDots},${layout.nameFontDots}^FB${layout.contentWidthDots},1,0,C,0^FD${_zplText(textLine)}^FS',
      );
    }
    final detailText = _detailText(line);
    if (detailText.isNotEmpty) {
      buffer.writeln(
        '^FO${layout.marginDots},$detailY^A0N,${layout.detailFontDots},${layout.detailFontDots}^FB${layout.contentWidthDots},1,0,C,0^FD${_zplText(detailText)}^FS',
      );
    }
    buffer
      ..writeln('^BY2,2,$barcodeHeight')
      ..writeln(
        '^FO${layout.marginDots},$barcodeY^BCN,$barcodeHeight,Y,N,N^FD${_barcodeData(label.barcode)}^FS',
      );
    final sku = label.sku.trim();
    if (sku.isNotEmpty && skuY < layout.heightDots) {
      buffer.writeln(
        '^FO${layout.marginDots},$skuY^A0N,${layout.detailFontDots},${layout.detailFontDots}^FB${layout.contentWidthDots},1,0,C,0^FD${_zplText(sku)}^FS',
      );
    }
    buffer
      ..writeln('^PQ${line.copies},0,1,Y')
      ..writeln('^XZ');
    return buffer.toString();
  }

  String _tspl(BarcodeLabelPrintLine line, PrinterEndpoint endpoint) {
    final layout = _NativeLabelLayout(endpoint);
    final label = line.label;
    final nameY = layout.mm(2);
    final detailY = nameY + layout.mm(8);
    final barcodeY = math.max(layout.mm(15), detailY + layout.mm(5));
    final barcodeHeight = math.max(
      layout.mm(8),
      math.min(layout.mm(13), layout.heightDots - barcodeY - layout.mm(7)),
    );
    final skuY = math.min(
      layout.heightDots - layout.mm(5),
      barcodeY + barcodeHeight + layout.mm(4),
    );
    final textX = layout.marginDots;

    final buffer = StringBuffer()
      ..writeln('SIZE ${layout.widthMm} mm,${layout.heightMm} mm')
      ..writeln('GAP ${layout.gapMm} mm,0')
      ..writeln('DIRECTION 1')
      ..writeln('CODEPAGE UTF-8')
      ..writeln('CLS');
    for (final textLine in _textLines(label.displayName, layout.nameChars)) {
      buffer.writeln('TEXT $textX,$nameY,"0",0,1,1,"${_quoted(textLine)}"');
    }
    final detailText = _detailText(line);
    if (detailText.isNotEmpty) {
      buffer.writeln('TEXT $textX,$detailY,"0",0,1,1,"${_quoted(detailText)}"');
    }
    buffer.writeln(
      'BARCODE $textX,$barcodeY,"128",$barcodeHeight,1,0,2,2,"${_quoted(_barcodeData(label.barcode))}"',
    );
    final sku = label.sku.trim();
    if (sku.isNotEmpty && skuY < layout.heightDots) {
      buffer.writeln('TEXT $textX,$skuY,"0",0,1,1,"${_quoted(sku)}"');
    }
    buffer.writeln('PRINT ${line.copies},1');
    return buffer.toString();
  }

  String _epl(BarcodeLabelPrintLine line, PrinterEndpoint endpoint) {
    final layout = _NativeLabelLayout(endpoint);
    final label = line.label;
    final nameY = layout.mm(2);
    final detailY = nameY + layout.mm(7);
    final barcodeY = math.max(layout.mm(14), detailY + layout.mm(5));
    final barcodeHeight = math.max(
      layout.mm(8),
      math.min(layout.mm(13), layout.heightDots - barcodeY - layout.mm(7)),
    );
    final skuY = math.min(
      layout.heightDots - layout.mm(5),
      barcodeY + barcodeHeight + layout.mm(4),
    );
    final x = layout.marginDots;

    final buffer = StringBuffer()
      ..writeln('N')
      ..writeln('q${layout.widthDots}')
      ..writeln('Q${layout.heightDots},${layout.gapDots}');
    for (final textLine in _textLines(label.displayName, layout.nameChars)) {
      buffer.writeln('A$x,$nameY,0,3,1,1,N,"${_quoted(textLine)}"');
    }
    final detailText = _detailText(line);
    if (detailText.isNotEmpty) {
      buffer.writeln('A$x,$detailY,0,2,1,1,N,"${_quoted(detailText)}"');
    }
    buffer.writeln(
      'B$x,$barcodeY,0,1,2,4,$barcodeHeight,B,"${_quoted(_barcodeData(label.barcode))}"',
    );
    final sku = label.sku.trim();
    if (sku.isNotEmpty && skuY < layout.heightDots) {
      buffer.writeln('A$x,$skuY,0,2,1,1,N,"${_quoted(sku)}"');
    }
    buffer.writeln('P${line.copies}');
    return buffer.toString();
  }

  String _cpcl(BarcodeLabelPrintLine line, PrinterEndpoint endpoint) {
    final layout = _NativeLabelLayout(endpoint);
    final label = line.label;
    final nameY = layout.mm(2);
    final detailY = nameY + layout.mm(8);
    final barcodeY = math.max(layout.mm(15), detailY + layout.mm(5));
    final barcodeHeight = math.max(
      layout.mm(8),
      math.min(layout.mm(13), layout.heightDots - barcodeY - layout.mm(7)),
    );
    final skuY = math.min(
      layout.heightDots - layout.mm(5),
      barcodeY + barcodeHeight + layout.mm(4),
    );
    final x = layout.marginDots;

    final buffer = StringBuffer()
      ..writeln('! 0 200 200 ${layout.heightDots} ${line.copies}')
      ..writeln('PAGE-WIDTH ${layout.widthDots}')
      ..writeln('ENCODING UTF-8');
    for (final textLine in _textLines(label.displayName, layout.nameChars)) {
      buffer.writeln('TEXT 0 3 $x $nameY ${_cpclText(textLine)}');
    }
    final detailText = _detailText(line);
    if (detailText.isNotEmpty) {
      buffer.writeln('TEXT 0 2 $x $detailY ${_cpclText(detailText)}');
    }
    buffer.writeln(
      'BARCODE 128 2 1 $barcodeHeight $x $barcodeY ${_cpclText(_barcodeData(label.barcode))}',
    );
    final sku = label.sku.trim();
    if (sku.isNotEmpty && skuY < layout.heightDots) {
      buffer.writeln('TEXT 0 2 $x $skuY ${_cpclText(sku)}');
    }
    buffer
      ..writeln('FORM')
      ..writeln('PRINT');
    return buffer.toString();
  }

  String _detailText(BarcodeLabelPrintLine line) {
    final details = [
      if (line.includePrice) 'السعر ${_money(line.label.unitPrice)}',
      if (line.expiryDate != null) 'تاريخ الانتهاء ${_date(line.expiryDate!)}',
    ];
    return details.join('  |  ');
  }

  List<String> _textLines(String value, int width) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    if (normalized.length <= width) {
      return [normalized];
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
      if (lines.length == 2) {
        break;
      }
    }
    if (lines.length < 2 && current.isNotEmpty) {
      lines.add(current);
    }
    return lines.take(2).toList(growable: false);
  }

  String _zplText(String value) {
    return value.replaceAll('^', ' ').replaceAll('~', ' ');
  }

  String _quoted(String value) {
    return value.replaceAll('"', "'").replaceAll('\n', ' ').trim();
  }

  String _cpclText(String value) {
    return value.replaceAll('\n', ' ').trim();
  }

  String _barcodeData(String value) {
    return value.replaceAll(RegExp(r'[\r\n]'), '').trim();
  }

  String _money(double value) => '${value.toStringAsFixed(2)} د.ل';

  String _date(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}

class _NativeLabelLayout {
  _NativeLabelLayout(PrinterEndpoint endpoint)
    : widthMm = math.max(20, endpoint.labelWidthMm),
      heightMm = math.max(15, endpoint.labelHeightMm),
      gapMm = math.max(0, endpoint.labelGapMm),
      dpi = endpoint.labelDpi <= 0 ? 203 : endpoint.labelDpi;

  final int widthMm;
  final int heightMm;
  final int gapMm;
  final int dpi;

  int get widthDots => mm(widthMm);

  int get heightDots => mm(heightMm);

  int get gapDots => mm(gapMm);

  int get marginDots => mm(3);

  int get contentWidthDots => math.max(mm(12), widthDots - marginDots * 2);

  int get nameFontDots => math.max(20, math.min(34, mm(3.5)));

  int get detailFontDots => math.max(18, math.min(26, mm(2.7)));

  int get nameChars => widthMm <= 35 ? 16 : (widthMm <= 50 ? 22 : 30);

  int mm(num value) => math.max(0, (value * dpi / 25.4).round());
}
