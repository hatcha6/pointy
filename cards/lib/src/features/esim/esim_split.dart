import 'package:flutter/material.dart';

import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';

/// An eSIM page on a wide screen (the iPhone Duo open on its side, a tablet):
/// the card and the main action on the leading side, the details scrolling
/// beside them. Each side is told the room it really has, so what is inside
/// it lays out as on a phone.
class EsimSplit extends StatelessWidget {
  const EsimSplit({super.key, required this.start, required this.end});

  final Widget start;
  final Widget end;

  /// Whether a page with this screen is laid out side by side.
  static bool of(BuildContext context) =>
      CardsLayout.sideBySide(MediaQuery.sizeOf(context));

  @override
  Widget build(BuildContext context) {
    Widget side(Widget child, BoxConstraints box) => MediaQuery(
      data: MediaQuery.of(context).copyWith(size: box.biggest),
      child: child,
    );
    // On a desktop's broad window the two sides stay together, centred, as
    // the shelf does.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: CardsLayout.shelf),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: LayoutBuilder(builder: (context, box) => side(start, box)),
            ),
            const SizedBox(width: CardsSpace.sm),
            Expanded(
              flex: 6,
              child: LayoutBuilder(builder: (context, box) => side(end, box)),
            ),
          ],
        ),
      ),
    );
  }
}
