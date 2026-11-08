import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

/// Dafa's bank-card page in a frame of the web app's own page, so paying
/// on the web is what it is on a phone: the page over the app, closed by the
/// app once the payment is done. Dafa's page allows framing (it sends no
/// X-Frame-Options or frame-ancestors).
///
/// After paying, «المتابعة» loads the relay's payment-return page inside the
/// frame. That page posts [returnMessage] to its parent, this page, and
/// [onReturn] fires: the app closes the frame and carries the checkout on.
/// Only a message from this frame counts.
class PaymentFrame extends StatefulWidget {
  const PaymentFrame({
    super.key,
    required this.url,
    required this.onLoaded,
    required this.onReturn,
  });

  final Uri url;
  final VoidCallback onLoaded;
  final VoidCallback onReturn;

  /// What the relay's payment-return page posts to the frame's owner.
  static const returnMessage = 'pointy-payment-return';

  @override
  State<PaymentFrame> createState() => _PaymentFrameState();
}

class _PaymentFrameState extends State<PaymentFrame> {
  static var _next = 0;
  late final String _viewType = 'pointy-payment-frame-${_next++}';
  late final JSFunction _onMessage = _message.toJS;
  _Frame? _frame;

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final frame = _frame = _document.createElement('iframe') as _Frame;
      frame
        ..src = widget.url.toString()
        ..setAttribute('allow', 'payment')
        ..setAttribute('title', widget.url.host);
      frame.style
        ..border = 'none'
        ..width = '100%'
        ..height = '100%'
        ..background = '#ffffff';
      frame.addEventListener(
        'load',
        (() {
          if (mounted) {
            widget.onLoaded();
          }
        }).toJS,
      );
      return frame;
    });
    _window.addEventListener('message', _onMessage);
  }

  void _message(_MessageEvent event) {
    final frame = _frame;
    if (mounted &&
        frame != null &&
        event.source != null &&
        event.source.strictEquals(frame.contentWindow).toDart &&
        event.data.dartify() == PaymentFrame.returnMessage) {
      widget.onReturn();
    }
  }

  @override
  void dispose() {
    _window.removeEventListener('message', _onMessage);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}

@JS('document')
external _Document get _document;

@JS('window')
external _Window get _window;

extension type _Document(JSObject _) implements JSObject {
  external JSObject createElement(String tag);
}

extension type _Window(JSObject _) implements JSObject {
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type _Frame(JSObject _) implements JSObject {
  external JSAny? get contentWindow;
  external set src(String value);
  external _Style get style;
  external void setAttribute(String name, String value);
  external void addEventListener(String type, JSFunction listener);
}

extension type _Style(JSObject _) implements JSObject {
  external set border(String value);
  external set width(String value);
  external set height(String value);
  external set background(String value);
}

extension type _MessageEvent(JSObject _) implements JSObject {
  external JSAny? get source;
  external JSAny? get data;
}
