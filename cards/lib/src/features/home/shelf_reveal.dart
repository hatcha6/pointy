import 'package:flutter/widgets.dart';

import '../../design/cards_tokens.dart';

/// Brings a shelf's content in when it changes (a category picked from the
/// bar or a shelf's «عرض الكل», or the home tab taking the shelf back to
/// all): the old content dips out, the new one rises into place piece by
/// piece. One controller drives every piece; each [ShelfRise] takes its own
/// slice of it by its order on the page.
class ShelfReveal {
  ShelfReveal(TickerProvider vsync)
    : controller = AnimationController(
        vsync: vsync,
        value: 1,
        duration: _inDuration,
        reverseDuration: CardsMotion.fast,
      );

  final AnimationController controller;
  int _serial = 0;

  static const Duration _inDuration = Duration(milliseconds: 560);

  /// Pieces after this many rise together with the last one: a long grid
  /// never makes the customer wait for its tail.
  static const int _staggered = 8;

  /// Dips the content out, runs [change] while nothing is visible, then
  /// raises the new content. A second switch mid-way takes over: only the
  /// latest change raises the content.
  Future<void> run(BuildContext context, VoidCallback change) async {
    final serial = ++_serial;
    if (MediaQuery.disableAnimationsOf(context)) {
      change();
      controller.value = 1;
      return;
    }
    try {
      await controller.reverse().orCancel;
    } on TickerCanceled {
      return;
    }
    if (serial != _serial) {
      return;
    }
    change();
    controller.forward(from: 0);
  }

  /// The slice of the reveal the piece at [order] rises over.
  Animation<double> slice(int order) {
    final start = (order.clamp(0, _staggered) / _staggered) * 0.45;
    return CurvedAnimation(
      parent: controller,
      curve: Interval(start, start + 0.55, curve: CardsMotion.curve),
    );
  }

  void dispose() => controller.dispose();
}

/// One piece of a [ShelfReveal]: it fades in, rises a little and settles
/// from a touch smaller, the way a card is set down on a table.
class ShelfRise extends StatelessWidget {
  const ShelfRise({
    super.key,
    required this.reveal,
    required this.order,
    required this.child,
  });

  final ShelfReveal reveal;
  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = reveal.slice(order);
    return AnimatedBuilder(
      animation: t,
      child: child,
      // The same tree at rest as in motion, so a shelf keeps its scroll
      // position and a carousel its page while they dip out.
      builder: (context, child) {
        final value = t.value;
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 28),
            child: Transform.scale(scale: 0.96 + value * 0.04, child: child),
          ),
        );
      },
    );
  }
}
