import 'package:flutter/material.dart';

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

  @override
  State<InfiniteScrollGrid<T>> createState() => _InfiniteScrollGridState<T>();
}

class _InfiniteScrollGridState<T> extends State<InfiniteScrollGrid<T>> {
  late final ScrollController _controller;
  bool _loadInFlight = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController()..addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
  }

  @override
  void didUpdateWidget(covariant InfiniteScrollGrid<T> oldWidget) {
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
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.items.isEmpty) {
      return widget.emptyBuilder(context);
    }

    return CustomScrollView(
      controller: _controller,
      slivers: [
        SliverPadding(
          padding: widget.padding,
          sliver: SliverGrid.builder(
            gridDelegate: widget.gridDelegate,
            itemCount: widget.items.length,
            itemBuilder: (context, index) {
              return widget.itemBuilder(context, widget.items[index]);
            },
          ),
        ),
        if (widget.isLoadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}
