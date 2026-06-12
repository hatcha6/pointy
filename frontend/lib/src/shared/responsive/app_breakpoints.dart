import 'package:flutter/widgets.dart';

enum AppBreakpoint { phone, largePhone, tablet, desktop, widePos }

class AppBreakpoints {
  const AppBreakpoints._();

  static const double phoneMin = 360;
  static const double phoneMax = 430;
  static const double largePhoneMin = 480;
  static const double tabletMin = 720;
  static const double desktopMin = 1024;
  static const double widePosMin = 1366;

  /// Minimum *content* width for inline master-detail panes. Measured against
  /// the pane's own constraints, not the viewport: a 1024 px desktop window
  /// with an extended navigation rail leaves ~784 px of content, so a
  /// viewport-tier threshold would disable dual-pane exactly where it helps.
  static const double masterDetailMin = 900;

  static AppBreakpoint of(BuildContext context) {
    return forWidth(MediaQuery.sizeOf(context).width);
  }

  static AppBreakpoint forWidth(double width) {
    if (width >= widePosMin) {
      return AppBreakpoint.widePos;
    }
    if (width >= desktopMin) {
      return AppBreakpoint.desktop;
    }
    if (width >= tabletMin) {
      return AppBreakpoint.tablet;
    }
    if (width >= largePhoneMin) {
      return AppBreakpoint.largePhone;
    }
    return AppBreakpoint.phone;
  }

  static bool isAtLeast(double width, AppBreakpoint breakpoint) {
    return forWidth(width).index >= breakpoint.index;
  }

  static bool usesTwoPane(double width) {
    return isAtLeast(width, AppBreakpoint.tablet);
  }
}

extension AppBreakpointX on AppBreakpoint {
  bool get isPhone => this == AppBreakpoint.phone;

  bool get isLargePhone => this == AppBreakpoint.largePhone;

  bool get isTablet => this == AppBreakpoint.tablet;

  bool get isDesktop => this == AppBreakpoint.desktop;

  bool get isWidePos => this == AppBreakpoint.widePos;

  bool get supportsTwoPane => index >= AppBreakpoint.tablet.index;
}
