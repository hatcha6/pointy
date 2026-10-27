import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../design/cards_tokens.dart';

/// A pinned header holding one row of controls (the shelf's categories,
/// My Cards' filters) the way Apple's pages pin them: nothing opaque, a soft
/// fade over the content once it scrolls beneath, reaching up under the
/// status bar too. With no [child] it takes no room.
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
    final theme = Theme.of(context);
    final scrolled = overlapsContent || shrinkOffset > 0;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: -statusBar,
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedOpacity(
            duration: CardsMotion.standard,
            opacity: scrolled ? 1 : 0,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0, 0.55, 1],
              ).createShader(bounds),
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: ColoredBox(
                    color: theme.scaffoldBackgroundColor.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
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
