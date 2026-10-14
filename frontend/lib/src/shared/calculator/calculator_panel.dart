import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/design.dart';
import '../formatters.dart';
import 'calculator_controller.dart';
import 'calculator_converter_view.dart';
import 'calculator_keyboard.dart';
import 'calculator_number.dart';
import 'currency_converter.dart';

/// What happened when the panel tried to put its answer into a field.
enum CalculatorInsertOutcome { inserted, rejected, unavailable }

/// The calculator itself: title bar (drag to move), display, keypad, tape,
/// and copy / insert. Takes keyboard input while [focusNode] has focus.
///
/// The display and keypad are always left-to-right — numbers and the 7-8-9
/// grid read the same in every language — inside the Arabic panel.
class CalculatorPanel extends StatefulWidget {
  const CalculatorPanel({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onClose,
    required this.onInsert,
    required this.canInsert,
    this.onDrag,
    this.clock = DateTime.now,
    this.initialShowHistory = false,
    this.initialPickTop = false,
    this.converter,
  });

  final CalculatorController controller;

  /// Convert mode; null (no toggle) when the user may not read rates.
  final CurrencyConverter? converter;
  final FocusNode focusNode;
  final VoidCallback onClose;

  /// Puts [text] into the field the user was typing in.
  final CalculatorInsertOutcome Function(String text) onInsert;

  /// Whether there is a field to insert into right now.
  final bool canInsert;
  final ValueChanged<Offset>? onDrag;
  final DateTime Function() clock;

  /// Opens with the tape showing (previews and tests).
  final bool initialShowHistory;

  /// Opens with the top row's currency picker showing (previews).
  final bool initialPickTop;

  @override
  State<CalculatorPanel> createState() => _CalculatorPanelState();
}

class _CalculatorPanelState extends State<CalculatorPanel> {
  late CalculatorKeyboardHandler _keyboard;
  final ValueNotifier<CalculatorKey?> _flashed = ValueNotifier(null);
  Timer? _flashTimer;
  Timer? _noticeTimer;

  /// The sheet risen over the keypad, if any.
  late _PanelSheet? _sheet = widget.initialShowHistory
      ? _PanelSheet.history
      : widget.initialPickTop
      ? _PanelSheet.pickTop
      : null;

