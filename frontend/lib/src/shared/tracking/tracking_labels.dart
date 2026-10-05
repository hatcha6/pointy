import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/identified_stock_settings.dart';
import '../../data/models/stock_unit.dart';
import '../../data/models/tracking_mode.dart';
import '../design/design.dart';

/// How each tracking mode is named wherever a person chooses or reads one —
/// the product form, the product's details, a filter chip. One table, so the
/// same mode is never called two things on two screens.
String trackingModeLabel(AppLocalizations l10n, TrackingMode mode) =>
    switch (mode) {
      TrackingMode.quantity => l10n.trackingModeQuantity,
      TrackingMode.batch => l10n.trackingModeBatch,
      TrackingMode.serial => l10n.trackingModeSerial,
      TrackingMode.serialBatch => l10n.trackingModeSerialBatch,
    };

/// One sentence on what choosing [mode] means for the shop, in its terms.
String trackingModeDescription(AppLocalizations l10n, TrackingMode mode) =>
    switch (mode) {
      TrackingMode.quantity => l10n.trackingModeQuantityDescription,
      TrackingMode.batch => l10n.trackingModeBatchDescription,
      TrackingMode.serial => l10n.trackingModeSerialDescription,
      TrackingMode.serialBatch => l10n.trackingModeSerialBatchDescription,
    };

IconData trackingModeIcon(TrackingMode mode) => switch (mode) {
  TrackingMode.quantity => Icons.numbers_outlined,
  TrackingMode.batch => Icons.event_available_outlined,
  TrackingMode.serial => Icons.qr_code_2_outlined,
  TrackingMode.serialBatch => Icons.medication_outlined,
};

/// The product form and the settings page name the strategies the same way.
String batchPickStrategyLabel(
  AppLocalizations l10n,
  BatchPickStrategy strategy,
) => switch (strategy) {
  BatchPickStrategy.fefo => l10n.batchPickStrategyFefo,
  BatchPickStrategy.fifo => l10n.batchPickStrategyFifo,
  BatchPickStrategy.manual => l10n.batchPickStrategyManual,
};

/// What an article's status is called wherever a person reads it — the units
/// list, the unit's page, the catalog's identifier match. An unknown status
/// from a newer server reads as itself rather than throwing.
String stockUnitStatusLabel(AppLocalizations l10n, String status) =>
    switch (status) {
      StockUnitStatus.inStock => l10n.stockUnitStatusInStock,
      StockUnitStatus.reserved => l10n.stockUnitStatusReserved,
      StockUnitStatus.sold => l10n.stockUnitStatusSold,
      StockUnitStatus.damaged => l10n.stockUnitStatusDamaged,
      StockUnitStatus.writtenOff => l10n.stockUnitStatusWrittenOff,
      StockUnitStatus.inTransit => l10n.aiUiStockUnitStatusInTransit,
      StockUnitStatus.returned => l10n.aiUiStockUnitStatusReturned,
      StockUnitStatus.expected => l10n.aiUiStockUnitStatusExpected,
      StockUnitStatus.cancelled => l10n.aiUiStockUnitStatusCancelled,
      _ => status,
    };

/// The accent a status pill is drawn in: on the shelf reads as good news,
/// gone for good as a warning, sold as a plain fact.
Color stockUnitStatusColor(PointySemanticColors colors, String status) =>
    switch (status) {
      StockUnitStatus.inStock => colors.success,
      StockUnitStatus.reserved ||
      StockUnitStatus.inTransit ||
      StockUnitStatus.expected => colors.primaryStrong,
      StockUnitStatus.damaged || StockUnitStatus.writtenOff => colors.danger,
      _ => colors.mutedInk,
    };
