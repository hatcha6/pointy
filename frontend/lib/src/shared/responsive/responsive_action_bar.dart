import 'package:flutter/widgets.dart';

import 'adaptive_spacing.dart';
import 'app_breakpoints.dart';

class ResponsiveActionBar extends StatelessWidget {
  const ResponsiveActionBar({
    super.key,
    required this.actions,
    this.leading,
    this.compactBreakpoint = AppBreakpoints.largePhoneMin,
    this.spacing,
    this.runSpacing,
    this.padding,
    this.alignment = WrapAlignment.end,
    this.crossAxisAlignment = WrapCrossAlignment.center,
    this.expandActionsOnCompact = true,
  });

  final Widget? leading;
  final List<Widget> actions;
  final double compactBreakpoint;
  final double? spacing;
  final double? runSpacing;
  final EdgeInsetsGeometry? padding;
  final WrapAlignment alignment;
  final WrapCrossAlignment crossAxisAlignment;
  final bool expandActionsOnCompact;

  @override
  Widget build(BuildContext context) {
    Widget content = LayoutBuilder(
      builder: (context, constraints) {
        final width = _effectiveWidth(context, constraints);
        final adaptiveSpacing = AdaptiveSpacing.fromWidth(width);
        final resolvedSpacing = spacing ?? adaptiveSpacing.sm;
        final resolvedRunSpacing = runSpacing ?? resolvedSpacing;

        if (width < compactBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (leading != null) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: leading,
                ),
                SizedBox(height: resolvedRunSpacing),
              ],
              for (var index = 0; index < actions.length; index++) ...[
                if (index > 0) SizedBox(height: resolvedRunSpacing),
                _compactAction(actions[index]),
              ],
            ],
          );
        }

        return Wrap(
          spacing: resolvedSpacing,
          runSpacing: resolvedRunSpacing,
          alignment: alignment,
          crossAxisAlignment: crossAxisAlignment,
          children: [?leading, ...actions],
        );
      },
    );

    final resolvedPadding = padding;
    if (resolvedPadding != null) {
      content = Padding(padding: resolvedPadding, child: content);
    }

    return content;
  }

  Widget _compactAction(Widget action) {
    if (!expandActionsOnCompact) {
      return Align(alignment: AlignmentDirectional.centerEnd, child: action);
    }
    return SizedBox(width: double.infinity, child: action);
  }

  double _effectiveWidth(BuildContext context, BoxConstraints constraints) {
    if (constraints.hasBoundedWidth) {
      return constraints.maxWidth;
    }
    return MediaQuery.sizeOf(context).width;
  }
}
