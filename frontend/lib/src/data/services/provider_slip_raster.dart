/// A provider's slip drawn in a thermal printer's own dots.
///
/// ESC/POS prints text a line at a time, and a line of text cannot sit beside
/// a picture, so a slip printed as text stacks everything — logo, title, PIN,
/// QR code, dial string, facts — one under the other: a hand's length of
/// paper for one card. Drawn as one picture, the slip is laid out like a
/// card: the logo beside the title, the QR code beside the PIN, short facts
/// two to a line. That is about half the paper, and its Arabic is shaped by
/// the app's own font instead of by whatever the printer's firmware does
/// with it.
///
/// Every dot is black or white, as the head prints it. The QR code is not
/// drawn by the canvas at all: its modules are stamped into the finished dots
/// whole, the way [escPosQrRaster] packs a code on its own, so no smoothing
/// can shave a module.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../shared/design/pointy_typography.dart';
import '../../shared/printing/print_qr_code.dart';
import 'receipt_provider_slips.dart';

/// One slip as a thermal head prints it: [height] rows of [width] dots.
class ProviderSlipRaster {
  ProviderSlipRaster({
    required this.width,
    required this.height,
    required this.bits,
    this.qr,
  }) : assert(width % 8 == 0),
       assert(bits.length == width ~/ 8 * height);

  /// Dots across; a whole number of bytes.
  final int width;
  final int height;

  /// Row after row, eight dots a byte, the leftmost dot in the high bit and a
  /// set bit printed: what `GS v 0` takes.
  final Uint8List bits;

  /// Where the QR code was stamped, quiet zone included; null with no code.
  final ProviderSlipQrSpot? qr;

  bool dot(int x, int y) =>
      bits[y * (width >> 3) + (x >> 3)] & (0x80 >> (x & 7)) != 0;
}

/// Where a slip's QR code sits: its top-left corner, quiet zone included.
class ProviderSlipQrSpot {
  const ProviderSlipQrSpot({
    required this.left,
    required this.top,
    required this.moduleDots,
    required this.code,
  });

  final int left;
  final int top;
  final int moduleDots;
  final PrintQrCode code;

  /// The side of the square, quiet zone included.
  int get side => code.moduleCountWithQuietZone * moduleDots;
}

/// Draws provider slips for the thermal receipt.
///
/// Needs the Flutter engine, so it runs before the encoder's background
/// isolate, and it is best-effort: null means "print the slips as text".
class ProviderSlipRasterizer {
  const ProviderSlipRasterizer({this.fontFamily = PointyTypography.fontFamily});

  final String fontFamily;

  /// A raster per slip, in order, [widthDots] wide; null when there is
  /// nothing to draw or drawing failed.
  Future<List<ProviderSlipRaster>?> render(
    List<ReceiptProviderSlip> slips, {
    required int widthDots,
    required bool dense,
  }) async {
    if (slips.isEmpty) {
      return null;
    }
    try {
      return [
        for (final slip in slips)
          await renderSlip(slip, widthDots: widthDots, dense: dense),
      ];
    } on Object {
      return null;
    }
  }

  Future<ProviderSlipRaster> renderSlip(
    ReceiptProviderSlip slip, {
    required int widthDots,
    required bool dense,
  }) async {
    final logo = await _decodeLogo(receiptSlipLogoBytes(slip));
    final mark = await _decodeLogo(receiptSlipProviderLogoBytes(slip));
    final layout = _SlipLayout(
      slip,
      width: widthDots ~/ 8 * 8,
      metrics: dense ? _Metrics.dense : _Metrics.normal,
      fontFamily: fontFamily,
      logo: logo,
      mark: mark,
    );
    try {
      return await layout.rasterize();
    } finally {
      layout.dispose();
      logo?.dispose();
      mark?.dispose();
    }
  }
}

/// Draws nothing, so the thermal receipt prints its slips as text.
class TextOnlySlipRasterizer extends ProviderSlipRasterizer {
  const TextOnlySlipRasterizer();

