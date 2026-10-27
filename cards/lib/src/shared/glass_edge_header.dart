import 'package:flutter/material.dart';

import '../design/cards_tokens.dart';
import 'glass_edge.dart';

/// A pinned header holding one row of controls (the shelf's categories,
/// My Cards' filters) the way Apple's pages pin them: nothing opaque, and
/// once content scrolls beneath, iOS's soft scroll edge ([GlassEdge]) reaching
/// up under the status bar too. With no [child] it takes no room.
class GlassEdgeHeader extends SliverPersistentHeaderDelegate {
  GlassEdgeHeader({
    required this.child,
    required this.childHeight,
    this.top = 0,
    this.statusBar = 0,
  });

  final Widget? child;
  final double childHeight;

  /// Room above the row where no status bar gives any: the iPhone Duo,
  /// whose status items sit in the side column, would otherwise pin the row
  /// against the screen's top edge.
  final double top;

  /// The status bar above the header: the fade reaches up under it, so the
  /// content passing beneath fades there too.
  final double statusBar;

  /// Room above the controls for the page: none where the status bar gives
  /// it, some where it does not (the iPhone Duo).
  static double topFor(EdgeInsets padding) =>
      padding.top < 24 ? CardsSpace.lg : 0;

  @override
  double get minExtent => child == null ? 0 : top + childHeight + CardsSpace.md;

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final scrolled = overlapsContent || shrinkOffset > 0;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: -statusBar,
          left: 0,
          right: 0,
          // A little past the row, so the blur has room to die away.
          bottom: -CardsSpace.md,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: scrolled ? 1 : 0),
            duration: CardsMotion.standard,
            curve: CardsMotion.curve,
            builder: (context, amount, _) => GlassEdge(amount: amount),
          ),
        ),
        if (child case final row?)
          Padding(
            padding: EdgeInsets.only(top: top),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(height: childHeight, child: row),
            ),
          ),
      ],
    );
  }

  @override
  bool shouldRebuild(covariant GlassEdgeHeader oldDelegate) => true;
}
