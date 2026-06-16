import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/design.dart';

Future<String?> showCameraTextBarcodeScannerSheet(
  BuildContext context, {
  required String title,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) {
      return FractionallySizedBox(
        heightFactor: 0.58,
        child: CameraTextBarcodeScannerSheet(title: title),
      );
    },
  );
}

class CameraTextBarcodeScannerSheet extends StatefulWidget {
  const CameraTextBarcodeScannerSheet({super.key, required this.title});

  final String title;

  @override
  State<CameraTextBarcodeScannerSheet> createState() =>
      _CameraTextBarcodeScannerSheetState();
}

class _CameraTextBarcodeScannerSheetState
    extends State<CameraTextBarcodeScannerSheet> {
  late final MobileScannerController _controller;
  bool _isClosing = false;
  String? _lastScannedCode;
  DateTime? _lastScannedAt;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [],
      facing: CameraFacing.back,
    );
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: l10n.switchCameraTooltip,
                icon: const Icon(Icons.cameraswitch_outlined),
                onPressed: () => unawaited(_controller.switchCamera()),
              ),
              ValueListenableBuilder<MobileScannerState>(
                valueListenable: _controller,
                builder: (context, state, _) {
                  return IconButton(
                    tooltip: l10n.toggleTorchTooltip,
                    icon: state.torchState == TorchState.on
                        ? const Icon(Icons.flash_on)
                        : const Icon(Icons.flash_off),
                    onPressed: state.torchState == TorchState.unavailable
                        ? null
                        : () => unawaited(_controller.toggleTorch()),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: _controller,
                    fit: BoxFit.cover,
                    onDetect: _handleDetection,
                    errorBuilder: (context, error) {
                      return _ScannerMessage(
                        icon: Icons.videocam_off_outlined,
                        message: l10n.cameraScannerPermissionError,
                      );
                    },
                    placeholderBuilder: (context) {
                      return _ScannerMessage(
                        icon: Icons.photo_camera_outlined,
                        message: l10n.cameraScannerStarting,
                      );
                    },
                  ),
                  IgnorePointer(
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.9),
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const SizedBox(width: 240, height: 180),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_isClosing) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue?.trim();
      if (code == null || code.isEmpty || _isDuplicateBurst(code)) {
        continue;
      }
      _isClosing = true;
      Navigator.of(context).pop(code);
      break;
    }
  }

  bool _isDuplicateBurst(String code) {
    final now = DateTime.now();
    final lastScannedAt = _lastScannedAt;
    if (_lastScannedCode == code &&
        lastScannedAt != null &&
        now.difference(lastScannedAt) < const Duration(milliseconds: 900)) {
      return true;
    }
    _lastScannedCode = code;
    _lastScannedAt = now;
    return false;
  }
}

class _ScannerMessage extends StatelessWidget {
  const _ScannerMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return ColoredBox(
      color: colors.surfaceSunken,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: colors.primaryStrong),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
