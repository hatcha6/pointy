import 'package:flutter/material.dart';

import '../../../../shared/design/design.dart';

/// One quiet line, at the top of a service, saying what the cashier needs in
/// hand before starting: «تحتاج: رقم العدّاد…». Seen first, so nobody starts a
/// sale without the number they will be asked for.
class ServiceNeedsLine extends StatelessWidget {
  const ServiceNeedsLine({super.key, required this.text, this.textKey});

  final String text;

  /// The key of the text itself.
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.assignment_outlined, size: 17, color: colors.primaryStrong),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            key: textKey,
            style: textTheme.bodySmall?.copyWith(
              color: colors.mutedInk,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
