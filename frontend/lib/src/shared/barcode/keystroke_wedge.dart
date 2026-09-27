import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A device that is not a keyboard, typing like one.
///
/// A USB barcode scanner works everywhere for one reason: it IS a keyboard. It
/// types what it reads as key presses, ends with Enter, and nothing in the app
/// has to know it exists. The till's scan listener, the payment sheet matching
/// a terminal slip, the card-receipt dialog, a search box, a supplier-invoice
/// number field — each of them is only listening to the keyboard.
///
/// This types a string the same way, one key press per character and then
/// Enter, through the same three stages a real key press takes in Flutter:
///
/// 1. the [HardwareKeyboard] handlers — `BarcodeScanListener`, the till's
///    function keys;
/// 2. the focus tree — `Focus.onKeyEvent` and `Shortcuts`, where the payment
///    sheet keeps its Enter and the cart its quantity keys. As on the real
///    path, it hears the key even when a stage-1 handler claimed it;
/// 3. when neither stage claimed the key, the focused text field, as the
///    platform's text input would: the character lands at the caret, and
///    Enter submits the field (or starts a new line in a multi-line one).
///
/// So a scan typed here lands wherever a USB scanner's would, behind the same
/// guards: a covered screen does not hear it, a screen mid-checkout drops it,
/// and a burst never becomes a quantity.
///
/// Where it deliberately differs from a USB scanner:
///
/// * **The characters are the scan's, whatever the keyboard layout.** A USB
///   scanner sends key positions, so with the Arabic layout switched on it
///   types a receipt link's Latin letters as Arabic ones.
/// * **Control characters are not typed.** A line break inside a code would
///   otherwise be an Enter that cuts one scan into two.
/// * **Nothing is typed while another program has the keyboard.** A USB
///   scanner's keys would go to that program; a camera that watches the
///   counter all day must not type into a cashier's chat window, and must not
///   type into the till behind it either. On the desktop,
///   [AppLifecycleState.resumed] is exactly "this window has keyboard focus".
/// * **Nothing is typed over a held Ctrl, Alt or ⌘.** The keys would arrive
///   as shortcuts — Ctrl+Enter is checkout. The scan waits for the modifier
///   to be let go, for up to [modifierPatience], and is dropped after that.
class KeystrokeWedge {
  KeystrokeWedge({
    required this.source,
    this.modifierPatience = const Duration(seconds: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// What is typing, in the words scan telemetry uses (`camera_wedge`).
  ///
  /// Readable as [typingSource] while this wedge's keys are being handled,
  /// which is how a scan handler can tell a camera scan from the counter
  /// scanner's without either of them changing shape.
  final String source;

  /// How long a scan waits for a held Ctrl, Alt or ⌘ to be let go.
  final Duration modifierPatience;

  final DateTime Function() _clock;
  final Queue<String> _pending = Queue<String>();
  Timer? _retry;
  DateTime? _waitingSince;
  bool _disposed = false;

  static const _retryEvery = Duration(milliseconds: 50);

  /// The key every wedge keystroke is pressed on. It sits in Flutter's own
  /// plane, which no keyboard reports (they send USB HID usages, and the
  /// embedders file keys they cannot name under per-platform planes), so a
  /// scan typed while the cashier holds a key down can never be taken for
  /// that key going up.
  static const _key = PhysicalKeyboardKey(0x02000057ED);

  static String? _typingSource;

  /// The [source] of the wedge whose key is being handled right now, or null
  /// when it is the real keyboard's.
  ///
  /// Only meaningful synchronously, inside a key handler — a scan listener's
  /// callback runs inside the Enter that ends the scan, so it can read it.
  static String? get typingSource => _typingSource;

  /// Type [payload], then press Enter.
  ///
  /// Typed at once when the app has the keyboard; held back while a modifier
  /// is down; dropped when another program has the keyboard, the way a USB
  /// scanner's keys would have gone to that program instead.
  void type(String payload) {
    if (_disposed) return;
    _pending.add(payload);
    _drain();
  }

  /// Stop typing and forget anything still waiting.
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _retry = null;
    _pending.clear();
  }

  void _drain() {
    _retry?.cancel();
    _retry = null;
    if (_disposed) return;
    if (_typingSource != null) {
      // A key handler asked for a scan while another scan's keys are still
      // being handled. Never interleave two scans: go once this one is done.
      scheduleMicrotask(_drain);
      return;
    }
    while (_pending.isNotEmpty) {
      if (!_appHasKeyboard) {
        _pending.clear();
        _waitingSince = null;
        return;
      }
      if (_modifierHeld) {
        final since = _waitingSince ??= _clock();
        if (_clock().difference(since) >= modifierPatience) {
          _pending.clear();
          _waitingSince = null;
          return;
        }
        _retry = Timer(_retryEvery, _drain);
        return;
      }
      _waitingSince = null;
      _typeNow(_pending.removeFirst());
    }
  }

  void _typeNow(String payload) {
    final characters = [
      for (final rune in payload.runes)
        if (!_isControl(rune)) String.fromCharCode(rune),
    ];
    // A lone Enter would press whatever button has focus.
    if (characters.isEmpty) return;
    _typingSource = source;
    try {
      for (final character in characters) {
        _press(
          _logicalKeyFor(character),
          character: character,
          ifUnclaimed: () => _typeIntoFocusedField(character),
        );
      }
      _press(LogicalKeyboardKey.enter, ifUnclaimed: _submitFocusedField);
    } finally {
      _typingSource = null;
    }
  }

  static bool get _appHasKeyboard {
    final state = SchedulerBinding.instance.lifecycleState;
    // Unknown (a platform that never reported one) is not a reason to go
    // deaf: only a known "somebody else has the keyboard" is.
    return state == null || state == AppLifecycleState.resumed;
  }

  static bool get _modifierHeld {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed;
  }

  static bool _isControl(int rune) =>
      rune < 0x20 || (rune >= 0x7F && rune < 0xA0);

  /// Flutter names a printable key after the character it types, lower-cased:
  /// "a" and "A" are both [LogicalKeyboardKey.keyA], "5" is `digit5`.
  static LogicalKeyboardKey _logicalKeyFor(String character) {
    final lower = character.toLowerCase();
    final id = (lower.runes.length == 1 ? lower : character).runes.first;
    return LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id);
  }

  static void _press(
    LogicalKeyboardKey logicalKey, {
    String? character,
    required VoidCallback ifUnclaimed,
  }) {
    try {
      final claimed = _dispatch(
        KeyDownEvent(
          physicalKey: _key,
          logicalKey: logicalKey,
          character: character,
          timeStamp: _now(),
        ),
      );
      if (!claimed) ifUnclaimed();
    } finally {
      // Always let go, or the keyboard state would hold this key down.
      _dispatch(
        KeyUpEvent(
          physicalKey: _key,
          logicalKey: logicalKey,
          timeStamp: _now(),
        ),
      );
    }
  }

  /// Hand one key event to both stages, the way `KeyEventManager` does for a
  /// real one, and say whether either claimed it.
  static bool _dispatch(KeyEvent event) {
    var handled = HardwareKeyboard.instance.handleKeyEvent(event);
    final focusTree = _focusTree;
    if (focusTree != null) {
      try {
        // ignore: deprecated_member_use
        handled = focusTree(KeyMessage([event], null)) || handled;
      } catch (exception, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: exception,
            stack: stack,
            library: 'keystroke wedge',
            context: ErrorDescription('while handing a typed key to the focus'),
          ),
        );
      }
    }
    return handled;
  }

  /// Where the focus tree hears keys. Not a HardwareKeyboard handler:
  /// FocusManager listens on keyMessageHandler, and a TODO in its
  /// registerGlobalHandlers moves it onto HardwareKeyboard once RawKeyEvent is
  /// removed. Then this stops compiling, which is the cue to drop it.
  // ignore: deprecated_member_use
  static KeyMessageHandler? get _focusTree =>
      // ignore: deprecated_member_use
      ServicesBinding.instance.keyEventManager.keyMessageHandler;

  static Duration _now() =>
      Duration(microseconds: DateTime.now().microsecondsSinceEpoch);

  /// The field the platform would be typing into: the one with primary focus.
  static EditableTextState? _focusedField() {
    final focus = FocusManager.instance.primaryFocus;
    final field = focus?.context?.findAncestorStateOfType<EditableTextState>();
    if (field == null || !identical(field.widget.focusNode, focus)) {
      return null;
    }
    // A read-only field takes no typing, from a person or from this.
    return field.widget.readOnly ? null : field;
  }

  /// What the engine does with a character nobody claimed: replace the
  /// selection with it and leave the caret after it. Input formatters and
  /// `onChanged` run as they do for typing, and the engine's copy of the
  /// field is told, so the next real key press starts from this text.
  static void _typeIntoFocusedField(String text) {
    final field = _focusedField();
    if (field == null) return;
    final value = field.textEditingValue;
    final length = value.text.length;
    // A field with no caret yet is typed into at its start, as the engine
    // does with the -1/-1 selection it is handed.
    final selection = value.selection.isValid
        ? value.selection
        : const TextSelection.collapsed(offset: 0);
    final start = selection.start.clamp(0, length);
    final end = selection.end.clamp(0, length);
    field.userUpdateTextEditingValue(
      TextEditingValue(
        text: value.text.replaceRange(start, end, text),
        selection: TextSelection.collapsed(offset: start + text.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  /// What the engine does with an Enter nobody claimed: a new line in a
  /// multi-line field that asked for one, then the field's input action —
  /// `onSubmitted` for an ordinary field.
  static void _submitFocusedField() {
    final field = _focusedField();
    if (field == null) return;
    final configuration = field.textInputConfiguration;
    if (configuration.inputType == TextInputType.multiline &&
        configuration.inputAction == TextInputAction.newline) {
      _typeIntoFocusedField('\n');
    }
    field.performAction(configuration.inputAction);
  }
}
