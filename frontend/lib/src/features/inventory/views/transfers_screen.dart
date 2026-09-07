import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_transfer.dart';
import '../../../data/repositories/warehouse_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/transfers_view_model.dart';
import 'transfer_composer_sheet.dart';
import 'transfer_receive_sheet.dart';

/// Stock moving between the shop's own places.
///
/// Grouped, not sorted. The three groups are three different jobs: goods on the
/// road are waiting for a person to receive them, a draft is waiting for
/// somebody to decide, and a finished transfer is only history. Sorting them
/// into one list by date would bury the only group that needs anything.
class TransfersScreen extends StatefulWidget {
  const TransfersScreen({
    super.key,
    required this.viewModel,
    required this.repository,
  });

  final TransfersViewModel viewModel;

  /// Handed to the composer so its product picker can ask what the source
  /// actually holds.
  final WarehouseRepository repository;

  @override
  State<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends State<TransfersScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.viewModel.load());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.transfersTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.refreshShopSettingsTooltip,
                onPressed: viewModel.isLoading ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: viewModel.canTransfer
              ? FloatingActionButton.extended(
                  onPressed: viewModel.isMutating
                      ? null
                      : () => _compose(context),
                  icon: const Icon(Icons.swap_horiz),
                  label: Text(l10n.transfersNewAction),
                )
              : null,
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.isEmpty) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.isEmpty) {
      return PointyErrorState(
        title: l10n.transfersTitle,
        icon: Icons.swap_horiz,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }
    if (viewModel.isEmpty) {
      return PointyEmptyState(
        icon: Icons.swap_horiz,
        title: l10n.transfersEmptyTitle,
        message: l10n.transfersEmptyBody,
        action: viewModel.canTransfer
            ? FilledButton.icon(
                onPressed: () => _compose(context),
                icon: const Icon(Icons.add),
                label: Text(l10n.transfersNewAction),
              )
            : null,
      );
    }

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Group(
                label: l10n.transfersNeedsAttention,
                transfers: viewModel.onTheRoad,
                builder: (transfer) => _TransferCard(
                  transfer: transfer,
                  isBusy: viewModel.isMutating,
                  primaryLabel: l10n.transferReceiveAction,
                  onPrimary: () => _receive(context, transfer),
                  onCancel: () => _cancel(context, transfer),
                ),
              ),
              _Group(
                label: l10n.transfersDrafts,
                transfers: viewModel.drafts,
                builder: (transfer) => _TransferCard(
                  transfer: transfer,
                  isBusy: viewModel.isMutating,
                  primaryLabel: l10n.transferSendAction,
                  onPrimary: () => _send(context, transfer),
                  onCancel: null,
                ),
              ),
              _Group(
                label: l10n.transfersSettled,
                transfers: viewModel.settled,
                builder: (transfer) => _TransferCard(
                  transfer: transfer,
                  isBusy: viewModel.isMutating,
                  primaryLabel: null,
                  onPrimary: null,
                  onCancel: null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _compose(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await showTransferComposer(
      context,
      places: widget.viewModel.places,
      repository: widget.repository,
    );
    if (outcome == null) return;
    final error = await widget.viewModel.create(
      outcome.draft,
      sendNow: outcome.sendNow,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error ??
              (outcome.sendNow
                  ? l10n.transferSent(outcome.draft.destination.name)
                  : l10n.warehouseSaved),
        ),
      ),
    );
  }

  Future<void> _send(BuildContext context, StockTransfer transfer) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final error = await widget.viewModel.send(transfer);
    messenger.showSnackBar(
      SnackBar(
        content: Text(error ?? l10n.transferSent(transfer.destinationName)),
      ),
    );
  }

  Future<void> _receive(BuildContext context, StockTransfer transfer) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final arrived = await showTransferReceiveSheet(context, transfer: transfer);
    if (arrived == null || arrived.isEmpty) return;
    final error = await widget.viewModel.receive(transfer, arrived);
    messenger.showSnackBar(
      SnackBar(
        content: Text(error ?? l10n.transferReceived(transfer.destinationName)),
      ),
    );
  }

  Future<void> _cancel(BuildContext context, StockTransfer transfer) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.undo),
        title: Text(l10n.transferCancelAction),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.transferCancelReasonLabel,
            // A cancelled transfer moves real stock back. Six months later the
            // only thing that explains why is what was typed here.
            helperText: l10n.transferCancelReasonRequired,
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || reason.isEmpty) return;
    final error = await widget.viewModel.cancel(transfer, reason);
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? l10n.transferCancelled)),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({
    required this.label,
    required this.transfers,
    required this.builder,
  });

  final String label;
  final List<StockTransfer> transfers;
  final Widget Function(StockTransfer) builder;

  @override
  Widget build(BuildContext context) {
    if (transfers.isEmpty) {
      // An empty group is not information. A shop with nothing on the road
      // should not be told so under a heading.
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            '$label · ${transfers.length}',
            style: theme.textTheme.labelLarge?.copyWith(color: colors.mutedInk),
          ),
        ),
        for (final transfer in transfers) builder(transfer),
      ],
    );
  }
}

