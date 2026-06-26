import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../voice_recording.dart';

/// The composer's recording state: replaces the text input with a live,
/// scrolling waveform + running timer while a voice message is being recorded.
/// Owns the capture lifecycle (start on mount, stop on send/cancel/dispose) but
/// not the [VoiceRecorder] instance itself — the host keeps that so it can be
/// reused across recordings (and injected in tests).
class VoiceRecorderBar extends StatefulWidget {
  const VoiceRecorderBar({
    super.key,
    required this.recorder,
    required this.onSend,
    required this.onCancel,
    this.maxDuration = const Duration(minutes: 5),
  });

  final VoiceRecorder recorder;

  /// Fires with the finished recording (WAV bytes + length) when the user taps
  /// send, or automatically when [maxDuration] is reached.
  final void Function(Uint8List wavBytes, Duration duration) onSend;

  /// Fires when the recording is discarded — the user tapped the trash, the
  /// recorder failed to start, or send was tapped with nothing captured.
  final VoidCallback onCancel;

  /// Hard cap; recording auto-sends when reached so a clip can't grow unbounded.
  final Duration maxDuration;

  @override
  State<VoiceRecorderBar> createState() => _VoiceRecorderBarState();
}

class _VoiceRecorderBarState extends State<VoiceRecorderBar> {
  /// How many trailing amplitude samples we retain. The painter only draws the
  /// ones that fit the current width; this just bounds memory on a long take.
  static const int _maxSamples = 256;

  final List<double> _amplitudes = [];
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  final Stopwatch _stopwatch = Stopwatch();

  StreamSubscription<Uint8List>? _sub;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final stream = await widget.recorder.start();
      if (!mounted) {
        await widget.recorder.stop();
        return;
      }
      _stopwatch.start();
      _ticker = Timer.periodic(const Duration(milliseconds: 100), _onTick);
      _sub = stream.listen(
        _onChunk,
        onError: (_) => _finish(send: false),
        cancelOnError: true,
      );
    } on Exception {
      if (mounted) {
        widget.onCancel();
      }
    }
  }

  void _onChunk(Uint8List chunk) {
    if (_finished) {
      return;
    }
    _pcm.add(chunk);
    final amplitude = pcm16PeakAmplitude(chunk);
    if (!mounted) {
      return;
    }
    setState(() {
      _amplitudes.add(amplitude);
      if (_amplitudes.length > _maxSamples) {
        _amplitudes.removeRange(0, _amplitudes.length - _maxSamples);
      }
    });
  }

  void _onTick(Timer timer) {
    if (!mounted) {
      return;
    }
    setState(() => _elapsed = _stopwatch.elapsed);
    if (_stopwatch.elapsed >= widget.maxDuration) {
      _finish(send: true);
    }
  }

  Future<void> _finish({required bool send}) async {
    if (_finished) {
      return;
    }
    _finished = true;
    _ticker?.cancel();
    _stopwatch.stop();

    // Emit the outcome immediately from captured state so the UI reacts on the
    // tap; releasing the mic + subscription is best-effort cleanup afterward.
    final elapsed = _stopwatch.elapsed;
    final bytes = _pcm.toBytes();
    if (send && bytes.isNotEmpty) {
      widget.onSend(buildWavFile(bytes), elapsed);
    } else {
      widget.onCancel();
    }

    unawaited(_sub?.cancel());
    _sub = null;
    try {
      await widget.recorder.stop();
    } on Exception {
      // Best-effort — the outcome already fired.
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_sub?.cancel());
    // If the bar is torn down mid-recording (e.g. the user navigated away),
    // make sure the native recorder is released.
    if (!_finished) {
      unawaited(widget.recorder.stop().catchError((_) {}));
    }
    _stopwatch.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;

    final remaining = widget.maxDuration - _elapsed;
    final nearLimit = remaining <= const Duration(seconds: 10);
    // Blink the recording dot roughly twice a second off the same ticker.
    final blinkOn = (_elapsed.inMilliseconds ~/ 500).isEven;

    return Semantics(
      label: l10n.aiAssistantRecording,
      container: true,
      child: SizedBox(
        height: 50,
        child: Row(
          children: [
            IconButton(
              tooltip: l10n.aiAssistantRecordCancelTooltip,
              onPressed: _finished ? null : () => _finish(send: false),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline_rounded, size: 22),
              color: colors.danger,
            ),
            Expanded(
              child: Row(
                children: [
                  _RecordingDot(visible: blinkOn, color: colors.danger),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: CustomPaint(
                      painter: _WaveformPainter(
                        amplitudes: _amplitudes,
                        color: colors.primary,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                  Text(
                    formatRecordingDuration(_elapsed.inMilliseconds),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: nearLimit ? colors.danger : colors.mutedInk,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                ],
              ),
            ),
            _RecorderSendButton(
              tooltip: l10n.aiAssistantSendTooltip,
              onTap: _finished ? null : () => _finish(send: true),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pulsing red "recording" indicator.
class _RecordingDot extends StatelessWidget {
  const _RecordingDot({required this.visible, required this.color});

  final bool visible;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0.25,
      duration: const Duration(milliseconds: 250),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// The primary send button shown inside the recorder bar.
class _RecorderSendButton extends StatelessWidget {
  const _RecorderSendButton({required this.tooltip, required this.onTap});

  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.primary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const SizedBox(
            width: 38,
            height: 38,
            child: Icon(
              Icons.arrow_upward_rounded,
              size: 20,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the rolling amplitude bars, newest at the trailing (leading-for-RTL)
/// edge so the wave scrolls as the user speaks.
class _WaveformPainter extends CustomPainter {
  _WaveformPainter({required this.amplitudes, required this.color});

  final List<double> amplitudes;
  final Color color;

  static const double _barWidth = 3;
  static const double _gap = 2;
  static const double _minBar = 3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    const slot = _barWidth + _gap;
    final maxBars = (size.width / slot).floor();
    if (maxBars <= 0) {
      return;
    }
    final visible = amplitudes.length > maxBars
        ? amplitudes.sublist(amplitudes.length - maxBars)
        : amplitudes;
    final centerY = size.height / 2;
    final maxBarHeight = size.height * 0.92;

    for (var i = 0; i < visible.length; i++) {
      // A perceptual curve so quiet speech still moves the bars visibly.
      final norm = math.sqrt(visible[i].clamp(0.0, 1.0));
      final barHeight = (norm * maxBarHeight).clamp(_minBar, maxBarHeight);
      // Right-align: the newest sample sits flush against the right edge.
      final x = size.width - (visible.length - i) * slot;
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x + _barWidth / 2, centerY),
          width: _barWidth,
          height: barHeight,
        ),
        const Radius.circular(_barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) => true;
}
