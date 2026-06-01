import 'package:flutter/widgets.dart';

typedef PointyAppBarActionsBuilder =
    List<Widget> Function(BuildContext context);
typedef PointyEndDrawerBuilder = Widget Function(BuildContext context);

class PointyShellActionScope extends InheritedWidget {
  const PointyShellActionScope({
    super.key,
    required super.child,
    this.appBarActionsBuilder,
    this.endDrawerBuilder,
  });

  final PointyAppBarActionsBuilder? appBarActionsBuilder;
  final PointyEndDrawerBuilder? endDrawerBuilder;

  static PointyShellActionScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PointyShellActionScope>();
  }

  List<Widget> buildAppBarActions(BuildContext context) {
    return appBarActionsBuilder?.call(context) ?? const [];
  }

  Widget? buildEndDrawer(BuildContext context) {
    return endDrawerBuilder?.call(context);
  }

  @override
  bool updateShouldNotify(PointyShellActionScope oldWidget) {
    return appBarActionsBuilder != oldWidget.appBarActionsBuilder ||
        endDrawerBuilder != oldWidget.endDrawerBuilder;
  }
}
