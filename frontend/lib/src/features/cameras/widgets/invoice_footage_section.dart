import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/camera.dart';
import '../../../data/repositories/surveillance_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../view_models/camera_player_view_model.dart';
import '../views/camera_player_screen.dart';
import 'mjpeg_view.dart';

/// The camera footage from the moment an invoice was rung up.
///
/// This is the feature no POS ships and no DVR makes easy: on the receipt for a
/// disputed sale, the twenty seconds either side of it, without knowing a time,
/// a channel, or the DVR's password.
///
/// The section renders nothing at all when the shop has no cameras, when the
/// user may not review recordings, or when the server cannot do playback —
/// there is no disabled state and no "not configured" placeholder on a screen
/// people use fifty times a day.
class InvoiceFootageSection extends StatefulWidget {
  const InvoiceFootageSection({
    super.key,
    required this.repository,
    required this.orderId,
    required this.capabilities,
  });

  final SurveillanceRepository repository;
  final int orderId;
  final AuthorizationCapabilities capabilities;

  @override
  State<InvoiceFootageSection> createState() => _InvoiceFootageSectionState();
}

class _InvoiceFootageSectionState extends State<InvoiceFootageSection> {
  InvoiceFootage? _footage;
  Camera? _camera;
  bool _isLoading = true;
  bool _isPlaying = false;
  int _generation = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final result = await widget.repository.loadInvoiceFootage(widget.orderId);
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
      if (result case Ok<InvoiceFootage>()) {
        _footage = result.value;
        _camera = result.value.cameras.isEmpty
            ? null
            : result.value.cameras.first;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.capabilities.canReviewCameraPlayback) {
      return const SizedBox.shrink();
    }
    final footage = _footage;
    if (_isLoading || footage == null) {
      // Silence while it loads: an invoice is not "missing its cameras" for the
      // half second before we know, and a skeleton here would flash on a screen
      // that is otherwise instant.
      return const SizedBox.shrink();
    }
    if (!footage.playbackAvailable || !footage.hasCameras) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    return PointyDetailSection(
      title: l10n.invoiceFootageSectionTitle,
      icon: Icons.videocam_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.invoiceFootageSubtitle,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (footage.cameras.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final camera in footage.cameras)
                    ChoiceChip(
                      label: Text(camera.displayName),
                      selected: _camera?.id == camera.id,
                      onSelected: (_) => setState(() {
                        _camera = camera;
                        _generation++;
                      }),
                    ),
                ],
              ),
            ),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(PointyRadii.card),
              child: ColoredBox(
                color: Colors.black,
                child: _isPlaying ? _player(footage, l10n) : _poster(l10n),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => _openFullPlayback(footage),
              icon: const Icon(Icons.open_in_full, size: 18),
              label: Text(l10n.invoiceFootageOpenAction),
            ),
          ),
        ],
      ),
    );
  }

  Widget _player(InvoiceFootage footage, AppLocalizations l10n) {
    final camera = _camera!;
    return Stack(
      fit: StackFit.expand,
      children: [
        MjpegView(
          key: ValueKey('invoice-footage-${camera.id}-$_generation'),
          fit: BoxFit.contain,
          autoReconnect: false,
          frames: () => widget.repository.playbackFrames(
            camera.id,
            start: footage.start,
            end: footage.end,
          ),
          onError: (error) {
            if (mounted) {
              setState(() => _error = error.toString());
            }
          },
          onEnded: () {
            if (mounted) {
              setState(() => _isPlaying = false);
            }
          },
          placeholder: const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: PointySpinner(strokeWidth: 2),
            ),
          ),
          errorBuilder: (context, error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.cameraPlaybackNoFootageBody,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _poster(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filled(
            iconSize: 32,
            onPressed: () => setState(() {
              _isPlaying = true;
              _error = '';
              _generation++;
            }),
            icon: const Icon(Icons.play_arrow),
            tooltip: l10n.invoiceFootageWatchAction,
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.cameraPlaybackNoFootageBody,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  void _openFullPlayback(InvoiceFootage footage) {
    final camera = _camera;
    if (camera == null) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CameraPlayerScreen(
          viewModel: CameraPlayerViewModel(
            widget.repository,
            camera: camera,
            mode: CameraPlayerMode.playback,
            start: footage.start,
            // A longer window than the inline clip: the reason someone opens
            // the full player is that the answer was not in the twenty seconds
            // the invoice panel showed.
            window: const Duration(minutes: 10),
            status: SurveillanceStatus(
              playbackAvailable: true,
              exportAvailable: widget.capabilities.canExportCameraFootage,
              variableSpeedAvailable: true,
              maxPlaybackFps: 25,
            ),
          ),
        ),
      ),
    );
  }
}
