import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_submission.dart';
import '../../../shared/design/design.dart';
import '../../../shared/tracking/expiry_date_field.dart';
import '../../../shared/tracking/tracking_capture_chip.dart';
import '../../../shared/tracking/unit_intake_permissions.dart';
import '../../inventory/views/tracked_goods_capture.dart';
import '../view_models/purchase_view_model.dart';

/// Opens a purchase line's lot and serial sheets — the same sheets, in the
/// same order, the receiving form opens — and stores what was typed on the
/// line. Shared by the line's buttons and the F9 key.
Future<void> capturePurchaseLine(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  required PurchaseDraftLine line,
  UnitIntakePermissions permissions = UnitIntakePermissions.none,
  bool lots = true,
  bool units = true,
}) async {
  final mode = line.variant.trackingMode;
  if (!mode.isTracked || viewModel.isSubmitting) {
    return;
  }
  final factor = line.unitFactor > 0 ? line.unitFactor : 1;
  final captured = await captureTrackedGoods(
    context,
    TrackedGoodsCaptureRequest(
      mode: mode,
      productLabel: line.variant.displayLabel,
      lotQuantity: line.baseQuantity,
      unitCount: line.baseQuantity.round(),
      baseUnitCost: line.unitCost / factor,
      existing: line.capture,
      expiryRequired: line.variant.expiryRequired,
      // An order is not a receipt: whatever is not typed now is simply asked
      // for when the goods arrive, so the scan loop never insists.
      allowCaptureLater: true,
      assetTypeId: line.variant.productDetail?.assetTypeId,
      permissions: permissions,
    ),
    lots: lots,
    units: units,
  );
  if (captured == null || !context.mounted) {
    return;
  }
  viewModel.updateLineCapture(line.variant, captured);
}

/// A tracked purchase line's lots, expiry and serials, typed while the order
/// is entered.
///
/// The expiry sits on the line itself whenever the line is one lot — the shape
/// of nearly every delivery a pharmacy or grocer types — so `12/27` and Enter
/// is the whole job. A lot number, a split across lots and the serials open
/// the same sheets the receiving form uses. Nothing here is required: whatever
/// is left is asked for when the goods arrive.
class PurchaseLineCaptureRow extends StatelessWidget {
  const PurchaseLineCaptureRow({
    super.key,
    required this.line,
    required this.enabled,
    required this.onExpiryChanged,
    required this.onCaptureLots,
    required this.onCaptureUnits,
    this.expiryFocusNode,
    this.onExpirySubmitted,
  });

  final PurchaseDraftLine line;
  final bool enabled;
  final ValueChanged<DateTime?> onExpiryChanged;
  final VoidCallback onCaptureLots;
  final VoidCallback onCaptureUnits;
  final FocusNode? expiryFocusNode;
  final VoidCallback? onExpirySubmitted;

  /// Lines of one lot whose product must say when it goes off show the date
  /// inline; a split shows a summary that opens the sheet. A lot of paint is
  /// named but never dated, so it is not asked for one here — its sheet still
  /// takes a date for whoever has one.
  static bool hasInlineExpiry(PurchaseDraftLine line) =>
      line.variant.trackingMode.tracksLots &&
      line.variant.expiryRequired &&
      line.batches.length <= 1;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final mode = line.variant.trackingMode;
    final batches = line.batches;
    final fits = line.captureFits;
    final singleLot = batches.length == 1 ? batches.single : null;
    final lotCode = singleLot?.code.trim() ?? '';
    final unitCount = line.baseQuantity.round();

    final lotsLabel = switch (batches.length) {
      0 => l10n.purchaseLineCaptureLotNumber,
      1 when lotCode.isNotEmpty => l10n.purchaseLineCaptureLotCode(lotCode),
      1 => l10n.purchaseLineCaptureLotNumber,
      _ => l10n.purchaseLineCaptureLotsCount(batches.length),
    };

    return Container(
      key: ValueKey('purchase_line_capture_${line.variant.id}'),
      padding: const EdgeInsetsDirectional.fromSTEB(10, 10, 10, 8),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: fits ? colors.line : colors.danger),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The date gets the strip's whole width: it is the one thing
          // nearly every pharmacy and grocery line here is opened for.
          if (hasInlineExpiry(line)) ...[
            ExpiryDateField(
              key: ValueKey('purchase_line_expiry_${line.variant.id}'),
              value: singleLot?.expiryDate,
              required: line.variant.expiryRequired,
              enabled: enabled,
              focusNode: expiryFocusNode,
              textInputAction: TextInputAction.done,
              onChanged: onExpiryChanged,
              onSubmitted: (_) => onExpirySubmitted?.call(),
            ),
            const SizedBox(height: 8),
          ],
          // Each capture its own full-width row, lined up under the date.
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              if (mode.tracksLots)
                TrackingCaptureChip(
                  key: ValueKey('purchase_line_lots_${line.variant.id}'),
                  icon: Icons.inventory_2_outlined,
                  label: lotsLabel,
                  done: fits && (lotCode.isNotEmpty || batches.length > 1),
                  owed: !fits && batches.length > 1,
                  expanded: true,
                  onPressed: enabled ? onCaptureLots : null,
                ),
              if (mode.tracksUnits)
                TrackingCaptureChip(
                  key: ValueKey('purchase_line_units_${line.variant.id}'),
                  icon: Icons.qr_code_scanner_outlined,
                  label: l10n.purchaseLineCaptureSerials(
                    line.units.length,
                    unitCount,
                  ),
                  done: unitCount > 0 && line.units.length == unitCount,
                  owed: line.units.length > unitCount,
                  expanded: true,
                  onPressed: enabled ? onCaptureUnits : null,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                fits ? Icons.info_outline : Icons.error_outline,
                size: 14,
                color: fits ? colors.mutedInk : colors.danger,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  fits
                      ? l10n.purchaseLineCaptureLater
                      : l10n.purchaseLineCaptureMismatch,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: fits ? colors.mutedInk : colors.danger,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
