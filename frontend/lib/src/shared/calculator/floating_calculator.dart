import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/design.dart';
import 'calculator_controller.dart';
import 'calculator_panel.dart';
import 'currency_converter.dart';

/// The host mounted in `MaterialApp.builder`; reach it from anywhere (the
/// command palette's quick action) through [toggleFloatingCalculator] and
/// [openFloatingCalculator].
final GlobalKey<FloatingCalculatorHostState> floatingCalculatorKey =
    GlobalKey<FloatingCalculatorHostState>(debugLabel: 'floating_calculator');

void openFloatingCalculator() => floatingCalculatorKey.currentState?.open();

void toggleFloatingCalculator() => floatingCalculatorKey.currentState?.toggle();

/// F12, anywhere in the app: a calculator floating over whatever is on
/// screen — the till, a payment sheet, a purchase order, settings.
///
/// Built like the F8 camera panel: above the Navigator so it floats over
/// every route, sheets and dialogs included, and toggled through
/// [HardwareKeyboard] because focus-tree shortcuts die whenever focus parks
/// outside the widget that declared them. F12 is the one function key no
/// screen uses (the till has F1, F2, F4, F9; purchasing F1–F4, F6; the
/// product form F7; the camera F8) and it types nothing, so it can never
/// collide with a field or a scan. Off on a price-checker kiosk, which faces
/// customers.
///
/// Unlike the camera panel it takes focus — it is for typing — and gives it
/// back on close. It remembers the last field the user was typing in, so
/// "insert" (or Shift+Enter) types the answer there through the field's own
/// input path, formatters and change handlers included. The calculator, its
/// tape and its position live for the whole session: closing only hides it.
class FloatingCalculatorHost extends StatefulWidget {
  const FloatingCalculatorHost({
    super.key,
    required this.child,
    this.enabled = true,
    this.clock = DateTime.now,
    this.ratesLoader,
    this.ratesKey,
  });

  static const LogicalKeyboardKey toggleKey = LogicalKeyboardKey.f12;
  static const double panelWidth = 304;

  final Widget child;
  final bool enabled;
  final DateTime Function() clock;

  /// Where Convert gets its rates; null hides Convert (signed out, or a user
  /// who may not read rates).
  final ConverterRatesLoader? ratesLoader;

  /// Whose rates these are (the signed-in user). A change drops the cached
  /// rates, so one cashier never converts with another session's snapshot.
  final Object? ratesKey;

  @override
  State<FloatingCalculatorHost> createState() => FloatingCalculatorHostState();
}

class FloatingCalculatorHostState extends State<FloatingCalculatorHost> {
  final CalculatorController _controller = CalculatorController();
  late final CurrencyConverter _converter = CurrencyConverter(
    loader: widget.ratesLoader,
    clock: widget.clock,
  );
  final FocusNode _focusNode = FocusNode(debugLabel: 'floating_calculator');

  bool _open = false;

  /// Top-left of the panel, once placed. Null means "the default corner".
  Offset? _position;

  /// Where focus was before the calculator took it — handed back on close.
  FocusNode? _returnFocus;

  /// The last text field the user typed in, outside the calculator.
  EditableTextState? _insertTarget;

