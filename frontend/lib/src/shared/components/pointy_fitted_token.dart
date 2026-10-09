import 'package:flutter/material.dart';

/// A code somebody has to read into a meter or a phone — a prepaid token, a
/// card's PIN — kept on ONE line: split over two it is easily read wrongly.
///
/// It lays [code] out left to right at [style]'s size and, when the width it
/// is given is not enough, scales the whole line down to fit instead of
/// wrapping it. The text stays selectable, so it can still be copied by hand.
class PointyFittedToken extends StatelessWidget {
  const PointyFittedToken({
    super.key,
    required this.code,
    required this.style,
    this.textKey,
  });

  final String code;
  final TextStyle style;

  /// The key of the selectable text itself, for tests and for finders.
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    // A FittedBox, not a LayoutBuilder: dialogs ask their content for its
    // intrinsic width, which a LayoutBuilder cannot answer.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SelectableText(
        code,
        key: textKey,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        style: style,
      ),
    );
  }
}