  @override
  Future<List<ProviderSlipRaster>?> render(
    List<ReceiptProviderSlip> slips, {
    required int widthDots,
    required bool dense,
  }) async => null;
}

/// [raster] as `GS v 0` images of at most [bandRows] rows each, stacked.
///
/// A slip is a few hundred rows; a cheap printer with a small buffer can
/// choke on one image that size, and stacked bands print as one.
List<int> escPosSlipRaster(ProviderSlipRaster raster, {int bandRows = 256}) {
  final widthBytes = raster.width >> 3;
  final bytes = <int>[];
  for (var top = 0; top < raster.height; top += bandRows) {
    final rows = math.min(bandRows, raster.height - top);
    bytes
      ..addAll([
        0x1D, 0x76, 0x30, 0x00, // GS v 0, normal density
        widthBytes & 0xFF, widthBytes >> 8,
        rows & 0xFF, rows >> 8,
      ])
      ..addAll(
        Uint8List.sublistView(
          raster.bits,
          top * widthBytes,
          (top + rows) * widthBytes,
        ),
      );
  }
  return bytes;
}

/// [text] with every run of digits joined by `-`, `/`, `:` or `.` held left
/// to right. After an Arabic word the bidi algorithm reads such digits as
/// Arabic numbers, which a hyphen does not join, so `2026-09-20` would print
/// as `20-09-2026`. The slip's own strings carry no isolates (a thermal code
/// page cannot encode them); only the drawing adds them.
String _isolateNumbers(String text) =>
    text.replaceAllMapped(_numberRun, (match) => '\u2066${match[0]}\u2069');

final RegExp _numberRun = RegExp(r'[0-9]+(?:[-/:.][0-9]+)+');

/// A `label: value` row whose value is only Latin letters, digits and
/// punctuation — a phone number, a network's Latin name, `5,000 XOF` — with
/// that value held left to right as one piece. Inside an Arabic line the
/// bidi algorithm would otherwise put a number's `+` on the wrong side and
/// turn `5,000 XOF` around.
String _isolateLatinValue(String text) {
  final match = _latinValueRow.firstMatch(text);
  if (match == null) {
    return text;
  }
  return '${match[1]}: \u{2066}${match[2]}\u{2069}';
}

final RegExp _latinValueRow = RegExp(r'^(.*?): ([\x20-\x7E]+)$');

Future<ui.Image?> _decodeLogo(Uint8List? bytes) async {
  if (bytes == null) {
    return null;
  }
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } on Object {
    // A logo that cannot be drawn costs the slip its logo, never the slip.
    return null;
  }
}

/// Sizes in printer dots (8 a millimetre). Text is bold throughout, as the
/// roll PDF prints it: a 203-dpi head drops the thin strokes of a regular
/// face, Arabic's first. Hierarchy is size alone.
class _Metrics {
  const _Metrics({
    required this.logoHeight,
    required this.markHeight,
    required this.title,
    required this.notice,
    required this.label,
    required this.pin,
    required this.dial,
    required this.fact,
    required this.small,
    required this.qrModuleDots,
    required this.qrStackedModuleDots,
  });

  final double logoHeight;

  /// The provider's mark beside a card's brand logo: a signature, not a
  /// second masthead.
  final double markHeight;
  final double title;
  final double notice;
  final double label;
  final double pin;
  final double dial;
  final double fact;
  final double small;

  /// The biggest module the QR code gets. Eight dots is a millimetre: twice
  /// the usual receipt code, and still a two-dot margin around a dead heating
  /// element's white line on either side.
  final int qrModuleDots;

  /// A code alone under the PIN takes the slip's whole width, so it is kept
  /// a size smaller: still half as big again as a usual receipt code.
  final int qrStackedModuleDots;

  static const normal = _Metrics(
    logoHeight: 72,
    markHeight: 40,
    title: 29,
    notice: 26,
    label: 21,
    pin: 50,
    dial: 32,
    fact: 22,
    small: 20,
    qrModuleDots: 8,
    qrStackedModuleDots: 6,
  );

