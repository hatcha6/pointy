import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'components/pointy_skeleton.dart';
import 'components/pointy_progress.dart';
import 'design/design.dart';

class InfiniteScrollView<T> extends StatefulWidget {
  const InfiniteScrollView({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.onLoadMore,
    required this.hasMore,
    required this.isLoadingInitial,
    required this.isLoadingMore,
    required this.emptyBuilder,
    required this.sliverBuilder,
    this.header,
    this.padding = EdgeInsets.zero,
    this.loadMoreExtent = 480,
    this.skeletonItemBuilder,
    this.skeletonItemCount = 8,
    this.loadMoreFailed = false,
    this.loadMoreErrorMessage,
  });

  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final Future<void> Function() onLoadMore;
  final bool hasMore;
  final bool isLoadingInitial;
  final bool isLoadingMore;
  final WidgetBuilder emptyBuilder;
  final Widget Function(BuildContext context, SliverChildDelegate delegate)
  sliverBuilder;

  /// Scrolls with the content above the first item, and stays visible in the
  /// loading and empty states.
  final Widget? header;
  final EdgeInsetsGeometry padding;
  final double loadMoreExtent;

  /// When provided, the initial-load state shows [skeletonItemCount] shimmering
  /// placeholders laid out with the real sliver shape (list or grid) instead of
  /// a centered spinner.
  final WidgetBuilder? skeletonItemBuilder;
  final int skeletonItemCount;

  /// The last page request failed. The rows already fetched stay on screen and
  /// a retry footer is shown at the end of the list; the automatic
  /// scroll-to-the-bottom trigger stands down until the reader asks again, so a
  /// server that is answering errors is not hammered once per scroll frame.
  ///
  /// This is deliberately separate from [hasMore]: a failed page says nothing
  /// about whether more rows exist. Answering a failure by clearing [hasMore]
  /// ends pagination for the life of the view model — one network blip and the
  /// list is frozen at its first page with no way back.
  final bool loadMoreFailed;

  /// Shown above the retry button when [loadMoreFailed]. Without one the footer
  /// is the button alone.
  final String? loadMoreErrorMessage;

  @override
  State<InfiniteScrollView<T>> createState() => _InfiniteScrollViewState<T>();
}

class _InfiniteScrollViewState<T> extends State<InfiniteScrollView<T>> {
  late final ScrollController _controller;
  bool _loadInFlight = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController()..addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
  }

  @override
  void didUpdateWidget(covariant InfiniteScrollView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  Future<void> _maybeLoadMore() async {
    if (!mounted ||
        !_controller.hasClients ||
        _loadInFlight ||
        widget.isLoadingInitial ||
        widget.isLoadingMore ||
        widget.loadMoreFailed ||
        !widget.hasMore) {
      return;
    }

    final position = _controller.position;
    if (position.maxScrollExtent == 0 ||
        position.extentAfter < widget.loadMoreExtent) {
      _loadInFlight = true;
      try {
        await widget.onLoadMore();
      } finally {
        _loadInFlight = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoadingInitial && widget.items.isEmpty) {
      final skeletonItemBuilder = widget.skeletonItemBuilder;
      if (skeletonItemBuilder != null) {
        return PointySkeleton(
          child: CustomScrollView(
            physics: const NeverScrollableScrollPhysics(),
            slivers: [
              if (widget.header != null)
                SliverToBoxAdapter(child: widget.header),
              SliverPadding(
                padding: widget.padding,
                sliver: widget.sliverBuilder(
                  context,
                  SliverChildBuilderDelegate(
                    (context, index) => skeletonItemBuilder(context),
                    childCount: widget.skeletonItemCount,
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return _withHeader(
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: PointySpinner()),
        ),
      );
    }

    if (widget.items.isEmpty) {
      return _withHeader(widget.emptyBuilder(context));
    }

    final delegate = SliverChildBuilderDelegate(
      (context, index) => widget.itemBuilder(context, widget.items[index]),
      childCount: widget.items.length,
    );

    // The scrollable owns a layer. A viewport re-emits its paint on every
    // scroll frame, and without a boundary here that re-recorded the whole
    // route's picture — page chrome, filter bars and headers included — 60
    // times a second while a cashier flicked through a list.
    return RepaintBoundary(
      child: CustomScrollView(
        controller: _controller,
        slivers: [
          if (widget.header != null) SliverToBoxAdapter(child: widget.header),
          SliverPadding(
            padding: widget.padding,
            sliver: widget.sliverBuilder(context, delegate),
          ),
          if (widget.isLoadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: PointySpinner()),
              ),
            )
          else if (widget.loadMoreFailed)
            SliverToBoxAdapter(child: _loadMoreErrorFooter(context)),
        ],
      ),
    );
  }

  /// The end of a list that stopped early. The reader is already looking at the
  /// bottom of the rows when this appears, which is the one place a retry is
  /// worth offering.
  Widget _loadMoreErrorFooter(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final message = widget.loadMoreErrorMessage;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message != null) ...[
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.pointyColors.danger),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton.tonalIcon(
            // Straight to onLoadMore: the automatic trigger is standing down
            // (see loadMoreFailed), and a tap is the reader asking for it.
            onPressed: () => widget.onLoadMore(),
            icon: const Icon(Icons.refresh),
            label: Text(l10n.retryButton),
          ),
        ],
      ),
    );
  }

  Widget _withHeader(Widget body) {
    final header = widget.header;
    if (header == null) {
      if (widget.isLoadingInitial && widget.items.isEmpty) {
        return const Center(child: PointySpinner());
      }
      return body;
    }
    return ListView(children: [header, body]);
  }
}

