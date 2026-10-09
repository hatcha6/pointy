import 'package:flutter/material.dart';

import '../../../../shared/design/design.dart';

/// A numbered section of a guided service screen: its number, its title, and
/// its content — drawn dimmed, and not touchable, until the steps before it
/// are done, so the whole path is on screen from the start.
class ServiceStepSection extends StatelessWidget {
  const ServiceStepSection({
    super.key,
    required this.number,
    required this.title,
    required this.child,
    this.enabled = true,
    this.interactive,
    this.done = false,
    this.trailing,
    this.subtitle,
  });

  final int number;
  final String title;
  final Widget child;

  /// The steps before this one are done.
  final bool enabled;

  /// Whether the content can be touched; by default only once it is
  /// [enabled]. A step can be dimmed and still take what is given to it — a
  /// whole number pasted into the number field before any country is chosen
  /// picks the country by itself.
  final bool? interactive;

  /// This step is done: its number becomes a check.
  final bool done;

  /// At the far end of the title row — "change" on a chosen country.
  final Widget? trailing;

  /// A line under the title: what this step needs.
  final String? subtitle;

  /// The least width the title keeps when the far end is crowded.
  static const double _minTitleWidth = 56;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            // The title always keeps room to be read; what is at the far end
            // gives way (shrinks) in a narrow column or with enlarged text.
            final room = constraints.maxWidth - 24 - 10 - _minTitleWidth;
            return Row(
              children: [
                ServiceStepBadge(number: number, done: done, active: enabled),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: textTheme.titleSmall?.copyWith(
                      color: enabled ? colors.ink : colors.mutedInk,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (trailing case final trailing?)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: room.isFinite && room > 0 ? room : 0,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: trailing,
                    ),
                  ),
              ],
            );
          },
        ),
        if (subtitle case final subtitle?) ...[
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 34),
            child: Text(
              subtitle,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ),
        ],
        const SizedBox(height: 8),
        AnimatedOpacity(
          duration: PointyMotion.fast,
          opacity: enabled ? 1 : 0.42,
          child: IgnorePointer(
            ignoring: !(interactive ?? enabled),
            child: child,
          ),
        ),
      ],
    );
  }
}

/// The round number of a step: filled when it is the one to do, a check when
/// done, an outline when it is waiting.
class ServiceStepBadge extends StatelessWidget {
  const ServiceStepBadge({
    super.key,
    required this.number,
    this.done = false,
    this.active = true,
    this.size = 24,
  });

  final int number;
  final bool done;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final filled = done || active;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done
            ? colors.success
            : (active ? colors.primaryStrong : Colors.transparent),
        border: Border.all(
          color: filled ? Colors.transparent : colors.lineStrong,
          width: 1.5,
        ),
      ),
      child: done
          ? Icon(Icons.check_rounded, size: size * 0.66, color: Colors.white)
          : Text(
              '$number',
              style: PointyTypography.numeric(
                TextStyle(
                  fontFamily: PointyTypography.fontFamily,
                  fontSize: size * 0.54,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  color: active
                      ? (ThemeData.estimateBrightnessForColor(
                                  colors.primaryStrong,
                                ) ==
                                Brightness.light
                            ? const Color(0xFF04201A)
                            : Colors.white)
                      : colors.mutedInk,
                ),
              ),
            ),
    );
  }
}
