import 'package:flutter/material.dart';

/// A card's or a game's name, read in its own direction: a Latin title keeps
/// its order inside the Arabic page («7 Days to Die», not «Days to Die 7»),
/// its ™ stays on its own end, and a cut-off one ends in «…» where it was
/// cut. It still sits against the page's start edge; an Arabic name is
/// unchanged.
class NameText extends StatelessWidget {
  const NameText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Where a line shorter than the space sits; the page's start edge when
  /// null.
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final page = Directionality.of(context);
    return Text(
      text,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textDirection: directionOf(text) ?? page,
      textAlign:
          textAlign ??
          (page == TextDirection.rtl ? TextAlign.right : TextAlign.left),
    );
  }

  /// The direction of [text]'s first letter: right to left for Arabic (or
  /// Hebrew), left to right for any other script; null when it has none.
  static TextDirection? directionOf(String text) {
    for (final rune in text.runes) {
      if (_rightToLeft(rune)) {
        return TextDirection.rtl;
      }
      if (_letter.hasMatch(String.fromCharCode(rune))) {
        return TextDirection.ltr;
      }
    }
    return null;
  }

  static final _letter = RegExp(r'\p{L}', unicode: true);

  static bool _rightToLeft(int rune) =>
      (rune >= 0x0590 && rune <= 0x08FF) ||
      (rune >= 0xFB1D && rune <= 0xFDFF) ||
      (rune >= 0xFE70 && rune <= 0xFEFF);
}