  static const dense = _Metrics(
    logoHeight: 56,
    markHeight: 32,
    title: 26,
    notice: 24,
    label: 20,
    pin: 44,
    dial: 28,
    fact: 21,
    small: 20,
    qrModuleDots: 7,
    qrStackedModuleDots: 5,
  );

  static const double border = 3;
  static const double radius = 14;
  static const double padX = 14;
  static const double padY = 12;
  static const double gap = 12;

  /// A PIN or dial string shrinks to fit its column, never below these: a
  /// PIN in a size nobody can read is worse than a taller slip.
  static const double pinMin = 30;
  static const double dialMin = 22;

  /// The smallest module a code sits beside anything at, and the smallest it
  /// prints at all.
  static const int qrBesideMinDots = 5;
  static const int qrMinDots = 4;

  /// The most of the slip's width a code beside the text may take.
  static const double qrShare = 0.52;

  /// Grey at or below this prints: a little darker than half, so the edge
  /// of a bold stroke keeps its dot.
  static const int inkLevel = 150;
}

class _Placed {
  const _Placed(this.painter, this.offset);

  final TextPainter painter;
  final Offset offset;
}

class _SlipLayout {
  _SlipLayout(
    this.slip, {
    required this.width,
    required this.metrics,
    required this.fontFamily,
    required this.logo,
    required this.mark,
  });

  final ReceiptProviderSlip slip;
  final int width;
  final _Metrics metrics;
  final String fontFamily;
  final ui.Image? logo;
  final ui.Image? mark;

  final List<TextPainter> _painters = [];
  final List<_Placed> _texts = [];
  final List<Rect> _rules = [];
  Rect? _logoRect;
  Rect? _markRect;
  ProviderSlipQrSpot? _qr;

  double get _left => _Metrics.border + _Metrics.padX;
  double get _right => width - _Metrics.border - _Metrics.padX;
  double get _inner => _right - _left;

