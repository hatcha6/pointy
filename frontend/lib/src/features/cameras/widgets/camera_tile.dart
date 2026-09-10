import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/camera.dart';
import '../../../data/services/surveillance_api_client.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import 'mjpeg_view.dart';

/// One camera on the wall: the picture, its name, and the actions that only
/// make sense on a live feed.
///
/// The chrome is drawn over the video rather than around it — a wall of tiles
/// with borders and headers wastes the pixels the picture needs — and it is
/// reachable by **tap** as well as hover, because a hover-only affordance is an
/// affordance a phone does not have.
class CameraTile extends StatefulWidget {
  const CameraTile({
    super.key,
    required this.camera,
    required this.frames,
    this.isActive = true,
    this.isFocused = false,
    this.onOpen,
    this.onRename,
    this.onOpenPlayback,
    this.onToggleFocus,
    this.compact = false,
    this.onFirstPaint,
  });

  final Camera camera;
  final Stream<CameraFrame> Function() frames;
  final bool isActive;
  final bool isFocused;

  /// Tapping the picture. On a phone this is the whole interaction — the tile
  /// is too small to work in, so it opens the camera rather than revealing
  /// controls inside a thumbnail.
  final VoidCallback? onOpen;
  final VoidCallback? onRename;
  final VoidCallback? onOpenPlayback;
  final VoidCallback? onToggleFocus;

  /// How long this tile took to show a real picture. Reported upward rather
  /// than recorded here: a tile should not know what telemetry is.
  final ValueChanged<Duration>? onFirstPaint;

  /// Drops the per-tile action buttons. Set on phones, where they would cover
  /// most of the picture and [onOpen] leads somewhere they fit.
  final bool compact;

  @override
  State<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<CameraTile> {
  /// Frame times arrive at the stream's rate; publishing them through a
  /// notifier keeps the clock's repaint out of the tile's build.
  final ValueNotifier<DateTime> _frameTime = ValueNotifier(DateTime.now());

  bool _hovering = false;
  bool _revealed = false;
  Timer? _revealTimer;
  Object? _error;
  bool _live = false;

  @override
  void dispose() {
    _revealTimer?.cancel();
    _frameTime.dispose();
    super.dispose();
  }

  void _reveal() {
    if (widget.compact) {
      return;
    }
    setState(() => _revealed = true);
    _revealTimer?.cancel();
    // Long enough to reach a button, short enough that the chrome is not part
    // of the picture. Touch gets the longer end of the range the platforms use.
    _revealTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _revealed = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showChrome =
        !widget.compact && (_hovering || _revealed || widget.isFocused);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onOpen ?? _reveal,
        onLongPress: widget.onRename,
        onDoubleTap: widget.onToggleFocus,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(PointyRadii.card),
          child: ColoredBox(
            // Black behind the picture, always: a letterboxed 4:3 feed in a
            // 16:9 tile should read as video, not as a gap in the layout.
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MjpegView(
                  frames: widget.frames,
                  isActive: widget.isActive,
                  frameTime: _frameTime,
                  onFirstFrame: (waited) {
                    widget.onFirstPaint?.call(waited);
                    if (mounted && !_live) {
                      setState(() => _live = true);
                    }
                  },
                  onError: (error) {
                    if (mounted) {
                      setState(() {
                        _error = error;
                        _live = false;
                      });
                    }
                  },
                  placeholder: _TilePlaceholder(
                    label: widget.isActive
                        ? l10n.cameraConnectingLabel
                        : l10n.camerasPausedBanner,
                    busy: widget.isActive,
                  ),
                  errorBuilder: (context, error, retry) => _TilePlaceholder(
                    label: l10n.cameraStreamFailedLabel,
                    detail: _detailOf(error),
                    icon: Icons.videocam_off_outlined,
                    onRetry: retry,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _TileFooter(
                    name: widget.camera.displayName,
                    offline:
                        widget.camera.status == CameraStatus.offline ||
                        _error != null,
                    offlineLabel: l10n.cameraOfflineLabel,
                    frameTime: _live ? _frameTime : null,
                  ),
                ),
                if (showChrome)
                  PositionedDirectional(
                    top: 4,
                    end: 4,
                    child: _TileActions(
                      onRename: widget.onRename,
                      onOpenPlayback: widget.onOpenPlayback,
                      onToggleFocus: widget.onToggleFocus,
                      isFocused: widget.isFocused,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _detailOf(Object error) {
    final text = error.toString();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}

class _TilePlaceholder extends StatelessWidget {
  const _TilePlaceholder({
    required this.label,
    this.detail,
    this.busy = false,
    this.icon,
    this.onRetry,
  });

  final String label;
  final String? detail;
  final bool busy;
  final IconData? icon;

  /// Offered when the stream has stopped retrying on its own.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: PointySpinner(strokeWidth: 2),
              )
            else
              Icon(
                icon ?? Icons.videocam_outlined,
                color: Colors.white70,
                size: 28,
              ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                detail!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 4),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  AppLocalizations.of(context)!.retryButton,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TileFooter extends StatelessWidget {
  const _TileFooter({
    required this.name,
    required this.offline,
    required this.offlineLabel,
    this.frameTime,
  });

  final String name;
  final bool offline;
  final String offlineLabel;
  final ValueListenable<DateTime>? frameTime;

  @override
  Widget build(BuildContext context) {
    final clock = frameTime;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 16, 10, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (offline)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 6),
                child: Text(
                  offlineLabel,
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 11,
                  ),
                ),
              )
            else if (clock != null)
              CameraClockText(frameTime: clock),
          ],
        ),
      ),
    );
  }
}

