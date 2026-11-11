import 'dart:js_interop';

@JS('document.title')
external String get _title;

/// The title index.html came with, read before the app sets its own.
String servedPageTitle() => _title;
