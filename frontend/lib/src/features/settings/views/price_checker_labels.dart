import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/price_check_event.dart';
import '../../../data/models/price_checker_device.dart';
import '../../../shared/design/design.dart';

/// Shared label/colour/icon mapping for price-checker devices and scan events,
/// so the list and detail screens stay in visual lockstep.

const String priceCheckerEmptyValue = '—';

String priceCheckerStatusLabel(
  AppLocalizations l10n,
  PriceCheckerDevice device,
) {
  return switch (device.status) {
    PriceCheckerStatus.active => l10n.priceCheckerStatusActive,
    PriceCheckerStatus.discovered => l10n.priceCheckerStatusDiscovered,
    PriceCheckerStatus.disabled => l10n.priceCheckerStatusDisabled,
    PriceCheckerStatus.unknown => device.statusRaw.isEmpty
        ? l10n.priceCheckerStatusDisabled
        : device.statusRaw,
  };
}

Color priceCheckerStatusColor(
  PointySemanticColors colors,
  PriceCheckerDevice device,
) {
  return switch (device.status) {
    PriceCheckerStatus.active => colors.success,
    PriceCheckerStatus.discovered => colors.warning,
    PriceCheckerStatus.disabled => colors.mutedInk,
    PriceCheckerStatus.unknown => colors.mutedInk,
  };
}

IconData priceCheckerStatusIcon(PriceCheckerDevice device) {
  return switch (device.status) {
    PriceCheckerStatus.active => Icons.check_circle_outline,
    PriceCheckerStatus.discovered => Icons.travel_explore_outlined,
    PriceCheckerStatus.disabled => Icons.do_not_disturb_on_outlined,
    PriceCheckerStatus.unknown => Icons.help_outline,
  };
}

IconData priceCheckerTransportIcon(PriceCheckerDevice device) {
  return switch (device.transport) {
    PriceCheckerTransport.http => Icons.public_outlined,
    PriceCheckerTransport.tcp => Icons.lan_outlined,
    PriceCheckerTransport.udp => Icons.sensors_outlined,
    PriceCheckerTransport.unknown => Icons.devices_other_outlined,
  };
}

String priceCheckerTransportLabel(
  AppLocalizations l10n,
  PriceCheckerDevice device,
) {
  return switch (device.transport) {
    PriceCheckerTransport.http => 'HTTP',
    PriceCheckerTransport.tcp => 'TCP',
    PriceCheckerTransport.udp => 'UDP',
    PriceCheckerTransport.unknown => device.transportRaw.isEmpty
        ? priceCheckerEmptyValue
        : device.transportRaw.toUpperCase(),
  };
}

String priceCheckerDiscoveryLabel(
  AppLocalizations l10n,
  PriceCheckerDevice device,
) {
  return switch (device.discoveryMethod) {
    PriceCheckerDiscoveryMethod.manual => l10n.priceCheckerDiscoveryManual,
    PriceCheckerDiscoveryMethod.scan => l10n.priceCheckerDiscoveryScan,
    PriceCheckerDiscoveryMethod.self => l10n.priceCheckerDiscoverySelf,
    PriceCheckerDiscoveryMethod.unknown => device.discoveryMethodRaw.isEmpty
        ? priceCheckerEmptyValue
        : device.discoveryMethodRaw,
  };
}

String priceCheckerArabicSupportLabel(
  AppLocalizations l10n,
  PriceCheckerDevice device,
) {
  return switch (device.arabicSupport) {
    PriceCheckerArabicSupport.none => l10n.priceCheckerArabicNone,
    PriceCheckerArabicSupport.unicode => l10n.priceCheckerArabicUnicode,
    PriceCheckerArabicSupport.cp1256 => l10n.priceCheckerArabicCp1256,
    PriceCheckerArabicSupport.glyphs => l10n.priceCheckerArabicGlyphs,
    PriceCheckerArabicSupport.unknown => device.arabicSupportRaw.isEmpty
        ? priceCheckerEmptyValue
        : device.arabicSupportRaw,
  };
}

/// The make + model, falling back to the driver key, then to a dash.
String priceCheckerHardwareLabel(PriceCheckerDevice device) {
  final parts = [
    device.make.trim(),
    device.model.trim(),
  ].where((part) => part.isNotEmpty).toList();
  if (parts.isNotEmpty) {
    return parts.join(' ');
  }
  return device.driver.trim().isNotEmpty ? device.driver.trim() : priceCheckerEmptyValue;
}

String priceCheckResultLabel(AppLocalizations l10n, PriceCheckEvent event) {
  return switch (event.result) {
    PriceCheckResult.found => l10n.priceCheckResultFound,
    PriceCheckResult.notFound => l10n.priceCheckResultNotFound,
    PriceCheckResult.error => l10n.priceCheckResultError,
    PriceCheckResult.unknown => event.resultRaw.isEmpty
        ? priceCheckerEmptyValue
        : event.resultRaw,
  };
}

Color priceCheckResultColor(
  PointySemanticColors colors,
  PriceCheckEvent event,
) {
  return switch (event.result) {
    PriceCheckResult.found => colors.success,
    PriceCheckResult.notFound => colors.warning,
    PriceCheckResult.error => colors.danger,
    PriceCheckResult.unknown => colors.mutedInk,
  };
}

IconData priceCheckResultIcon(PriceCheckEvent event) {
  return switch (event.result) {
    PriceCheckResult.found => Icons.check_circle_outline,
    PriceCheckResult.notFound => Icons.search_off_outlined,
    PriceCheckResult.error => Icons.error_outline,
    PriceCheckResult.unknown => Icons.help_outline,
  };
}
