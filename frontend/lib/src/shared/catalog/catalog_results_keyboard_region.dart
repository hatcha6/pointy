import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../barcode/barcode_scan_listener.dart';
import 'catalog_results_focus.dart';

/// The catalog results grid as the keyboard sees it: arrows move between
/// products, Enter adds the focused one.
///
/// * The arrows are bound here, explicitly, to directional focus. The app's
///   default bindings differ by platform — on the web they scroll the list
///   instead — and a picker that works on one till and not another is worse
///   than none.
/// * [ArrowKeyNavigationRegion] keeps the scan listener from spending the
///   same arrows on its own shortcut (cycling the active line's unit).
/// * [focus] lets the search box send ↓ to the FIRST result, not to whichever
///   card happens to sit geometrically nearest below it.
class CatalogResultsKeyboardRegion extends StatefulWidget {
  const CatalogResultsKeyboardRegion({
    super.key,
    required this.focus,
    required this.child,
  });

  final CatalogResultsFocus focus;
  final Widget child;

  @override
  State<CatalogResultsKeyboardRegion> createState() =>
      _CatalogResultsKeyboardRegionState();
}

class _CatalogResultsKeyboardRegionState
    extends State<CatalogResultsKeyboardRegion> {
  final FocusNode _node = FocusNode(
    debugLabel: 'catalog_results',
    canRequestFocus: false,
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    widget.focus.attach(_focusFirst);
  }

  @override
  void didUpdateWidget(covariant CatalogResultsKeyboardRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focus, widget.focus)) {
      oldWidget.focus.detach(_focusFirst);
      widget.focus.attach(_focusFirst);
    }
  }

  @override
  void dispose() {
    widget.focus.detach(_focusFirst);
    _node.dispose();
    super.dispose();
  }

  bool _focusFirst() {
    final first = _node.traversalDescendants.firstOrNull;
    final context = first?.context;
    if (first == null || context == null) {
      return false;
    }
    first.requestFocus();
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 120),
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return ArrowKeyNavigationRegion(
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
            TraversalDirection.up,
          ),
          SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
            TraversalDirection.down,
          ),
          SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
            TraversalDirection.left,
          ),
          SingleActivator(LogicalKeyboardKey.arrowRight):
              DirectionalFocusIntent(TraversalDirection.right),
        },
        child: Focus(
          focusNode: _node,
          canRequestFocus: false,
          skipTraversal: true,
          child: widget.child,
        ),
      ),
    );
  }
}
