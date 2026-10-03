import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/wallet_view_model.dart';
import 'wallet_rows.dart';

/// Everything the wallet has done: its top-ups (with whether each went into
/// the books), every movement of the main balance, and — where SMS is paid
/// from it — every movement of the SMS balance, newest first, paged.
class WalletHistoryPage extends StatefulWidget {
  const WalletHistoryPage({super.key, required this.viewModel});

  final WalletViewModel viewModel;

  @override
  State<WalletHistoryPage> createState() => _WalletHistoryPageState();
}

class _WalletHistoryPageState extends State<WalletHistoryPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.loadHistoryTopUps(reset: true));
      unawaited(widget.viewModel.loadHistoryEntries(reset: true));
      if (_showsSms) {
        unawaited(widget.viewModel.spending.loadSmsEntries(reset: true));
      }
    });
  }

  bool get _showsSms => widget.viewModel.overview?.sms != null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showsSms = _showsSms;
    return DefaultTabController(
      length: showsSms ? 3 : 2,
      child: PointyScaffold(
        appBar: PointyAppBar(
          title: Text(l10n.walletHistoryTitle),
          bottom: TabBar(
            tabs: [
              Tab(text: l10n.walletHistoryTopUpsTab),
              Tab(text: l10n.walletHistoryEntriesTab),
              if (showsSms) Tab(text: l10n.walletHistorySmsTab),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: Listenable.merge([
            widget.viewModel,
            widget.viewModel.spending,
          ]),
          builder: (context, _) {
            final viewModel = widget.viewModel;
            final spending = viewModel.spending;
            return TabBarView(
              children: [
                _HistoryList(
                  itemCount: viewModel.historyTopUps.length,
                  itemBuilder: (index) =>
                      WalletTopUpTile(topUp: viewModel.historyTopUps[index]),
                  isLoading: viewModel.isLoadingHistoryTopUps,
                  hasMore: viewModel.historyTopUpsHasMore,
                  failed: viewModel.historyTopUpsFailed,
                  emptyIcon: Icons.add_card_outlined,
                  emptyTitle: l10n.walletHistoryEmptyTopUps,
                  onLoadMore: viewModel.loadHistoryTopUps,
                  onRefresh: () => viewModel.loadHistoryTopUps(reset: true),
                ),
                _HistoryList(
                  itemCount: viewModel.historyEntries.length,
                  itemBuilder: (index) =>
                      WalletEntryTile(entry: viewModel.historyEntries[index]),
                  isLoading: viewModel.isLoadingHistoryEntries,
                  hasMore: viewModel.historyEntriesHasMore,
                  failed: viewModel.historyEntriesFailed,
                  emptyIcon: Icons.receipt_long_outlined,
                  emptyTitle: l10n.walletHistoryEmptyEntries,
                  onLoadMore: viewModel.loadHistoryEntries,
                  onRefresh: () => viewModel.loadHistoryEntries(reset: true),
                ),
                if (showsSms)
                  _HistoryList(
                    itemCount: spending.smsEntries.length,
                    itemBuilder: (index) =>
                        WalletEntryTile(entry: spending.smsEntries[index]),
                    isLoading: spending.isLoadingSmsEntries,
                    hasMore: spending.smsEntriesHasMore,
                    failed: spending.smsEntriesFailed,
                    emptyIcon: Icons.sms_outlined,
                    emptyTitle: l10n.walletHistoryEmptySms,
                    onLoadMore: spending.loadSmsEntries,
                    onRefresh: () => spending.loadSmsEntries(reset: true),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.itemCount,
    required this.itemBuilder,
    required this.isLoading,
    required this.hasMore,
    required this.failed,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.onLoadMore,
    required this.onRefresh,
  });

  final int itemCount;
  final Widget Function(int index) itemBuilder;
  final bool isLoading;
  final bool hasMore;
  final bool failed;
  final IconData emptyIcon;
  final String emptyTitle;
  final Future<void> Function() onLoadMore;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (itemCount == 0) {
      if (isLoading) {
        return const PointyLoadingArea();
      }
      if (failed) {
        return PointyErrorState(
          title: l10n.walletHistoryLoadFailed,
          icon: Icons.cloud_off_outlined,
          action: FilledButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.sync),
            label: Text(l10n.retryButton),
          ),
        );
      }
      return PointyEmptyState(icon: emptyIcon, title: emptyTitle);
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: spacing.pagePadding,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: itemCount + 1,
        separatorBuilder: (_, index) => index < itemCount - 1
            ? const Divider(height: 1)
            : const SizedBox.shrink(),
        itemBuilder: (context, index) {
          if (index < itemCount) {
            return AdaptiveMaxWidth(
              width: AppContentWidth.detail,
              child: itemBuilder(index),
            );
          }
          if (!hasMore) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: EdgeInsets.symmetric(vertical: spacing.md),
            child: Center(
              child: isLoading
                  ? const SizedBox.square(dimension: 24, child: PointySpinner())
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (failed)
                          Padding(
                            padding: EdgeInsets.only(bottom: spacing.xs),
                            child: Text(
                              l10n.walletHistoryLoadFailed,
                              style: TextStyle(
                                color: context.pointyColors.danger,
                              ),
                            ),
                          ),
                        OutlinedButton(
                          onPressed: onLoadMore,
                          child: Text(l10n.walletHistoryLoadMore),
                        ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }
}
