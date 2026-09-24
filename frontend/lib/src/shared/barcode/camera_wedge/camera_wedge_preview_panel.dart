import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../design/design.dart';
import '../../formatters.dart';
import '../../responsive/responsive.dart';
import 'camera_wedge_controller.dart';
import 'camera_wedge_health.dart';
import 'camera_wedge_preview.dart';
import 'camera_wedge_source.dart';
import 'camera_wedge_status_text.dart';

/// F8, anywhere in the app: a small floating window showing what the counter
/// camera sees, whether it is reading, and the last thing it read.
///
/// Installed above the Navigator (in `MaterialApp.builder`, beside
/// `CameraWedgeScope`), so it floats over every route — the till, a payment
/// sheet, settings — and a cashier can keep scanning while it is open: it
/// takes no focus, and the barcode wedge and catalog search carry on
/// underneath. The key is read through `HardwareKeyboard`, the way the till's
/// own function keys are (`BarcodeScanListener`), because focus-tree
/// shortcuts die whenever focus parks outside the widget that declared them.
class CameraWedgePreviewHost extends StatefulWidget {
  const CameraWedgePreviewHost({
    super.key,
    required this.controller,
    required this.child,
    this.available,
  });

  static const toggleKey = LogicalKeyboardKey.f8;

  /// The running wedge, or null when it is off on this machine or nobody is
  /// signed in — F8 then does nothing, so it never pops a camera panel over
  /// the login screen or a price-checker kiosk.
  final CameraWedgeController? controller;
  final Widget child;

  /// Whether this platform has a camera wedge at all. Null asks
  /// [CameraWedgeController.backend]; tests pass it.
  final bool? available;

  @override
  State<CameraWedgePreviewHost> createState() => _CameraWedgePreviewHostState();
}

class _CameraWedgePreviewHostState extends State<CameraWedgePreviewHost> {
  bool _open = false;

  /// Top-left of the panel, once placed. Null means "the default corner".
  Offset? _position;

  bool get _available =>
      widget.controller != null &&
      (widget.available ??
          CameraWedgeController.backend != CameraWedgeBackend.none);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != CameraWedgePreviewHost.toggleKey) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed ||
        !_available) {
      return false;
    }
    setState(() => _open = !_open);
    return true;
  }

  @override
  void didUpdateWidget(CameraWedgePreviewHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Signed out, or the camera switched off in settings: nothing to show.
    if (widget.controller == null) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_open && widget.controller != null)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  Stack(children: [_placedPanel(context, constraints.biggest)]),
            ),
          ),
      ],
    );
  }

  Widget _placedPanel(BuildContext context, Size bounds) {
    const margin = 16.0;
    final width = (bounds.width * 0.28).clamp(300.0, 460.0);
    // An estimate, only for placing and clamping: the panel sizes itself.
    final height = width * 9 / 16 + 150;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // The start corner at the bottom: over the catalog on the till, away from
    // the cart and its checkout button.
    final initial = Offset(
      rtl ? bounds.width - width - margin : margin,
      bounds.height - height - margin,
    );
    final position = _clamp(_position ?? initial, bounds, width, height);
    return Positioned(
      left: position.dx,
      top: position.dy,
      width: width,
      child: CameraWedgePreviewPanel(
        key: const ValueKey('camera_wedge_preview_panel'),
        controller: widget.controller!,
        onClose: () => setState(() => _open = false),
        onDrag: (delta) => setState(() {
          _position = _clamp(position + delta, bounds, width, height);
        }),
      ),
    );
  }

  Offset _clamp(Offset offset, Size bounds, double width, double height) {
    return Offset(
      offset.dx.clamp(0.0, (bounds.width - width).clamp(0.0, double.infinity)),
      offset.dy.clamp(
        0.0,
        (bounds.height - height).clamp(0.0, double.infinity),
      ),
    );
  }
}

/// The panel itself: title bar (drag to move), live picture, status, last
/// read. Also usable on its own.
class CameraWedgePreviewPanel extends StatelessWidget {
  const CameraWedgePreviewPanel({
    super.key,
    required this.controller,
    required this.onClose,
    this.onDrag,
  });

  final CameraWedgeController controller;
  final VoidCallback onClose;
  final ValueChanged<Offset>? onDrag;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final controller = this.controller;

    return Material(
      elevation: 12,
      color: colors.surface,
      shadowColor: colors.shadow,
      borderRadius: BorderRadius.circular(PointyRadii.dialog),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(spacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: onDrag == null ? null : (d) => onDrag!(d.delta),
              child: Row(
                children: [
                  Icon(Icons.videocam_outlined, color: colors.primaryStrong),
                  SizedBox(width: spacing.xs),
                  Expanded(
                    child: Text(
                      l10n.cameraWedgePreviewTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('camera_wedge_preview_close'),
                    visualDensity: VisualDensity.compact,
                    onPressed: onClose,
                    icon: Icon(
                      Icons.close,
                      semanticLabel: l10n.cameraWedgePreviewClose,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: spacing.xs),
            if (!controller.supportsPreview)
              _PanelNote(message: l10n.cameraWedgePreviewUnavailable)
            else
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final health = controller.health;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (health.expectsPicture) ...[
                        CameraWedgePreview(controller: controller),
                        SizedBox(height: spacing.xs),
                      ],
                      CameraWedgeStatusLines(health: health),
                    ],
                  );
                },
              ),
            SizedBox(height: spacing.xs),
            Text(
              l10n.cameraWedgePreviewShortcutHint,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelNote extends StatelessWidget {
  const _PanelNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.md),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

/// Status, stream and last read, as short lines under a preview.
class CameraWedgeStatusLines extends StatelessWidget {
  const CameraWedgeStatusLines({
    super.key,
    required this.health,
    this.showStatus = true,
  });

  final CameraWedgeHealth health;

  /// Off where the status is already said louder (settings shows it as an
  /// inline message above the preview).
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final status = cameraWedgeStatusText(l10n, health);
    final stream = cameraWedgeStreamText(l10n, health);
    final lastScan = health.lastScan;
    final statusColor = switch (status.tone) {
      CameraWedgeStatusTone.ok => colors.success,
      CameraWedgeStatusTone.pending => colors.mutedInk,
      CameraWedgeStatusTone.problem => colors.warning,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showStatus)
          Text(
            status.message,
            key: const ValueKey('camera_wedge_status_line'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: statusColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        if (stream != null && health.isRunning)
          Text(
            stream,
            style: theme.textTheme.labelSmall?.copyWith(color: colors.mutedInk),
          ),
        if (lastScan != null)
          Text(
            // The value is Latin digits or a URL inside Arabic text.
            l10n.cameraWedgeLastScan(ltrIsolated(lastScan.value)),
            key: const ValueKey('camera_wedge_last_scan'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.ink),
          ),
      ],
    );
  }
}
