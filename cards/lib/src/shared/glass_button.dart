import 'dart:ui' show ImageFilter;

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/material.dart';

import '../features/shell/cards_tab_bar.dart';

/// A round glass button (back, close, share): the system's own Liquid Glass
/// where the phone draws it (iOS 26 and later), like the status bar and tab
/// bars beside it; our frosted glass elsewhere.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.symbol,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 44,
    this.tint,
  });

  /// The SF Symbol the system's glass button draws (`chevron.left`).
  final String symbol;

  /// The same mark where the button is our own glass.
  final Widget icon;
  final String tooltip;

  /// Given the button's own context, for a sheet that points at it.
  final void Function(BuildContext button) onPressed;

  /// The button's width and height.
  final double size;

  /// The mark's colour when the button stands for something switched on (a
  /// filter in use); the page's ink otherwise.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (CardsTabBar.nativeGlass) {
      return Semantics(
        button: true,
        label: tooltip,
        child: SizedBox.square(
          dimension: size,
          child: CNButton.icon(
            icon: CNSymbol(
              symbol,
              size: 17,
              color: tint ?? theme.colorScheme.onSurface,
            ),
            onPressed: () => onPressed(context),
            config: CNButtonConfig(
              style: CNButtonStyle.glass,
              width: size,
              minHeight: size,
            ),
          ),
        ),
      );
    }
    final dark = theme.brightness == Brightness.dark;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Material(
            color: theme.colorScheme.surface.withValues(
              alpha: dark ? 0.6 : 0.72,
            ),
            shape: CircleBorder(
              side: BorderSide(
                color: (dark ? Colors.white : Colors.black).withValues(
                  alpha: 0.08,
                ),
              ),
            ),
            child: IconButton(
              tooltip: tooltip,
              onPressed: () => onPressed(context),
              icon: icon,
              color: tint ?? theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
