import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:qr/qr.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/design/design.dart';

Future<void> showPublicInvoiceDialog({
  required BuildContext context,
  required SaleOrder order,
}) {
  final publicUrl = order.publicInvoiceUrl.trim();
  if (publicUrl.isEmpty) {
    return Future<void>.value();
  }

  return showDialog<void>(
    context: context,
    builder: (context) =>
        _PublicInvoiceDialog(order: order, publicUrl: publicUrl),
  );
}

class _PublicInvoiceDialog extends StatelessWidget {
  const _PublicInvoiceDialog({required this.order, required this.publicUrl});

  final SaleOrder order;
  final String publicUrl;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final receiptNumber = order.receiptNumber ?? '';

    return AlertDialog(
      icon: const Icon(Icons.qr_code_2_outlined),
      title: Text(l10n.publicInvoiceDialogTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              receiptNumber.isEmpty
                  ? l10n.publicInvoiceDialogSubtitle
                  : l10n.publicInvoiceDialogSubtitleWithReceipt(receiptNumber),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Center(child: _QrCodeImage(data: publicUrl, size: 220)),
            const SizedBox(height: 16),
            Text(l10n.publicInvoiceUrlLabel, style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: SelectableText(
                  publicUrl,
                  textDirection: TextDirection.ltr,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.closeButton),
        ),
        FilledButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: publicUrl));
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                SnackBar(content: Text(l10n.publicInvoiceUrlCopiedMessage)),
              );
          },
          icon: const Icon(Icons.copy_outlined),
          label: Text(l10n.copyPublicInvoiceUrlButton),
        ),
      ],
    );
  }
}

class _QrCodeImage extends StatelessWidget {
  const _QrCodeImage({required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final qrImage = QrImage(qrCode);
    final colors = context.pointyColors;

    return Semantics(
      label: AppLocalizations.of(context)!.publicInvoiceQrSemanticsLabel,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _QrCodePainter(
          qrImage: qrImage,
          foreground: colors.ink,
          background: colors.surface,
        ),
      ),
    );
  }
}

class _QrCodePainter extends CustomPainter {
  const _QrCodePainter({
    required this.qrImage,
    required this.foreground,
    required this.background,
  });

  final QrImage qrImage;
  final Color foreground;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final quietZone = 4;
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
        final rect = Rect.fromLTWH(
          (col + quietZone) * moduleSize,
          (row + quietZone) * moduleSize,
          moduleSize,
          moduleSize,
        );
        canvas.drawRect(rect, foregroundPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrCodePainter oldDelegate) {
    return oldDelegate.qrImage != qrImage ||
        oldDelegate.foreground != foreground ||
        oldDelegate.background != background;
  }
}
