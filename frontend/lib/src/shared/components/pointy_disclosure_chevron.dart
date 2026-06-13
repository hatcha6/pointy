import 'package:flutter/material.dart';

/// Trailing "opens something" indicator that points along the reading
/// direction: left in RTL, right in LTR.
///
/// Chevron glyphs do not auto-mirror like [Icons.arrow_back]/[Icons.arrow_forward]
/// do, so every disclosure affordance should use this widget instead of a raw
/// chevron icon.
class PointyDisclosureChevron extends StatelessWidget {
  const PointyDisclosureChevron({super.key, this.color, this.size});

  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return Icon(
      isRtl ? Icons.chevron_left : Icons.chevron_right,
      color: color,
      size: size,
    );
  }
}
