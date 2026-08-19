import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/product_variant.dart';
import '../design/design.dart';
import '../formatters.dart';

enum CameraBarcodeScannerMode { single, multiple }

class CameraVariantScanEntry {
  const CameraVariantScanEntry({required this.variant, required this.quantity});

  final ProductVariant variant;
  final int quantity;

  CameraVariantScanEntry copyWith({int? quantity}) {
    return CameraVariantScanEntry(
      variant: variant,
      quantity: quantity ?? this.quantity,
    );
  }
}

typedef CameraVariantLookup = Future<ProductVariant?> Function(String barcode);
typedef CameraMissingVariantCreator =
    Future<ProductVariant?> Function(String barcode);

Future<List<CameraVariantScanEntry>?> showCameraBarcodeScannerSheet(
  BuildContext context, {
  required CameraBarcodeScannerMode mode,
  required CameraVariantLookup lookupVariant,
  CameraMissingVariantCreator? createMissingVariant,
  bool enableQuantity = false,
  int initialQuantity = 1,
}) {
  return showModalBottomSheet<List<CameraVariantScanEntry>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) {
      return FractionallySizedBox(
        heightFactor: 0.58,
        child: CameraBarcodeScannerSheet(
          mode: mode,
          lookupVariant: lookupVariant,
          createMissingVariant: createMissingVariant,
          enableQuantity: enableQuantity,
          initialQuantity: initialQuantity,
        ),
      );
    },
  );
}

class CameraBarcodeScannerSheet extends StatefulWidget {
  const CameraBarcodeScannerSheet({
    super.key,
    required this.mode,
    required this.lookupVariant,
    this.createMissingVariant,
    this.enableQuantity = false,
    this.initialQuantity = 1,
  });

  final CameraBarcodeScannerMode mode;
  final CameraVariantLookup lookupVariant;
  final CameraMissingVariantCreator? createMissingVariant;
  final bool enableQuantity;
  final int initialQuantity;

  @override
  State<CameraBarcodeScannerSheet> createState() =>
      _CameraBarcodeScannerSheetState();
}

class _CameraBarcodeScannerSheetState extends State<CameraBarcodeScannerSheet> {
  late final MobileScannerController _controller;
  final List<CameraVariantScanEntry> _entries = [];
  late int _scanQuantity;
  bool _isClosing = false;
  bool _isResolving = false;
  String? _lastScannedCode;
  DateTime? _lastScannedAt;
  String? _statusMessage;
  bool _isStatusError = false;

