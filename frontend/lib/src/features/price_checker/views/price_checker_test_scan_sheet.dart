import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/price_lookup_result.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import 'price_checker_kiosk_view.dart';

/// Looks a code up the way staff mode does: the customer's answer, plus the
/// lot's own state when the reader may see it.
typedef PriceCheckerStaffLookup =
    Future<Result<PriceLookupResult>> Function(String barcode);

/// Staff-mode price check, from the price-checker fleet page.
///
/// Answers the two questions a manager has after quarantining a lot: *what does
/// the kiosk show a customer for this pack now?* (the real kiosk view, framed)
/// and *what is this lot's state?* (status, since when, why) — the second of
/// which the kiosk itself never shows.
Future<void> showPriceCheckerTestScanSheet(
  BuildContext context, {
  required PriceCheckerStaffLookup lookup,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 760),
    builder: (context) => PriceCheckerTestScanPanel(lookup: lookup),
  );
}

class PriceCheckerTestScanPanel extends StatefulWidget {
  const PriceCheckerTestScanPanel({
    super.key,
    required this.lookup,
    this.initialResult,
  });

  final PriceCheckerStaffLookup lookup;

  /// Seeds a result without scanning — for the preview harness and tests.
  final PriceLookupResult? initialResult;

  @override
  State<PriceCheckerTestScanPanel> createState() =>
      _PriceCheckerTestScanPanelState();
}

class _PriceCheckerTestScanPanelState extends State<PriceCheckerTestScanPanel> {
  final _controller = TextEditingController();
  late PriceLookupResult? _result = widget.initialResult;
  bool _busy = false;
  bool _failed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = _controller.text.trim();
    if (code.isEmpty || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    final outcome = await widget.lookup(code);
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      switch (outcome) {
        case Ok<PriceLookupResult>(:final value):
          _result = value;
        case Error<PriceLookupResult>():
          _failed = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final result = _result;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: spacing.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.priceCheckerTestScanTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: spacing.md),
            Row(
              children: [
                Expanded(
                  child: ScanWedgeTarget(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        hintText: l10n.priceCheckerTestScanHint,
                        prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
                      ),
                      onSubmitted: (_) => _scan(),
                    ),
                  ),
                ),
                SizedBox(width: spacing.sm),
                FilledButton(
                  onPressed: _busy ? null : _scan,
                  child: Text(l10n.priceCheckerTestScanSubmit),
                ),
              ],
            ),
            SizedBox(height: spacing.md),
            if (_busy)
              const PointyLoadingArea()
            else if (_failed)
              PointyInlineMessage.error(
                message: l10n.priceCheckerTestScanFailed,
              )
            else if (result == null)
              PointyInlineMessage(message: l10n.priceCheckerTestScanEmpty)
            else ...[
              if (result.lotDetail case final detail?) ...[
                _StaffLotPanel(detail: detail, result: result),
                SizedBox(height: spacing.md),
              ],
              PointySectionHeader(
                title: l10n.priceCheckerTestScanPreview,
                leading: const Icon(Icons.storefront_outlined),
              ),
              _KioskFrame(result: result),
            ],
          ],
        ),
      ),
    );
  }
}

/// The real kiosk view, framed at a shelf-tablet aspect, so staff see exactly
/// what a customer would.
class _KioskFrame extends StatelessWidget {
  const _KioskFrame({required this.result});

  /// A common shelf tablet in landscape.
  static const Size _kioskSize = Size(1280, 800);

  final PriceLookupResult result;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(PointyRadii.card),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(PointyRadii.card),
          border: Border.all(color: colors.line),
        ),
        // Laid out at a real landscape kiosk's size and scaled down, so the
        // preview is that screen in miniature rather than the phone layout a
        // sheet-sized box would get.
        child: AspectRatio(
          aspectRatio: _kioskSize.aspectRatio,
          child: FittedBox(
            child: SizedBox.fromSize(
              size: _kioskSize,
              child: PriceCheckerKioskView(
                status: result.found
                    ? PriceCheckerKioskStatus.found
                    : PriceCheckerKioskStatus.notFound,
                result: result.found ? result : null,
                barcode: result.barcode,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the kiosk never says: the lot's status, since when, and why.
class _StaffLotPanel extends StatelessWidget {
  const _StaffLotPanel({required this.detail, required this.result});

  final PriceLookupLotDetail detail;
  final PriceLookupResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final stopped = result.isStopped;
    final expired = result.availability == PriceLookupAvailability.expired;
    final statusLabel = !stopped
        ? l10n.priceCheckerStaffLotActive
        : expired
        ? l10n.posBatchPickerExpired
        : l10n.stockBatchQuarantinedBadge;
    final since = detail.quarantinedAt;
    final expiry = detail.expiryDate ?? result.lotExpiry;
    final format = DateFormat('yyyy/MM/dd HH:mm', 'en');
    final dateOnly = DateFormat('yyyy/MM/dd', 'en');

    return PointyDetailSection(
      title: l10n.priceCheckerStaffLotTitle,
      icon: Icons.inventory_2_outlined,
      trailing: PointyStatusPill(
        label: statusLabel,
        icon: stopped ? Icons.block_outlined : Icons.check_circle_outline,
        color: stopped ? colors.danger : colors.success,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySummaryList(
            rows: [
              if (result.lotCode.isNotEmpty)
                PointySummaryRow(
                  label: l10n.aiUiStockUnitLot,
                  value: result.lotCode,
                ),
              if (since != null)
                PointySummaryRow(
                  label: l10n.priceCheckerStaffLotSince,
                  // An LTR isolate, or the RTL row prints the time first.
                  value: '\u2066${format.format(since)}\u2069',
                ),
              if (stopped && !expired)
                PointySummaryRow(
                  label: l10n.priceCheckerStaffLotReason,
                  value: detail.quarantineReason.isEmpty
                      ? l10n.priceCheckerStaffLotNoReason
                      : detail.quarantineReason,
                ),
              if (expiry != null)
                PointySummaryRow(
                  label: l10n.priceCheckerStaffLotExpiry,
                  value: dateOnly.format(expiry),
                  valueColor: expired ? colors.danger : null,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.priceCheckerStaffLotHidden,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
    );
  }
}
