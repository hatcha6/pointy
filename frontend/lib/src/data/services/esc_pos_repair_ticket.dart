part of 'esc_pos_receipt_encoder.dart';

/// The repair intake receipt on a raw ESC/POS printer: what was left with the
/// shop, by whom, how to get it back, and a barcode the counter scans to find
/// the job again.
///
/// The payload arrives fully worded and formatted (see
/// `PrintingRepository.printRepairTicket`), so this only lays it out, on the
/// same masthead, text path and cut sequence as the sale receipt.
extension on EscPosReceiptEncoder {
  List<int> _encodeRepairTicket({
    required Map<String, Object?> payload,
    required PrinterEndpoint endpoint,
    required Generator generator,
    required String? codeTable,
    bool dense = false,
    Uint8List? brandLogoBytes,
  }) {
    final shop = _map(payload['shop']);
    final ticket = _map(payload['ticket']);
    final width = _charsPerLine(endpoint.paperWidthMm);
    final fineWidth = _charsPerLine(endpoint.paperWidthMm, dense: true);
    final bytes = <int>[];

    PosStyles styles({
      PosAlign align = PosAlign.right,
      bool bold = false,
      PosTextSize textHeight = PosTextSize.size1,
      PosTextSize textWidth = PosTextSize.size1,
      PosFontType fontType = PosFontType.fontA,
    }) {
      // Every line names its font. The generator only switches font when told
      // to, so a line that left it null would inherit the fine print's Font B.
      return PosStyles(
        align: align,
        bold: bold,
        height: textHeight,
        width: textWidth,
        fontType: fontType,
        codeTable: codeTable,
      );
    }

    void line(String text, PosStyles lineStyles, {int wrapAt = 0}) {
      for (final wrapped in _wrap(text, wrapAt <= 0 ? width : wrapAt)) {
        bytes.addAll(_text(generator, wrapped, styles: lineStyles));
      }
    }

    // `label: value` on one line when it fits; otherwise the label, then the
    // value whole on a line of its own. Word-wrapping the pair would split a
    // date from its time, or an amount from its currency.
    void ticketRow(String label, String value, {bool emphasize = false}) {
      final rowStyles = styles(bold: emphasize);
      final joined = '$label: $value';
      if (joined.length <= width || value.isEmpty) {
        line(joined, rowStyles);
        return;
      }
      line('$label:', rowStyles);
      line(value, rowStyles);
    }

    bytes.addAll(
      _shopMasthead(generator, shop, codeTable, width, dense: dense),
    );
    final shopPhone = _string(ticket['shop_phone_line']);
    if (shopPhone.isNotEmpty) {
      line(shopPhone, styles(align: PosAlign.center));
    }

    // The heading block: what this slip is, and the number it is found by —
    // big enough to read aloud across a counter, with the barcode under it.
    bytes.addAll(generator.hr());
    line(
      _string(ticket['title'], fallback: 'إيصال استلام جهاز'),
      styles(
        align: PosAlign.center,
        bold: true,
        textHeight: _emphasisHeight(dense),
      ),
    );
    final jobNumber = _string(ticket['job_number']);
    if (jobNumber.isNotEmpty) {
      // Double width only when the number still fits on one line at that
      // size: a job number broken across two lines is a number misread.
      final wide = jobNumber.length * 2 <= width;
      line(
        jobNumber,
        styles(
          align: PosAlign.center,
          bold: true,
          textHeight: PosTextSize.size2,
          textWidth: wide ? PosTextSize.size2 : PosTextSize.size1,
        ),
      );
    }
    bytes.addAll(
      _repairTicketBarcode(
        generator,
        _string(ticket['scan_code'], fallback: jobNumber),
        endpoint.paperWidthMm,
        dense: dense,
      ),
    );
    final scanHint = _string(ticket['scan_hint']);
    if (scanHint.isNotEmpty) {
      line(scanHint, styles(align: PosAlign.center));
    }

    final details = _list(ticket['details']);
    if (details.isNotEmpty) {
      bytes.addAll(generator.hr());
      for (final raw in details) {
        final row = _map(raw);
        ticketRow(
          _string(row['label']),
          _string(row['value']),
          emphasize: row['emphasize'] == true,
        );
      }
    }

    // Customer, device, fault: a bold heading over its lines, one block each.
    for (final raw in _list(ticket['sections'])) {
      final section = _map(raw);
      final lines = [
        for (final text in _list(section['lines']))
          if (_string(text).trim().isNotEmpty) _string(text).trim(),
      ];
      if (lines.isEmpty) {
        continue;
      }
      bytes.addAll(generator.hr());
      line(_string(section['title']), styles(bold: true));
      for (var index = 0; index < lines.length; index++) {
        // The first line is the one that identifies: the customer's name, the
        // device's model. It is set bold so the eye finds it first.
        line(lines[index], styles(bold: index == 0 && section['lead'] == true));
      }
    }

    final money = _list(ticket['money']);
    if (money.isNotEmpty) {
      bytes.addAll(generator.hr());
      for (final raw in money) {
        final row = _map(raw);
        ticketRow(
          _string(row['label']),
          _string(row['value']),
          emphasize: row['emphasize'] == true,
        );
      }
    }

    // The conditions are fine print: Font B fits a third more on a line, and
    // on a slip the customer files away that is paper worth saving.
    final terms = [
      for (final text in _list(ticket['terms']))
        if (_string(text).trim().isNotEmpty) _string(text).trim(),
    ];
    if (terms.isNotEmpty) {
      bytes.addAll(generator.hr());
      line(
        _string(ticket['terms_title'], fallback: 'الشروط'),
        styles(bold: true),
      );
      for (var index = 0; index < terms.length; index++) {
        line(
          '${index + 1}. ${terms[index]}',
          styles(fontType: PosFontType.fontB),
          wrapAt: fineWidth,
        );
      }
    }

    bytes.addAll(generator.hr());
    final receivedBy = _string(ticket['received_by']);
    if (receivedBy.isNotEmpty) {
      line(receivedBy, styles());
    }
    final signature = _string(ticket['signature_label']);
    if (signature.isNotEmpty) {
      if (!dense) {
        bytes.addAll(generator.feed(1));
      }
      // Room to sign: the label, then a rule to the edge of the paper.
      final rule = '_' * math.max(8, width - signature.length - 2);
      line('$signature: $rule', styles());
    }

    bytes.addAll(_shopFooter(generator, shop, codeTable, width, dense: dense));
    bytes.addAll(
      _brandTagline(generator, codeTable, brandLogoBytes, dense: dense),
    );
    bytes.addAll(_finishTicket(generator, endpoint));
    return bytes;
  }

