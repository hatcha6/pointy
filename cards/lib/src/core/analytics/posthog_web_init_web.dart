import 'dart:js_interop';

@JS('posthog')
external _PostHogJs? get _posthog;

extension type _PostHogJs(JSObject _) implements JSObject {
  external void init(String token, JSObject options);
}

/// Starts posthog-js from the loader in web/index.html: only now, with the
/// build's token, is the library fetched. The page is a Flutter canvas, so
/// clicks say nothing (no autocapture) and nothing is recorded (a card's
/// code is on screen); addresses do change per page, so those count.
void startPosthogWeb({
  required String token,
  required String host,
  required bool share,
}) {
  _posthog?.init(
    token,
    {
          'api_host': host,
          'defaults': '2026-08-30',
          'person_profiles': 'identified_only',
          'autocapture': false,
          'capture_pageview': 'history_change',
          'disable_session_recording': true,
          // Nor what the page would only fetch more scripts for: page-speed
          // timings, dead-click hunting, surveys. They are switched on here
          // when one is wanted.
          'capture_performance': false,
          'capture_dead_clicks': false,
          'disable_surveys': true,
          'enable_heatmaps': false,
          // A customer who turned sharing off sends nothing from the start.
          'opt_out_capturing_by_default': !share,
        }.jsify()!
        as JSObject,
  );
}
