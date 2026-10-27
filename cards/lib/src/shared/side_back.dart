import 'dart:ui' show ImageFilter;

import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:flutter/material.dart';

import '../features/shell/cards_tab_bar.dart';
import 'haptics.dart';

/// A page's back (or close) button, standing in the system's side column
/// where the screen has one (the iPhone Duo), on the status bar's own line
/// just under the time and the signal, as the system's navigation does
/// there. Elsewhere the page keeps it in its app bar: pages ask [active] to
/// leave their own one out.
///
/// The page itself, its app bar and title too, is kept clear of the column,
/// unless it is [edgeToEdge] (artwork that should run under the column) and
/// insets its own content.
class SideBack extends StatelessWidget {
  const SideBack({
    super.key,
    required this.child,
    this.close = false,
    this.tooltip,
    this.onPressed,
    this.edgeToEdge = false,
  });

  final Widget child;

  /// A close (×) rather than a back (‹) button.
  final bool close;
  final String? tooltip;

  /// Null pops the page (a disabled button is not a thing here: a page that
  /// cannot be left passes a callback that does nothing).
  final VoidCallback? onPressed;
  final bool edgeToEdge;

  /// Where the system draws its column on the iPhone Duo, as measured on
  /// the simulator and on Apple's own App Store screenshots: the centre line
  /// of the status items this far in from the screen's edge, for the column's
  /// buttons and tabs alike.
  static const double statusCentre = 48;

  /// Where the status items end. Closed, the column starts with the camera,
  /// so the time and the signal sit lower than on the open screen.
  static double statusFoot(Size screen) =>
      screen.height > screen.width ? 150 : 88;

  /// The gap Apple leaves under the status items before the first button.
  static const double statusGap = 24;

  /// The column's glass buttons, as Apple sizes them there.
  static const double size = 48;

  static bool active(BuildContext context) =>
      CardsTabBar.side(MediaQuery.paddingOf(context)) != null;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final side = CardsTabBar.side(padding);
    if (side == null) {
      return child;
    }
    final right = side == AxisDirection.right;
    final page = edgeToEdge
        ? child
        : ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Padding(
              padding: EdgeInsets.only(
                left: padding.left,
                right: padding.right,
              ),
              child: MediaQuery(
                // The page is told the room it really has: no side insets,
                // and the width without the column.
                data: MediaQuery.of(context)
                    .removePadding(removeLeft: true, removeRight: true)
                    .copyWith(
                      size: Size(
                        MediaQuery.sizeOf(context).width - padding.horizontal,
                        MediaQuery.sizeOf(context).height,
                      ),
                    ),
                child: child,
              ),
            ),
          );
    final localizations = MaterialLocalizations.of(context);
    return Stack(
      children: [
        page,
        Positioned(
          top: padding.top + statusFoot(MediaQuery.sizeOf(context)) + statusGap,
          left: right ? null : statusCentre - size / 2,
          right: right ? statusCentre - size / 2 : null,
          width: size,
          height: size,
          child: _SideButton(
            close: close,
            tooltip:
                tooltip ??
                (close
                    ? localizations.closeButtonTooltip
                    : localizations.backButtonTooltip),
            onPressed: () {
              Haptics.tap();
              (onPressed ?? () => Navigator.of(context).maybePop())();
            },
          ),
        ),
      ],
    );
  }
}

/// The button itself: the system's own Liquid Glass where the phone draws
/// it (iOS 26 and later), like the status bar and tab bars beside it; our
/// frosted glass elsewhere.
class _SideButton extends StatelessWidget {
  const _SideButton({
    required this.close,
    required this.tooltip,
    required this.onPressed,
  });

  final bool close;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (CardsTabBar.nativeGlass) {
      final rtl = Directionality.of(context) == TextDirection.rtl;
      return Semantics(
        button: true,
        label: tooltip,
        child: CNButton.icon(
          icon: CNSymbol(
            close ? 'xmark' : (rtl ? 'chevron.right' : 'chevron.left'),
            size: 17,
            color: theme.colorScheme.onSurface,
          ),
          onPressed: onPressed,
          config: const CNButtonConfig(
            style: CNButtonStyle.glass,
            width: SideBack.size,
            minHeight: SideBack.size,
          ),
        ),
      );
    }
    final dark = theme.brightness == Brightness.dark;
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Material(
          color: theme.colorScheme.surface.withValues(alpha: dark ? 0.6 : 0.72),
          shape: CircleBorder(
            side: BorderSide(
              color: (dark ? Colors.white : Colors.black).withValues(
                alpha: 0.08,
              ),
            ),
          ),
          child: IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            icon: close
                ? const Icon(Icons.close_rounded)
                : const BackButtonIcon(),
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
