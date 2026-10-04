import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/services/print_transport.dart';

/// What to tell someone whose print came out on the driver's own paper
/// instead of the page it asked for: the two sizes, and that the fix is in the
/// printer's driver, which no setting here can reach.
String printPaperMismatchMessage(
  AppLocalizations l10n,
  PrintPaperMismatch mismatch,
) {
  final requested = _paperSize(
    mismatch.requestedWidthMm,
    mismatch.requestedHeightMm,
  );
  if (!mismatch.knowsPrintedSize) {
    return l10n.printPaperUnsupportedMessage(requested);
  }
  return l10n.printPaperMismatchMessage(
    requested,
    _paperSize(mismatch.printedWidthMm!, mismatch.printedHeightMm!),
  );
}

/// "50×30" — isolated left-to-right, or an Arabic sentence turns it around.
String _paperSize(double widthMm, double heightMm) {
  String mm(double value) {
    final tenths = (value * 10).round() / 10;
    return tenths == tenths.roundToDouble()
        ? '${tenths.round()}'
        : tenths.toStringAsFixed(1);
  }

  return '\u2066${mm(widthMm)}×${mm(heightMm)}\u2069';
}