  /// The job's barcode as a native `GS k` Code 128 symbol.
  ///
  /// Code 128 over `GS k` does not choose its own alphabets: the data names
  /// them. Left to the one alphabet the label path uses (`{B`), a job's date
  /// and id cost a symbol per digit; [escPosCode128Data] packs runs of digits
  /// two to a symbol instead, which is what lets the bars stay two dots wide
  /// on a 58 mm roll. The widest bar that still fits the paper, quiet zones
  /// included, is chosen — wider bars are simply easier to scan.
  List<int> _repairTicketBarcode(
    Generator generator,
    String value,
    int paperWidthMm, {
    required bool dense,
  }) {
    final code = value.trim();
    if (code.isEmpty ||
        !code.codeUnits.every((unit) => unit >= 0x20 && unit <= 0x7E)) {
      return const [];
    }
    final data = escPosCode128Data(code);
    final modules = escPosCode128Modules(data);
    final printableDots = paperWidthMm <= 58
        ? 384
        : paperWidthMm <= 72
        ? 512
        : 576;
    var barWidth = 3;
    // Ten modules of quiet zone either side, so a scanner sees where it ends.
    while (barWidth > 1 && (modules + 20) * barWidth > printableDots) {
      barWidth--;
    }
    return [
      if (!dense) ...generator.feed(1),
      ...generator.barcode(
        Barcode.code128(data),
        width: barWidth,
        height: dense ? 56 : 72,
        textPos: BarcodeText.none,
      ),
      ...generator.feed(1),
    ];
  }
}

/// `GS k` Code 128 data for [value]: `{B` for text, `{C` for runs of four or
/// more digits, packed two to a symbol (each pair sent as one byte, 0–99).
///
/// An odd run keeps its first digit in B, so the pairs line up behind it.
@visibleForTesting
List<String> escPosCode128Data(String value) {
  final data = <String>[];
  String? current;
  void use(String set) {
    if (current != set) {
      data
        ..add('{')
        ..add(set);
      current = set;
    }
  }

  bool isDigit(int index) {
    final unit = value.codeUnitAt(index);
    return unit >= 0x30 && unit <= 0x39;
  }

  var index = 0;
  while (index < value.length) {
    var end = index;
    while (end < value.length && isDigit(end)) {
      end++;
    }
    final run = end - index;
    final wholeValue = index == 0 && end == value.length;
    if (run >= 4 || (wholeValue && run >= 2)) {
      var start = index;
      if (run.isOdd) {
        use('B');
        data.add(value[index]);
        start++;
      }
      use('C');
      for (var pair = start; pair < end; pair += 2) {
        data.add(
          String.fromCharCode(int.parse(value.substring(pair, pair + 2))),
        );
      }
      index = end;
      continue;
    }
    use('B');
    data.add(value[index]);
    index++;
  }
  return data;
}

/// How many modules wide [data] (from [escPosCode128Data]) prints: eleven per
/// symbol — each code-set switch included, the first being the start code —
/// plus the check symbol and the thirteen-module stop.
@visibleForTesting
int escPosCode128Modules(List<String> data) {
  var symbols = 0;
  for (var index = 0; index < data.length; index++) {
    if (data[index] == '{' && index + 1 < data.length) {
      index++;
    }
    symbols++;
  }
  return (symbols + 1) * 11 + 13;
}
