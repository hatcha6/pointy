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
/// A page's other actions ([actions], such as sharing) stand under it in the
/// same column, where its app bar would otherwise carry them.
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
    this.actions = const [],
  });

  final Widget child;
  final List<SideAction> actions;

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

  /// The space between one of the column's buttons and the next.
  static const double gap = 12;

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
    final top =
        padding.top + statusFoot(MediaQuery.sizeOf(context)) + statusGap;
    Widget at(int slot, Widget button) => Positioned(
      top: top + slot * (size + gap),
      left: right ? null : statusCentre - size / 2,
      right: right ? statusCentre - size / 2 : null,
      width: size,
      height: size,
      child: button,
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Stack(
      children: [
        page,
        at(
          0,
          _SideButton(
            symbol: close ? 'xmark' : (rtl ? 'chevron.right' : 'chevron.left'),
            icon: close
                ? const Icon(Icons.close_rounded)
                : const BackButtonIcon(),
            tooltip:
                tooltip ??
                (close
                    ? localizations.closeButtonTooltip
                    : localizations.backButtonTooltip),
            onPressed: (_) {
              Haptics.tap();
              (onPressed ?? () => Navigator.of(context).maybePop())();
            },
          ),
        ),
        for (final (i, action) in actions.indexed)
          at(
            i + 1,
            _SideButton(
              symbol: action.symbol,
              icon: Icon(action.icon),
              tooltip: action.tooltip,
              onPressed: (button) {
                Haptics.tap();
                action.onPressed(button);
              },
            ),
          ),
      ],
    );
  }
}

/// One of a page's actions in the side column.
@immutable
class SideAction {
  const SideAction({
    required this.symbol,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  /// The SF Symbol the system's glass button draws (`square.and.arrow.up`).
  final String symbol;

  /// The same mark where the button is our own glass.
  final IconData icon;
  final String tooltip;

  /// Given the button's own context, for a sheet that points at it.
  final void Function(BuildContext button) onPressed;
}

/// The button itself: the system's own Liquid Glass where the phone draws
/// it (iOS 26 and later), like the status bar and tab bars beside it; our
/// frosted glass elsewhere.
class _SideButton extends StatelessWidget {
  const _SideButton({
    required this.symbol,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final String symbol;
  final Widget icon;
  final String tooltip;
  final void Function(BuildContext button) onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (CardsTabBar.nativeGlass) {
      return Semantics(
        button: true,
        label: tooltip,
        child: CNButton.icon(
          icon: CNSymbol(symbol, size: 17, color: theme.colorScheme.onSurface),
          onPressed: () => onPressed(context),
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
            onPressed: () => onPressed(context),
            icon: icon,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
