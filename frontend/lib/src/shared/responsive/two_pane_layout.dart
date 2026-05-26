import 'package:flutter/material.dart';

import 'adaptive_constraints.dart';
import 'app_breakpoints.dart';

class TwoPaneLayout extends StatelessWidget {
  const TwoPaneLayout({
    super.key,
    required this.primaryPane,
    required this.secondaryPane,
    this.dualPaneBreakpoint = AppBreakpoints.tabletMin,
    this.primaryFlex = 3,
    this.compactPrimaryFlex = 1,
    this.compactSecondaryFlex = 1,
    this.secondaryPaneWidth,
    this.secondaryPaneMinWidth = AppPaneWidths.compact,
    this.secondaryPaneMaxWidth = AppPaneWidths.widePos,
    this.secondaryPaneMaxWidthFraction = 0.42,
    this.verticalDivider = const VerticalDivider(width: 1),
    this.horizontalDivider = const Divider(height: 1),
    this.secondaryFirst = false,
  });

  final Widget primaryPane;
  final Widget secondaryPane;
  final double dualPaneBreakpoint;
  final int primaryFlex;
  final int compactPrimaryFlex;
  final int compactSecondaryFlex;
  final double? secondaryPaneWidth;
  final double secondaryPaneMinWidth;
  final double secondaryPaneMaxWidth;
  final double secondaryPaneMaxWidthFraction;
  final Widget? verticalDivider;
  final Widget? horizontalDivider;
  final bool secondaryFirst;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = _effectiveWidth(context, constraints);
        if (width >= dualPaneBreakpoint) {
          final paneWidth =
              secondaryPaneWidth ??
              AppPaneWidths.trailingPaneForWidth(
                width,
                minWidth: secondaryPaneMinWidth,
                maxWidth: secondaryPaneMaxWidth,
                maxWidthFraction: secondaryPaneMaxWidthFraction,
              );
          return Row(children: _wideChildren(paneWidth));
        }

        return Column(children: _compactChildren());
      },
    );
  }

  List<Widget> _wideChildren(double secondaryWidth) {
    final primary = Expanded(flex: primaryFlex, child: primaryPane);
    final secondary = SizedBox(width: secondaryWidth, child: secondaryPane);
    final divider = verticalDivider;

    if (secondaryFirst) {
      return [secondary, ?divider, primary];
    }

    return [primary, ?divider, secondary];
  }

  List<Widget> _compactChildren() {
    final primary = Expanded(flex: compactPrimaryFlex, child: primaryPane);
    final secondary = Expanded(
      flex: compactSecondaryFlex,
      child: secondaryPane,
    );
    final divider = horizontalDivider;

    if (secondaryFirst) {
      return [secondary, ?divider, primary];
    }

    return [primary, ?divider, secondary];
  }

  double _effectiveWidth(BuildContext context, BoxConstraints constraints) {
    if (constraints.hasBoundedWidth) {
      return constraints.maxWidth;
    }
    return MediaQuery.sizeOf(context).width;
  }
}
