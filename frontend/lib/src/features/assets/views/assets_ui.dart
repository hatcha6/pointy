import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/customer_asset.dart';
import '../../../shared/design/design.dart';

/// Cross-screen building blocks for the asset registry, so the list, the
/// details page and the intake wizard name and picture an item the same way.

/// Icons a shop-defined type can choose from, by key.
///
/// The type carries a *key*, not an icon: the server has no business knowing
/// about Flutter, and a shop that invents "مولد كهرباء" picks from this list.
/// An unknown key falls back to a generic device rather than rendering blank,
/// so a type created by a newer client never breaks an older one.
const Map<String, IconData> assetTypeIcons = {
  'phone': Icons.smartphone_outlined,
  'tablet': Icons.tablet_mac_outlined,
  'laptop': Icons.laptop_mac_outlined,
  'console': Icons.sports_esports_outlined,
  'appliance': Icons.kitchen_outlined,
  'vehicle': Icons.directions_car_outlined,
  'motorcycle': Icons.two_wheeler_outlined,
  'bicycle': Icons.pedal_bike_outlined,
  'television': Icons.tv_outlined,
  'camera': Icons.photo_camera_outlined,
  'watch': Icons.watch_outlined,
  'audio': Icons.headphones_outlined,
  'generator': Icons.bolt_outlined,
  'tool': Icons.handyman_outlined,
  'furniture': Icons.chair_outlined,
  'device': Icons.devices_other_outlined,
};

IconData assetIconForKey(String? key) {
  return assetTypeIcons[key] ?? Icons.devices_other_outlined;
}

/// The item's name for a human: "Toyota Corolla", "iPhone 15 Pro", or the type's
/// own name when the shop only recorded a number.
String assetTitle(AppLocalizations l10n, CustomerAsset asset) {
  final label = asset.displayName.trim();
  if (label.isNotEmpty) {
    return label;
  }
  final type = asset.assetTypeName.trim();
  return type.isEmpty ? l10n.assetTypeOther : type;
}

/// A tinted circular badge carrying the item's type icon.
class AssetIconBadge extends StatelessWidget {
  const AssetIconBadge({
    super.key,
    required this.iconKey,
    this.size = 44,
    this.color,
  });

  final String iconKey;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final tint = color ?? colors.primaryStrong;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(assetIconForKey(iconKey), color: tint, size: size * 0.5),
    );
  }
}

/// One identity number with its label, rendered so the number itself stays
/// left-to-right inside an Arabic layout — a VIN read right-to-left is not the
/// same VIN.
class AssetIdentityChip extends StatelessWidget {
  const AssetIdentityChip({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: textTheme.labelSmall?.copyWith(color: colors.mutedInk),
        ),
        const SizedBox(height: 2),
        Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            value,
            style: textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// Every identity number this item actually has, in the order a person would
/// reach for them.
List<({String label, String value})> assetIdentityFields(
  AppLocalizations l10n,
  CustomerAsset asset,
) {
  final fields = <({String label, String value})>[];
  void add(String label, String value) {
    if (value.trim().isNotEmpty) {
      fields.add((label: label, value: value.trim()));
    }
  }

  add(l10n.assetPlateLabel, asset.plateNumber);
  add(l10n.assetVinLabel, asset.vin);
  add(l10n.assetEngineLabel, asset.engineNumber);
  add(l10n.assetImeiLabel, asset.imei);
  add(l10n.assetSerialLabel, asset.serialNumber);
  // Whatever this trade calls its own number, named by the type that defined it.
  add(
    asset.customIdentifierLabel.trim().isEmpty
        ? l10n.assetCustomIdentifierFallbackLabel
        : asset.customIdentifierLabel,
    asset.customIdentifier,
  );
  return fields;
}
