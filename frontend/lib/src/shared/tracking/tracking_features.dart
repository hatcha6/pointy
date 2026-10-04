import 'package:flutter/widgets.dart';

import '../../data/models/pos_user.dart';
import '../../data/models/tracking_mode.dart';

/// Which identified-stock trades this shop has switched on.
///
/// Read from the session, where the two shop switches ride with the user, so a
/// form can decide what to offer without a settings round trip. Off for every
/// shop that never asked — the product form then shows exactly what it always
/// did.
class TrackingFeatures {
  const TrackingFeatures({
    this.serial = false,
    this.batch = false,
    this.captureLater = false,
  });

  factory TrackingFeatures.of(PosUser user) => TrackingFeatures(
    serial: user.serializedInventoryEnabled,
    batch: user.batchTrackingEnabled,
    captureLater: user.serializedCaptureLaterAllowed,
  );

  static const none = TrackingFeatures();

  /// IMEIs, serials, VINs.
  final bool serial;

  /// Lots and expiry dates.
  final bool batch;

  /// A delivery may be received before every article is scanned.
  final bool captureLater;

  bool get any => serial || batch;

  /// The modes a product may be given, in the order a person reads them.
  ///
  /// [current] is always among them: a product a shop tracked before switching
  /// its trade off still shows what it is, rather than a choice that would
  /// quietly change it.
  List<TrackingMode> offeredModes({
    TrackingMode current = TrackingMode.quantity,
  }) {
    return [
      for (final mode in TrackingMode.values)
        if (mode == current || _offers(mode)) mode,
    ];
  }

  bool _offers(TrackingMode mode) => switch (mode) {
    TrackingMode.quantity => true,
    TrackingMode.batch => batch,
    TrackingMode.serial => serial,
    TrackingMode.serialBatch => serial && batch,
  };

  @override
  bool operator ==(Object other) =>
      other is TrackingFeatures &&
      other.serial == serial &&
      other.batch == batch &&
      other.captureLater == captureLater;

  @override
  int get hashCode => Object.hash(serial, batch, captureLater);
}

/// The shop's [TrackingFeatures], for any screen, sheet or dialog that asks.
///
/// Installed above the Navigator, like the other app-wide scopes, because the
/// product form opens as a sheet from the catalog, from a purchase order and
/// from a product's page, and each of those would otherwise need a constructor
/// parameter only to pass two booleans along. Absent — a test, a preview —
/// reads as [TrackingFeatures.none]: the form exactly as it always was.
class TrackingFeaturesScope extends InheritedWidget {
  const TrackingFeaturesScope({
    super.key,
    required this.features,
    required super.child,
  });

  final TrackingFeatures features;

  static TrackingFeatures of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<TrackingFeaturesScope>()
            ?.features ??
        TrackingFeatures.none;
  }

  @override
  bool updateShouldNotify(TrackingFeaturesScope oldWidget) =>
      oldWidget.features != features;
}
