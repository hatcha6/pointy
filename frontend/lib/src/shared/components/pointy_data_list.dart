import 'package:flutter/material.dart';

import '../design/design.dart';
import '../infinite_scroll_grid.dart';
import 'pointy_loading_area.dart';

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
    this.framed = true,
    this.loadMoreExtent = 480,
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
  final bool framed;
  final double loadMoreExtent;

  @override
  Widget build(BuildContext context) {
    if (isLoadingInitial && items.isEmpty) {
      return const PointyLoadingArea();
    }
    if (hasError && items.isEmpty && errorBuilder != null) {
      return errorBuilder!(context);
    }
    if (items.isEmpty) {
      return emptyBuilder(context);
    }

    final colors = context.pointyColors;
    final list = InfiniteScrollList<T>(
      items: items,
      itemBuilder: itemBuilder,
      onLoadMore: onLoadMore,
      hasMore: hasMore,
      isLoadingInitial: isLoadingInitial,
      isLoadingMore: isLoadingMore,
      emptyBuilder: emptyBuilder,
      padding: padding,
      loadMoreExtent: loadMoreExtent,
      separatorBuilder: separatorBuilder ?? (_, _) => const SizedBox(height: 8),
    );

    if (!framed) {
      return list;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: list,
      ),
    );
  }
}
