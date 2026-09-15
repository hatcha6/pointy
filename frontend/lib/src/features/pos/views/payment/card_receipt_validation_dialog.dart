import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/card_payment_receipt.dart';
import '../../../../shared/barcode/barcode_scan_listener.dart';
import '../../../../shared/barcode/camera_text_barcode_scanner_sheet.dart';
import '../../../companion/companion_scan_listener.dart';
import '../../../companion/companion_scope.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/responsive/responsive.dart';

Future<CardPaymentReceipt?> showCardReceiptValidationDialog({
  required BuildContext context,
  required double expectedAmount,
  required List<String> trustedTerminalIds,
}) {
  return showDialog<CardPaymentReceipt>(
    context: context,
    builder: (context) {
      return AdaptiveDialogSurface(
        size: AdaptiveModalSize.compact,
        child: CardReceiptValidationDialog(
          expectedAmount: expectedAmount,
          trustedTerminalIds: trustedTerminalIds,
        ),
      );
    },
  );
}

/// The cashier-facing reason a scanned receipt was refused.
///
/// Lives here rather than inside the dialog because the payment sheet refuses
/// receipts too — one wording for one outcome, wherever the receipt came from.
String cardReceiptErrorMessage(
  AppLocalizations l10n,
  CardPaymentReceiptException exception, {
  double? expectedAmount,
}) {
  return switch (exception.code) {
    CardPaymentReceiptErrorCode.invalidUrl => l10n.cardReceiptInvalidUrlError,
    CardPaymentReceiptErrorCode.missingQuery =>
      l10n.cardReceiptMissingQueryError,
    CardPaymentReceiptErrorCode.decodeFailed => l10n.cardReceiptDecodeError,
    CardPaymentReceiptErrorCode.invalidPayload => l10n.cardReceiptDecodeError,
    CardPaymentReceiptErrorCode.invalidAmount =>
      l10n.cardReceiptInvalidAmountError,
    CardPaymentReceiptErrorCode.unsuccessfulTransaction =>
      l10n.cardReceiptUnsuccessfulError,
    CardPaymentReceiptErrorCode.missingReference =>
      l10n.cardReceiptMissingReferenceError,
    CardPaymentReceiptErrorCode.amountMismatch =>
      l10n.cardReceiptAmountMismatch(
        formatMoney(exception.receipt?.amount ?? 0),
        formatMoney(expectedAmount ?? 0),
      ),
    CardPaymentReceiptErrorCode.terminalNotTrusted =>
      l10n.cardReceiptTerminalNotTrusted(exception.receipt?.terminalId ?? ''),
  };
}

class CardReceiptValidationDialog extends StatefulWidget {
  const CardReceiptValidationDialog({
    super.key,
    required this.expectedAmount,
    required this.trustedTerminalIds,
    this.matcher = const CardReceiptMatcher(),
  });

  final double expectedAmount;
  final List<String> trustedTerminalIds;
  final CardReceiptMatcher matcher;

  @override
  State<CardReceiptValidationDialog> createState() =>
      _CardReceiptValidationDialogState();
}

class _CardReceiptValidationDialogState
    extends State<CardReceiptValidationDialog> {
  late final TextEditingController _urlController;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    // The QR on a payment-terminal receipt is exactly what a shop's laser wedge
    // cannot read, which is why this dialog exists at all. A paired phone reads
    // it and lands here through the same handler as any other scan.
    return CompanionScanListener(
      bridge: CompanionScope.bridgeOf(context),
      onScan: _validateUrl,
      child: BarcodeScanListener(
        minLength: 16,
        ignoreTextInputFocus: false,
        requireCurrentRoute: false,
        onBarcodeScanned: _validateUrl,
        child: AlertDialog(
          icon: const Icon(Icons.qr_code_scanner_outlined),
          title: Text(l10n.cardReceiptDialogTitle),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PointyInlineMessage(
                  compact: true,
                  icon: Icons.payments_outlined,
                  message: l10n.cardReceiptExpectedAmount(
                    formatMoney(widget.expectedAmount),
                  ),
                ),
                SizedBox(height: spacing.md),
                TextField(
                  key: const ValueKey('card_receipt_url_field'),
                  controller: _urlController,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  textDirection: TextDirection.ltr,
                  onSubmitted: _validateUrl,
                  decoration: InputDecoration(
                    labelText: l10n.cardReceiptUrlLabel,
                    prefixIcon: const Icon(Icons.link_outlined),
                    suffixIcon: IconButton(
                      tooltip: l10n.cardReceiptCameraTooltip,
                      onPressed: _scanWithCamera,
                      icon: const Icon(Icons.photo_camera_outlined),
                    ),
                  ),
                ),
                if (_errorMessage != null) ...[
                  SizedBox(height: spacing.sm),
                  PointyInlineMessage.error(
                    compact: true,
                    message: _errorMessage!,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancelButton),
            ),
            FilledButton.icon(
              onPressed: () => _validateUrl(_urlController.text),
              icon: const Icon(Icons.verified_outlined),
              label: Text(l10n.cardReceiptValidateButton),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanWithCamera() async {
    final l10n = AppLocalizations.of(context)!;
    final scanned = await showCameraTextBarcodeScannerSheet(
      context,
      title: l10n.cardReceiptCameraTitle,
    );
    if (scanned == null || !mounted) {
      return;
    }
    _urlController.text = scanned;
    _validateUrl(scanned);
  }

  void _validateUrl(String value) {
    final l10n = AppLocalizations.of(context)!;
    final url = value.trim();
    if (url.isEmpty) {
      setState(() {
        _errorMessage = l10n.cardReceiptUrlRequiredError;
      });
      return;
    }

    final CardPaymentReceipt receipt;
    try {
      receipt = widget.matcher.match(
        url,
        expectedAmount: widget.expectedAmount,
        trustedTerminalIds: widget.trustedTerminalIds,
      );
    } on CardPaymentReceiptException catch (exception) {
      setState(() {
        _errorMessage = cardReceiptErrorMessage(
          l10n,
          exception,
          expectedAmount: widget.expectedAmount,
        );
      });
      return;
    }

    Navigator.of(context).pop(receipt);
  }
}
