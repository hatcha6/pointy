import 'package:flutter/material.dart';

import '../app_navigation_drawer.dart';
import '../responsive/responsive.dart';
import 'pointy_navigation_rail_scope.dart';
import 'pointy_shell_action_scope.dart';

class PointyScaffold extends StatefulWidget {
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
  State<PointyScaffold> createState() => _PointyScaffoldState();
}

class _PointyScaffoldState extends State<PointyScaffold> {
  late final PointyNavigationRailController _fallbackNavigationRailController;

  @override
  void initState() {
    super.initState();
    _fallbackNavigationRailController = PointyNavigationRailController();
    _fallbackNavigationRailController.addListener(
      _handleFallbackNavigationRailChanged,
    );
  }

  @override
  void dispose() {
    _fallbackNavigationRailController.removeListener(
      _handleFallbackNavigationRailChanged,
    );
    _fallbackNavigationRailController.dispose();
    super.dispose();
  }

  void _handleFallbackNavigationRailChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final parentNavigationRailScope = PointyNavigationRailScope.maybeOf(
      context,
    );
    final navigationRailController =
        parentNavigationRailScope?.controller ??
        _fallbackNavigationRailController;
    final navigationDrawer = widget.drawer;
    final shellActionScope = PointyShellActionScope.maybeOf(context);
    final resolvedEndDrawer =
        widget.endDrawer ?? shellActionScope?.buildEndDrawer(context);
    final usesNavigationRail =
        navigationDrawer is AppNavigationDrawer &&
        AppBreakpoints.of(context).index >= AppBreakpoint.desktop.index;

    Widget resolvedBody = widget.body;
    if (usesNavigationRail) {
      resolvedBody = Row(
        children: [
          navigationDrawer.buildRail(
            context,
            extended: navigationRailController.isExpanded,
          ),
          const VerticalDivider(width: 1),
          Expanded(child: resolvedBody),
        ],
      );
    }

    if (widget.safeArea) {
      resolvedBody = SafeArea(
        top: widget.safeAreaTop,
        bottom: widget.safeAreaBottom,
        left: widget.safeAreaLeft,
        right: widget.safeAreaRight,
        child: resolvedBody,
      );
    }

    return PointyNavigationRailScope(
      isActive: usesNavigationRail,
      controller: navigationRailController,
      // Pass the app shell's bucket through so the drawer/rail surfaces (below
      // this re-wrap) keep their scroll offsets across page changes.
      navigationBucket: parentNavigationRailScope?.navigationBucket,
      child: Scaffold(
        appBar: widget.appBar,
        drawer: usesNavigationRail ? null : widget.drawer,
        endDrawer: resolvedEndDrawer,
        floatingActionButton: widget.floatingActionButton,
        bottomNavigationBar: widget.bottomNavigationBar,
        backgroundColor: widget.backgroundColor,
        resizeToAvoidBottomInset: widget.resizeToAvoidBottomInset,
        body: resolvedBody,
      ),
    );
  }
}
