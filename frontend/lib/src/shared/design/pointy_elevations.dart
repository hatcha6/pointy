import 'package:flutter/material.dart';

/// Soft ink-tinted shadow recipes for raised surfaces.
///
/// Cards keep their 1 px `line` border; these shadows add a whisper of depth
/// on top of it rather than replacing the outline language.
abstract final class PointyShadows {
  /// Cards, tiles, and panels that sit on the page surface.
  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x0D101828), offset: Offset(0, 1), blurRadius: 2),
    BoxShadow(
      color: Color(0x14101828),
      offset: Offset(0, 2),
      blurRadius: 6,
      spreadRadius: -1,
    ),
  ];

  /// Floating overlays: dialogs, side panels, menus.
  static const List<BoxShadow> overlay = [
    BoxShadow(
      color: Color(0x1F101828),
      offset: Offset(0, 8),
      blurRadius: 24,
      spreadRadius: -4,
    ),
  ];
}
