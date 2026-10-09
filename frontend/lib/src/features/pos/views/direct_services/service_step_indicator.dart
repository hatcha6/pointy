import 'package:flutter/material.dart';

import '../../../../shared/design/design.dart';
import 'service_step_section.dart';

/// ① الدولة — ② الجهة — ③ الرقم — ④ المبلغ — ⑤ الملخص, the current one filled.
class ServiceStepIndicator extends StatelessWidget {
  const ServiceStepIndicator({
    super.key,
    required this.names,
    required this.index,
  });

  final List<String> names;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        for (var i = 0; i < names.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.only(bottom: 16),
                color: i <= index ? colors.primaryStrong : colors.line,
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ServiceStepBadge(
                number: i + 1,
                size: 24,
                done: i < index,
                active: i == index,
              ),
              const SizedBox(height: 3),
              Text(
                names[i],
                style: textTheme.labelSmall?.copyWith(
                  color: i == index ? colors.primaryDark : colors.mutedInk,
                  fontWeight: i == index ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