  /// What the sheet showed last — kept while it slides away.
  late _PanelSheet _sheetContent = _sheet ?? _PanelSheet.history;
  bool _copied = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _keyboard = CalculatorKeyboardHandler(
      controller: widget.controller,
      clock: widget.clock,
    );
    widget.focusNode.addListener(_onFocusChanged);
    // Opening on Convert: fetch rates unless the last ones are recent.
    final converter = widget.converter;
    if (converter != null && converter.enabled) {
      unawaited(converter.refresh());
    }
  }

  @override
  void didUpdateWidget(CalculatorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.clock != widget.clock) {
      _keyboard = CalculatorKeyboardHandler(
        controller: widget.controller,
        clock: widget.clock,
      );
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    _flashTimer?.cancel();
    _noticeTimer?.cancel();
    _flashed.dispose();
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  bool get _showHistory => _sheet == _PanelSheet.history;

  bool get _converting => widget.converter?.enabled ?? false;

  void _setSheet(_PanelSheet? sheet) {
    setState(() {
      _sheet = sheet;
      if (sheet != null) _sheetContent = sheet;
    });
    // Closing hands the keyboard back to the calculator (from the picker's
    // search field, too).
    if (sheet == null || !widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
  }

  void _setHistory(bool show) => _setSheet(show ? _PanelSheet.history : null);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final sheet = _sheet;
    if (sheet != null) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        _setSheet(null);
        return KeyEventResult.handled;
      }
      // The picker's search field owns the keyboard: its keys bubble up
      // here too, and must not also type into the calculator.
      if (sheet != _PanelSheet.history) {
        return KeyEventResult.ignored;
      }
    }
    final keyboard = HardwareKeyboard.instance;
    if (_converting &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.tab &&
        !keyboard.isShiftPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed) {
      widget.converter!.swap();
      return KeyEventResult.handled;
    }
    return _keyboard.handle(event, _actions);
  }

  /// The number copy and insert hand out: in Convert mode the converted
  /// amount, rounded to its currency (what is on screen); otherwise the
  /// result, live answer or typed number.
  String? get _answerText {
    final converter = widget.converter;
    if (_converting && converter != null) {
      if (!converter.isReady || widget.controller.error != null) {
        return null;
      }
      final value = converter.convertRounded(widget.controller.conversionInput);
      final decimals = converter.currency(converter.outputCode)!.decimals;
      return value?.toPlainString(maxFractionDigits: decimals);
    }
    return widget.controller.currentValue?.toPlainString();
  }

  /// A tap on a converter row: the result row becomes the input, carrying
  /// the amount it showed (Calculator.app does the same).
  void _tapConverterRow(bool top) {
    final converter = widget.converter!;
    if (converter.inputIsTop == top || !converter.isReady) {
      return;
    }
    final shown = widget.controller.error != null
        ? null
        : converter.convertRounded(widget.controller.conversionInput);
    converter.focusRow(top: top);
    widget.controller.clear();
    if (shown != null && !shown.isZero) {
      widget.controller.useValue(shown);
    }
  }

  CalculatorKeyboardActions get _actions => CalculatorKeyboardActions(
    onCopy: _copy,
    onPaste: _paste,
    onInsert: _insert,
    onClose: widget.onClose,
    onFlash: _flash,
  );

  void _flash(CalculatorKey key) {
    _flashed.value = key;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 130), () {
      _flashed.value = null;
    });
  }

  void _press(CalculatorKey key) {
    key.applyTo(widget.controller);
    _flash(key);
    // A click moves keyboard input here, so typing carries on from the keys.
    if (!widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
  }

  Future<void> _copy() async {
    final text = _answerText;
    if (text == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    setState(() => _copied = true);
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) {
      return;
    }
    // A paste is a few numbers, not an essay.
    widget.controller.inputText(
      text.length > 200 ? text.substring(0, 200) : text,
    );
  }

  void _insert() {
    final l10n = AppLocalizations.of(context)!;
    final text = _answerText;
    if (text == null) {
      return;
    }
    switch (widget.onInsert(text)) {
      case CalculatorInsertOutcome.inserted:
        break;
      case CalculatorInsertOutcome.rejected:
        _showNotice(l10n.calculatorInsertRejected);
      case CalculatorInsertOutcome.unavailable:
        _showNotice(l10n.calculatorInsertUnavailable);
    }
  }

  void _showNotice(String message) {
    setState(() => _notice = message);
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  Widget _sheetBody() {
    final converter = widget.converter;
    switch (_sheetContent) {
      case _PanelSheet.history:
        return _HistorySheet(
          controller: widget.controller,
          onClose: () => _setSheet(null),
          onPick: (value) {
            widget.controller.useValue(value);
            _setSheet(null);
          },
        );
      case _PanelSheet.pickTop || _PanelSheet.pickBottom:
        if (converter == null || converter.rates == null) {
          return const SizedBox.shrink();
        }
        // Keyed by side so the search starts empty each time it opens.
        return CurrencyPickerSheet(
          key: ValueKey(_sheetContent),
          converter: converter,
          top: _sheetContent == _PanelSheet.pickTop,
          onPicked: () => _setSheet(null),
          onClose: () => _setSheet(null),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final focused = widget.focusNode.hasFocus;

    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      child: Listener(
        // Any press inside the panel gives it the keyboard back.
        onPointerDown: (_) {
          if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
        },
        child: Material(
          key: const ValueKey('floating_calculator_panel'),
          elevation: 12,
          color: colors.surface,
          shadowColor: colors.shadow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PointyRadii.dialog),
            side: BorderSide(
              color: focused ? colors.primary : colors.line,
              width: focused ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              widget.controller,
              ?widget.converter,
            ]),
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: _TitleBar(
                    onDrag: widget.onDrag,
                    showHistory: _showHistory,
                    onToggleHistory: () => _setHistory(!_showHistory),
                    converting: (widget.converter?.isAvailable ?? false)
                        ? _converting
                        : null,
                    onToggleConvert: () {
                      widget.converter?.toggle();
                      widget.focusNode.requestFocus();
                    },
                    onClose: widget.onClose,
                  ),
                ),
                // The tape is a sheet rising from the bottom of the panel,
                // over the keypad; the display stays in view above it.
                ClipRect(
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_converting)
                              CalculatorConverterDisplay(
                                controller: widget.controller,
                                converter: widget.converter!,
                                focused: focused,
                                copied: _copied,
                                onCopy: _answerText == null ? null : _copy,
                                onPickCurrency: (top) => _setSheet(
                                  top
                                      ? _PanelSheet.pickTop
                                      : _PanelSheet.pickBottom,
                                ),
                                onTapRow: _tapConverterRow,
                              )
                            else
                              _Display(
                                controller: widget.controller,
                                focused: focused,
                                copied: _copied,
                                onCopy: _answerText == null ? null : _copy,
                              ),
                            const SizedBox(height: 10),
                            Directionality(
                              textDirection: TextDirection.ltr,
                              child: _Keypad(
                                flashed: _flashed,
                                onPressed: _press,
                              ),
                            ),
                            // Only when there is a field to put the answer in.
                            if (widget.canInsert && _answerText != null) ...[
                              const SizedBox(height: 10),
                              _InsertButton(onInsert: _insert),
                            ],
                            if (_notice != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                _notice!,
                                key: const ValueKey(
                                  'floating_calculator_notice',
                                ),
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.danger,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            const SizedBox(height: 6),
                            Text(
                              _converting
                                  ? l10n.calculatorConvertShortcutHint
                                  : l10n.calculatorShortcutHint,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colors.mutedInk,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: _sheet == null,
                          child: GestureDetector(
                            onTap: () => _setSheet(null),
                            child: AnimatedOpacity(
                              opacity: _sheet != null ? 1 : 0,
                              duration: PointyMotion.standard,
                              child: ColoredBox(
                                color: colors.ink.withValues(alpha: 0.18),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            heightFactor: 0.78,
                            child: IgnorePointer(
                              ignoring: _sheet == null,
                              child: AnimatedSlide(
                                offset: _sheet != null
                                    ? Offset.zero
                                    : const Offset(0, 1.05),
                                duration: PointyMotion.emphasized,
                                curve: PointyMotion.emphasizedCurve,
                                child: ExcludeSemantics(
                                  excluding: _sheet == null,
                                  child: _sheetBody(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _PanelSheet { history, pickTop, pickBottom }

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.onDrag,
    required this.showHistory,
    required this.onToggleHistory,
    required this.converting,
    required this.onToggleConvert,
    required this.onClose,
  });

  final ValueChanged<Offset>? onDrag;
  final bool showHistory;
  final VoidCallback onToggleHistory;

  /// Whether Convert is on; null hides the toggle (no rates for this user).
  final bool? converting;
  final VoidCallback onToggleConvert;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: onDrag == null ? null : (d) => onDrag!(d.delta),
      child: MouseRegion(
        cursor: onDrag == null ? MouseCursor.defer : SystemMouseCursors.move,
        child: Row(
          children: [
            Icon(
              Icons.calculate_outlined,
              color: colors.primaryStrong,
              size: 20,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.calculatorTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (converting != null)
              IconButton(
                key: const ValueKey('floating_calculator_convert'),
                visualDensity: VisualDensity.compact,
                isSelected: converting,
                onPressed: onToggleConvert,
                color: converting! ? colors.primaryStrong : colors.mutedInk,
                style: converting!
                    ? IconButton.styleFrom(
                        backgroundColor: colors.primaryContainer,
                      )
                    : null,
                icon: Icon(
                  Icons.currency_exchange_rounded,
                  semanticLabel: l10n.calculatorConvert,
                ),
              ),
            IconButton(
              key: const ValueKey('floating_calculator_history'),
              visualDensity: VisualDensity.compact,
              isSelected: showHistory,
              onPressed: onToggleHistory,
              color: showHistory ? colors.primaryStrong : colors.mutedInk,
              icon: Icon(
                Icons.history_rounded,
                semanticLabel: l10n.calculatorShowHistory,
              ),
            ),
            IconButton(
              key: const ValueKey('floating_calculator_close'),
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              color: colors.mutedInk,
              icon: Icon(Icons.close, semanticLabel: l10n.calculatorClose),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two lines, like Calculator.app: while typing, the expression is large
/// with the live answer under it; after `=`, the expression shrinks to the
/// small line and the answer takes the large one.
class _Display extends StatelessWidget {
  const _Display({
    required this.controller,
    required this.focused,
    required this.copied,
    required this.onCopy,
  });

  final CalculatorController controller;
  final bool focused;
  final bool copied;

  /// Copies the number on the display; null when there is none.
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final outcome = controller.showsOutcome;
    final error = controller.error;
    final preview = controller.preview;

    final large = PointyTypography.numeric(
      theme.textTheme.headlineMedium!.copyWith(
        color: colors.ink,
        fontWeight: FontWeight.w700,
        height: 1.15,
      ),
    );
    final small = PointyTypography.numeric(
      theme.textTheme.titleSmall!.copyWith(
        color: colors.mutedInk,
        fontWeight: FontWeight.w500,
      ),
    );

    final expression = controller.expressionText;
    final String bottom;
    if (error != null) {
      bottom = switch (error) {
        CalculatorErrorKind.undefined => l10n.calculatorUndefined,
        CalculatorErrorKind.overflow => l10n.calculatorTooLarge,
      };
    } else if (outcome) {
      bottom = controller.result!.format();
    } else if (preview != null) {
      bottom = '= ${preview.format()}';
    } else {
      bottom = '';
    }

    return AnimatedContainer(
      duration: PointyMotion.fast,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(
          color: focused
              ? colors.primary.withValues(alpha: 0.45)
              : colors.surfaceSunken,
        ),
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Copy sits at the start of the display, beside the number it
            // copies.
            IconButton(
              key: const ValueKey('floating_calculator_copy'),
              onPressed: onCopy,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              color: copied ? colors.success : colors.mutedInk,
              icon: Icon(
                copied ? Icons.check_rounded : Icons.copy_rounded,
                semanticLabel: copied
                    ? l10n.calculatorCopied
                    : l10n.calculatorCopy,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _Line(
                    key: const ValueKey('floating_calculator_expression'),
                    text: expression.isEmpty
                        ? '0'
                        : (outcome ? '$expression =' : expression),
                    style: outcome || expression.isEmpty
                        ? (outcome
                              ? small
                              : large.copyWith(color: colors.mutedInk))
                        : large,
                    scrolls: true,
                  ),
                  const SizedBox(height: 2),
                  _Line(
                    key: const ValueKey('floating_calculator_result'),
                    text: bottom,
                    style: outcome
                        ? large.copyWith(
                            color: error != null ? colors.danger : colors.ink,
                            fontSize: error != null ? 22 : null,
                          )
                        : small,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One display line. Long expressions scroll to keep their end in view;
/// long results shrink to fit.
class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.text,
    required this.style,
    this.scrolls = false,
  });

  final String text;
  final TextStyle style;
  final bool scrolls;

  @override
  Widget build(BuildContext context) {
    final content = AnimatedDefaultTextStyle(
      duration: PointyMotion.standard,
      curve: PointyMotion.curve,
      style: style,
      maxLines: 1,
      // Isolated LTR: a line that opens with digits or "=" is otherwise pulled
      // into the Arabic UI's direction ("9÷0 =" drawn as "= 0÷9").
      child: Text(text.isEmpty ? ' ' : ltrIsolated(text), softWrap: false),
    );
    return SizedBox(
      width: double.infinity,
      child: scrolls
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: content,
            )
          : FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: content,
            ),
    );
  }
}

enum _KeyTone { digit, function, operator, equals }

class _KeySpec {
  const _KeySpec(this.key, this.label, this.tone, {this.icon});

  final CalculatorKey key;
  final String label;
  final _KeyTone tone;
  final IconData? icon;
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.flashed, required this.onPressed});

  final ValueListenable<CalculatorKey?> flashed;
  final ValueChanged<CalculatorKey> onPressed;

  static const _rows = <List<_KeySpec>>[
    [
      _KeySpec(CalculatorKey.clear, 'C', _KeyTone.function),
      _KeySpec(
        CalculatorKey.backspace,
        '',
        _KeyTone.function,
        icon: Icons.backspace_outlined,
      ),
      _KeySpec(CalculatorKey.percent, '%', _KeyTone.function),
      _KeySpec(CalculatorKey.divide, '÷', _KeyTone.operator),
    ],
    [
      _KeySpec(CalculatorKey.seven, '7', _KeyTone.digit),
      _KeySpec(CalculatorKey.eight, '8', _KeyTone.digit),
      _KeySpec(CalculatorKey.nine, '9', _KeyTone.digit),
      _KeySpec(CalculatorKey.multiply, '×', _KeyTone.operator),
    ],
    [
      _KeySpec(CalculatorKey.four, '4', _KeyTone.digit),
      _KeySpec(CalculatorKey.five, '5', _KeyTone.digit),
      _KeySpec(CalculatorKey.six, '6', _KeyTone.digit),
      _KeySpec(CalculatorKey.subtract, '−', _KeyTone.operator),
    ],
    [
      _KeySpec(CalculatorKey.one, '1', _KeyTone.digit),
      _KeySpec(CalculatorKey.two, '2', _KeyTone.digit),
      _KeySpec(CalculatorKey.three, '3', _KeyTone.digit),
      _KeySpec(CalculatorKey.add, '+', _KeyTone.operator),
    ],
    [
      _KeySpec(CalculatorKey.doubleZero, '00', _KeyTone.digit),
      _KeySpec(CalculatorKey.zero, '0', _KeyTone.digit),
      _KeySpec(CalculatorKey.decimal, '.', _KeyTone.digit),
      _KeySpec(CalculatorKey.equals, '=', _KeyTone.equals),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (index, row) in _rows.indexed) ...[
          if (index > 0) const SizedBox(height: 8),
          Row(
            children: [
              for (final (column, spec) in row.indexed) ...[
                if (column > 0) const SizedBox(width: 8),
                Expanded(
                  child: _KeyButton(
                    spec: spec,
                    flashed: flashed,
                    onPressed: () => onPressed(spec.key),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.spec,
    required this.flashed,
    required this.onPressed,
  });

  final _KeySpec spec;
  final ValueListenable<CalculatorKey?> flashed;
  final VoidCallback onPressed;

  String? _semanticLabel(AppLocalizations l10n) => switch (spec.key) {
    CalculatorKey.clear => l10n.calculatorKeyClear,
    CalculatorKey.backspace => l10n.calculatorKeyBackspace,
    CalculatorKey.percent => l10n.calculatorKeyPercent,
    CalculatorKey.divide => l10n.calculatorKeyDivide,
    CalculatorKey.multiply => l10n.calculatorKeyMultiply,
    CalculatorKey.subtract => l10n.calculatorKeySubtract,
    CalculatorKey.add => l10n.calculatorKeyAdd,
    CalculatorKey.equals => l10n.calculatorKeyEquals,
    CalculatorKey.decimal => l10n.calculatorKeyDecimal,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final (Color background, Color foreground) = switch (spec.tone) {
      _KeyTone.digit => (colors.subtleFill, colors.ink),
      _KeyTone.function => (colors.surfaceSunken, colors.ink),
      _KeyTone.operator => (colors.primaryContainer, colors.primaryStrong),
      _KeyTone.equals => (colors.primary, theme.colorScheme.onPrimary),
    };
    final label = _semanticLabel(l10n);

    return ValueListenableBuilder<CalculatorKey?>(
      valueListenable: flashed,
      builder: (context, active, child) {
        final pressed = active == spec.key;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: 48,
          decoration: BoxDecoration(
            color: pressed
                ? Color.lerp(background, foreground, 0.22)
                : background,
            borderRadius: BorderRadius.circular(PointyRadii.button),
          ),
          child: child,
        );
      },
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: label != null,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('calculator_key_${spec.key.name}'),
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(PointyRadii.button),
            onTap: onPressed,
            child: Center(
              child: spec.icon != null
                  ? Icon(spec.icon, size: 20, color: foreground)
                  : Text(
                      spec.label,
                      style: PointyTypography.numeric(
                        theme.textTheme.titleLarge!.copyWith(
                          color: foreground,
                          fontWeight: spec.tone == _KeyTone.digit
                              ? FontWeight.w600
                              : FontWeight.w700,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tape, as a sheet: handle (drag down or tap to close), title with
/// "clear", then earlier calculations newest first — tap one to use it.
class _HistorySheet extends StatelessWidget {
  const _HistorySheet({
    required this.controller,
    required this.onClose,
    required this.onPick,
  });

  final CalculatorController controller;
  final VoidCallback onClose;
  final ValueChanged<CalculatorNumber> onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final history = controller.history;

    return Material(
      key: const ValueKey('floating_calculator_history_list'),
      color: colors.surface,
      elevation: 8,
      shadowColor: colors.shadow,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 0) onClose();
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.lineStrong,
                    borderRadius: BorderRadius.circular(PointyRadii.pill),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 8, 4),
            child: Row(
              children: [
                Icon(Icons.history_rounded, size: 18, color: colors.mutedInk),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.calculatorShowHistory,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (history.isNotEmpty)
                  TextButton(
                    onPressed: controller.clearHistory,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: colors.danger,
                    ),
                    child: Text(l10n.calculatorClearHistory),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.line),
          Expanded(
            child: history.isEmpty
                ? Center(
                    child: Text(
                      l10n.calculatorHistoryEmpty,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: history.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: colors.line,
                    ),
                    itemBuilder: (context, index) {
                      final entry = history[index];
                      return InkWell(
                        canRequestFocus: false,
                        onTap: () => onPick(entry.result),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Directionality(
                            textDirection: TextDirection.ltr,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  ltrIsolated(entry.expression),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: PointyTypography.numeric(
                                    theme.textTheme.bodySmall!.copyWith(
                                      color: colors.mutedInk,
                                    ),
                                  ),
                                ),
                                Text(
                                  ltrIsolated('= ${entry.result.format()}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: PointyTypography.numeric(
                                    theme.textTheme.titleMedium!.copyWith(
                                      color: colors.ink,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// "Insert into the field": types the answer where the user was typing.
class _InsertButton extends StatelessWidget {
  const _InsertButton({required this.onInsert});

  final VoidCallback onInsert;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FilledButton.tonalIcon(
      key: const ValueKey('floating_calculator_insert'),
      onPressed: onInsert,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        visualDensity: VisualDensity.compact,
      ),
      icon: const Icon(Icons.input_rounded, size: 18),
      label: Text(l10n.calculatorInsert),
    );
  }
}