/// One transfer, drawn as the journey it is.
///
/// The rail across the middle is the point: a transfer is not a row with a
/// status word, it is stock that has left one place and not yet reached
/// another. Showing where it has got to answers "is anything of mine sitting in
/// a van right now" without reading a single number.
class _TransferCard extends StatelessWidget {
  const _TransferCard({
    required this.transfer,
    required this.isBusy,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onCancel,
  });

  final StockTransfer transfer;
  final bool isBusy;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    transfer.transferNumber,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                _StatusChip(status: transfer.status),
              ],
            ),
            const SizedBox(height: 12),
            _JourneyRail(transfer: transfer),
            const SizedBox(height: 10),
            Text(
              [
                l10n.transferItemsCount('${transfer.lines.length}'),
                if (transfer.isOnTheRoad)
                  l10n.transferArrivedOf(
                    _short(transfer.receivedQuantity),
                    _short(transfer.totalQuantity),
                  ),
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
            if (transfer.isCancelled && transfer.cancelReason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                transfer.cancelledByUsername.isEmpty
                    ? transfer.cancelReason
                    : '${transfer.cancelReason} — '
                          '${l10n.transferCancelledByLabel(transfer.cancelledByUsername)}',
                style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
              ),
            ],
            if (primaryLabel != null || onCancel != null) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onCancel != null)
                    TextButton(
                      onPressed: isBusy ? null : onCancel,
                      child: Text(l10n.transferCancelAction),
                    ),
                  if (primaryLabel != null) ...[
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: isBusy ? null : onPrimary,
                      child: Text(primaryLabel!),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _short(double value) {
    final rounded = value.roundToDouble();
    return value == rounded
        ? rounded.toInt().toString()
        : value.toStringAsFixed(2);
  }
}

/// Source → road → destination, with the goods drawn where they actually are.
class _JourneyRail extends StatelessWidget {
  const _JourneyRail({required this.transfer});

  final StockTransfer transfer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final isMoving = transfer.isOnTheRoad;
    final done = transfer.status == StockTransferStatus.received;

    return Row(
      children: [
        _End(
          icon: Icons.storefront_outlined,
          label: transfer.sourceName,
          // The source is dimmed once the goods have left it: they are not
          // there any more, and the card should not suggest they are.
          muted: isMoving || done,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: [
                if (isMoving)
                  Icon(
                    Icons.local_shipping_outlined,
                    size: 18,
                    color: colors.accentAmber,
                  )
                else
                  Icon(
                    done ? Icons.check_circle : Icons.more_horiz,
                    size: 18,
                    color: done ? colors.success : colors.mutedInk,
                  ),
                const SizedBox(height: 4),
                PointyProgressBar(
                  value: transfer.isDraft ? 0 : (done ? 1 : transfer.progress),
                ),
                if (isMoving) ...[
                  const SizedBox(height: 4),
                  Text(
                    l10n.transferOnTheRoadLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        _End(
          icon: Icons.warehouse_outlined,
          label: transfer.destinationName,
          muted: !done,
        ),
      ],
    );
  }
}

class _End extends StatelessWidget {
  const _End({required this.icon, required this.label, required this.muted});

  final IconData icon;
  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final tint = muted ? colors.mutedInk : colors.ink;
    return SizedBox(
      width: 92,
      child: Column(
        children: [
          Icon(icon, size: 20, color: tint),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(color: tint),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final StockTransferStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final (label, background) = switch (status) {
      StockTransferStatus.draft => (
        l10n.transferStatusDraft,
        colors.subtleFill,
      ),
      StockTransferStatus.inTransit => (
        l10n.transferStatusInTransit,
        colors.amberContainer,
      ),
      StockTransferStatus.partiallyReceived => (
        l10n.transferStatusPartial,
        colors.amberContainer,
      ),
      StockTransferStatus.received => (
        l10n.transferStatusReceived,
        colors.primaryContainer,
      ),
      StockTransferStatus.cancelled => (
        l10n.transferStatusCancelled,
        colors.subtleFill,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: colors.ink),
      ),
    );
  }
}