  bool get isOpen => _open;
  CalculatorController get controller => _controller;
  CurrencyConverter get converter => _converter;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    FocusManager.instance.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    _converter.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(FloatingCalculatorHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _open) {
      _open = false;
    }
    if (oldWidget.ratesKey != widget.ratesKey) {
      _converter.reset(loader: widget.ratesLoader);
    } else {
      _converter.loader = widget.ratesLoader;
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != FloatingCalculatorHost.toggleKey ||
        !widget.enabled) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return false;
    }
    toggle();
    return true;
  }

  /// Opens; when already open but the page has the keyboard, takes it back
  /// (so F12 always means "let me type a sum"); when focused, closes.
  void toggle() {
    if (!_open) {
      open();
    } else if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    } else {
      close();
    }
  }

  void open() {
    if (!widget.enabled || !mounted) {
      return;
    }
    if (!_open) {
      setState(() => _open = true);
    }
    // After the panel is built — and after a closing palette or menu has
    // finished handing focus back to its route.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _open) _focusNode.requestFocus();
    });
  }

  void close() {
    if (!_open) {
      return;
    }
    if (_focusNode.hasFocus) {
      final back = _returnFocus;
      if (back != null && _isUsable(back)) {
        back.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
    setState(() => _open = false);
  }

  void _onFocusChanged() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || _isOurs(primary)) {
      return;
    }
    _returnFocus = primary;
    final editable = primary.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (editable != null && !editable.widget.readOnly) {
      _insertTarget = editable;
    }
    if (_open && mounted) {
      // The insert button follows the field.
      setState(() {});
    }
  }

  bool _isOurs(FocusNode node) =>
      node == _focusNode || node.ancestors.contains(_focusNode);

  static bool _isUsable(FocusNode node) =>
      (node.context?.mounted ?? false) && node.canRequestFocus;

  /// The remembered field, if it is still on screen and on the top route —
  /// a field under a closed dialog, or on a screen left behind, is not.
  EditableTextState? get _liveInsertTarget {
    final target = _insertTarget;
    if (target == null || !target.mounted || target.widget.readOnly) {
      return null;
    }
    if (ModalRoute.of(target.context)?.isCurrent == false) {
      return null;
    }
    return target;
  }

  CalculatorInsertOutcome _insert(String text) {
    final target = _liveInsertTarget;
    if (target == null) {
      return CalculatorInsertOutcome.unavailable;
    }
    final before = target.textEditingValue;
    final selection = before.selection.isValid
        ? before.selection
        : TextSelection.collapsed(offset: before.text.length);
    final intended = before.replaced(selection, text);
    // The field's own path: input formatters run, onChanged fires.
    target.userUpdateTextEditingValue(intended, SelectionChangedCause.keyboard);
    if (target.textEditingValue.text == before.text && text.isNotEmpty) {
      return CalculatorInsertOutcome.rejected;
    }
    final node = target.widget.focusNode;
    setState(() => _open = false);
    node.requestFocus();
    return CalculatorInsertOutcome.inserted;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_open)
          Positioned.fill(
            // Its own Overlay: the panel sits above the Navigator's, and the
            // currency search field needs one for its selection handles.
            // Empty space still passes taps through to the app below.
            child: Overlay.wrap(
              child: LayoutBuilder(
                builder: (context, constraints) => Stack(
                  children: [_placedPanel(context, constraints.biggest)],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _placedPanel(BuildContext context, Size bounds) {
    const margin = 16.0;
    final width = FloatingCalculatorHost.panelWidth.clamp(
      0.0,
      (bounds.width - 2 * margin).clamp(0.0, double.infinity),
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // Anchored by its bottom edge, so opening the tape grows it upwards
    // instead of off the screen. The start corner, low: over the catalogue
    // on the till, clear of the cart and its totals (the camera panel's side).
    final initial = Offset(
      rtl ? bounds.width - width - margin : margin,
      margin,
    );
    final position = _clamp(_position ?? initial, bounds, width);
    return Positioned(
      left: position.dx,
      bottom: position.dy,
      width: width,
      child: ConstrainedBox(
        // A short window scrolls the panel rather than clipping the keypad.
        constraints: BoxConstraints(
          maxHeight: (bounds.height - position.dy).clamp(0.0, double.infinity),
        ),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: PointyMotion.standard,
          curve: PointyMotion.curve,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.scale(
              scale: 0.96 + 0.04 * t,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
          ),
          child: SingleChildScrollView(
            child: CalculatorPanel(
              controller: _controller,
              converter: _converter,
              focusNode: _focusNode,
              clock: widget.clock,
              onClose: close,
              canInsert: _liveInsertTarget != null,
              onInsert: _insert,
              onDrag: (delta) => setState(() {
                _position = _clamp(
                  Offset(position.dx + delta.dx, position.dy - delta.dy),
                  bounds,
                  width,
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  /// Keeps the panel's left edge on screen and at least its title bar
  /// reachable: [offset] is (left, distance from the bottom).
  Offset _clamp(Offset offset, Size bounds, double width) {
    const minVisibleHeight = 120.0;
    return Offset(
      offset.dx.clamp(0.0, (bounds.width - width).clamp(0.0, double.infinity)),
      offset.dy.clamp(
        0.0,
        (bounds.height - minVisibleHeight).clamp(0.0, double.infinity),
      ),
    );
  }
}
