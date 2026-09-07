import 'package:flutter/material.dart';

import '../../../shared/design/design.dart';

/// A stretch of the window that holds footage, as 0..1 fractions of it.
typedef TimelineSpan = ({double start, double end});

/// The playback bar, in the shape every NVR uses: a strip of time with the
/// recorded stretches painted on it.
///
/// A blank scrubber is the thing that makes reviewing footage feel like
/// guessing — you cannot tell a gap in the recording from a camera that was
/// pointed at a wall until you have scrubbed into it. Painting the segments
/// turns the bar into a map. Pass an empty [recorded] when the recorder will
/// not answer the search: nothing is painted, because drawing "no footage"
/// there would be a lie about a device that plays back fine.
///
/// In export mode the same strip becomes a range selector with draggable
/// brackets, which is the interaction the shop already knows from the DVR's own
/// software.
class CameraTimeline extends StatefulWidget {
  const CameraTimeline({
    super.key,
    required this.progress,
    required this.onSeek,
    this.onScrub,
    this.recorded = const [],
    this.selection,
    this.onSelectionChanged,
    this.onSelectionCommitted,
    this.enabled = true,
  });

  /// 0..1 through the window.
  final double progress;

  /// Committed on release, never during the drag: a seek is a restart of the
  /// recorder's stream, so seeking per dragged pixel would start (and kill) a
  /// decode pipeline per pixel.
  final ValueChanged<double> onSeek;

  /// Called as the finger moves, so the caller can keep the controls awake and
  /// show where the scrub has got to. Never a seek.
  final void Function(double? fraction)? onScrub;

  /// Where footage exists, as fractions of the same window [progress] is in.
  final List<TimelineSpan> recorded;

  /// Start/end as 0..1 fractions of the window. Non-null puts the bar into
  /// range-selection mode.
  final TimelineSpan? selection;
  final void Function(double start, double end)? onSelectionChanged;
  final void Function(double start, double end)? onSelectionCommitted;
  final bool enabled;

  @override
  State<CameraTimeline> createState() => _CameraTimelineState();
}

enum _Grip { none, start, end, playhead }

class _CameraTimelineState extends State<CameraTimeline> {
  _Grip _grip = _Grip.none;

  /// Where the playhead has been dragged to, before the seek is committed.
  double? _scrubbing;

  /// Fat enough to grab with a thumb: a 4px handle on a phone is a handle you
  /// miss, and missing it seeks instead, which loses your place.
  static const double _touchSlop = 28;
  static const double _height = 44;

  double _fractionAt(double dx, double width) {
    if (width <= 0) {
      return 0;
    }
    final raw = dx / width;
    return raw.clamp(0.0, 1.0);
  }

  _Grip _grabAt(double fraction, double width) {
    final selection = widget.selection;
    if (selection == null) {
      return _Grip.playhead;
    }
    final slop = width <= 0 ? 0.05 : _touchSlop / width;
    final toStart = (fraction - selection.start).abs();
    final toEnd = (fraction - selection.end).abs();
    if (toStart <= slop && toStart <= toEnd) {
      return _Grip.start;
    }
    if (toEnd <= slop) {
      return _Grip.end;
    }
    return _Grip.playhead;
  }

