import 'package:flutter/material.dart';

import '../../../data/models/product_variant.dart';
import '../view_models/pos_view_model.dart';
import 'pos_unit_picker_sheet.dart';

/// Open the unit picker for [variant] and add the article the cashier chose.
///
/// One place, because every route into a serialized product — tapping it,
/// choosing it out of the variant sheet, scanning its box, the camera — has to
/// end the same way. A line that reaches the cart without a unit is a receipt
/// naming whichever handset happened to be oldest.
Future<void> pickAndAddStockUnit(
  BuildContext context, {
  required PosViewModel viewModel,
  required ProductVariant variant,
  required String source,
}) async {
  final repository = viewModel.trackedStockRepository;
  if (repository == null) {
    return;
  }
  final unit = await showPosUnitPickerSheet(
    context,
    repository: repository,
    variantId: variant.id,
    productLabel: variant.displayLabel,
  );
  if (unit != null && context.mounted) {
    viewModel.addVariant(variant, stockUnit: unit, source: source);
  }
}
