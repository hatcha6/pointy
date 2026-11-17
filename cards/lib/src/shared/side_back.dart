import 'package:flutter/material.dart';

import '../design/cards_theme.dart';
import '../features/shell/cards_tab_bar.dart';
import 'glass_button.dart';
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

  /// Whether the column holds the page's buttons: asked from the page or
  /// from anything inside it (where the column is already set aside).
  static bool active(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SideBackScope>() != null ||
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
    // Where the column's foot group starts: those stand up from the bottom,
    // where a tab's page has its tabs.
    final foot = actions.indexWhere((action) => action.spaced);
    Widget at(int slot, Widget button) => Positioned(
      top: foot >= 0 && slot > foot ? null : top + slot * (size + gap),
      bottom: foot >= 0 && slot > foot
          ? CardsSideTabBar.bottom + (actions.length - slot) * (size + gap)
          : null,
      left: right ? null : statusCentre - size / 2,
      right: right ? statusCentre - size / 2 : null,
      width: size,
      height: size,
      child: button,
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Stack(
      children: [
        _SideBackScope(child: page),
        at(
          0,
          GlassButton(
            size: size,
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
            GlassButton(
              size: size,
              symbol: action.symbol,
              icon: Icon(action.icon),
              tooltip: action.tooltip,
              tint: action.on ? CardsTheme.link(Theme.of(context)) : null,
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
    this.on = false,
    this.spaced = false,
  });

  /// Starts the group that stands at the column's foot, where a tab's page
  /// has its tabs (the page's filters), away from back and share.

  final bool spaced;

  /// Switched on (a filter in use): the mark takes the app's tint.
  final bool on;

  /// The SF Symbol the system's glass button draws (`square.and.arrow.up`).
  final String symbol;

  /// The same mark where the button is our own glass.
  final IconData icon;
  final String tooltip;

  /// Given the button's own context, for a sheet that points at it.
  final void Function(BuildContext button) onPressed;
}

/// Marks a page whose buttons stand in the side column.
class _SideBackScope extends InheritedWidget {
  const _SideBackScope({required super.child});

  @override
  bool updateShouldNotify(_SideBackScope oldWidget) => false;
}
