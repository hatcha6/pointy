import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void>? _loading;

/// Adds flutter_soloud's loader to the page the first time the game needs
/// it, rather than in `index.html`: its WebAssembly is about 2 MB, and only
/// a customer who waits long enough to play should download it.
Future<void> loadMixerScript() => _loading ??= () {
  final done = Completer<void>();
  final script = web.HTMLScriptElement()
    ..src = 'assets/packages/flutter_soloud/web/init_soloud.js'
    ..defer = true;
  script.onload = ((web.Event _) => done.complete()).toJS;
  script.onerror = ((web.Event _) {
    _loading = null;
    done.completeError(StateError('the sound mixer did not load'));
  }).toJS;
  web.document.body!.append(script);
  return done.future;
}();
