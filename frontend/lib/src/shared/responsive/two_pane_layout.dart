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
    this.minPrimaryWidth = AppPaneWidths.minPrimary,
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
  final double minPrimaryWidth;
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
                minPrimaryWidth: minPrimaryWidth,
              );
          return Row(children: _wideChildren(paneWidth));
        }

        return Column(children: _compactChildren());
      },
    );
  }

  // Each pane owns a layer. The panes change independently — typing in the
  // catalog search, editing a quantity in the draft — but without boundaries
  // the nearest picture holding them is the Scaffold's whole body, so a
  // keystroke on one side re-recorded both panes and the chrome around them.
  // Measured on the purchase draft (2026-09-21 sweep): the body boundary went
  // from 4 pictures a keystroke frame covering 305% of the window to 1 at 76%,
  // and the draft pane stopped re-recording for the catalog's keystrokes
  // altogether.
  List<Widget> _wideChildren(double secondaryWidth) {
    final primary = Expanded(
      flex: primaryFlex,
      child: RepaintBoundary(child: primaryPane),
    );
    final secondary = SizedBox(
      width: secondaryWidth,
      child: RepaintBoundary(child: secondaryPane),
    );
    final divider = verticalDivider;

    if (secondaryFirst) {
      return [secondary, ?divider, primary];
    }

    return [primary, ?divider, secondary];
  }

  List<Widget> _compactChildren() {
    final primary = Expanded(
      flex: compactPrimaryFlex,
      child: RepaintBoundary(child: primaryPane),
    );
    final secondary = Expanded(
      flex: compactSecondaryFlex,
      child: RepaintBoundary(child: secondaryPane),
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
