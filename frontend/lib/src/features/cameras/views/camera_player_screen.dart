import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/services/camera_file_saver.dart';
import '../../../shared/components/components.dart';
import '../view_models/camera_player_view_model.dart';
import '../widgets/camera_timeline.dart';
import '../widgets/camera_tile.dart';
import '../widgets/mjpeg_view.dart';
import 'camera_time_picker.dart';

/// One camera, full screen.
///
/// Built to the conventions people already have from every video player they
/// use: the picture is the screen, the controls are a translucent overlay that
/// **auto-hides** and comes back on a tap, and the secondary actions live
/// behind one menu instead of a row of buttons across the bottom. Touch gets
/// the gestures it expects — tap to show, double-tap either side to skip —
/// and every target is at least 48dp.
///
/// Exporting is a *mode*, not a pair of "mark start"/"mark end" buttons: the
/// bar turns into a range selector, playback loops inside the selection, and
/// what you are watching is exactly the clip that will be saved.
class CameraPlayerScreen extends StatefulWidget {
  const CameraPlayerScreen({super.key, required this.viewModel});

  final CameraPlayerViewModel viewModel;

  @override
  State<CameraPlayerScreen> createState() => _CameraPlayerScreenState();
}

class _CameraPlayerScreenState extends State<CameraPlayerScreen> {
  final ValueNotifier<DateTime> _frameTime = ValueNotifier(DateTime.now());

  bool _chromeVisible = true;
  Timer? _hideTimer;
  ({double start, double end})? _dragSelection;

  /// True while a finger or pointer is down on the timeline.
  bool _isInteracting = false;

