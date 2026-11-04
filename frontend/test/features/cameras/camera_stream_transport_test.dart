import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/surveillance_api_client.dart';

/// When a camera picture is streamed and when a browser polls stills instead.
///
/// The browser client streams a response body as it arrives, so the old rule —
/// every browser polls, and playback is refused — cost the hosted web app its
/// recorded footage and spent the relay's request budget on stills.
void main() {
  bool polls(String target, {bool isWeb = true, bool hasStillFallback = true}) {
    return SurveillanceApiClient.pollsInsteadOfStreaming(
      isWeb: isWeb,
      target: Uri.parse(target),
      hasStillFallback: hasStillFallback,
    );
  }

  test('a till streams, whatever the address', () {
    expect(polls('http://192.168.1.10/api/x/', isWeb: false), isFalse);
    expect(polls('https://app.dftr.ly/api/x/', isWeb: false), isFalse);
  });

  test('a browser over https streams: HTTP/2 holds every tile at once', () {
    expect(
      polls('https://app.dftr.ly/api/surveillance/cameras/1/live/'),
      isFalse,
    );
  });

  test('a browser over plain http polls live tiles: HTTP/1.1 caps at six', () {
    expect(
      polls('http://192.168.1.10/api/surveillance/cameras/1/live/'),
      isTrue,
    );
  });

  group('stream budget', () {
    ({int fps, int width}) budget({
      required bool throughRelay,
      required int fps,
      int width = 0,
    }) => SurveillanceApiClient.streamBudget(
      throughRelay: throughRelay,
      fps: fps,
      width: width,
    );

    test('on the LAN a stream asks for exactly what the caller wants', () {
      expect(budget(throughRelay: false, fps: 30), (fps: 30, width: 0));
      expect(budget(throughRelay: false, fps: 25, width: 1920), (
        fps: 25,
        width: 1920,
      ));
    });

    test('through the relay the full-screen player is held to the cap', () {
      // The player asks for the recorder's full rate and no width at all:
      // through the relay that is the uplink-filling request.
      expect(budget(throughRelay: true, fps: 30), (
        fps: SurveillanceApiClient.remoteMaxFps,
        width: SurveillanceApiClient.remoteMaxWidth,
      ));
    });

    test('a narrow tile keeps its own width; slow streams keep their rate', () {
      expect(budget(throughRelay: true, fps: 2, width: 320), (
        fps: 2,
        width: 320,
      ));
    });
  });

  test('playback has no still to fall back on, so it always streams', () {
    expect(
      polls(
        'http://192.168.1.10/api/surveillance/cameras/1/playback/',
        hasStillFallback: false,
      ),
      isFalse,
    );
  });
}
