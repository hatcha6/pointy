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
    required this.lineStrong,
    required this.page,
    required this.surface,
    required this.surfaceSunken,
    required this.subtleFill,
    required this.onDarkTopBar,
    required this.shadow,
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
      lineStrong = PointyColors.lineStrong,
      page = PointyColors.page,
      surface = PointyColors.surface,
      surfaceSunken = PointyColors.surfaceSunken,
      subtleFill = PointyColors.subtleFill,
      onDarkTopBar = PointyColors.surface,
      shadow = PointyColors.ink;

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
  final Color lineStrong;
  final Color page;
  final Color surface;
  final Color surfaceSunken;
  final Color subtleFill;
  final Color onDarkTopBar;
  final Color shadow;

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
    Color? lineStrong,
    Color? page,
    Color? surface,
    Color? surfaceSunken,
    Color? subtleFill,
    Color? onDarkTopBar,
    Color? shadow,
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
      lineStrong: lineStrong ?? this.lineStrong,
      page: page ?? this.page,
      surface: surface ?? this.surface,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      subtleFill: subtleFill ?? this.subtleFill,
      onDarkTopBar: onDarkTopBar ?? this.onDarkTopBar,
      shadow: shadow ?? this.shadow,
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
      lineStrong: Color.lerp(lineStrong, other.lineStrong, t)!,
      page: Color.lerp(page, other.page, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceSunken: Color.lerp(surfaceSunken, other.surfaceSunken, t)!,
      subtleFill: Color.lerp(subtleFill, other.subtleFill, t)!,
      onDarkTopBar: Color.lerp(onDarkTopBar, other.onDarkTopBar, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
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
