import 'package:flutter/widgets.dart';

/// The system side column a page sets aside (the iPhone Duo), handed to the
/// rows inside the page that should run on under it, as Apple's own
/// horizontal shelves do there: the row starts in line with the page and
/// scrolls on underneath the column's glass to the screen's edge.
class ColumnBleedScope extends InheritedWidget {
  const ColumnBleedScope({
    super.key,
    required this.insets,
    required super.child,
  });

  /// The column, on its side of the screen (left or right only).
  final EdgeInsets insets;

  static EdgeInsets of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ColumnBleedScope>()?.insets ??
      EdgeInsets.zero;

  @override
  bool updateShouldNotify(ColumnBleedScope oldWidget) =>
      oldWidget.insets != insets;
}

/// A horizontal row that runs on under the side column: [builder] gets the
/// column's insets to add to the row's own padding, so its first item stays
/// in line with the page. Where there is no column it is the row as it is.
///
/// The scroll view holding the row must not clip it (its clipBehavior
/// none while there is a column).
class ColumnBleed extends StatelessWidget {
  const ColumnBleed({super.key, required this.builder});

  final Widget Function(EdgeInsets extra) builder;

  @override
  Widget build(BuildContext context) {
    final insets = ColumnBleedScope.of(context);
    if (insets == EdgeInsets.zero) {
      return builder(EdgeInsets.zero);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth + insets.horizontal;
        return OverflowBox(
          alignment: insets.right > 0
              ? Alignment.centerLeft
              : Alignment.centerRight,
          minWidth: width,
          maxWidth: width,
          child: builder(insets),
        );
      },
    );
  }
}
