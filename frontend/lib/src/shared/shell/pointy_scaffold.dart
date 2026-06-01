import 'package:flutter/material.dart';

import '../app_navigation_drawer.dart';
import '../responsive/responsive.dart';

class PointyScaffold extends StatelessWidget {
  const PointyScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.drawer,
    this.endDrawer,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.backgroundColor,
    this.safeArea = true,
    this.safeAreaTop = true,
    this.safeAreaBottom = true,
    this.safeAreaLeft = true,
    this.safeAreaRight = true,
    this.resizeToAvoidBottomInset,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? drawer;
  final Widget? endDrawer;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final Color? backgroundColor;
  final bool safeArea;
  final bool safeAreaTop;
  final bool safeAreaBottom;
  final bool safeAreaLeft;
  final bool safeAreaRight;
  final bool? resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    final navigationDrawer = drawer;
    final usesNavigationRail =
        navigationDrawer is AppNavigationDrawer &&
        AppBreakpoints.of(context).index >= AppBreakpoint.desktop.index;

    Widget resolvedBody = body;
    if (usesNavigationRail) {
      resolvedBody = Row(
        children: [
          navigationDrawer.buildRail(context),
          const VerticalDivider(width: 1),
          Expanded(child: resolvedBody),
        ],
      );
    }

    if (safeArea) {
      resolvedBody = SafeArea(
        top: safeAreaTop,
        bottom: safeAreaBottom,
        left: safeAreaLeft,
        right: safeAreaRight,
        child: resolvedBody,
      );
    }

    return Scaffold(
      appBar: appBar,
      drawer: drawer,
      endDrawer: endDrawer,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      backgroundColor: backgroundColor,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      body: resolvedBody,
    );
  }
}
