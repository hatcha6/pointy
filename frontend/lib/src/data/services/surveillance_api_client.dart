import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/camera.dart';
import 'api_session.dart';

/// One decoded video frame off the wire, with the moment it depicts.
///
/// [capturedAt] is the *footage* time, not the delivery time: for playback it is
/// a moment in the past, and it is what drives the scrubber and the timestamp
/// the player burns into the corner. The backend sends it per part in
/// `X-Pointy-Frame-Time`.
class CameraFrame {
  const CameraFrame({required this.bytes, required this.capturedAt});

  final Uint8List bytes;
  final DateTime capturedAt;
}

/// Talks to `apps.surveillance`: recorder setup, camera naming, and the two
/// MJPEG streams (live and playback) that share one wire format.
class SurveillanceApiClient {
  const SurveillanceApiClient(this._session);

  final PosApiSession _session;

  // -- configuration -------------------------------------------------------
  Future<SurveillanceStatus> fetchStatus() async {
    final response = await _session.get('surveillance/status/');
    _session.ensureSuccess(
      response,
      'Camera status request failed with status',
    );
    final decoded = _session.decodedBody(response);
    return SurveillanceStatus.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<List<Recorder>> fetchRecorders() async {
    final response = await _session.get('surveillance/recorders/');
    _session.ensureSuccess(response, 'Recorders request failed with status');
    return _listFromResponse(_session.decodedBody(response), Recorder.fromJson);
  }

  Future<Recorder> saveRecorder(RecorderDraft draft) async {
    final isUpdate = draft.id != null;
    final path = isUpdate
        ? 'surveillance/recorders/${draft.id}/'
        : 'surveillance/recorders/';
    final response = isUpdate
        ? await _session.patch(path, body: draft.toJson())
        : await _session.post(path, body: draft.toJson());
    _session.ensureSuccess(response, 'Saving the recorder failed with status');
    final decoded = _session.decodedBody(response);
    return Recorder.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<void> deleteRecorder(int id) async {
    final response = await _session.delete('surveillance/recorders/$id/');
    _session.ensureSuccess(
      response,
      'Removing the recorder failed with status',
    );
  }

  /// Probes credentials that may not be saved yet, so the setup screen can show
  /// "Hikvision DS-7216, 16 cameras" before anyone commits.
  Future<RecorderTestResult> testRecorder(RecorderDraft draft) async {
    final response = await _session.post(
      'surveillance/recorders/test/',
      body: {...draft.toJson(), if (draft.id != null) 'id': draft.id},
    );
    _session.ensureSuccess(response, 'Testing the recorder failed with status');
    final decoded = _session.decodedBody(response);
    return RecorderTestResult.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  /// Re-reads a saved recorder's channel list and reconciles it with ours.
  Future<Recorder> syncRecorder(int id) async {
    final response = await _session.post('surveillance/recorders/$id/sync/');
    _session.ensureSuccess(response, 'Syncing the recorder failed with status');
    final decoded = _session.decodedBody(response);
    return Recorder.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<List<Camera>> fetchCameras({bool enabledOnly = false}) async {
    final response = await _session.get(
      'surveillance/cameras/',
      query: {if (enabledOnly) 'enabled': 'true'},
    );
    _session.ensureSuccess(response, 'Cameras request failed with status');
    return _listFromResponse(_session.decodedBody(response), Camera.fromJson);
  }

  Future<Camera> updateCamera(
    int id, {
    String? name,
    bool? isEnabled,
    int? displayOrder,
    bool? coversCheckout,
    CameraQuality? liveQuality,
    CameraQuality? playbackQuality,
  }) async {
    final response = await _session.patch(
      'surveillance/cameras/$id/',
      // Only the fields the caller actually named are sent, so one switch on
      // the settings page cannot overwrite the camera's other settings.
      body: {
        'name': ?name,
        'is_enabled': ?isEnabled,
        'display_order': ?displayOrder,
        'covers_checkout': ?coversCheckout,
        if (liveQuality != null) 'live_quality': liveQuality.wireValue,
        if (playbackQuality != null)
          'playback_quality': playbackQuality.wireValue,
      },
    );
    _session.ensureSuccess(response, 'Saving the camera failed with status');
    final decoded = _session.decodedBody(response);
    return Camera.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  /// Which stretches of a window actually hold footage, for the timeline.
  Future<RecordingIndex> fetchRecordings(
    int cameraId, {
    required DateTime start,
    required DateTime end,
  }) async {
    final response = await _session.get(
      'surveillance/cameras/$cameraId/recordings/',
      query: {
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
      },
    );
    _session.ensureSuccess(response, 'Recordings request failed with status');
    final decoded = _session.decodedBody(response);
    return RecordingIndex.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  Future<InvoiceFootage> fetchInvoiceFootage(int orderId) async {
    final response = await _session.get(
      'surveillance/orders/$orderId/footage/',
    );
    _session.ensureSuccess(
      response,
      'Invoice footage request failed with status',
    );
    final decoded = _session.decodedBody(response);
    return InvoiceFootage.fromJson(
      decoded is Map<String, Object?> ? decoded : const {},
    );
  }

  // -- video ---------------------------------------------------------------
  /// Live frames for one camera.
  ///
  /// [smooth] asks the server for the RTSP pipeline instead of snapshot polling
  /// — more frames, more server CPU — and is silently ignored where ffmpeg is
  /// absent, so callers need not pre-check.
  Stream<CameraFrame> liveFrames(
    int cameraId, {
    int fps = 4,
    CameraQuality? quality,
    bool smooth = false,
    int width = 0,
  }) {
    return _frames(
      'surveillance/cameras/$cameraId/live/',
      query: {
        'fps': '$fps',
        if (quality != null) 'quality': quality.wireValue,
        // Always stated, never omitted. The server treats an absent `smooth`
        // as "yes" — the RTSP pipeline is its default — so a caller that wants
        // the cheap snapshot path (the dashboard) has to say so out loud.
        'smooth': smooth ? 'true' : 'false',
        if (width > 0) 'width': '$width',
      },
      pollFallback: () => snapshotUrl(cameraId, quality: quality),
      pollInterval: Duration(milliseconds: (1000 / fps).round()),
    );
  }

  /// A short-lived URL for listening to one camera.
  ///
  /// Two calls rather than one because the thing that fetches sound is the
  /// platform's own audio player, which cannot portably be handed an
  /// Authorization header. So this call — authenticated, like everything else
  /// here — asks permission and gets back a URL carrying a signed ticket that
  /// the player can fetch with no headers at all.
  ///
  /// It is also where "this camera has no microphone" is answered, as a 409
  /// with a sentence in it. Most analogue cameras are silent, so that is a
  /// normal outcome and not an error to log.
  Future<Uri> audioStreamUri(int cameraId) async {
    final response = await _session.post(
      'surveillance/cameras/$cameraId/audio/ticket/',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = _session.body(response);
      final message = _messageFor(response.statusCode, body);
      if (response.statusCode == 409) {
        // Not a failure to retry: the server measured this channel and there
        // is no microphone on it. A distinct type so the caller can stop
        // offering the button rather than letting it fail again.
        throw CameraHasNoAudio(message);
      }
      throw PosApiException(
        message: message,
        statusCode: response.statusCode,
        responseBody: body,
      );
    }
    final decoded = _session.decodedBody(response);
    final ticket = decoded is Map<String, Object?>
        ? decoded['ticket']?.toString() ?? ''
        : '';
    if (ticket.isEmpty) {
      throw PosApiException(
        message: 'The server did not return a listening link.',
        statusCode: response.statusCode,
        responseBody: '',
      );
    }
    return _session.uri(
      'surveillance/cameras/$cameraId/audio/',
      queryParameters: {'ticket': ticket},
    );
  }

  /// Recorded frames for a window, paced at [speed] times real time.
  Stream<CameraFrame> playbackFrames(
    int cameraId, {
    required DateTime start,
    required DateTime end,
    double speed = 1.0,
    int fps = 10,
    CameraQuality? quality,
    int width = 0,
  }) {
    return _frames(
      'surveillance/cameras/$cameraId/playback/',
      query: {
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'speed': '$speed',
        'fps': '$fps',
        if (quality != null) 'quality': quality.wireValue,
        if (width > 0) 'width': '$width',
      },
    );
  }

  String snapshotUrl(int cameraId, {CameraQuality? quality}) {
    final suffix = quality == null ? '' : '?quality=${quality.wireValue}';
    return 'surveillance/cameras/$cameraId/snapshot/$suffix';
  }

  Future<Uint8List> fetchSnapshot(
    int cameraId, {
    CameraQuality? quality,
  }) async {
    final response = await _session.get(
      'surveillance/cameras/$cameraId/snapshot/',
      query: {if (quality != null) 'quality': quality.wireValue},
    );
    _session.ensureSuccess(response, 'Snapshot request failed with status');
    return response.bodyBytes;
  }

  /// One frame from the past, as a JPEG the caller can save.
  Future<Uint8List> fetchStill(int cameraId, {required DateTime at}) async {
    final response = await _session.get(
      'surveillance/cameras/$cameraId/still/',
      query: {'at': at.toUtc().toIso8601String()},
    );
    _session.ensureSuccess(response, 'Still request failed with status');
    return response.bodyBytes;
  }

  /// Downloads a window as MP4. Streamed rather than buffered: a clip is tens
  /// of megabytes and holding it whole in app memory on a till is not an option.
  Future<void> exportClip(
    int cameraId, {
    required DateTime start,
    required DateTime end,
    CameraQuality? quality,
    required Future<void> Function(Stream<List<int>> bytes) onBytes,
  }) async {
    final response = await _session.getStreamed(
      'surveillance/cameras/$cameraId/export/',
      query: {
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        if (quality != null) 'quality': quality.wireValue,
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw PosApiException(
        message: 'Export failed with status ${response.statusCode}',
        statusCode: response.statusCode,
        responseBody: body,
      );
    }
    await onBytes(response.stream);
  }

  // -- multipart plumbing --------------------------------------------------
  /// Opens an MJPEG (`multipart/x-mixed-replace`) response and emits its parts.
  ///
  /// On web the HTTP client buffers a response until it completes, so a live
  /// stream would deliver nothing, ever. [pollFallback] is the honest answer
  /// there: fetch stills on a timer at the same rate. Native platforms — the
  /// tills, which is where this feature lives — stream properly.
  Stream<CameraFrame> _frames(
    String path, {
    Map<String, String> query = const {},
    String Function()? pollFallback,
    Duration pollInterval = const Duration(milliseconds: 250),
  }) {
    if (kIsWeb) {
      if (pollFallback == null) {
        return Stream<CameraFrame>.error(
          StateError('Playback is not supported in the browser build.'),
        );
      }
      return _pollFrames(pollFallback(), pollInterval);
    }
    late StreamController<CameraFrame> controller;
    StreamSubscription<List<int>>? subscription;
    var closed = false;

    Future<void> stop() async {
      closed = true;
      final active = subscription;
      subscription = null;
      // Cancelling the byte subscription is what actually closes the socket —
      // and closing it is what makes the server's producer shut down and stop
      // loading the DVR. Leaking it would keep a camera pulling for a screen
      // nobody is on.
      await active?.cancel();
    }

    Future<void> start() async {
      try {
        final response = await _session.getStreamed(path, query: query);
        if (closed) {
          await response.stream.drain<void>();
          return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await response.stream.bytesToString();
          controller.addError(
            PosApiException(
              message: _messageFor(response.statusCode, body),
              statusCode: response.statusCode,
              responseBody: body,
            ),
          );
          await controller.close();
          return;
        }
        final parser = MjpegParser(
          _boundaryOf(response.headers['content-type']),
        );
        subscription = response.stream.listen(
          (chunk) {
            for (final frame in parser.consume(chunk)) {
              if (!controller.isClosed) {
                controller.add(frame);
              }
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!controller.isClosed) {
              controller.addError(error, stack);
            }
          },
          onDone: () {
            if (!controller.isClosed) {
              controller.close();
            }
          },
          cancelOnError: true,
        );
      } on Object catch (error, stack) {
        if (!controller.isClosed) {
          controller.addError(error, stack);
          await controller.close();
        }
      }
    }

    controller = StreamController<CameraFrame>(onListen: start, onCancel: stop);
    return controller.stream;
  }

  Stream<CameraFrame> _pollFrames(String path, Duration interval) async* {
    while (true) {
      final started = DateTime.now();
      final response = await _session.get(path);
      _session.ensureSuccess(response, 'Snapshot request failed with status');
      yield CameraFrame(bytes: response.bodyBytes, capturedAt: DateTime.now());
      final elapsed = DateTime.now().difference(started);
      if (elapsed < interval) {
        await Future<void>.delayed(interval - elapsed);
      }
    }
  }

  String _messageFor(int statusCode, String body) {
    // The backend answers a failed stream with a JSON `detail`, in plain
    // language ("the recorder rejected the username or password"). Surface that
    // rather than a status code the shop cannot act on.
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } on FormatException {
      // Fall through to the generic message.
    }
    return 'Camera stream failed with status $statusCode';
  }

  static String _boundaryOf(String? contentType) {
    final raw = contentType ?? '';
    final marker = raw.indexOf('boundary=');
    if (marker == -1) {
      return 'pointyframe';
    }
    return raw
        .substring(marker + 'boundary='.length)
        .split(';')
        .first
        .trim()
        .replaceAll('"', '');
  }

  List<T> _listFromResponse<T>(
    Object? decoded,
    T Function(Map<String, Object?>) build,
  ) {
    final rows = decoded is Map<String, Object?> ? decoded['results'] : decoded;
    if (rows is! List) {
      return const [];
    }
    return rows.whereType<Map<String, Object?>>().map(build).toList();
  }
}

/// Incremental `multipart/x-mixed-replace` reader.
///
/// Public for its tests: the failure it exists to prevent — a frame split
/// across two socket reads, or a boundary-shaped byte run inside JPEG entropy
/// data — is invisible on a fast LAN and routine over a relay tunnel.
///
/// Every part the backend writes carries a `Content-Length`, so the body is
/// read by length rather than by scanning for the next boundary — the scan
/// would have to look inside JPEG entropy data, which is exactly where a
/// boundary-shaped byte sequence eventually turns up.
class MjpegParser {
  MjpegParser(String boundary)
    : _delimiter = utf8.encode('--$boundary'),
      _buffer = BytesBuilder(copy: false);

  final List<int> _delimiter;
  BytesBuilder _buffer;
  Uint8List _pending = Uint8List(0);

  static final List<int> _headerEnd = utf8.encode('\r\n\r\n');

  Iterable<CameraFrame> consume(List<int> chunk) sync* {
    _buffer.add(chunk);
    _pending = _joined();
    _buffer = BytesBuilder(copy: false);

    var cursor = 0;
    while (true) {
      final boundaryAt = _indexOf(_pending, _delimiter, cursor);
      if (boundaryAt == -1) {
        break;
      }
      final headerEnd = _indexOf(_pending, _headerEnd, boundaryAt);
      if (headerEnd == -1) {
        break;
      }
      final headerText = utf8.decode(
        _pending.sublist(boundaryAt, headerEnd),
        allowMalformed: true,
      );
      final length = _intHeader(headerText, 'content-length');
      if (length == null) {
        // A terminating `--boundary--` has no body; anything else without a
        // length is unreadable and skipping it is better than desynchronising.
        cursor = headerEnd + _headerEnd.length;
        continue;
      }
      final bodyStart = headerEnd + _headerEnd.length;
      if (_pending.length < bodyStart + length) {
        break;
      }
      yield CameraFrame(
        bytes: Uint8List.sublistView(_pending, bodyStart, bodyStart + length),
        capturedAt:
            DateTime.tryParse(_textHeader(headerText, 'x-pointy-frame-time')) ??
            DateTime.now(),
      );
      cursor = bodyStart + length;
    }
    if (cursor > 0) {
      _pending = Uint8List.sublistView(_pending, cursor);
    }
    _buffer.add(_pending);
    _pending = Uint8List(0);
  }

  Uint8List _joined() {
    if (_pending.isEmpty) {
      return _buffer.takeBytes();
    }
    final builder = BytesBuilder(copy: false)
      ..add(_pending)
      ..add(_buffer.takeBytes());
    return builder.takeBytes();
  }

  static int? _intHeader(String headers, String name) {
    final value = _textHeader(headers, name);
    return value.isEmpty ? null : int.tryParse(value);
  }

  static String _textHeader(String headers, String name) {
    for (final line in headers.split('\r\n')) {
      final separator = line.indexOf(':');
      if (separator == -1) {
        continue;
      }
      if (line.substring(0, separator).trim().toLowerCase() == name) {
        return line.substring(separator + 1).trim();
      }
    }
    return '';
  }

  static int _indexOf(Uint8List haystack, List<int> needle, int from) {
    if (needle.isEmpty) {
      return -1;
    }
    final limit = haystack.length - needle.length;
    outer:
    for (var index = from < 0 ? 0 : from; index <= limit; index++) {
      for (var offset = 0; offset < needle.length; offset++) {
        if (haystack[index + offset] != needle[offset]) {
          continue outer;
        }
      }
      return index;
    }
    return -1;
  }
}


/// Thrown when the server has measured a channel and found no microphone.
///
/// Most analogue cameras are silent — sound on an XVR arrives on separate
/// inputs, and only some HDCVI cameras carry it — so this is a normal answer,
/// not an error worth logging.
class CameraHasNoAudio implements Exception {
  const CameraHasNoAudio(this.message);

  final String message;

  @override
  String toString() => message;
}
