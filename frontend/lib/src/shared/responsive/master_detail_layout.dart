import 'package:flutter/material.dart';

import '../design/pointy_motion.dart';
import 'app_breakpoints.dart';
import 'two_pane_layout.dart';

/// Master-detail orchestrator for management screens.
///
/// At [dualPaneBreakpoint] and above, the list renders as a fixed-width
/// leading pane and the detail (or [placeholder]) fills the rest. Below it,
/// only the list renders and the screen keeps its existing push-navigation —
/// selection state stays in the screen, this widget only arranges panes.
class MasterDetailLayout extends StatelessWidget {
  const MasterDetailLayout({
    super.key,
    required this.listPaneBuilder,
    required this.placeholder,
    this.detailPane,
    this.dualPaneBreakpoint = AppBreakpoints.masterDetailMin,
    this.listPaneWidth,
  });

  /// Builds the list pane. `isDualPane` tells the screen whether row taps
  /// should update the inline selection (true) or push a route (false).
  final Widget Function(BuildContext context, bool isDualPane) listPaneBuilder;

  /// Shown in the detail pane while nothing is selected.
  final Widget placeholder;

  /// The currently selected item's detail view. Give distinct selections
  /// distinct keys so the swap animation runs.
  final Widget? detailPane;

  final double dualPaneBreakpoint;
  final double? listPaneWidth;

  /// Whether a screen at this width shows the inline detail pane. Prefer the
  /// `isDualPane` flag passed to [listPaneBuilder] (it reflects the actual
  /// pane constraints); this viewport-based check is for handlers that run
  /// outside the layout, such as barcode scans.
  static bool isDualPane(
    BuildContext context, {
    double breakpoint = AppBreakpoints.masterDetailMin,
  }) {
    return MediaQuery.sizeOf(context).width >= breakpoint;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final isDual = width >= dualPaneBreakpoint;
        final list = listPaneBuilder(context, isDual);

        if (!isDual) {
          return list;
        }

        final detail = AnimatedSwitcher(
          duration: PointyMotion.standard,
          switchInCurve: PointyMotion.curve,
          switchOutCurve: PointyMotion.curve,
          child:
              detailPane ??
              KeyedSubtree(
                key: const ValueKey('master_detail_placeholder'),
                child: placeholder,
              ),
        );

        return TwoPaneLayout(
          dualPaneBreakpoint: dualPaneBreakpoint,
          primaryPane: detail,
          secondaryPane: list,
          secondaryFirst: true,
          secondaryPaneWidth: listPaneWidth,
        );
      },
    );
  }
}
