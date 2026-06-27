import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../design/design.dart';

/// Renders [data] as a themed QR code. Shared so download/pairing screens draw a
/// consistent code without each re-implementing the painter.
class PointyQrImage extends StatelessWidget {
  const PointyQrImage({
    super.key,
    required this.data,
    this.size = 220,
    this.semanticsLabel,
  });

  final String data;
  final double size;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final qrImage = QrImage(
      QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    final colors = context.pointyColors;
    final image = CustomPaint(
      size: Size.square(size),
      painter: _PointyQrPainter(
        qrImage: qrImage,
        foreground: colors.ink,
        background: colors.surface,
      ),
    );
    if (semanticsLabel == null) {
      return image;
    }
    return Semantics(label: semanticsLabel, image: true, child: image);
  }
}

class _PointyQrPainter extends CustomPainter {
  const _PointyQrPainter({
    required this.qrImage,
    required this.foreground,
    required this.background,
  });

  final QrImage qrImage;
  final Color foreground;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    const quietZone = 4;
    final moduleCount = qrImage.moduleCount;
    final totalModules = moduleCount + quietZone * 2;
    final moduleSize = size.shortestSide / totalModules;
    final backgroundPaint = Paint()..color = background;
    final foregroundPaint = Paint()..color = foreground;

    canvas.drawRect(Offset.zero & size, backgroundPaint);
    for (var row = 0; row < moduleCount; row += 1) {
      for (var col = 0; col < moduleCount; col += 1) {
        if (!qrImage.isDark(row, col)) {
          continue;
        }
        canvas.drawRect(
          Rect.fromLTWH(
            (col + quietZone) * moduleSize,
            (row + quietZone) * moduleSize,
            moduleSize,
            moduleSize,
          ),
          foregroundPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PointyQrPainter oldDelegate) {
    return oldDelegate.qrImage != qrImage ||
        oldDelegate.foreground != foreground ||
        oldDelegate.background != background;
  }
}