  void _apply(double fraction) {
    final selection = widget.selection;
    if (selection == null || _grip == _Grip.playhead) {
      setState(() => _scrubbing = fraction);
      widget.onScrub?.call(fraction);
      return;
    }
    // A handle may not cross its partner; clamping keeps the range legible
    // instead of letting it invert and disappear.
    const minimum = 0.005;
    if (_grip == _Grip.start) {
      widget.onSelectionChanged?.call(
        fraction.clamp(0.0, selection.end - minimum),
        selection.end,
      );
    } else if (_grip == _Grip.end) {
      widget.onSelectionChanged?.call(
        selection.start,
        fraction.clamp(selection.start + minimum, 1.0),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.enabled
              ? (details) {
                  final fraction = _fractionAt(details.localPosition.dx, width);
                  setState(() => _grip = _grabAt(fraction, width));
                  if (_grip != _Grip.playhead) {
                    _apply(fraction);
                  }
                }
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (details) =>
                    _apply(_fractionAt(details.localPosition.dx, width))
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (_) {
                  final selection = widget.selection;
                  final scrubbed = _scrubbing;
                  if (selection != null && _grip != _Grip.playhead) {
                    // Re-cut once, on release.
                    widget.onSelectionCommitted?.call(
                      selection.start,
                      selection.end,
                    );
                  } else if (scrubbed != null) {
                    widget.onSeek(scrubbed);
                  }
                  widget.onScrub?.call(null);
                  setState(() {
                    _grip = _Grip.none;
                    _scrubbing = null;
                  });
                }
              : null,
          onHorizontalDragCancel: widget.enabled
              ? () {
                  widget.onScrub?.call(null);
                  setState(() {
                    _grip = _Grip.none;
                    _scrubbing = null;
                  });
                }
              : null,
          onTapUp: widget.enabled
              ? (details) {
                  final fraction = _fractionAt(details.localPosition.dx, width);
                  if (widget.selection == null) {
                    widget.onSeek(fraction);
                  }
                }
              : null,
          child: SizedBox(
            height: _height,
            child: CustomPaint(
              painter: _TimelinePainter(
                progress: _scrubbing ?? widget.progress,
                recorded: widget.recorded,
                selection: widget.selection,
                accent: colors.primaryStrong,
                recordedColor: colors.success,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class _TimelinePainter extends CustomPainter {
  const _TimelinePainter({
    required this.progress,
    required this.recorded,
    required this.selection,
    required this.accent,
    required this.recordedColor,
  });

  final double progress;
  final List<TimelineSpan> recorded;
  final TimelineSpan? selection;
  final Color accent;
  final Color recordedColor;

  static const double _trackHeight = 10;

  /// The bar always reads left-to-right, RTL screen or not.
  ///
  /// Time is not text: a timeline that ran right-to-left would put the past on
  /// the right and invert the meaning of every drag, and no camera software
  /// anywhere does that. Since drag coordinates are physical (x grows to the
  /// right) whatever the app's direction, the painter uses them unchanged —
  /// and the labels under the bar are forced to match.
  double _x(double fraction, double width) => fraction * width;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final top = (size.height - _trackHeight) / 2;
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, top, size.width, _trackHeight),
      const Radius.circular(5),
    );

    canvas.drawRRect(track, Paint()..color = Colors.white24);

    // Where footage actually exists.
    if (recorded.isNotEmpty) {
      canvas.save();
      canvas.clipRRect(track);
      final paint = Paint()..color = recordedColor.withValues(alpha: 0.65);
      for (final span in recorded) {
        canvas.drawRect(
          Rect.fromLTRB(
            _x(span.start, size.width),
            top,
            _x(span.end, size.width),
            top + _trackHeight,
          ),
          paint,
        );
      }
      canvas.restore();
    }

    final range = selection;
    if (range != null) {
      // Dim everything outside the clip so the selection reads as "this is what
      // you are exporting", not as a decoration on the bar.
      final shade = Paint()..color = Colors.black.withValues(alpha: 0.55);
      canvas
        ..save()
        ..clipRRect(track)
        ..drawRect(
          Rect.fromLTRB(
            0,
            top,
            _x(range.start, size.width),
            top + _trackHeight,
          ),
          shade,
        )
        ..drawRect(
          Rect.fromLTRB(
            _x(range.end, size.width),
            top,
            size.width,
            top + _trackHeight,
          ),
          shade,
        )
        ..restore();

      final bracket = Paint()..color = accent;
      for (final fraction in [range.start, range.end]) {
        final x = _x(fraction, size.width);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x - 3, top - 9, 6, _trackHeight + 18),
            const Radius.circular(3),
          ),
          bracket,
        );
      }
    }

    final head = _x(progress, size.width);
    canvas
      ..drawRect(
        Rect.fromLTWH(head - 1, top - 6, 2, _trackHeight + 12),
        Paint()..color = Colors.white,
      )
      ..drawCircle(
        Offset(head, top + _trackHeight / 2),
        7,
        Paint()..color = Colors.white,
      );
  }

  @override
  bool shouldRepaint(_TimelinePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.selection != selection ||
        !identical(oldDelegate.recorded, recorded);
  }
}