  @override
  void initState() {
    super.initState();
    _scanQuantity = widget.initialQuantity.clamp(1, 999);
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
                  widget.mode == CameraBarcodeScannerMode.single
                      ? l10n.cameraScannerSingleTitle
                      : l10n.cameraScannerMultipleTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              _ScannerIconButton(
                tooltip: l10n.switchCameraTooltip,
                icon: Icons.cameraswitch_outlined,
                onPressed: () => unawaited(_controller.switchCamera()),
              ),
              ValueListenableBuilder<MobileScannerState>(
                valueListenable: _controller,
                builder: (context, state, _) {
                  return _ScannerIconButton(
                    tooltip: l10n.toggleTorchTooltip,
                    icon: state.torchState == TorchState.on
                        ? Icons.flash_on
                        : Icons.flash_off,
                    onPressed: state.torchState == TorchState.unavailable
                        ? null
                        : () => unawaited(_controller.toggleTorch()),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_statusMessage != null) ...[
            _ScannerStatusLine(
              message: _statusMessage!,
              isError: _isStatusError,
              isLoading: _isResolving,
            ),
            const SizedBox(height: 8),
          ],
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
                      return CameraScannerErrorView(
                        errorCode: error.errorCode,
                        onRetry: () => unawaited(_restartCamera()),
                      );
                    },
                    placeholderBuilder: (context) {
                      return _ScannerMessage(
                        icon: Icons.photo_camera_outlined,
                        message: l10n.cameraScannerStarting,
                      );
                    },
                  ),
                  const _ScannerFrame(),
                ],
              ),
            ),
          ),
          if (widget.enableQuantity) ...[
            const SizedBox(height: 12),
            _QuantitySelector(
              label: l10n.cameraScannerScanQuantityLabel,
              value: _scanQuantity,
              onChanged: (value) {
                setState(() {
                  _scanQuantity = value;
                });
              },
            ),
          ],
          if (widget.mode == CameraBarcodeScannerMode.multiple) ...[
            const SizedBox(height: 12),
            _ScannedEntriesList(
              entries: _entries,
              enableQuantity: widget.enableQuantity,
              onQuantityChanged: _updateEntryQuantity,
              onRemove: _removeEntry,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _entries.isEmpty ? null : _finishMultipleScan,
              icon: const Icon(Icons.check),
              label: Text(l10n.cameraScannerDoneButton),
            ),
          ],
        ],
      ),
    );
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_isResolving || _isClosing) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue?.trim();
      if (code == null || code.isEmpty || _isDuplicateBurst(code)) {
        continue;
      }
      unawaited(_resolveScan(code));
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

  Future<void> _resolveScan(String code) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _isResolving = true;
      _isStatusError = false;
      _statusMessage = l10n.cameraScannerResolvingProduct(code);
    });

    ProductVariant? variant;
    try {
      variant = await widget.lookupVariant(code);
    } on Exception {
      if (!mounted) {
        return;
      }
      setState(() {
        _isResolving = false;
        _isStatusError = true;
        _statusMessage = l10n.barcodeScanError;
      });
      return;
    }

    if (!mounted) {
      return;
    }

    if (variant == null) {
      final createMissingVariant = widget.createMissingVariant;
      if (createMissingVariant != null) {
        setState(() {
          _isResolving = false;
          _isStatusError = true;
          _statusMessage = l10n.barcodeScanNotFound(code);
        });

        final createdVariant = await createMissingVariant(code);
        if (!mounted) {
          return;
        }
        if (createdVariant != null) {
          _recordVariant(createdVariant);
          return;
        }
      }

      setState(() {
        _isResolving = false;
        _isStatusError = true;
        _statusMessage = l10n.barcodeScanNotFound(code);
      });
      return;
    }

    _recordVariant(variant);
  }

  void _recordVariant(ProductVariant variant) {
    final l10n = AppLocalizations.of(context)!;
    final quantity = widget.enableQuantity ? _scanQuantity : 1;
    if (widget.mode == CameraBarcodeScannerMode.single) {
      if (_isClosing) {
        return;
      }
      _isClosing = true;
      Navigator.of(
        context,
      ).pop([CameraVariantScanEntry(variant: variant, quantity: quantity)]);
      return;
    }

    setState(() {
      final index = _entries.indexWhere(
        (entry) => entry.variant.id == variant.id,
      );
      if (index == -1) {
        _entries.add(
          CameraVariantScanEntry(variant: variant, quantity: quantity),
        );
      } else {
        final entry = _entries[index];
        _entries[index] = entry.copyWith(
          quantity: (entry.quantity + quantity).clamp(1, 999),
        );
      }
      _isResolving = false;
      _isStatusError = false;
      _statusMessage = l10n.barcodeScanAdded(variant.displayLabel);
    });
  }

  Future<void> _restartCamera() async {
    try {
      await _controller.start();
    } on MobileScannerException {
      // The scanner reports the new failure through its own error builder.
    }
  }

  void _updateEntryQuantity(int variantId, int quantity) {
    setState(() {
      final index = _entries.indexWhere(
        (entry) => entry.variant.id == variantId,
      );
      if (index == -1) {
        return;
      }
      _entries[index] = _entries[index].copyWith(
        quantity: quantity.clamp(1, 999),
      );
    });
  }

  void _removeEntry(int variantId) {
    setState(() {
      _entries.removeWhere((entry) => entry.variant.id == variantId);
    });
  }

  void _finishMultipleScan() {
    Navigator.of(context).pop(List.unmodifiable(_entries));
  }
}

class _ScannedEntriesList extends StatelessWidget {
  const _ScannedEntriesList({
    required this.entries,
    required this.enableQuantity,
    required this.onQuantityChanged,
    required this.onRemove,
  });

