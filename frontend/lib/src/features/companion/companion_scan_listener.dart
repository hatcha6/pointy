import 'dart:async';

import 'package:flutter/widgets.dart';

import 'companion_bridge.dart';

/// Delivers what a paired phone scans to the screen's own scan handler.
///
/// The point of this widget is what it does *not* do: it invents no routing,
/// no queue and no second scanning model. A phone scan is handed to the exact
/// callback the USB wedge scanner already feeds, so every screen that can be
/// scanned into — POS, purchasing, stock count, the card-receipt dialog —
/// gains phone scanning without knowing a companion exists.
///
/// Wrap it around (not inside) the screen's [BarcodeScanListener] and pass the
/// same handler to both.
class CompanionScanListener extends StatefulWidget {
  const CompanionScanListener({
    super.key,
    required this.bridge,
    required this.onScan,
    required this.child,
    this.enabled = true,
    this.requireCurrentRoute = true,
  });

  /// Null when no companion is running — the widget then does nothing, which
  /// is what lets callers wire it in unconditionally.
  final CompanionBridge? bridge;
  final ValueChanged<String> onScan;
  final Widget child;

  /// Mirrors the wedge listener's own gate: while a screen is mid-checkout or
  /// resolving a previous scan, a phone scan is dropped rather than queued, so
  /// an impatient double-scan cannot land twice.
  final bool enabled;

  /// Deliver only while this screen's route is the one on top — the same rule
  /// [BarcodeScanListener] applies to the wedge.
  ///
  /// A phone scan is broadcast to every listener at once, so without this the
  /// POS behind an open payment sheet would still try to add a product for the
  /// receipt QR the cashier just scanned *into* that sheet. Route gating makes
  /// the topmost surface the only one that hears — exactly what happens with
  /// the counter scanner.
  final bool requireCurrentRoute;

  @override
  State<CompanionScanListener> createState() => _CompanionScanListenerState();
}

class _CompanionScanListenerState extends State<CompanionScanListener> {
  StreamSubscription<String>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(CompanionScanListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bridge != widget.bridge) {
      _subscription?.cancel();
      _subscription = null;
      _subscribe();
    }
  }

  void _subscribe() {
    final bridge = widget.bridge;
    if (bridge == null) return;
    _subscription = bridge.scans.listen((value) {
      if (!mounted || !widget.enabled || _isCoveredByAnotherRoute) return;
      widget.onScan(value);
    });
  }

  bool get _isCoveredByAnotherRoute {
    if (!widget.requireCurrentRoute) return false;
    return ModalRoute.of(context)?.isCurrent == false;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
