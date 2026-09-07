import '../models/camera.dart';

import 'recorder_discovery_stub.dart'
    if (dart.library.io) 'recorder_discovery_io.dart';

/// A DVR/NVR found on the local network, before anyone has typed a password.
class DiscoveredRecorder {
  const DiscoveredRecorder({
    required this.host,
    required this.port,
    this.brand = RecorderBrand.auto,
    this.model = '',
  });

  final String host;
  final int port;

  /// A *hint*, not a verdict. Both brands guard their identity endpoint behind
  /// the same kind of challenge, and a box that answers ambiguously is reported
  /// as [RecorderBrand.auto] so the backend settles it with credentials in hand.
  final RecorderBrand brand;

  /// Whatever the device volunteered about itself in its auth challenge —
  /// usually a model number. Shown so a shop with two recorders can tell them
  /// apart before committing.
  final String model;

  String get label => model.isEmpty ? host : '$model · $host';
}

/// Sweeps the local network for recorders, from **this device**.
///
/// Deliberately client-side. The backend runs in a container with no route onto
/// the shop's LAN broadcast domain, which is the same wall the UDP backend
/// discovery hit; the till is already on the network the cameras are on, so it
/// is the thing that can see them.
///
/// Needs no credentials: both brands answer their identity endpoint with an
/// authentication challenge, and *which* endpoint challenges is what names the
/// brand.
Future<List<DiscoveredRecorder>> discoverRecorders({
  Duration perProbeTimeout = const Duration(milliseconds: 400),
  int concurrency = 64,
}) {
  return discoverRecordersPlatform(
    perProbeTimeout: perProbeTimeout,
    concurrency: concurrency,
  );
}