  final List<CameraVariantScanEntry> entries;
  final bool enableQuantity;
  final void Function(int variantId, int quantity) onQuantityChanged;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (entries.isEmpty) {
      return Text(
        l10n.cameraScannerEmptyScans,
        style: Theme.of(context).textTheme.bodySmall,
        textAlign: TextAlign.center,
      );
    }

    return SizedBox(
      height: 82,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return SizedBox(
            width: enableQuantity ? 260 : 190,
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            entry.variant.displayLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${entry.variant.sku} · ${formatMoney(entry.variant.unitPrice)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            l10n.cameraScannerQuantityValue(entry.quantity),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (enableQuantity)
                      CameraScannerQuantityStepper(
                        value: entry.quantity,
                        onChanged: (value) {
                          onQuantityChanged(entry.variant.id, value);
                        },
                      ),
                    IconButton(
                      tooltip: l10n.removeScannedCodeTooltip,
                      onPressed: () => onRemove(entry.variant.id),
                      icon: const Icon(Icons.close),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _QuantitySelector extends StatelessWidget {
  const _QuantitySelector({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        CameraScannerQuantityStepper(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// The compact -/+ pair used for both the per-scan quantity and each scanned
/// line. Public so a widget test can assert its labels without a camera.
class CameraScannerQuantityStepper extends StatelessWidget {
  const CameraScannerQuantityStepper({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          tooltip: l10n.removeOneTooltip,
          onPressed: value <= 1 ? null : () => onChanged(value - 1),
          icon: const Icon(Icons.remove),
          visualDensity: VisualDensity.compact,
        ),
        SizedBox(width: 34, child: Center(child: Text('$value'))),
        IconButton.filledTonal(
          tooltip: l10n.addOneTooltip,
          onPressed: value >= 999 ? null : () => onChanged(value + 1),
          icon: const Icon(Icons.add),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _ScannerStatusLine extends StatelessWidget {
  const _ScannerStatusLine({
    required this.message,
    required this.isError,
    required this.isLoading,
  });

  final String message;
  final bool isError;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final color = isError ? colors.danger : colors.primaryStrong;

    return Row(
      children: [
        if (isLoading)
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 18,
            color: color,
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _ScannerIconButton extends StatelessWidget {
  const _ScannerIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(tooltip: tooltip, onPressed: onPressed, icon: Icon(icon));
  }
}

class _ScannerFrame extends StatelessWidget {
  const _ScannerFrame();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: AspectRatio(
          aspectRatio: 1.65,
          child: FractionallySizedBox(
            widthFactor: 0.72,
            heightFactor: 0.62,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The camera preview replaced by an explanation of why it will not start.
///
/// The three failures a cashier can actually hit need different answers: a
/// denied permission is fixed in device settings, a device with no camera can
/// never be fixed here at all, and everything else is worth one retry. Showing
/// the permission wording for all of them sends a cashier on a till PC hunting
/// through settings for a camera that does not exist.
class CameraScannerErrorView extends StatelessWidget {
  const CameraScannerErrorView({
    super.key,
    required this.errorCode,
    required this.onRetry,
  });

  final MobileScannerErrorCode errorCode;
  final VoidCallback onRetry;

  bool get _isRetryable => errorCode != MobileScannerErrorCode.unsupported;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final message = switch (errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        l10n.cameraScannerPermissionError,
      MobileScannerErrorCode.unsupported => l10n.cameraScannerNoCameraError,
      _ => l10n.cameraScannerGenericError,
    };

    return _ScannerMessage(
      icon: errorCode == MobileScannerErrorCode.unsupported
          ? Icons.no_photography_outlined
          : Icons.videocam_off_outlined,
      message: message,
      action: _isRetryable
          ? OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white),
              ),
              child: Text(l10n.retryButton),
            )
          : null,
    );
  }
}

class _ScannerMessage extends StatelessWidget {
  const _ScannerMessage({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 32),
              const SizedBox(height: 8),
              Text(
                message,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              if (action != null) ...[const SizedBox(height: 12), action!],
            ],
          ),
        ),
      ),
    );
  }
}
