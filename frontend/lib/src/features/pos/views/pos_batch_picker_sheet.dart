import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/stock_batch.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/components/pointy_progress.dart';
import '../../../shared/design/design.dart';
import '../../../shared/units.dart';

/// Which lot, when the customer asks for a different one.
///
/// The default path never opens this: a scan rings up the earliest-expiring lot
/// in this till's warehouse with no tap at all, which is the only thing that
/// works at pharmacy speed. This is for the customer who wants a longer expiry,
/// and for the cashier who scanned the carton rather than the shelf edge.
///
/// **Only lots with goods in this warehouse are listed.** Stock of the same lot
/// sitting in another branch is deliberately absent: it is not on this shelf,
/// and offering it would be offering something the cashier cannot hand over.
Future<StockBatch?> showPosBatchPickerSheet(
  BuildContext context, {
  required TrackedStockRepository repository,
  required int variantId,
  required String productLabel,
}) {
  return showModalBottomSheet<StockBatch>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) {
      return _PosBatchPickerSheet(
        repository: repository,
        variantId: variantId,
        productLabel: productLabel,
      );
    },
  );
}

class _PosBatchPickerSheet extends StatefulWidget {
  const _PosBatchPickerSheet({
    required this.repository,
    required this.variantId,
    required this.productLabel,
  });

  final TrackedStockRepository repository;
  final int variantId;
  final String productLabel;

  @override
  State<_PosBatchPickerSheet> createState() => _PosBatchPickerSheetState();
}

class _PosBatchPickerSheetState extends State<_PosBatchPickerSheet> {
  List<StockBatch> _batches = const [];
  bool _isLoading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await widget.repository.loadSellableBatches(
      variantId: widget.variantId,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
      switch (result) {
        case Ok<StockBatchPage>(:final value):
          // Earliest expiry first, which is the order the till would have
          // picked in anyway — so the top row is the zero-tap answer and
          // anything below it is a deliberate override.
          _batches =
              value.batches
                  .where((batch) => batch.onHand > 0 && batch.isSellable)
                  .toList()
                ..sort(_byExpiry);
          _error = '';
        case Error<StockBatchPage>():
          _batches = const [];
          _error = AppLocalizations.of(context)!.posBatchPickerLoadFailed;
      }
    });
  }

  int _byExpiry(StockBatch left, StockBatch right) {
    final leftDate = left.expiryDate;
    final rightDate = right.expiryDate;
    if (leftDate == null && rightDate == null) {
      return left.id.compareTo(right.id);
    }
    // A lot that never expires sorts last: it is the one there is no hurry to
    // shift.
    if (leftDate == null) {
      return 1;
    }
    if (rightDate == null) {
      return -1;
    }
    return leftDate.compareTo(rightDate);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.inventory_2_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.posBatchPickerTitle(widget.productLabel),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: PointySpinner()),
              )
            else if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(_error, textAlign: TextAlign.center),
              )
            else if (_batches.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  l10n.posBatchPickerEmpty,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _batches.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final batch = _batches[index];
                    return _BatchRow(
                      batch: batch,
                      available: batch.onHand,
                      onTap: () => Navigator.of(context).pop(batch),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BatchRow extends StatelessWidget {
  const _BatchRow({
    required this.batch,
    required this.available,
    required this.onTap,
  });

  final StockBatch batch;
  final double available;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final days = batch.daysUntilExpiry;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      title: Text(
        batch.label.isNotEmpty ? batch.label : l10n.stockBatchNoCode,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontStyle: batch.label.isEmpty ? FontStyle.italic : FontStyle.normal,
        ),
      ),
      subtitle: Row(
        children: [
          if (batch.expiryDate != null) ...[
            Icon(
              Icons.event_outlined,
              size: 14,
              color: _expiryTone(context, days),
            ),
            const SizedBox(width: 4),
            Text(
              formatExpiry(batch.expiryDate!),
              style: theme.textTheme.bodySmall?.copyWith(
                color: _expiryTone(context, days),
              ),
            ),
            if (days != null) ...[
              const SizedBox(width: 6),
              Text(
                days >= 0
                    ? l10n.posBatchPickerDaysLeft(days)
                    : l10n.posBatchPickerExpired,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _expiryTone(context, days),
                ),
              ),
            ],
          ] else
            Text(
              l10n.posBatchPickerNoExpiry,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
        ],
      ),
      trailing: Text(
        formatQuantity(available),
        style: theme.textTheme.titleSmall,
      ),
    );
  }

  /// Red inside a month, amber inside three. The cashier is the last person who
  /// can catch a pack that is about to turn, and a date that reads the same as
  /// every other date is a date nobody reads.
  Color _expiryTone(BuildContext context, int? days) {
    final colors = context.pointyColors;
    if (days == null) {
      return Theme.of(context).hintColor;
    }
    if (days < 30) {
      return colors.danger;
    }
    if (days < 90) {
      return colors.warning;
    }
    return colors.primaryStrong;
  }
}
