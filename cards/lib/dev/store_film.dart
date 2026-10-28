// Dev-only (safe to delete): the app preview's take. With
// `"STORE_SCREEN": "film"` in store_shot.json the app plays one purchase on
// its own with real touches, so a phone can record it with nobody holding
// it: the opening, a look along the shelf, Libyana, 10 دينار, buy, pay from
// credit, the card, copy. Not shipped.
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Plays the film once the app is up.
Future<void> playFilm() async {
  await _pause(4200); // the opening, then the shelf settles
  await _swipe(const Offset(0, -320), at: 0.62, ms: 900);
  await _pause(1100);
  await _swipe(const Offset(0, 320), at: 0.4, ms: 800);
  await _pause(900);
  await _tapText('ليبيانا', first: true); // the large card up top
  await _pause(1900);
  await _tapText('10 دينار');
  await _pause(900);
  await _tapText('اشترِ');
  await _pause(2000);
  await _tapText('ادفع من رصيدك');
  await _pause(5200); // the seal, then the flip
  await _tapText('نسخ');
}

Future<void> _pause(int ms) => Future.delayed(Duration(milliseconds: ms));

final _clock = Stopwatch()..start();
var _pointer = 100;

void _send(PointerEvent event) =>
    GestureBinding.instance.handlePointerEvent(event);

Future<void> _tapText(String text, {bool first = false}) async {
  final at = _find(text, first: first);
  if (at == null) {
    debugPrint('store_film: no "$text" on screen');
    return;
  }
  final pointer = _pointer++;
  _send(
    PointerDownEvent(
      pointer: pointer,
      position: at,
      kind: PointerDeviceKind.touch,
      timeStamp: _clock.elapsed,
    ),
  );
  await _pause(110); // long enough for the pressed state to show
  _send(
    PointerUpEvent(
      pointer: pointer,
      position: at,
      kind: PointerDeviceKind.touch,
      timeStamp: _clock.elapsed,
    ),
  );
}

/// A finger's drag by [by], starting [at] down the screen, eased out.
Future<void> _swipe(Offset by, {required double at, required int ms}) async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final size = view.physicalSize / view.devicePixelRatio;
  final start = Offset(size.width / 2, size.height * at);
  final pointer = _pointer++;
  _send(
    PointerDownEvent(
      pointer: pointer,
      position: start,
      kind: PointerDeviceKind.touch,
      timeStamp: _clock.elapsed,
    ),
  );
  const steps = 40;
  var last = start;
  for (var i = 1; i <= steps; i++) {
    await _pause(ms ~/ steps);
    final t = Curves.easeInOut.transform(i / steps);
    final next = start + by * t;
    _send(
      PointerMoveEvent(
        pointer: pointer,
        position: next,
        delta: next - last,
        kind: PointerDeviceKind.touch,
        timeStamp: _clock.elapsed,
      ),
    );
    last = next;
  }
  // Held still a moment so it settles instead of flinging.
  await _pause(80);
  _send(
    PointerUpEvent(
      pointer: pointer,
      position: last,
      kind: PointerDeviceKind.touch,
      timeStamp: _clock.elapsed,
    ),
  );
}

/// The centre of the last on-screen text that reads [text] (the top route's),
/// or the [first].
Offset? _find(String text, {bool first = false}) {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  Offset? hit;
  void visit(Element element) {
    final widget = element.widget;
    if (widget is RichText && widget.text.toPlainText() == text) {
      final box = element.renderObject;
      if (box is RenderBox && box.attached && box.hasSize) {
        final centre = box.localToGlobal(box.size.center(Offset.zero));
        if (screen.deflate(4).contains(centre) && (hit == null || !first)) {
          hit = centre;
        }
      }
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return hit;
}
