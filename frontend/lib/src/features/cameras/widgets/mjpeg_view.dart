import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../data/services/api_session.dart';
import '../../../data/services/surveillance_api_client.dart';

/// Renders a stream of JPEG frames as video, at the lowest cost this app can
/// manage.
///
/// This widget is the frame rate. Nine tiles at 30fps is 270 decodes and 270
/// repaints a second, so every one of the following is load-bearing — drop any
/// of them and the wall becomes a slideshow long before the recorder or the
/// network is the reason:
///
/// 1. **No widget rebuild per frame.** The decoded image lands in a
///    [ValueNotifier] that the painter listens to directly, so a new frame
///    repaints one layer and never walks the element tree. The obvious
///    `setState` per frame is 270 dirty elements a second across a wall; at
///    that point Flutter is spending its budget on bookkeeping for pixels that
///    are about to be replaced.
/// 2. **Decode to the size actually shown.** [ui.instantiateImageCodec] is
///    given a `targetWidth` from the tile's real layout, so a 704x576 frame in
///    a 240px tile is scaled down *inside* the JPEG decoder — several times
///    cheaper than decoding full size and letting the GPU shrink it, and it is
///    what makes a 3x3 wall cost roughly what one full-screen camera costs.
/// 3. **Drop frames rather than queue them.** While a decode is in flight the
///    newest arrival replaces any pending one. A late frame of video is
///    worthless, and a queue of them is a memory leak with a spinner in front.
/// 4. **One decode per displayed frame.** The next decode is scheduled in a
///    post-frame callback, so decoding cannot outrun the compositor no matter
///    how fast the server sends.
/// 5. **Cost nothing when unwatched.** The subscription is torn down when the
///    widget is not [isActive], which closes the socket, which is what tells the
///    server to stop pulling from the recorder.
class MjpegView extends StatefulWidget {
  const MjpegView({
    super.key,
    required this.frames,
    this.isActive = true,
    this.fit = BoxFit.cover,
    this.frameTime,
    this.onError,
    this.onEnded,
    this.onFirstFrame,
    this.placeholder,
    this.errorBuilder,
    this.reconnectDelay = const Duration(seconds: 3),
    this.maxReconnectDelay = const Duration(seconds: 60),
    this.maxReconnectAttempts = 6,
    this.autoReconnect = true,
  });

  /// Builds the frame stream. Called again on every (re)connect, so it must be
  /// a factory, not a single stream instance.
  final Stream<CameraFrame> Function() frames;

  /// False while the widget is off-screen, backgrounded, or behind another
  /// route. The stream is closed and reopened as this flips.
  final bool isActive;
  final BoxFit fit;

  /// Published on every frame: the wall-clock moment the picture depicts.
  ///
  /// A notifier rather than a callback, deliberately — a callback at 30fps
  /// invites the parent to `setState` per frame and undo point 1 above. Clocks
  /// and scrubbers listen to this and repaint themselves.
  final ValueNotifier<DateTime>? frameTime;
  final ValueChanged<Object>? onError;

  /// The stream completed normally: playback reached the end of its window.
  final VoidCallback? onEnded;

  /// Fired once per view, with how long the first real picture took to
  /// arrive AND decode AND paint. Measured from the first connection
  /// attempt, so a stream that had to retry reports the whole wait — which
  /// is the number the person in the shop actually experienced, and the one
  /// the server cannot see.
  final ValueChanged<Duration>? onFirstFrame;
  final Widget? placeholder;

  /// Renders the failure state. ``retry`` dials again from scratch — offer it
  /// whenever it is passed, because once the attempts are spent nothing else
  /// will reconnect this tile.
  final Widget Function(BuildContext context, Object error, VoidCallback retry)?
  errorBuilder;

  /// The first retry's wait. Each further failure doubles it, up to
  /// [maxReconnectDelay].
  final Duration reconnectDelay;

  /// Ceiling for the doubling above.
  final Duration maxReconnectDelay;

  /// How many times a dead stream is retried before the tile gives up and waits
  /// to be asked again.
  ///
  /// A fixed 3-second retry with no limit is what turned one unreachable DVR
  /// into 18,160 failed requests over three days on 2026-09-08, each one
  /// holding a server thread through a six-second connect timeout. A camera
  /// that has not answered six escalating times is not going to answer on the
  /// seventh, and the person watching would rather be told.
  final int maxReconnectAttempts;

