import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import 'native_glass_chips.dart';
import 'side_back.dart';

/// One filter in a [GlassFilterRow]: a switch (offers only) or a list to
/// choose from (a trip's length).
class GlassFilter {
  const GlassFilter.toggle({
    required this.key,
    required this.label,
    required this.symbol,
    required this.icon,
    required this.on,
    required VoidCallback this.onTap,
  }) : title = null,
       choices = const [],
       current = null,
       onPick = null;

  GlassFilter.menu({
    required this.key,
    required this.label,
    required this.symbol,
    required this.icon,
    required this.on,
    required String this.title,
    required this.choices,
    required this.current,
    required ValueChanged<Object?> this.onPick,
  }) : onTap = null;

  final String key;
  final String label;

  /// The SF Symbol the system's glass chip draws.
  final String symbol;

  /// The same mark where the button is our own glass.
  final IconData icon;
  final bool on;
  final String? title;
  final List<(Object?, String)> choices;
  final Object? current;
  final VoidCallback? onTap;
  final ValueChanged<Object?>? onPick;

  bool get isMenu => onPick != null;

  /// The filter as a round button in the iPhone Duo's side column: its mark
  /// alone, tinted while it is on; a list opens the same sheet.
  SideAction toSide({bool spaced = false}) => SideAction(
    spaced: spaced,
    symbol: symbol,
    icon: icon,
    tooltip: label,
    on: on,
    onPressed: (button) =>
        isMenu ? showGlassFilterChoices(button, this) : onTap!(),
  );
}

/// The system's action sheet for a filter that is a list to choose from.
Future<void> showGlassFilterChoices(BuildContext context, GlassFilter filter) {
  final theme = Theme.of(context);
  final l10n = AppLocalizations.of(context);
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (sheet) => CupertinoTheme(
      data: CupertinoThemeData(brightness: theme.brightness),
      child: CupertinoActionSheet(
        title: Text(filter.title!),
        actions: [
          for (final (value, text) in filter.choices)
            CupertinoActionSheetAction(
              isDefaultAction: value == filter.current,
              onPressed: () {
                Navigator.of(sheet).pop();
                filter.onPick!(value);
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(text),
                  if (value == filter.current) ...[
                    const SizedBox(width: 8),
                    const Icon(CupertinoIcons.checkmark_alt, size: 18),
                  ],
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: Text(l10n.cancelAction),
        ),
      ),
    ),
  );
}

/// A row of filters as the system's Liquid Glass chips, the way the home
/// page's categories are: a switch toggles on tap, a list opens the system's
/// action sheet. Only where [CardsTabBar.nativeGlass] holds.
class GlassFilterRow extends StatefulWidget {
  const GlassFilterRow({
    super.key,
    required this.filters,
    this.gutter = 20,
    this.clip = false,
  });

  final List<GlassFilter> filters;
  final double gutter;

  /// Standing between other controls: the chips stop at the row's edges.
  final bool clip;

  static const double height = NativeGlassChips.height;

  @override
  State<GlassFilterRow> createState() => _GlassFilterRowState();
}

class _GlassFilterRowState extends State<GlassFilterRow> {
  /// The sheet is a route over the page, which would otherwise take the
  /// native row down while it is open.
  bool _choosing = false;

  Future<void> _choose(GlassFilter filter) async {
    setState(() => _choosing = true);
    await showGlassFilterChoices(context, filter);
    if (mounted) {
      setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filters = widget.filters;
    return NativeGlassChips(
      gutter: widget.gutter,
      clip: widget.clip,
      holdOpen: _choosing,
      chips: [
        for (final f in filters) (key: f.key, label: f.label, symbol: f.symbol),
      ],
      selected: '',
      selectedKeys: {
        for (final f in filters)
          if (f.on) f.key,
      },
      menus: {
        for (final f in filters)
          if (f.isMenu) f.key,
      },
      onSelect: (key) {
        final filter = filters.where((f) => f.key == key).firstOrNull;
        if (filter == null) {
          return;
        }
        if (filter.isMenu) {
          _choose(filter);
        } else {
          filter.onTap!();
        }
      },
    );
  }
}
