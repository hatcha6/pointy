import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../core/result.dart';
import '../../../../data/models/bulk_price_preview.dart';
import '../../../../data/repositories/catalog_repository.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/date_formatters.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/responsive/responsive.dart';

/// Past rule-driven price changes, newest first, each undoable once.
///
/// Returns true when something was undone, so the caller can refresh.
Future<bool> showBulkPriceHistorySheet(
  BuildContext context, {
  required CatalogRepository catalogRepository,
}) async {
  final changed = await showAdaptiveModalBottomSheet<bool>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.85,
    builder: (context) =>
        _BulkPriceHistory(catalogRepository: catalogRepository),
  );
  return changed ?? false;
}

/// Undo one change after confirming, with the outcome as a snackbar.
Future<bool> confirmAndRevertBulkPriceChange(
  BuildContext context, {
  required CatalogRepository catalogRepository,
  required int changeId,
  VoidCallback? onConfirmed,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => PointyConfirmationDialog(
      title: l10n.bulkPriceRevertConfirmTitle,
      message: l10n.bulkPriceRevertConfirmBody,
      confirmLabel: l10n.bulkPriceUndoAction,
      icon: Icons.undo,
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  onConfirmed?.call();
  final result = await catalogRepository.revertBulkPriceChange(changeId);
  if (!context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  switch (result) {
    case Ok(value: final record):
      final revert = record.revert;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.bulkPriceRevertDone(
              revert?.restored ?? 0,
              revert?.skipped ?? 0,
            ),
          ),
        ),
      );
      return true;
    case Error(exception: final error):
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error is BulkPriceException &&
                    error.failure == BulkPriceFailure.alreadyReverted
                ? l10n.bulkPriceAlreadyReverted
                : l10n.bulkPriceRevertFailed,
          ),
        ),
      );
      return false;
  }
}

class _BulkPriceHistory extends StatefulWidget {
  const _BulkPriceHistory({required this.catalogRepository});

  final CatalogRepository catalogRepository;

  @override
  State<_BulkPriceHistory> createState() => _BulkPriceHistoryState();
}

class _BulkPriceHistoryState extends State<_BulkPriceHistory> {
  List<BulkPriceChangeRecord>? _records;
  bool _failed = false;
  bool _reverted = false;
  int? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    final result = await widget.catalogRepository.loadBulkPriceChanges();
    if (!mounted) return;
    setState(() {
      switch (result) {
        case Ok(value: final records):
          _records = records;
        case Error():
          _failed = true;
      }
    });
  }

  Future<void> _revert(BulkPriceChangeRecord record) async {
    final done = await confirmAndRevertBulkPriceChange(
      context,
      catalogRepository: widget.catalogRepository,
      changeId: record.id,
      onConfirmed: () => setState(() => _busyId = record.id),
    );
    if (!mounted) return;
    setState(() => _busyId = null);
    if (done) {
      _reverted = true;
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final records = _records;

    final Widget body;
    if (_failed) {
      body = PointyErrorState(
        title: l10n.bulkPriceHistoryLoadFailed,
        action: TextButton(
          onPressed: _load,
          child: Text(l10n.bulkPricePreviewRetry),
        ),
      );
    } else if (records == null) {
      body = const Center(child: PointySpinner());
    } else if (records.isEmpty) {
      body = PointyEmptyState(
        icon: Icons.history,
        title: l10n.bulkPriceHistoryEmpty,
      );
    } else {
      body = ListView.separated(
        shrinkWrap: true,
        itemCount: records.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final record = records[index];
          final subtitle = [
            formatDateTime(record.createdAt),
            if (record.createdByName != null)
              l10n.bulkPriceHistoryBy(record.createdByName!),
          ].join(' · ');
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(
              record.isReverted ? Icons.undo : Icons.price_change_outlined,
              color: record.isReverted ? colors.mutedInk : colors.primaryStrong,
            ),
            title: Text(
              l10n.bulkPriceHistoryEntry(record.changed),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subtitle),
                Text(
                  l10n.bulkPriceHistoryDetail(
                    record.increased,
                    record.decreased,
                    record.stepCount,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
                if (record.revert != null)
                  Text(
                    l10n.bulkPriceRevertDone(
                      record.revert!.restored,
                      record.revert!.skipped,
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
              ],
            ),
            trailing: record.isReverted
                ? PointyStatusPill(
                    label: l10n.bulkPriceHistoryReverted,
                    color: colors.mutedInk,
                  )
                : (_busyId == record.id
                      ? const SizedBox.square(
                          dimension: 20,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : OutlinedButton.icon(
                          key: ValueKey('bulk_price_revert_${record.id}'),
                          onPressed: _busyId == null
                              ? () => _revert(record)
                              : null,
                          icon: const Icon(Icons.undo),
                          label: Text(l10n.bulkPriceUndoAction),
                        )),
          );
        },
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_reverted);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.bulkPriceHistoryTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(child: body),
          ],
        ),
      ),
    );
  }
}
