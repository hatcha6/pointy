import 'package:flutter/material.dart';

import '../design/design.dart';
import 'pointy_shell_action_scope.dart';
import '../components/pointy_progress.dart';

enum PointyAppBarStyle { standard, highFocus }

class PointyAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PointyAppBar({
    super.key,
    required this.title,
    this.style = PointyAppBarStyle.standard,
    this.leading,
    this.actions = const [],
    this.isLoading = false,
    this.centerTitle = true,
    this.reserveLoadingSlot = true,
    this.bottom,
  });

  final Widget title;
  final PointyAppBarStyle style;
  final Widget? leading;
  final List<Widget> actions;
  final bool isLoading;
  final bool centerTitle;
  final bool reserveLoadingSlot;
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize {
    final bottomHeight = bottom?.preferredSize.height ?? 0;
    return Size.fromHeight(kToolbarHeight + bottomHeight);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scopedActions =
        PointyShellActionScope.maybeOf(context)?.buildAppBarActions(context) ??
        const <Widget>[];
    final appBarTheme = switch (style) {
      PointyAppBarStyle.standard => theme.appBarTheme,
      PointyAppBarStyle.highFocus => PointyComponentStyles.darkAppBarTheme(
        theme.textTheme,
      ),
    };

    return AppBar(
      leading: leading,
      title: title,
      centerTitle: centerTitle,
      actions: [
        if (reserveLoadingSlot)
          _LoadingSlot(isLoading: isLoading, color: appBarTheme.foregroundColor)
        else if (isLoading)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: _AppBarProgress(color: appBarTheme.foregroundColor),
          ),
        ...scopedActions,
        ...actions,
      ],
      bottom: bottom,
      backgroundColor: appBarTheme.backgroundColor,
      foregroundColor: appBarTheme.foregroundColor,
      surfaceTintColor: appBarTheme.surfaceTintColor,
      elevation: appBarTheme.elevation,
      scrolledUnderElevation: appBarTheme.scrolledUnderElevation,
      titleTextStyle: appBarTheme.titleTextStyle,
      iconTheme: appBarTheme.iconTheme,
      actionsIconTheme: appBarTheme.actionsIconTheme,
    );
  }
}

class _LoadingSlot extends StatelessWidget {
  const _LoadingSlot({required this.isLoading, required this.color});

  final bool isLoading;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: PointyDimensions.iconButton,
      child: Center(
        child: isLoading
            ? _AppBarProgress(color: color)
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _AppBarProgress extends StatelessWidget {
  const _AppBarProgress({required this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 18,
      child: PointySpinner(
        strokeWidth: 2,
        color: color ?? PointyColors.primary,
      ),
    );
  }
}
