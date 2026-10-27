import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/cards_theme.dart';
import 'haptics.dart';

/// One chip: its key, its name and its SF Symbol.
typedef GlassChip = ({String key, String label, String symbol});

/// A row of Liquid Glass chips drawn by the system
/// (ios/Runner/CategoryChipsView.swift): the iOS 26 way of floating a choice
/// over content. This widget tells the native row what to show and hears
/// which chip was tapped. Only where [CardsTabBar.nativeGlass] holds.
class NativeGlassChips extends StatefulWidget {
  const NativeGlassChips({
    super.key,
    required this.chips,
    required this.selected,
    required this.onSelect,
    this.column = EdgeInsets.zero,
    this.gutter = 20,
  });

  final List<GlassChip> chips;
  final String selected;
  final ValueChanged<String> onSelect;

  /// The system side column the row runs under: the chips start clear of
  /// it and scroll on beneath it, still taking taps there.
  final EdgeInsets column;

  /// The room before the first chip and after the last, so the first lines
  /// up with the page.
  final double gutter;

  /// The row's height: the chips and their glass's room to breathe.
  static const double height = 52;

  @override
  State<NativeGlassChips> createState() => _NativeGlassChipsState();
}

class _NativeGlassChipsState extends State<NativeGlassChips> {
  MethodChannel? _channel;

  Map<String, Object> _params(BuildContext context) {
    final theme = Theme.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return {
      'chips': [
        for (final chip in widget.chips)
          {'key': chip.key, 'label': chip.label, 'symbol': chip.symbol},
      ],
      'selected': widget.selected,
      'tint': CardsTheme.link(theme).toARGB32(),
      'dark': theme.brightness == Brightness.dark,
      'rtl': rtl,
      'gutter': widget.gutter,
      'leading': rtl ? widget.column.right : widget.column.left,
      'trailing': rtl ? widget.column.left : widget.column.right,
    };
  }

  void _update() {
    _channel
        ?.invokeMethod<void>('update', _params(context))
        .catchError((Object _) {});
  }

  @override
  void didUpdateWidget(NativeGlassChips oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  void _created(int id) {
    final channel = MethodChannel('cards/category_chips_$id');
    channel.setMethodCallHandler((call) async {
      if (call.method == 'select') {
        Haptics.select();
        widget.onSelect(call.arguments as String);
      }
    });
    _channel = channel;
  }

  @override
  Widget build(BuildContext context) {
    // Out while a page covers this one: the system's hosted glass goes stale
    // and out of place under a pushed page, so it is made afresh on return.
    final covered = !(ModalRoute.isCurrentOf(context) ?? true);
    return SizedBox(
      height: NativeGlassChips.height,
      child: covered
          ? null
          : UiKitView(
              viewType: 'cards/category_chips',
              creationParams: _params(context),
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _created,
              // A sideways drag is the row's own scrolling: claimed here, or
              // the page's scroll view takes it and the page moves instead.
              gestureRecognizers: {
                Factory<HorizontalDragGestureRecognizer>(
                  HorizontalDragGestureRecognizer.new,
                ),
              },
            ),
    );
  }
}
