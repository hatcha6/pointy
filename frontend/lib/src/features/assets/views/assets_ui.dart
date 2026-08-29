import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/customer_asset.dart';
import '../../../shared/design/design.dart';

/// Cross-screen building blocks for the asset registry, so the list, the
/// details page and the intake wizard name and picture an item the same way.

String assetTypeName(AppLocalizations l10n, CustomerAssetType type) {
  return switch (type) {
    CustomerAssetType.phone => l10n.assetTypePhone,
    CustomerAssetType.tablet => l10n.assetTypeTablet,
    CustomerAssetType.laptop => l10n.assetTypeLaptop,
    CustomerAssetType.console => l10n.assetTypeConsole,
    CustomerAssetType.appliance => l10n.assetTypeAppliance,
    CustomerAssetType.vehicle => l10n.assetTypeVehicle,
    CustomerAssetType.other => l10n.assetTypeOther,
  };
}

IconData assetTypeIcon(CustomerAssetType type) {
  return switch (type) {
    CustomerAssetType.phone => Icons.smartphone_outlined,
    CustomerAssetType.tablet => Icons.tablet_mac_outlined,
    CustomerAssetType.laptop => Icons.laptop_mac_outlined,
    CustomerAssetType.console => Icons.sports_esports_outlined,
    CustomerAssetType.appliance => Icons.kitchen_outlined,
    CustomerAssetType.vehicle => Icons.directions_car_outlined,
    CustomerAssetType.other => Icons.devices_other_outlined,
  };
}

/// The item's name for a human: "Toyota Corolla", "iPhone 15 Pro", or the type
/// when the shop only recorded a serial.
String assetTitle(AppLocalizations l10n, CustomerAsset asset) {
  final label = asset.displayName.trim();
  return label.isEmpty ? assetTypeName(l10n, asset.assetType) : label;
}

/// A tinted circular badge carrying the item's type icon.
class AssetIconBadge extends StatelessWidget {
  const AssetIconBadge({
    super.key,
    required this.type,
    this.size = 44,
    this.color,
  });

  final CustomerAssetType type;
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
      child: Icon(assetTypeIcon(type), color: tint, size: size * 0.5),
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
  return fields;
}
