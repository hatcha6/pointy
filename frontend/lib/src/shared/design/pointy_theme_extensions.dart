import 'package:flutter/material.dart';

import 'pointy_colors.dart';

@immutable
class PointySemanticColors extends ThemeExtension<PointySemanticColors> {
  const PointySemanticColors({
    required this.primaryStrong,
    required this.primaryDark,
    required this.darkTopBar,
    required this.accentAmber,
    required this.danger,
    required this.warning,
    required this.success,
    required this.ink,
    required this.mutedInk,
    required this.line,
    required this.page,
    required this.surface,
    required this.subtleFill,
    required this.onDarkTopBar,
  });

  const PointySemanticColors.light()
    : primaryStrong = PointyColors.primaryStrong,
      primaryDark = PointyColors.primaryDark,
      darkTopBar = PointyColors.darkTopBar,
      accentAmber = PointyColors.accentAmber,
      danger = PointyColors.danger,
      warning = PointyColors.warning,
      success = PointyColors.success,
      ink = PointyColors.ink,
      mutedInk = PointyColors.mutedInk,
      line = PointyColors.line,
      page = PointyColors.page,
      surface = PointyColors.surface,
      subtleFill = PointyColors.subtleFill,
      onDarkTopBar = PointyColors.surface;

  final Color primaryStrong;
  final Color primaryDark;
  final Color darkTopBar;
  final Color accentAmber;
  final Color danger;
  final Color warning;
  final Color success;
  final Color ink;
  final Color mutedInk;
  final Color line;
  final Color page;
  final Color surface;
  final Color subtleFill;
  final Color onDarkTopBar;

  @override
  PointySemanticColors copyWith({
    Color? primaryStrong,
    Color? primaryDark,
    Color? darkTopBar,
    Color? accentAmber,
    Color? danger,
    Color? warning,
    Color? success,
    Color? ink,
    Color? mutedInk,
    Color? line,
    Color? page,
    Color? surface,
    Color? subtleFill,
    Color? onDarkTopBar,
  }) {
    return PointySemanticColors(
      primaryStrong: primaryStrong ?? this.primaryStrong,
      primaryDark: primaryDark ?? this.primaryDark,
      darkTopBar: darkTopBar ?? this.darkTopBar,
      accentAmber: accentAmber ?? this.accentAmber,
      danger: danger ?? this.danger,
      warning: warning ?? this.warning,
      success: success ?? this.success,
      ink: ink ?? this.ink,
      mutedInk: mutedInk ?? this.mutedInk,
      line: line ?? this.line,
      page: page ?? this.page,
      surface: surface ?? this.surface,
      subtleFill: subtleFill ?? this.subtleFill,
      onDarkTopBar: onDarkTopBar ?? this.onDarkTopBar,
    );
  }

  @override
  PointySemanticColors lerp(
    ThemeExtension<PointySemanticColors>? other,
    double t,
  ) {
    if (other is! PointySemanticColors) {
      return this;
    }
    return PointySemanticColors(
      primaryStrong: Color.lerp(primaryStrong, other.primaryStrong, t)!,
      primaryDark: Color.lerp(primaryDark, other.primaryDark, t)!,
      darkTopBar: Color.lerp(darkTopBar, other.darkTopBar, t)!,
      accentAmber: Color.lerp(accentAmber, other.accentAmber, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      success: Color.lerp(success, other.success, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      mutedInk: Color.lerp(mutedInk, other.mutedInk, t)!,
      line: Color.lerp(line, other.line, t)!,
      page: Color.lerp(page, other.page, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      subtleFill: Color.lerp(subtleFill, other.subtleFill, t)!,
      onDarkTopBar: Color.lerp(onDarkTopBar, other.onDarkTopBar, t)!,
    );
  }
}

extension PointyThemeDataX on ThemeData {
  PointySemanticColors get pointyColors {
    return extension<PointySemanticColors>() ??
        const PointySemanticColors.light();
  }
}

extension PointyBuildContextX on BuildContext {
  PointySemanticColors get pointyColors => Theme.of(this).pointyColors;
}
