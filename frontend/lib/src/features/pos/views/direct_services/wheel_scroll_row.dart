import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A row that scrolls sideways under a finger, a dragged mouse and the mouse
/// wheel alike — a wheel has no sideways axis, so its turns move the row —
/// so nothing in it is ever out of reach of the cashier's hand.
class WheelScrollRow extends StatefulWidget {
  const WheelScrollRow({
    super.key,
    required this.child,
    this.padding,
    this.fadeEdges = false,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// Fades the row out at both ends, so an item cut by the edge reads as
  /// scrolling on rather than as clipped.
  final bool fadeEdges;

  @override
  State<WheelScrollRow> createState() => _WheelScrollRowState();
}

class _WheelScrollRowState extends State<WheelScrollRow> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final position = _controller.position;
      if (position.maxScrollExtent <= 0) {
        return;
      }
      final delta = (event as PointerScrollEvent).scrollDelta;
      final turn = delta.dx != 0 ? delta.dx : delta.dy;
      _controller.jumpTo(
        (position.pixels + turn).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final row = Listener(
      onPointerSignal: _onWheel,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: PointerDeviceKind.values.toSet(),
          scrollbars: false,
        ),
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: widget.padding,
          child: widget.child,
        ),
      ),
    );
    if (!widget.fadeEdges) {
      return row;
    }
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        colors: [
          Color(0x00FFFFFF),
          Color(0xFFFFFFFF),
          Color(0xFFFFFFFF),
          Color(0x00FFFFFF),
        ],
        stops: [0, 0.04, 0.94, 1],
      ).createShader(bounds),
      child: row,
    );
  }
}
