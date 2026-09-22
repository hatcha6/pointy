import 'dart:async';

import 'package:flutter/widgets.dart';

import 'camera_wedge_controller.dart';
import 'camera_wedge_policy.dart';

/// Delivers what the counter camera reads to the screen's own scan handler.
///
/// Deliberately the same shape as `CompanionScanListener`, and for the same
/// reason: it invents no routing, no queue and no second scanning model. A
/// camera scan is handed to the exact callback the USB wedge already feeds, so
/// every screen that can be scanned into gains camera scanning without knowing
/// a camera exists.
///
/// Wrap it around (not inside) the screen's `BarcodeScanListener` and pass the
/// same handler to both.
class CameraWedgeListener extends StatefulWidget {
  const CameraWedgeListener({
    super.key,
    required this.controller,
    required this.onScan,
    required this.child,
    this.enabled = true,
    this.requireCurrentRoute = true,
  });

  /// Null when no camera wedge is running — the widget then does nothing,
  /// which is what lets callers wire it in unconditionally.
  final CameraWedgeController? controller;
  final ValueChanged<String> onScan;
  final Widget child;

  /// Mirrors the wedge listener's own gate: while a screen is mid-checkout or
  /// resolving a previous scan, a camera scan is dropped rather than queued,
  /// so an item still sitting under the lens cannot land twice.
  final bool enabled;

  /// Deliver only while this screen's route is the one on top — the same rule
  /// `BarcodeScanListener` applies to the wedge, and the same reason
  /// `CompanionScanListener` needs it: a scan is broadcast to every listener
  /// at once, so without this the POS behind an open payment sheet would try
  /// to add a product for the receipt QR being scanned *into* that sheet.
  final bool requireCurrentRoute;

  @override
  State<CameraWedgeListener> createState() => _CameraWedgeListenerState();
}

class _CameraWedgeListenerState extends State<CameraWedgeListener> {
  StreamSubscription<CameraWedgeScan>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(CameraWedgeListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _subscription?.cancel();
      _subscription = null;
      _subscribe();
    }
  }

  void _subscribe() {
    final controller = widget.controller;
    if (controller == null) return;
    _subscription = controller.scans.listen((scan) {
      if (!mounted || !widget.enabled || _isCoveredByAnotherRoute) return;
      widget.onScan(scan.value);
    });
  }

  bool get _isCoveredByAnotherRoute {
    if (!widget.requireCurrentRoute) return false;
    final route = ModalRoute.of(context);
    return route != null && !route.isCurrent;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
