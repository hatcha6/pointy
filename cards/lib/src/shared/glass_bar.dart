import 'package:flutter/material.dart';

import '../design/cards_tokens.dart';
import '../features/shell/cards_tab_bar.dart';
import 'glass_button.dart';
import 'glass_edge.dart';
import 'haptics.dart';
import 'side_back.dart';

/// A page's top bar: its back (or close) button, its title, its actions.
///
/// Where the system draws Liquid Glass (iOS 26 and later) the bar is the
/// way Apple's pages have it: nothing opaque, the buttons the system's own
/// glass circles, and once content scrolls beneath, iOS's soft scroll edge
/// ([GlassEdge]) reaching up under the status bar. A page using it there
/// runs its body under the bar ([extendsBody]) and pads its own top.
/// Elsewhere it is the app's plain bar.
///
/// Where the screen has a side column (the iPhone Duo) the buttons stand
/// there instead ([SideBack]), and the bar keeps only its title.
class GlassBar extends StatefulWidget implements PreferredSizeWidget {
  const GlassBar({
    super.key,
    this.title,
    this.close = false,
    this.onLeading,
    this.leadingTooltip,
    this.actions = const [],
    this.clear = false,
    this.fill = false,
    this.topRoom = 0,
  }) : scrolled = null;

  const GlassBar._pinned({
    required bool this.scrolled,
    this.title,
    this.close = false,
    this.onLeading,
    this.actions = const [],
  }) : clear = false,
       fill = false,
       topRoom = 0,
       leadingTooltip = null;

  final Widget? title;

  /// A close (×) rather than a back (‹) button.
  final bool close;

  /// Null pops the page.
  final VoidCallback? onLeading;
  final String? leadingTooltip;
  final List<SideAction> actions;

  /// Over a page's own artwork: no bar colour and no scroll edge.
  final bool clear;

  /// The title is a row of its own (filters) that takes all the room
  /// between the buttons, instead of a centred name.
  final bool fill;

  /// Room above the bar's row where no status bar gives any (the iPhone
  /// Duo, whose status items sit in the side column): a row of controls
  /// would otherwise stand against the screen's top edge.
  final double topRoom;

  /// Told by a pinned sliver; otherwise heard from the page's scrolling.
  final bool? scrolled;

  /// Whether a page's body should run under this bar.
  static bool get extendsBody => CardsTabBar.nativeGlass;

  /// The bar as a pinned sliver, for a page that scrolls as one.
  static Widget sliver(
    BuildContext context, {
    Widget? title,
    bool close = false,
    VoidCallback? onLeading,
    List<SideAction> actions = const [],
  }) {
    if (!CardsTabBar.nativeGlass) {
      return SliverAppBar(
        pinned: true,
        centerTitle: true,
        automaticallyImplyLeading: !SideBack.active(context),
        leading: _plainLeading(context, close, onLeading, null),
        title: title,
        actions: _plainActions(context, actions),
      );
    }
    return SliverPersistentHeader(
      pinned: true,
      delegate: _GlassBarHeader(
        top: MediaQuery.paddingOf(context).top,
        bar: (scrolled) => GlassBar._pinned(
          scrolled: scrolled,
          title: title,
          close: close,
          onLeading: onLeading,
          actions: actions,
        ),
      ),
    );
  }

  static Widget? _plainLeading(
    BuildContext context,
    bool close,
    VoidCallback? onLeading,
    String? tooltip,
  ) {
    // A plain back is the bar's own (and only where there is a page to go
    // back to).
    if (SideBack.active(context) || (!close && onLeading == null)) {
      return null;
    }
    final localizations = MaterialLocalizations.of(context);
    return IconButton(
      tooltip:
          tooltip ??
          (close
              ? localizations.closeButtonTooltip
              : localizations.backButtonTooltip),
      icon: close ? const Icon(Icons.close_rounded) : const BackButtonIcon(),
      onPressed: onLeading ?? () => Navigator.of(context).maybePop(),
    );
  }

  static List<Widget> _plainActions(
    BuildContext context,
    List<SideAction> actions,
  ) => [
    if (!SideBack.active(context))
      for (final action in actions)
        Builder(
          // Its own context: an iPad's share sheet points at this button.
          builder: (context) => IconButton(
            tooltip: action.tooltip,
            icon: Icon(action.icon),
            onPressed: () => action.onPressed(context),
          ),
        ),
  ];

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + topRoom);

  @override
  State<GlassBar> createState() => _GlassBarState();
}

