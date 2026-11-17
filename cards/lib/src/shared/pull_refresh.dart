import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pull-to-refresh for a page whose header pins: the spinner starts at the
/// top, and as the page scrolls and the header pins it slides down to sit
/// just below it, so a refresh still running never spins over the header.
class PullRefresh extends StatefulWidget {
  const PullRefresh({
    super.key,
    required this.onRefresh,
    required this.scroll,
    required this.pinnedAt,
    required this.pinnedExtent,
    required this.child,
  });

  final Future<void> Function() onRefresh;

  /// The page's scroll position.
  final ScrollController scroll;

  /// How far the page scrolls before its header has pinned.
  final double pinnedAt;

  /// How tall the header is once pinned.
  final double pinnedExtent;

  final Widget child;

  /// The spinner already rests this far down, less the gap it keeps from the
  /// header.
  static const double _rest = 24;

  @override
  State<PullRefresh> createState() => _PullRefreshState();
}

class _PullRefreshState extends State<PullRefresh> {
  /// How far the header has pinned, 0 to 1.
  double _pinned = 0;

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_follow);
  }

  @override
  void didUpdateWidget(PullRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scroll != widget.scroll) {
      oldWidget.scroll.removeListener(_follow);
      widget.scroll.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_follow);
    super.dispose();
  }

  /// Rebuilds only while the header is pinning: past it the answer never
  /// changes, so a long scroll costs nothing here.
  void _follow() {
    final scroll = widget.scroll;
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final pinned = widget.pinnedAt <= 0
        ? 0.0
        : (offset / widget.pinnedAt).clamp(0.0, 1.0);
    if (pinned != _pinned) {
      setState(() => _pinned = pinned);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      edgeOffset:
          _pinned * math.max(0.0, widget.pinnedExtent - PullRefresh._rest),
      child: widget.child,
    );
  }
}
