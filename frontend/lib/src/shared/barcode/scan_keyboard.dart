import 'dart:async';

import 'package:flutter/widgets.dart';

import 'keystroke_wedge.dart';

/// Makes a scanning device that is not a keyboard — the counter camera, a
/// paired phone — type what it reads into the app, key by key and then Enter,
/// the way a USB scanner does.
///
/// One sits above the Navigator per device (`app.dart`), and it is the only
/// thing that device's scans go to. No screen subscribes to a device: the
/// till, the payment sheet matching a terminal slip, the card-receipt dialog,
/// purchasing, stock count and every search box hear it as keystrokes, through
/// the listeners and fields they already have for the counter scanner. That is
/// what makes these devices work everywhere a scanner does, screens written
/// after them included.
///
/// It replaced a listener per device per screen, each handing the scan to one
/// screen's callback. The camera's existed only on the till and went deaf
/// whenever a sheet covered it, so the camera read a payment terminal's
/// receipt QR and the payment sheet waiting for exactly that never heard it.
///
/// A scan that arrives while another program has the keyboard is not typed at
/// all (see [KeystrokeWedge]).
class ScanKeyboard<T extends Object> extends StatefulWidget {
  const ScanKeyboard({
    super.key,
    required this.source,
    required this.device,
    required this.scans,
    required this.child,
  });

  /// What this device's scans are tagged with in telemetry (`camera_wedge`,
  /// `companion_camera`), readable from a scan handler as
  /// [KeystrokeWedge.typingSource].
  final String source;

  /// The running device, or null when there is none on this machine — the
  /// widget then does nothing, which is what lets it be wired in
  /// unconditionally.
  final T? device;

  /// The device's confirmed reads. Subscribed once per [device], not per
  /// build, so a rebuild can never drop a scan in flight.
  final Stream<String> Function(T device) scans;

  final Widget child;

  @override
  State<ScanKeyboard<T>> createState() => _ScanKeyboardState<T>();
}

class _ScanKeyboardState<T extends Object> extends State<ScanKeyboard<T>> {
  late KeystrokeWedge _keyboard;
  StreamSubscription<String>? _subscription;

  @override
  void initState() {
    super.initState();
    _keyboard = KeystrokeWedge(source: widget.source);
    _subscribe();
  }

  @override
  void didUpdateWidget(ScanKeyboard<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _keyboard.dispose();
      _keyboard = KeystrokeWedge(source: widget.source);
    }
    if (!identical(oldWidget.device, widget.device)) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    final device = widget.device;
    _subscription = device == null
        ? null
        : widget.scans(device).listen((value) => _keyboard.type(value));
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _keyboard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
