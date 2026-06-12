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
    this.header,
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

  /// Scrolls with the items above the first row, and stays visible in the
  /// loading, error, and empty states.
  final Widget? header;
  final bool framed;
  final double loadMoreExtent;

  @override
  Widget build(BuildContext context) {
    final Widget? stateBody;
    if (isLoadingInitial && items.isEmpty) {
      stateBody = const PointyLoadingArea();
    } else if (hasError && items.isEmpty && errorBuilder != null) {
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

    final colors = context.pointyColors;
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
        boxShadow: PointyShadows.raised,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: list,
      ),
    );
  }
}
