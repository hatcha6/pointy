// compat/win8: the real web implementation imported `package:web` (and
// dart:js_interop), whose Dart-3.3-compatible line (web <=0.5.1) conflicts
// with the Flutter SDK's own `web` pin. This is a Windows-only build that
// never runs on the web platform, so re-export the no-op stub — the
// conditional export in order_document_web_delivery.dart still resolves,
// now without pulling `package:web`.
export 'order_document_web_delivery_stub.dart';