class _GlassBarState extends State<GlassBar> {
  ScrollNotificationObserverState? _observer;
  bool _under = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observer?.removeListener(_heard);
    _observer = widget.scrolled == null && CardsTabBar.nativeGlass
        ? ScrollNotificationObserver.maybeOf(context)
        : null;
    _observer?.addListener(_heard);
  }

  @override
  void dispose() {
    _observer?.removeListener(_heard);
    super.dispose();
  }

  void _heard(ScrollNotification note) {
    if (note.depth != 0 || note.metrics.axis != Axis.vertical) {
      return;
    }
    final under = note.metrics.extentBefore > 0;
    if (under != _under && mounted) {
      setState(() => _under = under);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!CardsTabBar.nativeGlass) {
      return AppBar(
        backgroundColor: widget.clear ? Colors.transparent : null,
        automaticallyImplyLeading: !SideBack.active(context),
        leading: GlassBar._plainLeading(
          context,
          widget.close,
          widget.onLeading,
          widget.leadingTooltip,
        ),
        title: widget.title,
        actions: GlassBar._plainActions(context, widget.actions),
      );
    }
    final theme = Theme.of(context);
    final side = SideBack.active(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final localizations = MaterialLocalizations.of(context);
    final scrolled = widget.scrolled ?? _under;
    final Widget? leading = side
        ? null
        : // The toolbar stretches its leading to its own height.
          Center(
            widthFactor: 1,
            child: GlassButton(
              symbol: widget.close
                  ? 'xmark'
                  : (rtl ? 'chevron.right' : 'chevron.left'),
              icon: widget.close
                  ? const Icon(Icons.close_rounded)
                  : const BackButtonIcon(),
              tooltip:
                  widget.leadingTooltip ??
                  (widget.close
                      ? localizations.closeButtonTooltip
                      : localizations.backButtonTooltip),
              onPressed: (_) {
                Haptics.tap();
                (widget.onLeading ?? () => Navigator.of(context).maybePop())();
              },
            ),
          );
    final Widget? middle = widget.title == null
        ? null
        : DefaultTextStyle.merge(
            style: theme.appBarTheme.titleTextStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: widget.title!,
          );
    final Widget? trailing = side || widget.actions.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            spacing: CardsSpace.sm,
            children: [
              for (final action in widget.actions)
                GlassButton(
                  symbol: action.symbol,
                  icon: Icon(action.icon),
                  tooltip: action.tooltip,
                  onPressed: (button) {
                    Haptics.tap();
                    action.onPressed(button);
                  },
                ),
            ],
          );
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (!widget.clear)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            // A little past the bar, so the blur has room to die away.
            bottom: -CardsSpace.md,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: scrolled ? 1 : 0),
              duration: CardsMotion.standard,
              curve: CardsMotion.curve,
              builder: (context, amount, _) => GlassEdge(amount: amount),
            ),
          ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.only(
              left: CardsSpace.lg,
              right: CardsSpace.lg,
              top: widget.topRoom,
            ),
            child: widget.fill
                ? Row(
                    children: [
                      ?leading,
                      Expanded(
                        child: ClipRect(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: CardsSpace.sm,
                            ),
                            child: widget.title,
                          ),
                        ),
                      ),
                      ?trailing,
                    ],
                  )
                : NavigationToolbar(
                    centerMiddle: true,
                    middleSpacing: CardsSpace.md,
                    leading: leading,
                    middle: middle,
                    trailing: trailing,
                  ),
          ),
        ),
      ],
    );
  }
}

class _GlassBarHeader extends SliverPersistentHeaderDelegate {
  _GlassBarHeader({required this.top, required this.bar});

  /// The status bar above the bar.
  final double top;
  final Widget Function(bool scrolled) bar;

  @override
  double get minExtent => top + kToolbarHeight;

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => bar(overlapsContent || shrinkOffset > 0);

  @override
  bool shouldRebuild(covariant _GlassBarHeader oldDelegate) => true;
}

/// For a tab's page with no bar of its own: where the system draws Liquid
/// Glass its list runs on under the status bar (the list must not clip),
/// and once it does, the soft scroll edge keeps the status bar readable.
class GlassStatusEdge extends StatefulWidget {
  const GlassStatusEdge({super.key, required this.child});

  final Widget child;

  /// How a list under this edge clips.
  static Clip get listClip =>
      CardsTabBar.nativeGlass ? Clip.none : Clip.hardEdge;

  @override
  State<GlassStatusEdge> createState() => _GlassStatusEdgeState();
}

class _GlassStatusEdgeState extends State<GlassStatusEdge> {
  bool _under = false;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final page = SafeArea(bottom: false, child: widget.child);
    if (!CardsTabBar.nativeGlass) {
      return page;
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (note) {
        if (note.depth == 0 && note.metrics.axis == Axis.vertical) {
          final under = note.metrics.extentBefore > 0;
          if (under != _under) {
            setState(() => _under = under);
          }
        }
        return false;
      },
      child: Stack(
        children: [
          page,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: top + CardsSpace.md,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: _under ? 1 : 0),
              duration: CardsMotion.standard,
              curve: CardsMotion.curve,
              builder: (context, amount, _) => GlassEdge(amount: amount),
            ),
          ),
        ],
      ),
    );
  }
}
