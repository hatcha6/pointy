import 'package:flutter/material.dart';

import '../design/design.dart';
import '../infinite_scroll_grid.dart';
import 'pointy_skeleton.dart';

class PointyDataList<T> extends StatelessWidget {
  const PointyDataList({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.onLoadMore,
    required this.hasMore,
    required this.isLoadingInitial,
    required this.isLoadingMore,
    required this.emptyBuilder,
    this.hasError = false,
    this.errorBuilder,
    this.padding = const EdgeInsets.all(8),
    this.separatorBuilder,
    this.header,
    this.framed = true,
    this.loadMoreExtent = 480,
    this.skeletonItemBuilder,
    this.skeletonItemCount = 6,
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
  final bool hasError;
  final WidgetBuilder? errorBuilder;
  final EdgeInsetsGeometry padding;
  final IndexedWidgetBuilder? separatorBuilder;

  /// Scrolls with the items above the first row, and stays visible in the
  /// loading, error, and empty states.
  final Widget? header;
  final bool framed;
  final double loadMoreExtent;

  /// Placeholder row shown (×[skeletonItemCount]) while the first page loads.
  /// Defaults to a generic [PointySkeletonListTile]; override to match an
  /// unusual row shape.
  final WidgetBuilder? skeletonItemBuilder;
  final int skeletonItemCount;

  /// See [InfiniteScrollView.loadMoreFailed]. Note this is about a page AFTER
  /// the first; [hasError] is the first page failing with nothing to show.
  final bool loadMoreFailed;

  /// See [InfiniteScrollView.loadMoreErrorMessage].
  final String? loadMoreErrorMessage;

  @override
  Widget build(BuildContext context) {
    // A content-shaped skeleton (not a spinner) makes the first paint feel
    // instant; framed so it matches the loaded list.
    if (isLoadingInitial && items.isEmpty) {
      final skeleton = _framed(context, _skeletonList(context));
      if (header == null) {
        return skeleton;
      }
      return ListView(children: [header!, skeleton]);
    }

    final Widget? stateBody;
    if (hasError && items.isEmpty && errorBuilder != null) {
      stateBody = errorBuilder!(context);
    } else if (items.isEmpty) {
      stateBody = emptyBuilder(context);
    } else {
      stateBody = null;
    }
    if (stateBody != null) {
      if (header == null) {
        return stateBody;
      }
      return ListView(children: [header!, stateBody]);
    }

    final list = InfiniteScrollList<T>(
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
      loadMoreFailed: loadMoreFailed,
      loadMoreErrorMessage: loadMoreErrorMessage,
      separatorBuilder: separatorBuilder ?? (_, _) => const SizedBox(height: 8),
    );

    return _framed(context, list);
  }

  Widget _framed(BuildContext context, Widget child) {
    if (!framed) {
      return child;
    }
    final colors = context.pointyColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        boxShadow: PointyShadows.raised,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: child,
      ),
    );
  }

  Widget _skeletonList(BuildContext context) {
    final builder =
        skeletonItemBuilder ?? (_) => const PointySkeletonListTile();
    final separator = separatorBuilder ?? (_, _) => const SizedBox(height: 8);
    return PointySkeleton(
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: padding,
        itemCount: skeletonItemCount,
        itemBuilder: (context, index) => builder(context),
        separatorBuilder: separator,
      ),
    );
  }
}
