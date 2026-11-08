import 'dart:js_interop';

@JS('document')
external _Document get _document;

extension type _Document(JSObject _) implements JSObject {
  external _Element get documentElement;
  external _Element? querySelector(String selector);
}

extension type _Element(JSObject _) implements JSObject {
  external _Style get style;
}

extension type _Style(JSObject _) implements JSObject {
  external set background(String value);
}

/// Sets [css] as the background of the page and of Flutter's view, the
/// fixed element covering it, which is the one Safari reads.
void setPageBackground(String css) {
  _document.documentElement.style.background = css;
  _document.querySelector('flutter-view')?.style.background = css;
}
