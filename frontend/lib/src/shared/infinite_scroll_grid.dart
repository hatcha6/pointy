import 'package:flutter/material.dart';

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
      return _withHeader(
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
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

    return CustomScrollView(
      controller: _controller,
      slivers: [
        if (widget.header != null)
          SliverToBoxAdapter(child: widget.header),
        SliverPadding(
          padding: widget.padding,
          sliver: widget.sliverBuilder(context, delegate),
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

  Widget _withHeader(Widget body) {
    final header = widget.header;
    if (header == null) {
      if (widget.isLoadingInitial && widget.items.isEmpty) {
        return const Center(child: CircularProgressIndicator());
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