  @override
  void initState() {
    super.initState();
    // The picture is the point; the status and navigation bars are not.
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    _frameTime.addListener(_onFrame);
    widget.viewModel.unawaitedLoadRecordings();
    _restartHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _frameTime.removeListener(_onFrame);
    _frameTime.dispose();
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: SystemUiOverlay.values,
      ),
    );
    super.dispose();
  }

  void _onFrame() => widget.viewModel.reportFrameTime(_frameTime.value);

  void _restartHideTimer() {
    _hideTimer?.cancel();
    if (widget.viewModel.isSelecting) {
      // While cutting a clip the controls *are* the task; hiding them mid-drag
      // would be hostile.
      return;
    }
    if (_isInteracting) {
      // A finger is on the timeline. Hiding the controls out from under a drag
      // is the worst possible moment to hide them.
      return;
    }
    _hideTimer = Timer(_hideAfter, () {
      if (mounted) {
        setState(() => _chromeVisible = false);
      }
    });
  }

  /// How long the controls stay up with nothing happening.
  ///
  /// Touch gets more than twice the desktop timeout, and deliberately more than
  /// a streaming player would give: a mouse re-summons the controls by merely
  /// moving, so a short timeout there costs nothing, while on a phone every
  /// re-summon is a tap that also toggles what you were about to press. The
  /// timeline here is a working surface — you read the clock, judge where to
  /// scrub, reach for the cut — not a pause button on a film.
  Duration get _hideAfter =>
      _isTouch ? const Duration(seconds: 9) : const Duration(seconds: 4);

  /// True where the pointer is a finger, which decides how patient the
  /// auto-hide is: a mouse proves the viewer is still there by moving and a
  /// finger cannot, so a desktop timeout on a phone reads as the controls
  /// flickering away mid-reach.
  ///
  /// Read from the platform rather than from a [MediaQuery], because the timer
  /// starts in `initState` where no inherited widget may be looked up yet.
  bool get _isTouch => switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => true,
    _ => false,
  };

  void _showChrome() {
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
    _restartHideTimer();
  }

  /// Holds the controls open for as long as a drag lasts, and restarts the
  /// countdown from the moment the finger lifts rather than from when it landed.
  void _onScrub(double? fraction) {
    final interacting = fraction != null;
    if (interacting != _isInteracting) {
      _isInteracting = interacting;
    }
    _showChrome();
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    if (_chromeVisible) {
      _restartHideTimer();
    } else {
      _hideTimer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        final l10n = AppLocalizations.of(context)!;
        final media = MediaQuery.of(context);
        final isCompact = media.size.shortestSide < 600;

        return PopScope(
          canPop: !viewModel.isSelecting,
          onPopInvokedWithResult: (didPop, _) {
            // Leaving export mode is what "back" means while a clip is being
            // cut; the screen itself stays.
            if (!didPop && viewModel.isSelecting) {
              viewModel.cancelSelection();
              _showChrome();
            }
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            body: MouseRegion(
              onHover: (_) => _showChrome(),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _video(viewModel, l10n),
                  _gestureLayer(viewModel, isCompact),
                  IgnorePointer(
                    ignoring: !_chromeVisible,
                    child: AnimatedOpacity(
                      opacity: _chromeVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Align(
                            alignment: Alignment.topCenter,
                            child: _TopBar(
                              viewModel: viewModel,
                              frameTime: _frameTime,
                              isCompact: isCompact,
                              onAction: _showChrome,
                              onSaveStill: _saveStill,
                              onPickMoment: _pickMoment,
                            ),
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: _BottomBar(
                              viewModel: viewModel,
                              isCompact: isCompact,
                              dragSelection: _dragSelection,
                              onInteraction: _showChrome,
                              onScrub: _onScrub,
                              onSelectionDrag: (start, end) {
                                setState(
                                  () =>
                                      _dragSelection = (start: start, end: end),
                                );
                              },
                              onSelectionCommitted: (start, end) {
                                setState(() => _dragSelection = null);
                                viewModel.setSelection(
                                  viewModel.momentAt(start),
                                  viewModel.momentAt(end),
                                  restart: true,
                                );
                              },
                              onExport: _export,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _video(CameraPlayerViewModel viewModel, AppLocalizations l10n) {
    return MjpegView(
      // The generation is part of the key so a seek tears the old stream down
      // instead of racing it: two streams from one camera would fight for
      // frames and for the recorder's session budget.
      key: ValueKey('player-${viewModel.mode}-${viewModel.generation}'),
      frames: viewModel.frames,
      isActive: viewModel.isPlaying,
      fit: BoxFit.contain,
      autoReconnect: viewModel.isLive,
      frameTime: _frameTime,
      onError: viewModel.reportError,
      onEnded: viewModel.reportEnded,
      placeholder: Center(
        child: viewModel.error.isNotEmpty
            ? _Message(text: viewModel.error)
            : const PointySpinner(strokeWidth: 2),
      ),
      errorBuilder: (context, error) => Center(
        child: _Message(
          text: viewModel.isLive
              ? l10n.cameraStreamFailedLabel
              : l10n.cameraPlaybackNoFootageBody,
          detail: '$error',
        ),
      ),
    );
  }

  /// Tap toggles the controls; a double-tap on either half skips. Both are the
  /// gestures people arrive with, and neither is discoverable as a button on a
  /// screen whose whole point is that it is uncluttered.
  Widget _gestureLayer(CameraPlayerViewModel viewModel, bool isCompact) {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _toggleChrome,
            onDoubleTap: viewModel.isLive
                ? null
                : () {
                    viewModel.skip(const Duration(seconds: -10));
                    _showChrome();
                  },
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _toggleChrome,
            onDoubleTap: viewModel.isLive
                ? null
                : () {
                    viewModel.skip(const Duration(seconds: 10));
                    _showChrome();
                  },
          ),
        ),
      ],
    );
  }

  Future<void> _pickMoment() async {
    _hideTimer?.cancel();
    final viewModel = widget.viewModel;
    final moment = await showCameraTimePicker(
      context,
      initial: viewModel.position,
    );
    if (!mounted) {
      return;
    }
    if (moment != null) {
      if (viewModel.isLive) {
        viewModel.switchTo(CameraPlayerMode.playback, at: moment);
      }
      viewModel.openWindowAt(moment);
    }
    _showChrome();
  }

  Future<void> _saveStill() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.viewModel.captureStill();
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok():
        final saved = await saveCameraStill(
          bytes: result.value,
          filename: _fileName(widget.viewModel.position, 'jpg'),
          dialogTitle: l10n.cameraSaveFrameTooltip,
        );
        if (!mounted || saved.isCanceled) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              saved.isSaved
                  ? l10n.cameraFrameSavedMessage
                  : l10n.cameraFrameSaveFailedMessage,
            ),
          ),
        );
      case Error():
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.cameraFrameSaveFailedMessage)),
        );
    }
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final viewModel = widget.viewModel;
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.cameraExportRunningMessage)),
    );
    CameraSaveResult? saved;
    final result = await viewModel.export(
      onBytes: (bytes) async {
        saved = await saveCameraClip(
          bytes: bytes,
          filename: _fileName(
            viewModel.selectionStart ?? viewModel.windowStart,
            'mp4',
          ),
          dialogTitle: l10n.cameraExportAction,
        );
      },
    );
    if (!mounted) {
      return;
    }
    final outcome = saved;
    if (outcome != null && outcome.isCanceled) {
      return;
    }
    final ok = result is Ok<void> && outcome != null && outcome.isSaved;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.cameraExportSavedMessage : l10n.cameraExportFailedMessage,
        ),
      ),
    );
    if (ok) {
      viewModel.cancelSelection();
    }
  }

  String _fileName(DateTime moment, String extension) {
    final local = moment.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${local.year}${two(local.month)}${two(local.day)}'
        '-${two(local.hour)}${two(local.minute)}${two(local.second)}';
    return 'camera-${widget.viewModel.camera.id}-$stamp.$extension';
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.detail});

  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off_outlined, color: Colors.white54),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white30, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.viewModel,
    required this.frameTime,
    required this.isCompact,
    required this.onAction,
    required this.onSaveStill,
    required this.onPickMoment,
  });

  final CameraPlayerViewModel viewModel;
  final ValueNotifier<DateTime> frameTime;
  final bool isCompact;
  final VoidCallback onAction;
  final Future<void> Function() onSaveStill;
  final Future<void> Function() onPickMoment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 24),
          child: Row(
            children: [
              IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
                color: Colors.white,
                iconSize: 24,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      viewModel.camera.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (viewModel.isLive) ...[
                          const _LiveDot(),
                          const SizedBox(width: 6),
                          Text(
                            l10n.cameraLiveBadge,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ] else
                          CameraClockText(
                            frameTime: frameTime,
                            withDate: !isCompact,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (viewModel.playbackAvailable)
                IconButton(
                  tooltip: viewModel.isLive
                      ? l10n.cameraOpenPlaybackTooltip
                      : l10n.cameraLiveBadge,
                  onPressed: () {
                    onAction();
                    viewModel.switchTo(
                      viewModel.isLive
                          ? CameraPlayerMode.playback
                          : CameraPlayerMode.live,
                    );
                  },
                  icon: Icon(viewModel.isLive ? Icons.history : Icons.sensors),
                  color: Colors.white,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
              _OverflowMenu(
                viewModel: viewModel,
                onAction: onAction,
                onSaveStill: onSaveStill,
                onPickMoment: onPickMoment,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(
        color: Color(0xFFE53935),
        shape: BoxShape.circle,
      ),
    );
  }
}

enum _PlayerAction { still, jump, window15m, window1h, window6h }

class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.viewModel,
    required this.onAction,
    required this.onSaveStill,
    required this.onPickMoment,
  });

  final CameraPlayerViewModel viewModel;
  final VoidCallback onAction;
  final Future<void> Function() onSaveStill;
  final Future<void> Function() onPickMoment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<_PlayerAction>(
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      icon: const Icon(Icons.more_vert, color: Colors.white),
      constraints: const BoxConstraints(minWidth: 200),
      onSelected: (action) {
        onAction();
        switch (action) {
          case _PlayerAction.still:
            unawaited(onSaveStill());
          case _PlayerAction.jump:
            unawaited(onPickMoment());
          case _PlayerAction.window15m:
            viewModel.setWindowLength(const Duration(minutes: 15));
          case _PlayerAction.window1h:
            viewModel.setWindowLength(const Duration(hours: 1));
          case _PlayerAction.window6h:
            viewModel.setWindowLength(const Duration(hours: 6));
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _PlayerAction.jump,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_outlined),
            title: Text(l10n.cameraPlaybackPickDateAction),
          ),
        ),
        if (!viewModel.isLive && viewModel.playbackAvailable)
          PopupMenuItem(
            value: _PlayerAction.still,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(l10n.cameraSaveFrameTooltip),
            ),
          ),
        if (!viewModel.isLive) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: _PlayerAction.window15m,
            child: Text(l10n.cameraWindow15Minutes),
          ),
          PopupMenuItem(
            value: _PlayerAction.window1h,
            child: Text(l10n.cameraWindow1Hour),
          ),
          PopupMenuItem(
            value: _PlayerAction.window6h,
            child: Text(l10n.cameraWindow6Hours),
          ),
        ],
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.viewModel,
    required this.isCompact,
    required this.dragSelection,
    required this.onInteraction,
    required this.onScrub,
    required this.onSelectionDrag,
    required this.onSelectionCommitted,
    required this.onExport,
  });

  final CameraPlayerViewModel viewModel;
  final bool isCompact;
  final ({double start, double end})? dragSelection;
  final VoidCallback onInteraction;
  final ValueChanged<double?> onScrub;
  final void Function(double start, double end) onSelectionDrag;
  final void Function(double start, double end) onSelectionCommitted;
  final Future<void> Function() onExport;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (viewModel.isLive) {
      return const SizedBox.shrink();
    }
    final selection = dragSelection ?? _selectionFractions();
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 28, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (viewModel.isSelecting)
                _SelectionSummary(viewModel: viewModel, compact: isCompact),
              // The bar and the controls that drive it are laid out
              // left-to-right whatever the app's direction, because they
              // describe time rather than text: "skip back" has to sit on the
              // side the past is on, and the past is on the left.
              Directionality(
                textDirection: TextDirection.ltr,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CameraTimeline(
                      progress: viewModel.progress,
                      recorded: _recordedSpans(),
                      selection: selection,
                      onSeek: (fraction) {
                        onInteraction();
                        viewModel.seekTo(viewModel.momentAt(fraction));
                      },
                      onScrub: onScrub,
                      onSelectionChanged: onSelectionDrag,
                      onSelectionCommitted: onSelectionCommitted,
                    ),
                    _WindowLabels(viewModel: viewModel),
                    const SizedBox(height: 4),
                    if (!viewModel.isSelecting)
                      _TransportRow(
                        viewModel: viewModel,
                        isCompact: isCompact,
                        onInteraction: onInteraction,
                        exportLabel: l10n.cameraExportAction,
                      ),
                  ],
                ),
              ),
              // Ordinary buttons, so they follow the app's own direction.
              if (viewModel.isSelecting)
                _SelectionActions(
                  viewModel: viewModel,
                  onInteraction: onInteraction,
                  onExport: onExport,
                ),
            ],
          ),
        ),
      ),
    );
  }

  ({double start, double end})? _selectionFractions() {
    if (!viewModel.isSelecting) {
      return null;
    }
    final start = viewModel.selectionStart;
    final end = viewModel.selectionEnd;
    if (start == null || end == null) {
      return null;
    }
    return (start: viewModel.fractionOf(start), end: viewModel.fractionOf(end));
  }

  List<TimelineSpan> _recordedSpans() {
    final index = viewModel.recordings;
    if (!index.known) {
      return const [];
    }
    return [
      for (final segment in index.segments)
        (
          start: viewModel.fractionOf(segment.start),
          end: viewModel.fractionOf(segment.end),
        ),
    ];
  }
}

