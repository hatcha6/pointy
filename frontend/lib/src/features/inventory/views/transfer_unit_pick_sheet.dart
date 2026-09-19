import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/stock_transfer.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';

/// Which handsets are actually in the van (§6.5).
///
/// Not auto-picked, and this is the one place a transfer differs from a sale.
/// The till may take the oldest handset off the shelf because the customer is
/// holding whichever one it hands them; a driver has already physically chosen
/// five, and a system that picked a different five would make the far end's
/// *«sent 5, arrived 4, missing 351…333»* reconciliation a lie about which
/// handset is gone.
Future<Map<int, TransferLinePick>?> showTransferUnitPickSheet(
  BuildContext context, {
  required StockTransfer transfer,
  required TrackedStockRepository repository,
}) {
  return showModalBottomSheet<Map<int, TransferLinePick>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) =>
        _TransferUnitPickSheet(transfer: transfer, repository: repository),
  );
}

/// True when this transfer cannot leave until somebody names its articles.
bool transferNeedsUnitPicks(StockTransfer transfer) {
  return transfer.lines.any((line) => line.trackingMode.tracksUnits);
}

class _TransferUnitPickSheet extends StatefulWidget {
  const _TransferUnitPickSheet({
    required this.transfer,
    required this.repository,
  });

  final StockTransfer transfer;
  final TrackedStockRepository repository;

  @override
  State<_TransferUnitPickSheet> createState() => _TransferUnitPickSheetState();
}

class _TransferUnitPickSheetState extends State<_TransferUnitPickSheet> {
  final Map<int, List<StockUnit>> _available = {};
  final Map<int, Set<int>> _picked = {};
  bool _isLoading = true;

  List<StockTransferLine> get _lines => widget.transfer.lines
      .where((line) => line.trackingMode.tracksUnits)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final line in _lines) {
      final result = await widget.repository.loadSellableUnits(
        variantId: line.variantId,
      );
      if (result is Ok<StockUnitPage>) {
        _available[line.id] = result.value.units;
      }
    }
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  void _toggle(StockTransferLine line, StockUnit unit) {
    setState(() {
      final chosen = _picked.putIfAbsent(line.id, () => <int>{});
      if (chosen.contains(unit.id)) {
        chosen.remove(unit.id);
        return;
      }
      if (chosen.length >= line.baseQuantity.round()) {
        return;
      }
      chosen.add(unit.id);
    });
  }

  bool get _isComplete => _lines.every(
    (line) => (_picked[line.id]?.length ?? 0) == line.baseQuantity.round(),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SafeArea(
      child: Padding(
        padding: spacing.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointyDetailCallout(
              icon: Icons.qr_code_scanner_outlined,
              title: l10n.transferPickUnitsTitle,
              message: l10n.transferPickUnitsBody,
            ),
            SizedBox(height: spacing.lg),
            if (_isLoading)
              const Center(child: PointySpinner())
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final line in _lines) ...[
                      PointySectionHeader(
                        title: line.variantName,
                        trailing: Text(
                          l10n.transferPickUnitsCount(
                            _picked[line.id]?.length ?? 0,
                            line.baseQuantity.round(),
                          ),
                        ),
                      ),
                      for (final unit
                          in _available[line.id] ?? const <StockUnit>[])
                        CheckboxListTile(
                          dense: true,
                          value: _picked[line.id]?.contains(unit.id) ?? false,
                          onChanged: (_) => _toggle(line, unit),
                          title: Text(unit.code),
                          subtitle: unit.secondaryCode.isEmpty
                              ? null
                              : Text(unit.secondaryCode),
                        ),
                    ],
                  ],
                ),
              ),
            SizedBox(height: spacing.lg),
            if (!_isComplete && !_isLoading)
              PointyInlineMessage.warning(
                message: l10n.transferPickUnitsIncomplete,
                compact: true,
              ),
            SizedBox(height: spacing.sm),
            FilledButton(
              onPressed: _isComplete
                  ? () => Navigator.of(context).pop({
                      for (final entry in _picked.entries)
                        entry.key: TransferLinePick(
                          unitIds: entry.value.toList(growable: false),
                        ),
                    })
                  : null,
              child: Text(l10n.transferSendAction),
            ),
          ],
        ),
      ),
    );
  }
}