/// The frame's own wall clock, repainted once a second rather than once a frame.
///
/// The notifier ticks at the stream's rate — thirty times a second on a good
/// feed — and rebuilding a text widget that often for a display that changes
/// once a second is pure waste, multiplied by every tile on the wall.
class CameraClockText extends StatefulWidget {
  const CameraClockText({
    super.key,
    required this.frameTime,
    this.style,
    this.withDate = false,
  });

  final ValueListenable<DateTime> frameTime;
  final TextStyle? style;
  final bool withDate;

  @override
  State<CameraClockText> createState() => _CameraClockTextState();
}

class _CameraClockTextState extends State<CameraClockText> {
  late String _label = _format(widget.frameTime.value);

  @override
  void initState() {
    super.initState();
    widget.frameTime.addListener(_onTick);
  }

  @override
  void didUpdateWidget(CameraClockText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.frameTime, widget.frameTime)) {
      oldWidget.frameTime.removeListener(_onTick);
      widget.frameTime.addListener(_onTick);
    }
  }

  @override
  void dispose() {
    widget.frameTime.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    final next = _format(widget.frameTime.value);
    if (next != _label && mounted) {
      setState(() => _label = next);
    }
  }

  String _format(DateTime moment) =>
      formatCameraClock(moment, withDate: widget.withDate);

  @override
  Widget build(BuildContext context) {
    // LTR-isolated: a clock inside an Arabic RTL layout otherwise renders its
    // colons and digits in the wrong visual order.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(
        _label,
        style:
            widget.style ??
            const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
      ),
    );
  }
}

/// `HH:MM:SS`, optionally with the date — the CCTV convention, in the viewer's
/// own local time.
String formatCameraClock(DateTime moment, {bool withDate = false}) {
  final local = moment.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  if (!withDate) {
    return clock;
  }
  return '${local.year}-${two(local.month)}-${two(local.day)}  $clock';
}

class _TileActions extends StatelessWidget {
  const _TileActions({
    required this.isFocused,
    this.onRename,
    this.onOpenPlayback,
    this.onToggleFocus,
  });

  final bool isFocused;
  final VoidCallback? onRename;
  final VoidCallback? onOpenPlayback;
  final VoidCallback? onToggleFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onOpenPlayback != null)
            _TileAction(
              icon: Icons.history,
              tooltip: l10n.cameraOpenPlaybackTooltip,
              onPressed: onOpenPlayback,
            ),
          if (onRename != null)
            _TileAction(
              icon: Icons.drive_file_rename_outline,
              tooltip: l10n.cameraRenameTitle,
              onPressed: onRename,
            ),
          if (onToggleFocus != null)
            _TileAction(
              icon: isFocused ? Icons.fullscreen_exit : Icons.fullscreen,
              tooltip: isFocused
                  ? l10n.cameraExitFullScreenTooltip
                  : l10n.cameraFullScreenTooltip,
              onPressed: onToggleFocus,
            ),
        ],
      ),
    );
  }
}

class _TileAction extends StatelessWidget {
  const _TileAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      // 40dp: comfortably tappable without eating the tile it floats over.
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: EdgeInsets.zero,
      icon: Icon(icon, color: Colors.white),
    );
  }
}