class _WindowLabels extends StatelessWidget {
  const _WindowLabels({required this.viewModel});

  final CameraPlayerViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    // Only the two ends. The moment being watched is already stated in the top
    // bar, and a third label floating in the middle of the bar reads as the
    // window's midpoint, which it is not.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _label(formatCameraClock(viewModel.windowStart)),
        _label(formatCameraClock(viewModel.windowEnd)),
      ],
    );
  }

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      color: Colors.white54,
      fontSize: 11,
      fontFeatures: [FontFeature.tabularFigures()],
    ),
  );
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({
    required this.viewModel,
    required this.isCompact,
    required this.onInteraction,
    required this.exportLabel,
  });

  final CameraPlayerViewModel viewModel;
  final bool isCompact;
  final VoidCallback onInteraction;
  final String exportLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        _RoundAction(
          icon: Icons.replay_10,
          tooltip: l10n.cameraPlaybackJumpBack,
          onPressed: () {
            onInteraction();
            viewModel.skip(const Duration(seconds: -10));
          },
        ),
        _RoundAction(
          icon: viewModel.isPlaying ? Icons.pause : Icons.play_arrow,
          tooltip: viewModel.isPlaying
              ? l10n.cameraPlaybackPauseTooltip
              : l10n.cameraPlaybackPlayTooltip,
          primary: true,
          onPressed: () {
            onInteraction();
            viewModel.togglePlaying();
          },
        ),
        _RoundAction(
          icon: Icons.forward_10,
          tooltip: l10n.cameraPlaybackJumpForward,
          onPressed: () {
            onInteraction();
            viewModel.skip(const Duration(seconds: 10));
          },
        ),
        const Spacer(),
        if (viewModel.variableSpeedAvailable && !isCompact)
          _SpeedPicker(viewModel: viewModel, onInteraction: onInteraction),
        if (viewModel.exportAvailable)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4),
            child: isCompact
                ? _RoundAction(
                    icon: Icons.content_cut,
                    tooltip: exportLabel,
                    onPressed: () {
                      onInteraction();
                      viewModel.beginSelection();
                    },
                  )
                : FilledButton.tonalIcon(
                    onPressed: () {
                      onInteraction();
                      viewModel.beginSelection();
                    },
                    icon: const Icon(Icons.content_cut, size: 18),
                    label: Text(exportLabel),
                  ),
          ),
      ],
    );
  }
}

