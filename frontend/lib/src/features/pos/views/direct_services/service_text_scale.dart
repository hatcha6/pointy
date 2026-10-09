import 'package:flutter/widgets.dart';

/// A height or width for a tile, chip, row or button that holds text: [base]
/// at normal text size, larger when the cashier enlarged the text in the
/// system settings, so a fixed-size box never cuts the words in it. Never
/// smaller than [base].
double textBoundExtent(BuildContext context, double base) {
  final scaled = MediaQuery.textScalerOf(context).scale(base);
  return scaled < base ? base : scaled;
}
