import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'adaptive_constraints.dart';
import 'app_breakpoints.dart';

enum AdaptiveModalSize { compact, standard, expanded }

class AdaptiveModalSizing {
  const AdaptiveModalSizing._();

  static double maxWidthFor(
    double availableWidth, {
    AdaptiveModalSize size = AdaptiveModalSize.standard,
  }) {
    if (availableWidth < AppBreakpoints.tabletMin) {
      return availableWidth;
    }

    final width = switch (size) {
      AdaptiveModalSize.compact => AppPaneWidths.standard,
      AdaptiveModalSize.standard => AppMaxContentWidths.form,
      AdaptiveModalSize.expanded => AppMaxContentWidths.detail,
    };

    return math.min(availableWidth, width);
  }

  static double maxHeightFactorForWidth(double width) {
    return switch (AppBreakpoints.forWidth(width)) {
      AppBreakpoint.phone => 0.94,
      AppBreakpoint.largePhone => 0.92,
      AppBreakpoint.tablet => 0.88,
      AppBreakpoint.desktop => 0.86,
      AppBreakpoint.widePos => 0.88,
    };
  }
}

class AdaptiveModalSheet extends StatelessWidget {
  const AdaptiveModalSheet({
    super.key,
    required this.child,
    this.size = AdaptiveModalSize.standard,
    this.maxWidth,
    this.maxHeight,
    this.maxHeightFactor,
  });

  final Widget child;
  final AdaptiveModalSize size;
  final double? maxWidth;
  final double? maxHeight;
  final double? maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final availableSize = MediaQuery.sizeOf(context);
    final resolvedMaxWidth =
        maxWidth ??
        AdaptiveModalSizing.maxWidthFor(availableSize.width, size: size);
    final resolvedMaxHeight =
        maxHeight ??
        availableSize.height *
            (maxHeightFactor ??
                AdaptiveModalSizing.maxHeightFactorForWidth(
                  availableSize.width,
                ));

    return Align(
      alignment: AlignmentDirectional.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: resolvedMaxWidth,
          maxHeight: resolvedMaxHeight,
        ),
        child: child,
      ),
    );
  }
}

class AdaptiveDialogSurface extends StatelessWidget {
  const AdaptiveDialogSurface({
    super.key,
    required this.child,
    this.size = AdaptiveModalSize.standard,
    this.maxWidth,
    this.maxHeight,
    this.maxHeightFactor,
  });

  final Widget child;
  final AdaptiveModalSize size;
  final double? maxWidth;
  final double? maxHeight;
  final double? maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final availableSize = MediaQuery.sizeOf(context);
    final resolvedMaxWidth =
        maxWidth ??
        AdaptiveModalSizing.maxWidthFor(availableSize.width, size: size);
    final resolvedMaxHeight =
        maxHeight ??
        availableSize.height *
            (maxHeightFactor ??
                AdaptiveModalSizing.maxHeightFactorForWidth(
                  availableSize.width,
                ));

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: resolvedMaxWidth,
          maxHeight: resolvedMaxHeight,
        ),
        child: child,
      ),
    );
  }
}

Future<T?> showAdaptiveModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  AdaptiveModalSize size = AdaptiveModalSize.standard,
  double? maxWidth,
  double? maxHeight,
  double? maxHeightFactor,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  bool showDragHandle = true,
  bool enableDrag = true,
  bool isDismissible = true,
  Color? backgroundColor,
  ShapeBorder? shape,
  Clip? clipBehavior,
  RouteSettings? routeSettings,
}) {
  final availableWidth = MediaQuery.sizeOf(context).width;
  final resolvedMaxWidth =
      maxWidth ?? AdaptiveModalSizing.maxWidthFor(availableWidth, size: size);

  return showModalBottomSheet<T>(
    context: context,
    constraints: BoxConstraints(maxWidth: resolvedMaxWidth),
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    showDragHandle: showDragHandle,
    enableDrag: enableDrag,
    isDismissible: isDismissible,
    backgroundColor: backgroundColor,
    shape: shape,
    clipBehavior: clipBehavior,
    routeSettings: routeSettings,
    builder: (sheetContext) {
      return AdaptiveModalSheet(
        size: size,
        maxWidth: resolvedMaxWidth,
        maxHeight: maxHeight,
        maxHeightFactor: maxHeightFactor,
        child: builder(sheetContext),
      );
    },
  );
}