class _SelectionSummary extends StatelessWidget {
  const _SelectionSummary({required this.viewModel, required this.compact});

  final CameraPlayerViewModel viewModel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final start = viewModel.selectionStart;
    final end = viewModel.selectionEnd;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          const Icon(Icons.content_cut, size: 15, color: Colors.white70),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              start == null || end == null
                  ? l10n.cameraSelectionHint
                  : l10n.cameraSelectionRangeLabel(
                      formatCameraClock(start),
                      formatCameraClock(end),
                      _duration(viewModel.selectionDuration),
                    ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  static String _duration(Duration span) {
    final minutes = span.inMinutes;
    final seconds = span.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _SelectionActions extends StatelessWidget {
  const _SelectionActions({
    required this.viewModel,
    required this.onInteraction,
    required this.onExport,
  });

  final CameraPlayerViewModel viewModel;
  final VoidCallback onInteraction;
  final Future<void> Function() onExport;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        TextButton(
          onPressed: () {
            onInteraction();
            viewModel.cancelSelection();
          },
          style: TextButton.styleFrom(foregroundColor: Colors.white),
          child: Text(l10n.cancelButton),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            l10n.cameraSelectionLoopHint,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ),
        const Spacer(),
        FilledButton.icon(
          onPressed: viewModel.isExporting || !viewModel.hasSelection
              ? null
              : () {
                  onInteraction();
                  unawaited(onExport());
                },
          icon: viewModel.isExporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined, size: 18),
          label: Text(l10n.cameraExportConfirmAction),
        ),
      ],
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        color: Colors.white,
        iconSize: primary ? 30 : 24,
        // 48dp everywhere: the minimum a thumb hits reliably, and these sit
        // over a moving picture where a miss is worse than usual.
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        style: primary
            ? IconButton.styleFrom(backgroundColor: Colors.white24)
            : null,
      ),
    );
  }
}

class _SpeedPicker extends StatelessWidget {
  const _SpeedPicker({required this.viewModel, required this.onInteraction});

  final CameraPlayerViewModel viewModel;
  final VoidCallback onInteraction;

  static const _speeds = [0.5, 1.0, 2.0, 4.0, 8.0, 16.0];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<double>(
      tooltip: l10n.cameraPlaybackSpeedLabel,
      initialValue: viewModel.speed,
      onSelected: (value) {
        onInteraction();
        viewModel.setSpeed(value);
      },
      itemBuilder: (context) => [
        for (final speed in _speeds)
          PopupMenuItem(value: speed, child: Text(_label(speed))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Text(
          _label(viewModel.speed),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  static String _label(double speed) {
    final value = speed % 1 == 0 ? speed.toInt().toString() : '$speed';
    return '$value×';
  }
}
