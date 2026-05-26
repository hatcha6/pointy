import 'package:flutter/widgets.dart';

import 'app_breakpoints.dart';

class AdaptiveSpacing {
  const AdaptiveSpacing({
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
    required this.xxl,
    required this.gutter,
    required this.pageHorizontal,
    required this.pageVertical,
    required this.formGap,
    required this.paneGap,
  });

  final double xs;
  final double sm;
  final double md;
  final double lg;
  final double xl;
  final double xxl;
  final double gutter;
  final double pageHorizontal;
  final double pageVertical;
  final double formGap;
  final double paneGap;

  EdgeInsetsDirectional get pagePadding {
    return EdgeInsetsDirectional.symmetric(
      horizontal: pageHorizontal,
      vertical: pageVertical,
    );
  }

  EdgeInsetsDirectional get sectionPadding {
    return EdgeInsetsDirectional.all(lg);
  }

  EdgeInsetsDirectional get compactPadding {
    return EdgeInsetsDirectional.all(md);
  }

  static AdaptiveSpacing of(BuildContext context) {
    return fromWidth(MediaQuery.sizeOf(context).width);
  }

  static AdaptiveSpacing fromWidth(double width) {
    return switch (AppBreakpoints.forWidth(width)) {
      AppBreakpoint.phone => const AdaptiveSpacing(
        xs: 4,
        sm: 8,
        md: 12,
        lg: 16,
        xl: 20,
        xxl: 24,
        gutter: 12,
        pageHorizontal: 12,
        pageVertical: 12,
        formGap: 12,
        paneGap: 8,
      ),
      AppBreakpoint.largePhone => const AdaptiveSpacing(
        xs: 4,
        sm: 8,
        md: 12,
        lg: 16,
        xl: 24,
        xxl: 32,
        gutter: 12,
        pageHorizontal: 16,
        pageVertical: 14,
        formGap: 12,
        paneGap: 12,
      ),
      AppBreakpoint.tablet => const AdaptiveSpacing(
        xs: 6,
        sm: 8,
        md: 16,
        lg: 20,
        xl: 28,
        xxl: 36,
        gutter: 16,
        pageHorizontal: 20,
        pageVertical: 16,
        formGap: 16,
        paneGap: 12,
      ),
      AppBreakpoint.desktop => const AdaptiveSpacing(
        xs: 6,
        sm: 10,
        md: 16,
        lg: 24,
        xl: 32,
        xxl: 40,
        gutter: 20,
        pageHorizontal: 24,
        pageVertical: 20,
        formGap: 16,
        paneGap: 16,
      ),
      AppBreakpoint.widePos => const AdaptiveSpacing(
        xs: 8,
        sm: 12,
        md: 20,
        lg: 28,
        xl: 36,
        xxl: 48,
        gutter: 24,
        pageHorizontal: 32,
        pageVertical: 24,
        formGap: 20,
        paneGap: 20,
      ),
    };
  }
}