class InfiniteScrollGrid<T> extends StatefulWidget {
  const InfiniteScrollGrid({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.onLoadMore,
    required this.hasMore,
    required this.isLoadingInitial,
    required this.isLoadingMore,
    required this.emptyBuilder,
    required this.gridDelegate,
    this.padding = EdgeInsets.zero,
    this.loadMoreExtent = 480,
    this.skeletonItemBuilder,
    this.skeletonItemCount = 8,
    this.loadMoreFailed = false,
    this.loadMoreErrorMessage,
  });

  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final Future<void> Function() onLoadMore;
  final bool hasMore;
  final bool isLoadingInitial;
  final bool isLoadingMore;
  final WidgetBuilder emptyBuilder;
  final SliverGridDelegate gridDelegate;
  final EdgeInsetsGeometry padding;
  final double loadMoreExtent;
  final WidgetBuilder? skeletonItemBuilder;
  final int skeletonItemCount;

  /// See [InfiniteScrollView.loadMoreFailed].
  final bool loadMoreFailed;

  /// See [InfiniteScrollView.loadMoreErrorMessage].
  final String? loadMoreErrorMessage;

  @override
  State<InfiniteScrollGrid<T>> createState() => _InfiniteScrollGridState<T>();
}

class _InfiniteScrollGridState<T> extends State<InfiniteScrollGrid<T>> {
  @override
  Widget build(BuildContext context) {
    return InfiniteScrollView<T>(
      items: widget.items,
      itemBuilder: widget.itemBuilder,
      onLoadMore: widget.onLoadMore,
      hasMore: widget.hasMore,
      isLoadingInitial: widget.isLoadingInitial,
      isLoadingMore: widget.isLoadingMore,
      emptyBuilder: widget.emptyBuilder,
      padding: widget.padding,
      loadMoreExtent: widget.loadMoreExtent,
      skeletonItemBuilder: widget.skeletonItemBuilder,
      skeletonItemCount: widget.skeletonItemCount,
      loadMoreFailed: widget.loadMoreFailed,
      loadMoreErrorMessage: widget.loadMoreErrorMessage,
      sliverBuilder: (context, delegate) {
        return SliverGrid(
          gridDelegate: widget.gridDelegate,
          delegate: delegate,
        );
      },
    );
  }
}

class InfiniteScrollList<T> extends StatelessWidget {
  const InfiniteScrollList({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.onLoadMore,
    required this.hasMore,
    required this.isLoadingInitial,
    required this.isLoadingMore,
    required this.emptyBuilder,
    this.separatorBuilder,
    this.header,
    this.padding = EdgeInsets.zero,
    this.loadMoreExtent = 480,
    this.skeletonItemBuilder,
    this.skeletonItemCount = 8,
    this.loadMoreFailed = false,
    this.loadMoreErrorMessage,
  });

  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;
  final Future<void> Function() onLoadMore;
  final bool hasMore;
  final bool isLoadingInitial;
  final bool isLoadingMore;
  final WidgetBuilder emptyBuilder;
  final Widget? header;
  final EdgeInsetsGeometry padding;
  final double loadMoreExtent;
  final WidgetBuilder? skeletonItemBuilder;
  final int skeletonItemCount;

  /// See [InfiniteScrollView.loadMoreFailed].
  final bool loadMoreFailed;

  /// See [InfiniteScrollView.loadMoreErrorMessage].
  final String? loadMoreErrorMessage;

  @override
  Widget build(BuildContext context) {
    return InfiniteScrollView<T>(
      items: items,
      itemBuilder: itemBuilder,
      onLoadMore: onLoadMore,
      hasMore: hasMore,
      isLoadingInitial: isLoadingInitial,
      isLoadingMore: isLoadingMore,
      emptyBuilder: emptyBuilder,
      header: header,
      padding: padding,
      loadMoreExtent: loadMoreExtent,
      skeletonItemBuilder: skeletonItemBuilder,
      skeletonItemCount: skeletonItemCount,
      loadMoreFailed: loadMoreFailed,
      loadMoreErrorMessage: loadMoreErrorMessage,
      sliverBuilder: (context, delegate) {
        if (separatorBuilder == null) {
          return SliverList(delegate: delegate);
        }

        return SliverList.separated(
          itemCount: items.length,
          itemBuilder: (context, index) => itemBuilder(context, items[index]),
          separatorBuilder: separatorBuilder!,
        );
      },
    );
  }
}