  TextPainter _text(
    String value,
    double size, {
    double? maxWidth,
    TextAlign align = TextAlign.right,
    TextDirection direction = TextDirection.rtl,
    int? maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: direction == TextDirection.rtl
            ? _isolateNumbers(_isolateLatinValue(value))
            : value,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: size,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF000000),
          height: 1.25,
        ),
      ),
      textAlign: align,
      textDirection: direction,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth ?? _inner);
    _painters.add(painter);
    return painter;
  }

  /// [value] left to right on one line, as big as [size] allows in [room]
  /// and no smaller than [minimum]; null when it does not fit even then.
  TextPainter? _unbroken(
    String value,
    double size,
    double minimum,
    double room,
  ) {
    var fontSize = size;
    while (fontSize >= minimum) {
      final painter = _text(
        value,
        fontSize,
        maxWidth: double.infinity,
        direction: TextDirection.ltr,
        align: TextAlign.left,
      );
      if (painter.width <= room) {
        return painter;
      }
      fontSize = math.min(fontSize - 1, (fontSize * room / painter.width));
      fontSize = fontSize.floorToDouble();
    }
    return null;
  }

  void _place(TextPainter painter, double x, double y) =>
      _texts.add(_Placed(painter, Offset(x, y)));

  /// Right-aligned: in Arabic the reading edge.
  void _placeRight(TextPainter painter, double right, double y) =>
      _place(painter, right - painter.width, y);

  void _placeCentered(TextPainter painter, double centre, double y) =>
      _place(painter, centre - painter.width / 2, y);

  /// Lays the slip out top to bottom; returns its height.
  double _layOut() {
    var y = _Metrics.border + _Metrics.padY;
    y = _header(y);
    final hasBody =
        slip.notice.isNotEmpty ||
        slip.pin.isNotEmpty ||
        slip.dial.isNotEmpty ||
        slip.rows.isNotEmpty;
    if (hasBody) {
      y += _Metrics.gap * 0.75;
      _rules.add(Rect.fromLTWH(_left, y.roundToDouble(), _inner, 2));
      y += 2 + _Metrics.gap * 0.75;
    }
    if (slip.notice.isNotEmpty) {
      final notice = _text(
        slip.notice,
        metrics.notice,
        align: TextAlign.center,
      );
      _placeCentered(notice, _left + _inner / 2, y);
      y += notice.height;
    }
    y = _body(y);
    return (y + _Metrics.padY + _Metrics.border).ceilToDouble();
  }

  /// The logo at the reading edge, the title beside it, and a card's
  /// provider's mark at the far edge; the title centred when there is no
  /// logo.
  double _header(double top) {
    final (logoWidth, logoHeight) = _fit(logo, metrics.logoHeight, 0.4);
    final (markWidth, markHeight) = _fit(mark, metrics.markHeight, 0.22);
    final room =
        _inner -
        (logoWidth > 0 ? logoWidth + _Metrics.gap : 0) -
        (markWidth > 0 ? markWidth + _Metrics.gap : 0);
    final title = _text(
      slip.title,
      metrics.title,
      maxWidth: room,
      maxLines: 3,
      align: logo == null ? TextAlign.center : TextAlign.right,
    );
    final height = [logoHeight, markHeight, title.height].reduce(math.max);
    double middle(double of) => (top + (height - of) / 2).roundToDouble();
    if (logoWidth > 0) {
      _logoRect = Rect.fromLTWH(
        _right - logoWidth,
        middle(logoHeight),
        logoWidth,
        logoHeight,
      );
    }
    if (markWidth > 0) {
      _markRect = Rect.fromLTWH(
        _left,
        middle(markHeight),
        markWidth,
        markHeight,
      );
    }
    if (logoWidth > 0) {
      _placeRight(
        title,
        _right - logoWidth - _Metrics.gap,
        top + (height - title.height) / 2,
      );
    } else {
      _placeCentered(
        title,
        _left + _inner / 2,
        top + (height - title.height) / 2,
      );
    }
    return top + height;
  }

  /// [image] scaled into [maxHeight] dots tall and [share] of the slip's
  /// width, never past twice its size; (0, 0) for none.
  (double, double) _fit(ui.Image? image, double maxHeight, double share) {
    if (image == null) {
      return (0, 0);
    }
    final scale = math.min(
      2.0,
      math.min(maxHeight / image.height, _inner * share / image.width),
    );
    return (
      (image.width * scale).roundToDouble(),
      (image.height * scale).roundToDouble(),
    );
  }

  /// The PIN, its dial string, its QR code and the slip's facts, as tight as
  /// they still read well: all of it beside the code while the PIN keeps a
  /// good size in what is left; else the PIN across the top and the code
  /// beside the rest; else one under the other.
  double _body(double top) {
    final data = slip.qrData;
    final code = data == null ? null : PrintQrCode.tryEncode(data);
    if (code == null) {
      return _facts(_redeemLines(top, printsCode: false), slip.rows);
    }
    final modules = code.moduleCountWithQuietZone;
    int? largest;
    for (
      var dots = metrics.qrModuleDots;
      dots >= _Metrics.qrBesideMinDots;
      dots--
    ) {
      final side = modules * dots;
      if (side > _inner * _Metrics.qrShare) {
        continue;
      }
      largest ??= dots;
      final lead = _leadLines(_inner - side - _Metrics.gap);
      if (lead != null) {
        return _besideCode(top, code, dots, lead);
      }
    }
    if (largest != null) {
      // The PIN would shrink too far beside the code: it goes across the
      // top, and the code sits beside the rest.
      final y = _redeemLines(top, printsCode: true);
      return _besideCode(y + _Metrics.gap / 2, code, largest, const []);
    }
    return _stacked(top, code);
  }

  /// The PIN and dial string with their labels, [room] wide, for the column
  /// beside the code; null when either would shrink below a readable size.
  List<TextPainter>? _leadLines(double room) {
    final lines = <TextPainter>[];
    if (slip.pin.isNotEmpty) {
      final pin = _unbroken(slip.pin, metrics.pin, _Metrics.pinMin, room);
      if (pin == null) {
        return null;
      }
      lines
        ..add(_text(slip.pinLabel, metrics.label, maxWidth: room))
        ..add(pin);
    }
    if (slip.dial.isNotEmpty) {
      final dial = _unbroken(slip.dial, metrics.dial, _Metrics.dialMin, room);
      if (dial == null) {
        return null;
      }
      lines
        ..add(_text(receiptOrDial, metrics.label, maxWidth: room))
        ..add(dial);
    }
    return lines;
  }

  /// The PIN and dial string across the slip, centred.
  double _redeemLines(double top, {required bool printsCode}) {
    final centre = _left + _inner / 2;
    var y = top;
    void line(TextPainter painter) {
      _placeCentered(painter, centre, y);
      y += painter.height;
    }

    if (slip.pin.isNotEmpty) {
      line(_text(slip.pinLabel, metrics.label));
      line(
        _unbroken(slip.pin, metrics.pin, 12, _inner) ??
            _text(slip.pin, metrics.fact, direction: TextDirection.ltr),
      );
    }
    if (slip.dial.isNotEmpty) {
      line(
        _text(printsCode ? receiptOrDial : receiptDialToRedeem, metrics.label),
      );
      line(
        _unbroken(slip.dial, metrics.dial, 12, _inner) ??
            _text(slip.dial, metrics.fact, direction: TextDirection.ltr),
      );
    }
    return y;
  }

  /// The code at the far edge; beside it, on the reading side, [lead], what
  /// scanning it does, and as many of the facts as fit its height. The rest
  /// of the facts go under both.
  double _besideCode(
    double top,
    PrintQrCode code,
    int dots,
    List<TextPainter> lead,
  ) {
    final side = (code.moduleCountWithQuietZone * dots).toDouble();
    final room = _inner - side - _Metrics.gap;
    final column = <(TextPainter, double)>[
      for (final line in lead) (line, 0),
      (
        _text(slip.qrCaption, metrics.small, maxWidth: room),
        lead.isEmpty ? 0 : _Metrics.gap / 2,
      ),
    ];
    double height() =>
        column.fold(0, (sum, item) => sum + item.$1.height + item.$2);
    var beside = 0;
    for (final row in slip.rows) {
      final fact = _columnFact(row, room);
      if (fact == null || height() + fact.height > side) {
        break;
      }
      column.add((fact, 0));
      beside++;
    }
    final rowHeight = math.max(side, height());
    var y = top + (rowHeight - height()) / 2;
    for (final (painter, before) in column) {
      y += before;
      _placeRight(painter, _right, y);
      y += painter.height;
    }
    _qr = ProviderSlipQrSpot(
      left: _left.round(),
      top: (top + (rowHeight - side) / 2).round(),
      moduleDots: dots,
      code: code,
    );
    return _facts(top + rowHeight, slip.rows.sublist(beside));
  }

  /// [row] wrapped to [room], on two lines at most; null when it needs more.
  TextPainter? _columnFact(String row, double room) {
    for (final size in [metrics.fact, metrics.small]) {
      final painter = _text(row, size, maxWidth: room);
      if (painter.computeLineMetrics().length <= 2) {
        return painter;
      }
    }
    return null;
  }

  /// PIN, code, dial string and facts one under the other, centred: the
  /// code too big to sit beside anything.
  double _stacked(double top, PrintQrCode code) {
    final centre = _left + _inner / 2;
    var y = _redeemLines(top, printsCode: true);
    final modules = code.moduleCountWithQuietZone;
    final dots = math.min(metrics.qrStackedModuleDots, _inner ~/ modules);
    if (dots >= _Metrics.qrMinDots) {
      final side = modules * dots;
      _qr = ProviderSlipQrSpot(
        left: (centre - side / 2).round(),
        top: (y + _Metrics.gap / 2).round(),
        moduleDots: dots,
        code: code,
      );
      y += _Metrics.gap / 2 + side;
      final caption = _text(
        slip.qrCaption,
        metrics.small,
        align: TextAlign.center,
      );
      _placeCentered(caption, centre, y);
      y += caption.height;
    }
    return _facts(y, slip.rows);
  }

  /// Short facts two to a line, as the invoice header pairs its own: the
  /// first at the reading edge, the second across from it at the far edge. A
  /// long one (a provider's help line) keeps a line to itself, smaller.
  double _facts(double top, List<String> rows) {
    if (rows.isEmpty) {
      return top;
    }
    var y = top + _Metrics.gap / 2;
    var i = 0;
    while (i < rows.length) {
      final first = _text(rows[i], metrics.fact, maxWidth: double.infinity);
      if (i + 1 < rows.length) {
        final second = _text(
          rows[i + 1],
          metrics.fact,
          maxWidth: double.infinity,
        );
        if (first.width + 2 * _Metrics.gap + second.width <= _inner) {
          _placeRight(first, _right, y);
          _place(second, _left, y);
          y += math.max(first.height, second.height);
          i += 2;
          continue;
        }
      }
      final whole = first.width <= _inner
          ? first
          : _text(rows[i], metrics.small);
      _placeRight(whole, _right, y);
      y += whole.height;
      i++;
    }
    return y;
  }

  Future<ProviderSlipRaster> rasterize() async {
    final height = _layOut().toInt();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final ink = Paint()..color = const Color(0xFF000000);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    const border = _Metrics.border;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(border / 2, border / 2, width - border, height - border),
        const Radius.circular(_Metrics.radius),
      ),
      Paint()
        ..color = const Color(0xFF000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = border,
    );
    for (final rule in _rules) {
      canvas.drawRect(rule, ink);
    }
    for (final (image, rect) in [(logo, _logoRect), (mark, _markRect)]) {
      if (image != null && rect != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          rect,
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
    }
    for (final text in _texts) {
      text.painter.paint(canvas, text.offset);
    }
    final picture = recorder.endRecording();
    final drawn = await picture.toImage(width, height);
    picture.dispose();
    final ByteData? rgba;
    try {
      rgba = await drawn.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      drawn.dispose();
    }
    if (rgba == null) {
      throw StateError('the slip could not be read back');
    }
    final widthBytes = width >> 3;
    final bits = Uint8List(widthBytes * height);
    final pixels = rgba.buffer.asUint8List(
      rgba.offsetInBytes,
      rgba.lengthInBytes,
    );
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        // Over white, so a half-covered edge pixel is a grey to judge.
        final alpha = pixels[i + 3];
        final luminance =
            (pixels[i] * 299 + pixels[i + 1] * 587 + pixels[i + 2] * 114) ~/
            1000;
        final level = 255 - ((255 - luminance) * alpha ~/ 255);
        if (level <= _Metrics.inkLevel) {
          bits[y * widthBytes + (x >> 3)] |= 0x80 >> (x & 7);
        }
      }
    }
    final qr = _qr;
    if (qr != null) {
      _stampQr(bits, widthBytes, qr);
    }
    return ProviderSlipRaster(width: width, height: height, bits: bits, qr: qr);
  }

  /// The code's square, quiet zone and all, written over whatever is there:
  /// blank paper, then its dark modules in whole dots.
  void _stampQr(Uint8List bits, int widthBytes, ProviderSlipQrSpot qr) {
    final code = qr.code;
    final dots = qr.moduleDots;
    for (var y = 0; y < qr.side; y++) {
      final row = y ~/ dots - PrintQrCode.quietZone;
      for (var x = 0; x < qr.side; x++) {
        final column = x ~/ dots - PrintQrCode.quietZone;
        final dark =
            row >= 0 &&
            column >= 0 &&
            row < code.moduleCount &&
            column < code.moduleCount &&
            code.isDark(row, column);
        final px = qr.left + x;
        final index = (qr.top + y) * widthBytes + (px >> 3);
        final mask = 0x80 >> (px & 7);
        bits[index] = dark ? bits[index] | mask : bits[index] & ~mask;
      }
    }
  }

  void dispose() {
    for (final painter in _painters) {
      painter.dispose();
    }
  }
}