  /// Whether a dead stream is retried. Off for playback, where reaching the end
  /// is success, not a failure to recover from.
  final bool autoReconnect;

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> with WidgetsBindingObserver {
  final ValueNotifier<ui.Image?> _image = ValueNotifier<ui.Image?>(null);

  StreamSubscription<CameraFrame>? _subscription;
  Timer? _reconnectTimer;

  Object? _error;
  int _reconnectAttempts = 0;
  bool _gaveUp = false;
  bool _hasPainted = false;
  DateTime? _waitingSince;
  bool _decoding = false;
  CameraFrame? _queued;
  bool _appIsForeground = true;

  /// The tile's width in physical pixels, for the scaled decode. Updated from
  /// layout; zero until the first build, where a full-size decode is the only
  /// option available.
  int _targetWidth = 0;

  /// The stream's own frame width, learned from the first decode.
  int _sourceWidth = 0;
  int _decodeFailures = 0;

  bool get _shouldRun => widget.isActive && _appIsForeground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_shouldRun) {
      _connect();
    }
  }

  @override
  void didUpdateWidget(MjpegView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive ||
        oldWidget.frames != widget.frames) {
      _restart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A till left on the camera wall overnight must not keep pulling video from
    // the DVR with the app minimised.
    final foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (foreground == _appIsForeground) {
      return;
    }
    _appIsForeground = foreground;
    _restart();
  }

  void _restart() {
    _teardown();
    _reconnectAttempts = 0;
    _gaveUp = false;
    if (_shouldRun) {
      _connect();
    } else if (mounted) {
      setState(() {});
    }
  }

  /// Try again now, after the tile has given up. Wired to the error state's
  /// retry affordance — the only way back once [maxReconnectAttempts] is spent,
  /// which is deliberate: an automatic escape would rebuild the same loop.
  void retry() {
    if (!mounted) {
      return;
    }
    setState(() {
      _error = null;
      _gaveUp = false;
      _reconnectAttempts = 0;
    });
    _teardown();
    if (_shouldRun) {
      _connect();
    }
  }

  void _connect() {
    // Set once per view, never on reconnect: the wait being measured is the
    // person's, and it does not restart because we retried.
    _waitingSince ??= DateTime.now();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _error = null;
    _subscription = widget.frames().listen(
      _onFrame,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  void _teardown() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _subscription;
    _subscription = null;
    subscription?.cancel();
    _queued = null;
  }

  void _onFrame(CameraFrame frame) {
    widget.frameTime?.value = frame.capturedAt;
    if (_decoding) {
      // Keep only the newest: this is the frame-drop that stops a slow client
      // (a manager over the relay tunnel) turning into a growing backlog.
      _queued = frame;
      return;
    }
    unawaited(_decode(frame));
  }

  Future<void> _decode(CameraFrame frame) async {
    _decoding = true;
    try {
      // Scale inside the decoder, but only ever downwards. The source size is
      // learned from the first frame rather than read from a descriptor,
      // because every frame in one stream is the same size and the descriptor
      // API is not uniformly available across the platforms this app ships on.
      // Asking for more pixels than the frame has would upscale during decode:
      // more cost, nothing more to see.
      final scaled =
          _sourceWidth > 0 && _targetWidth > 0 && _targetWidth < _sourceWidth;
      final codec = await ui.instantiateImageCodec(
        frame.bytes,
        targetWidth: scaled ? _targetWidth : null,
      );
      final decoded = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        decoded.image.dispose();
        return;
      }
      if (!scaled) {
        _sourceWidth = decoded.image.width;
      }
      _decodeFailures = 0;
      // Pictures are arriving, so whatever run of failures preceded this is
      // over. Without this a camera that drops out once an hour would walk its
      // backoff up to the ceiling over a day and never walk it back.
      _reconnectAttempts = 0;
      final previous = _image.value;
      _image.value = decoded.image;
      // Disposed after the swap, never before: releasing the image still on
      // screen is a black flash on every frame.
      previous?.dispose();
      if (!_hasPainted) {
        _hasPainted = true;
        widget.onFirstFrame?.call(
          DateTime.now().difference(_waitingSince ?? DateTime.now()),
        );
        // One rebuild, on the transition out of the placeholder. Not per frame.
        setState(() => _error = null);
      } else if (_error != null) {
        setState(() => _error = null);
      }
    } on Object catch (error) {
      // A truncated or malformed frame is one bad frame, not a broken stream,
      // so it is skipped. A *run* of them is different: it means nothing here
      // can read what the server is sending, and silently showing black
      // forever is the worst possible way to report that.
      _decodeFailures++;
      if (_decodeFailures >= 10 && mounted && _error == null) {
        widget.onError?.call(error);
        setState(() => _error = error);
      }
    } finally {
      _decoding = false;
      final pending = _queued;
      _queued = null;
      if (pending != null && mounted && _shouldRun) {
        // Wait for the frame we just published to reach the screen before
        // starting the next decode, so decoding cannot outrun the compositor.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_decoding) {
            unawaited(_decode(pending));
          }
        });
        SchedulerBinding.instance.scheduleFrame();
      }
    }
  }

  void _onError(Object error) {
    widget.onError?.call(error);
    if (!mounted) {
      return;
    }
    setState(() => _error = error);
    _scheduleReconnect(error);
  }

  void _onDone() {
    widget.onEnded?.call();
    if (widget.autoReconnect) {
      _scheduleReconnect(null);
    }
  }

  /// How long to wait before the next attempt.
  ///
  /// A server that has opened its own breaker tells us exactly how long it will
  /// refuse for; honouring that beats guessing, and keeps a wall of tiles from
  /// all waking at the same moment on their own schedules.
  Duration _backoffFor(Object? error) {
    final serverAsk = _retryAfterFrom(error);
    if (serverAsk != null) {
      return serverAsk;
    }
    final doubled = widget.reconnectDelay * (1 << (_reconnectAttempts - 1));
    return doubled > widget.maxReconnectDelay
        ? widget.maxReconnectDelay
        : doubled;
  }

  static Duration? _retryAfterFrom(Object? error) {
    if (error is! PosApiException || error.statusCode != 503) {
      return null;
    }
    final body = error.decodedBody;
    if (body is! Map) {
      return null;
    }
    final seconds = body['retry_after'];
    final value = seconds is num
        ? seconds.toInt()
        : int.tryParse('${seconds ?? ''}');
    if (value == null || value <= 0) {
      return null;
    }
    return Duration(seconds: value.clamp(1, 600));
  }

  /// Whether retrying this failure could ever work.
  ///
  /// A recorder with no still-image endpoint answers 501 however many times it
  /// is asked, and a rejected password answers 401. Spending the retry ladder
  /// on those produces the same loop the ladder was added to stop, only slower.
  /// Anything else — a timeout, a 5xx, a dropped socket — is worth another go.
  static bool _isPermanent(Object? error) {
    final status = _statusOf(error);
    if (status == null) {
      return false;
    }
    // 408 and 429 are explicitly temporary despite being 4xx.
    if (status == 408 || status == 429) {
      return false;
    }
    return status >= 400 && status < 500 || status == 501;
  }

  static int? _statusOf(Object? error) =>
      error is PosApiException ? error.statusCode : null;

  void _scheduleReconnect(Object? error) {
    if (!widget.autoReconnect || !_shouldRun) {
      return;
    }
    if (_isPermanent(error)) {
      if (mounted && !_gaveUp) {
        setState(() => _gaveUp = true);
      }
      return;
    }
    _reconnectAttempts++;
    if (_reconnectAttempts > widget.maxReconnectAttempts) {
      // Stop. The stream stays in its error state, which is what surfaces the
      // retry affordance; nothing else here will dial the recorder again.
      if (mounted && !_gaveUp) {
        setState(() => _gaveUp = true);
      }
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_backoffFor(error), () {
      if (mounted && _shouldRun) {
        _connect();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _teardown();
    _image.value?.dispose();
    _image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final width = (constraints.maxWidth * ratio).round();
        if (width > 0 && width != _targetWidth) {
          _targetWidth = width;
        }
        if (!_hasPainted) {
          final error = _error;
          if (error != null && widget.errorBuilder != null) {
            return widget.errorBuilder!(context, error, retry);
          }
          return widget.placeholder ?? const SizedBox.expand();
        }
        return RepaintBoundary(
          child: CustomPaint(
            painter: _FramePainter(frame: _image, fit: widget.fit),
            size: Size.infinite,
            isComplex: true,
            willChange: true,
          ),
        );
      },
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter({required this.frame, required this.fit})
    : super(repaint: frame);

  /// Repaints straight off this, without a rebuild — see [MjpegView] point 1.
  final ValueListenable<ui.Image?> frame;
  final BoxFit fit;

  final Paint _paint = Paint()
    // Bilinear only: a camera tile is downscaled from 704x576 and nobody can
    // tell it from a cubic filter, which costs several times more per frame on
    // the low-end GPUs these tills have.
    ..filterQuality = FilterQuality.low;

  @override
  void paint(Canvas canvas, Size size) {
    final image = frame.value;
    if (image == null || size.isEmpty) {
      return;
    }
    final source = Size(image.width.toDouble(), image.height.toDouble());
    final sizes = applyBoxFit(fit, source, size);
    final input = Alignment.center.inscribe(sizes.source, Offset.zero & source);
    final output = Alignment.center.inscribe(
      sizes.destination,
      Offset.zero & size,
    );
    canvas.drawImageRect(image, input, output, _paint);
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) {
    return oldDelegate.fit != fit || !identical(oldDelegate.frame, frame);
  }
}
