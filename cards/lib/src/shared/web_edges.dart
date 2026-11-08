import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'web_edges_css.dart'
    if (dart.library.js_interop) 'web_edges_css_web.dart';

/// The web build's page edges, as Safari on an iPhone paints them.
///
/// Safari gives the page the screen between the status bar and its own
/// floating toolbar, and paints those two strips itself, taking each colour
/// from the CSS background at that edge of the page. The app is a canvas
/// with no CSS colour, so the strips came out a flat colour that did not
/// match the app, most visibly a band under the tab bar. Measured on iOS
/// 27 Safari: the toolbar strip stays outside the page whatever the
/// viewport says (`viewport-fit=cover` changes nothing), a background that
/// is a two-colour gradient tints each strip separately, and thin stripes
/// or anything under the canvas are ignored.
///
/// So the page's CSS background carries the app's top colour above and its
/// bottom colour below: the page colour, and the tab bar's while the shell
/// is in front ([WebBottomEdge]). Off the web it does nothing.
class WebEdges extends StatefulWidget {
  const WebEdges({super.key, required this.child});

  final Widget child;

  @override
  State<WebEdges> createState() => _WebEdgesState();
}

class _WebEdgesState extends State<WebEdges> {
  /// The colour a [WebBottomEdge] on the front screen claims.
  Color? _bottom;
  String? _shown;

  void _claim(Color? bottom) {
    if (bottom != _bottom) {
      _bottom = bottom;
      _paint();
    }
  }

  void _paint() {
    if (!kIsWeb || !mounted) {
      return;
    }
    final page = Theme.of(context).scaffoldBackgroundColor;
    final css = edgesCss(top: page, bottom: _bottom ?? page);
    if (css != _shown) {
      _shown = css;
      setPageBackground(css);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The theme may have changed (light, dark): paint once the frame is done.
    WidgetsBinding.instance.addPostFrameCallback((_) => _paint());
    return _WebEdgesScope(state: this, child: widget.child);
  }
}

class _WebEdgesScope extends InheritedWidget {
  const _WebEdgesScope({required this.state, required super.child});

  final _WebEdgesState state;

  @override
  bool updateShouldNotify(_WebEdgesScope oldWidget) => false;
}

/// Claims the page's bottom edge for [color] while this widget's screen is
/// the front one: a bar that sits on the bottom edge.
class WebBottomEdge extends StatefulWidget {
  const WebBottomEdge({super.key, required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<WebBottomEdge> createState() => _WebBottomEdgeState();
}

class _WebBottomEdgeState extends State<WebBottomEdge> {
  _WebEdgesState? _edges;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      _edges = context.getInheritedWidgetOfExactType<_WebEdgesScope>()?.state;
      // Read as a dependency: the screen rebuilds when it stops being the
      // front one, and gives the edge back.
      final front = ModalRoute.of(context)?.isCurrent ?? true;
      final color = widget.color;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _edges?._claim(front ? color : null),
      );
    }
    return widget.child;
  }

  @override
  void dispose() {
    final edges = _edges;
    if (edges != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => edges._claim(null));
    }
    super.dispose();
  }
}

/// The CSS background with [top] on the upper half and [bottom] below.
@visibleForTesting
String edgesCss({required Color top, required Color bottom}) {
  String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  return top == bottom
      ? hex(top)
      : 'linear-gradient(${hex(top)} 50%, ${hex(bottom)} 50%)';
}
