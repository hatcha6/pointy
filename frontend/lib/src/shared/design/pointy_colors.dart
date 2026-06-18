import 'package:flutter/material.dart';

abstract final class PointyColors {
  static const Color primary = Color(0xFF0F766E);
  static const Color primaryStrong = Color(0xFF006C53);
  static const Color primaryDark = Color(0xFF064E3B);
  static const Color darkTopBar = Color(0xFF0B111C);
  static const Color accentAmber = Color(0xFFC98A3B);
  static const Color danger = Color(0xFFB42318);
  static const Color warning = Color(0xFFB65F2A);
  static const Color success = Color(0xFF0E6B4E);
  static const Color ink = Color(0xFF101828);
  static const Color mutedInk = Color(0xFF667085);
  static const Color line = Color(0xFFE5E0D8);
  static const Color lineStrong = Color(0xFFD5CFC4);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color page = Color(0xFFF8F7F4);
  static const Color subtleFill = Color(0xFFF2F4F2);
  static const Color surfaceSunken = Color(0xFFF1EFEA);
  static const Color primaryContainer = Color(0xFFE0F2EF);
  static const Color amberContainer = Color(0xFFFFF4E3);
}

/// Dark-mode palette, mirroring [PointyColors] token-for-token so the theme
/// builder can stay palette-driven.
///
/// Tuned for dim shops: deep blue-charcoal surfaces, a brighter teal accent
/// that keeps the brand identity, and status colours lifted for legibility on
/// dark backgrounds. The filled-button teal ([primary]) stays deep enough for
/// white text, while [primaryStrong]/[primaryDark] brighten so text, icons and
/// outlines read against dark surfaces.
abstract final class PointyColorsDark {
  static const Color primary = Color(0xFF0F766E);
  static const Color primaryStrong = Color(0xFF2DD4BF);
  static const Color primaryDark = Color(0xFF5EEAD4);
  static const Color darkTopBar = Color(0xFF0B111C);
  static const Color accentAmber = Color(0xFFE0A458);
  static const Color danger = Color(0xFFF97066);
  static const Color warning = Color(0xFFE0A05A);
  static const Color success = Color(0xFF3DD68C);
  static const Color ink = Color(0xFFE6E8EC);
  static const Color mutedInk = Color(0xFF94A0B0);
  static const Color line = Color(0xFF273039);
  static const Color lineStrong = Color(0xFF3A4552);
  static const Color surface = Color(0xFF161B22);
  static const Color page = Color(0xFF0D1117);
  static const Color subtleFill = Color(0xFF1C242E);
  static const Color surfaceSunken = Color(0xFF10161D);
  static const Color primaryContainer = Color(0xFF0C3A34);
  static const Color amberContainer = Color(0xFF332A1A);
}
