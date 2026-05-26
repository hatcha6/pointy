import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'app_breakpoints.dart';

enum AppContentWidth { compact, form, detail, list, workspace }

class AppMaxContentWidths {
  const AppMaxContentWidths._();

  static const double compact = 430;
  static const double form = 720;
  static const double detail = 860;
  static const double list = 1120;
  static const double workspace = 1440;

  static double resolve(AppContentWidth width) {
    return switch (width) {
      AppContentWidth.compact => compact,
      AppContentWidth.form => form,
      AppContentWidth.detail => detail,
      AppContentWidth.list => list,
      AppContentWidth.workspace => workspace,
    };
  }

  static double forAvailableWidth(
    double availableWidth, {
    AppContentWidth width = AppContentWidth.workspace,
  }) {
    return math.min(availableWidth, resolve(width));
  }
}

class AppPaneWidths {
  const AppPaneWidths._();

  static const double compact = 320;
  static const double standard = 420;
  static const double desktop = 460;
  static const double widePos = 520;
  static const double minPrimary = 280;

  static double trailingPaneForWidth(
    double availableWidth, {
    double minWidth = compact,
    double maxWidth = widePos,
    double maxWidthFraction = 0.42,
    double minPrimaryWidth = minPrimary,
  }) {
    if (availableWidth < AppBreakpoints.tabletMin) {
      return availableWidth;
    }

    final preferredWidth = switch (AppBreakpoints.forWidth(availableWidth)) {
      AppBreakpoint.phone || AppBreakpoint.largePhone => compact,
      AppBreakpoint.tablet => standard,
      AppBreakpoint.desktop => desktop,
      AppBreakpoint.widePos => widePos,
    };
    final fractionLimit = math.max(minWidth, availableWidth * maxWidthFraction);
    final primaryLimit = math.max(minWidth, availableWidth - minPrimaryWidth);
    final upperBound = math.min(
      maxWidth,
      math.max(fractionLimit, primaryLimit),
    );

    return preferredWidth.clamp(minWidth, upperBound).toDouble();
  }
}

class AdaptiveMaxWidth extends StatelessWidget {
  const AdaptiveMaxWidth({
    super.key,
    required this.child,
    this.width = AppContentWidth.workspace,
    this.customMaxWidth,
    this.alignment = AlignmentDirectional.topCenter,
    this.padding,
    this.expand = true,
  });

  final Widget child;
  final AppContentWidth width;
  final double? customMaxWidth;
  final AlignmentGeometry alignment;
  final EdgeInsetsGeometry? padding;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final maxWidth = customMaxWidth ?? AppMaxContentWidths.resolve(width);
    Widget content = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: expand ? SizedBox(width: double.infinity, child: child) : child,
    );
    content = Align(alignment: alignment, child: content);

    final resolvedPadding = padding;
    if (resolvedPadding == null) {
      return content;
    }

    return Padding(padding: resolvedPadding, child: content);
  }
}
