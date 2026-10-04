import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../core/result.dart';
import '../../data/models/stock_batch.dart';
import '../components/components.dart';
import '../date_formatters.dart';
import '../responsive/responsive.dart';
import '../units.dart';
import 'lot_state_badges.dart';

/// One document line whose lots somebody may name before it leaves.
class LotPickLine {
  const LotPickLine({
    required this.key,
    required this.title,
    required this.quantity,
    required this.variantId,
  });

  /// Echoed back as this line's key in [showLotPickSheet]'s result.
  final int key;
  final String title;

  /// How much this line moves, in base units.
  final double quantity;
  final int variantId;
}

/// Loads every lot of a variant the line could leave from.
typedef LotPickLoader = Future<Result<StockBatchPage>> Function(int variantId);

/// Which lots are leaving — optional, unlike handsets.
///
/// A lot line is answerable without anybody choosing (the server takes the
/// earliest-expiring good stock), so choosing nothing is a valid answer and
/// says so. Naming is for the cases the default gets wrong, chiefly a recall:
/// the recalled lot is listed first, marked «محجورة», because sending it back
/// is the reason this sheet exists. Only lots holding goods in [warehouseId]
/// are offered.
///
/// Returns `{line key: lot ids}` (empty = automatic), or null when dismissed.
Future<Map<int, List<int>>?> showLotPickSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required List<LotPickLine> lines,
  required LotPickLoader loadLots,
  int? warehouseId,
}) {
  return showModalBottomSheet<Map<int, List<int>>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => _LotPickSheet(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      lines: lines,
      loadLots: loadLots,
      warehouseId: warehouseId,
    ),
  );
}

class _LotPickSheet extends StatefulWidget {
  const _LotPickSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.lines,
    required this.loadLots,
    required this.warehouseId,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final List<LotPickLine> lines;
  final LotPickLoader loadLots;
  final int? warehouseId;

  @override
  State<_LotPickSheet> createState() => _LotPickSheetState();
}

class _LotPickSheetState extends State<_LotPickSheet> {
  final Map<int, List<StockBatch>> _available = {};
  final Map<int, Set<int>> _picked = {};
  bool _isLoading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      for (final line in widget.lines) widget.loadLots(line.variantId),
    ]);
    if (!mounted) {
      return;
    }
    setState(() {
      for (final (index, line) in widget.lines.indexed) {
        switch (results[index]) {
          case Ok<StockBatchPage>(:final value):
            _available[line.key] =
                value.batches.where((lot) => _here(lot) > 0).toList()
                  ..sort(_stoppedFirstThenExpiry);
          case Error<StockBatchPage>():
            _loadFailed = true;
        }
      }
      _isLoading = false;
    });
  }

  double _here(StockBatch lot) => lot.quantityAt(widget.warehouseId);

  static bool _isStopped(StockBatch lot) => _badges(lot).isStopped;

  static LotStateBadges _badges(StockBatch lot) => LotStateBadges(
    isSellable: lot.isSellable,
    status: lot.status,
    expiryDate: lot.expiryDate,
  );

  /// The recall on top — it is why anybody opens this — then the order the
  /// server would have drawn in anyway.
  static int _stoppedFirstThenExpiry(StockBatch left, StockBatch right) {
    final stopped = (_isStopped(right) ? 1 : 0) - (_isStopped(left) ? 1 : 0);
    if (stopped != 0) {
      return stopped;
    }
    final leftDate = left.expiryDate;
    final rightDate = right.expiryDate;
    if (leftDate == null && rightDate == null) {
      return left.id.compareTo(right.id);
    }
    if (leftDate == null) {
      return 1;
    }
    if (rightDate == null) {
      return -1;
    }
    return leftDate.compareTo(rightDate);
  }

  double _chosenQuantity(LotPickLine line) {
    final chosen = _picked[line.key] ?? const <int>{};
    return (_available[line.key] ?? const <StockBatch>[])
        .where((lot) => chosen.contains(lot.id))
        .fold(0.0, (sum, lot) => sum + _here(lot));
  }

  /// Named lots that cannot cover the line: the server would refuse, so the
  /// sheet says it first.
  bool _isShort(LotPickLine line) {
    if ((_picked[line.key] ?? const <int>{}).isEmpty) {
      return false;
    }
    return _chosenQuantity(line) + 0.0005 < line.quantity;
  }

  bool get _canConfirm => !_isLoading && !widget.lines.any(_isShort);

  void _toggle(LotPickLine line, StockBatch lot) {
    setState(() {
      final chosen = _picked.putIfAbsent(line.key, () => <int>{});
      if (!chosen.remove(lot.id)) {
        chosen.add(lot.id);
      }
    });
  }

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
              icon: Icons.inventory_2_outlined,
              title: widget.title,
              message: widget.message,
            ),
            SizedBox(height: spacing.md),
            if (_isLoading)
              const Center(child: PointySpinner())
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (_loadFailed)
                      PointyInlineMessage.error(
                        message: l10n.lotPickLoadFailed,
                        compact: true,
                      ),
                    for (final line in widget.lines) ..._section(l10n, line),
                  ],
                ),
              ),
            SizedBox(height: spacing.md),
            FilledButton(
              onPressed: _canConfirm
                  ? () => Navigator.of(context).pop({
                      for (final line in widget.lines)
                        line.key: (_picked[line.key] ?? const <int>{}).toList(
                          growable: false,
                        ),
                    })
                  : null,
              child: Text(widget.confirmLabel),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _section(AppLocalizations l10n, LotPickLine line) {
    final theme = Theme.of(context);
    final chosen = _picked[line.key] ?? const <int>{};
    final lots = _available[line.key] ?? const <StockBatch>[];
    return [
      PointySectionHeader(
        title: line.title,
        trailing: Text(l10n.lotPickNeeded(formatQuantity(line.quantity))),
      ),
      if (lots.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(l10n.lotPickEmpty),
        )
      else if (chosen.isEmpty)
        Text(
          l10n.lotPickAutomatic,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        )
      else if (_isShort(line))
        PointyInlineMessage.warning(
          message: l10n.lotPickShort(
            formatQuantity(_chosenQuantity(line)),
            formatQuantity(line.quantity),
          ),
          compact: true,
        ),
      for (final lot in lots)
        CheckboxListTile(
          dense: true,
          value: chosen.contains(lot.id),
          onChanged: (_) => _toggle(line, lot),
          title: Text(
            lot.label.isNotEmpty ? lot.label : l10n.stockBatchNoCode,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                lot.expiryDate == null
                    ? l10n.posBatchPickerNoExpiry
                    : formatExpiry(lot.expiryDate!),
              ),
              _badges(lot),
            ],
          ),
          secondary: Text(
            formatQuantity(_here(lot)),
            style: theme.textTheme.titleSmall,
          ),
        ),
    ];
  }
}
