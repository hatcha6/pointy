import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/models/catalog.dart';
import '../../shared/card_art.dart';

/// A code as a grid of QR modules, with the room cleared at its centre for the
/// brand's mark.
class QrGrid {
  QrGrid._(this.modules, this.cleared, this._dark);

  /// Null for a code too long for a QR.
  static QrGrid? of(String data) {
    final result = QrValidator.validate(
      data: data,
      errorCorrectionLevel: QrErrorCorrectLevel.H,
    );
    final code = result.qrCode;
    if (!result.isValid || code == null) {
      return null;
    }
    final QrImage image;
    try {
      image = QrImage(code);
    } on Exception {
      return null;
    }
    final modules = code.moduleCount;
    return QrGrid._(modules, _clearedFor(modules), [
      for (var row = 0; row < modules; row++)
        for (var column = 0; column < modules; column++)
          image.isDark(row, column),
    ]);
  }

  /// The mark's share of the code's width. The highest error correction
  /// survives about 30% of the code lost; this clears a small fraction of it,
  /// well clear of what scanners tolerate.
  static const double markShare = 0.24;

  /// Whole modules, and an odd number, as a grid's centre is one: the mark
  /// sits in a clean hole, with no dot sliced by its edge.
  static int _clearedFor(int modules) {
    final wanted = (modules * markShare).round();
    return wanted.isOdd ? wanted : wanted + 1;
  }

  final int modules;

  /// The width of the hole at the centre, in modules.
  final int cleared;
  final List<bool> _dark;

  bool isDark(int row, int column) =>
      row >= 0 &&
      column >= 0 &&
      row < modules &&
      column < modules &&
      _dark[row * modules + column] &&
      !_inHole(row, column);

  bool _inHole(int row, int column) {
    final from = (modules - cleared) ~/ 2;
    final to = from + cleared;
    return row >= from && row < to && column >= from && column < to;
  }

  /// One of the three big squares a scanner finds the code by.
  bool isFinder(int row, int column) {
    final nearEnd = modules - 7;
    return (row < 7 && column < 7) ||
        (row < 7 && column >= nearEnd) ||
        (row >= nearEnd && column < 7);
  }

  /// The dots and finders as one shape, one unit to a module: scaled to any
  /// size, it is the same drawing.
  Path toPath() {
    // Even-odd for the finders' nested squares; the dots never overlap, so it
    // changes nothing for them.
    final dots = Path()..fillType = PathFillType.evenOdd;
    for (var row = 0; row < modules; row++) {
      for (var column = 0; column < modules; column++) {
        if (!isDark(row, column) || isFinder(row, column)) {
          continue;
        }
        // A corner rounds only where nothing joins it, so neighbours run
        // together and a scanner reads whole, solid modules.
        final up = isDark(row - 1, column);
        final down = isDark(row + 1, column);
        final left = isDark(row, column - 1);
        final right = isDark(row, column + 1);
        Radius corner(bool a, bool b) =>
            a || b ? Radius.zero : const Radius.circular(0.5);
        dots.addRRect(
          RRect.fromLTRBAndCorners(
            column.toDouble(),
            row.toDouble(),
            column + 1.0,
            row + 1.0,
            topLeft: corner(up, left),
            topRight: corner(up, right),
            bottomLeft: corner(down, left),
            bottomRight: corner(down, right),
          ),
        );
      }
    }
    final last = (modules - 7).toDouble();
    for (final at in [Offset.zero, Offset(last, 0), Offset(0, last)]) {
      dots.addPath(_finder, at);
    }
    return dots;
  }

  static final Path _finder = Path()
    ..addRRect(RRect.fromLTRBR(0, 0, 7, 7, const Radius.circular(1.9)))
    ..addRRect(RRect.fromLTRBR(1, 1, 6, 6, const Radius.circular(1.1)))
    ..addRRect(RRect.fromLTRBR(2, 2, 5, 5, const Radius.circular(0.9)));
}

/// The code for a camera to read, in the brand's own deep colour with its art
/// at the centre. Drawn from the modules at any size without rounding them to
/// the screen's pixels, so it is the same picture on the page and held up.
class CardQr extends StatefulWidget {
  const CardQr({
    super.key,
    required this.brand,
    required this.ink,
    required this.code,
    required this.label,
  });

  final CardBrand brand;
  final Color ink;
  final String code;
  final String label;

  @override
  State<CardQr> createState() => _CardQrState();
}

class _CardQrState extends State<CardQr> {
  late QrGrid? _grid = QrGrid.of(widget.code);
  late Path? _path = _grid?.toPath();

  @override
  void didUpdateWidget(CardQr old) {
    super.didUpdateWidget(old);
    if (old.code != widget.code) {
      _grid = QrGrid.of(widget.code);
      _path = _grid?.toPath();
    }
  }

  @override
  Widget build(BuildContext context) {
    final grid = _grid;
    final path = _path;
    if (grid == null || path == null) {
      return const SizedBox.shrink();
    }
    return Semantics(
      image: true,
      label: widget.label,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final module = constraints.maxWidth / grid.modules;
          // A hair inside its hole, so white still rings it.
          final mark = module * (grid.cleared - 0.7);
          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _QrPainter(path, grid.modules, widget.ink),
                  ),
                ),
              ),
              SizedBox.square(
                dimension: mark,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(mark * 0.22),
                  // The whole card's art made small and cropped, not laid out
                  // at this size: drawn art would cut its name short.
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: 160,
                      height: 160 / kCardAspect,
                      child: CardArtImage(brand: widget.brand),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.path, this.modules, this.ink);

  final Path path;
  final int modules;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / modules;
    canvas
      ..save()
      ..scale(scale)
      ..drawPath(path, Paint()..color = ink)
      ..restore();
  }

  @override
  bool shouldRepaint(_QrPainter old) =>
      old.path != path || old.ink != ink || old.modules != modules;
}
