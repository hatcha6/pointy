import 'package:flutter/material.dart';

/// The "this row opens something" chevron, pointing the way the next screen
/// comes from — right in LTR, left in RTL.
///
/// Always `chevron_right`. Material's `chevron_right` is declared with
/// `matchTextDirection: true`, so Flutter already mirrors it under an RTL
/// `Directionality`. Choosing `chevron_left` in RTL by hand flips it a second
/// time and the two cancel, which is how every disclosure row in the app came
/// to point backwards.
class PointyDisclosureChevron extends StatelessWidget {
  const PointyDisclosureChevron({super.key, this.color, this.size});

  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.chevron_right, color: color, size: size);
  }
}
