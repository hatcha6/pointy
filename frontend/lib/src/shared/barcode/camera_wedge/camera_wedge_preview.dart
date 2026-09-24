import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../design/design.dart';
import 'camera_wedge_controller.dart';
import 'camera_wedge_health.dart';

/// What the counter camera sees, live, in grey.
///
/// For aiming the camera and checking its focus: the frames are the ones the
/// decoder reads (shrunk), so a barcode that looks sharp here is one the
/// wedge can read. Frames flow only while this widget is on screen — it holds
/// [CameraWedgeController.acquirePreview] for exactly its own lifetime.
class CameraWedgePreview extends StatefulWidget {
  const CameraWedgePreview({super.key, required this.controller});

  final CameraWedgeController controller;

  @override
  State<CameraWedgePreview> createState() => _CameraWedgePreviewState();
}

class _CameraWedgePreviewState extends State<CameraWedgePreview> {
  ui.Image? _image;
  bool _converting = false;
  CameraWedgePreviewFrame? _waiting;

  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
  }

  @override
  void didUpdateWidget(CameraWedgePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _detach(oldWidget.controller);
      _attach(widget.controller);
    }
  }

  @override
  void dispose() {
    _detach(widget.controller);
    _image?.dispose();
    super.dispose();
  }

  void _attach(CameraWedgeController controller) {
    controller.acquirePreview();
    controller.preview.addListener(_onFrame);
  }

  void _detach(CameraWedgeController controller) {
    controller.preview.removeListener(_onFrame);
    controller.releasePreview();
  }

  void _onFrame() {
    final frame = widget.controller.preview.value;
    if (frame == null) return;
    // One conversion at a time; a frame that arrives meanwhile replaces any
    // other waiting one, so a slow machine shows the newest picture late
    // rather than every picture later and later.
    if (_converting) {
      _waiting = frame;
      return;
    }
    _convert(frame);
  }

  void _convert(CameraWedgePreviewFrame frame) {
    _converting = true;
    final rgba = Uint8List(frame.width * frame.height * 4);
    final pixels = rgba.buffer.asUint32List();
    final luma = frame.luma;
    for (var i = 0; i < luma.length; i++) {
      final y = luma[i];
      // Little-endian RGBA: R, G, B = y, A = 255.
      pixels[i] = 0xFF000000 | (y << 16) | (y << 8) | y;
    }
    ui.decodeImageFromPixels(
      rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        _converting = false;
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
        final next = _waiting;
        _waiting = null;
        if (next != null) _convert(next);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final image = _image;
    final aspectRatio = image == null ? 16 / 9 : image.width / image.height;
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: ColoredBox(
          color: Colors.black,
          child: image == null
              ? Center(
                  child: Text(
                    l10n.cameraWedgePreviewWaiting,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                )
              : RawImage(
                  key: const ValueKey('camera_wedge_preview_image'),
                  image: image,
                  fit: BoxFit.contain,
                ),
        ),
      ),
    );
  }
}
