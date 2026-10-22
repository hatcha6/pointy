import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/bulk_price_preview.dart';
import '../../../../data/models/bulk_price_rule.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';

/// Arabic names for every part of the bulk price rule language — one place,
/// so a condition row, a step card and the history read the same words.
extension BulkPriceLabels on AppLocalizations {
  String fieldLabel(BulkPriceField field) => switch (field) {
    BulkPriceField.name => bulkPriceFieldName,
    BulkPriceField.sku => bulkPriceFieldSku,
    BulkPriceField.barcode => bulkPriceFieldBarcode,
    BulkPriceField.category => bulkPriceFieldCategory,
    BulkPriceField.supplier => bulkPriceFieldSupplier,
    BulkPriceField.product => bulkPriceFieldProduct,
    BulkPriceField.price => bulkPriceFieldPrice,
    BulkPriceField.cost => bulkPriceFieldCost,
    BulkPriceField.markup => bulkPriceFieldMarkup,
    BulkPriceField.stock => bulkPriceFieldStock,
    BulkPriceField.isActive => bulkPriceFieldIsActive,
    BulkPriceField.isService => bulkPriceFieldIsService,
    BulkPriceField.foreignPriced => bulkPriceFieldForeignPriced,
  };

  String operatorLabel(BulkPriceOperator operator) => switch (operator) {
    BulkPriceOperator.contains => bulkPriceOpContains,
    BulkPriceOperator.notContains => bulkPriceOpNotContains,
    BulkPriceOperator.equals || BulkPriceOperator.eq => bulkPriceOpEquals,
    BulkPriceOperator.notEquals ||
    BulkPriceOperator.neq => bulkPriceOpNotEquals,
    BulkPriceOperator.startsWith => bulkPriceOpStartsWith,
    BulkPriceOperator.endsWith => bulkPriceOpEndsWith,
    BulkPriceOperator.isEmpty => bulkPriceOpIsEmpty,
    BulkPriceOperator.isNotEmpty => bulkPriceOpIsNotEmpty,
    BulkPriceOperator.gt => bulkPriceOpGt,
    BulkPriceOperator.gte => bulkPriceOpGte,
    BulkPriceOperator.lt => bulkPriceOpLt,
    BulkPriceOperator.lte => bulkPriceOpLte,
    BulkPriceOperator.between => bulkPriceOpBetween,
    BulkPriceOperator.inList => bulkPriceOpIn,
    BulkPriceOperator.notInList => bulkPriceOpNotIn,
    BulkPriceOperator.isTrue => bulkPriceOpIsTrue,
    BulkPriceOperator.isFalse => bulkPriceOpIsFalse,
  };

  String actionLabel(BulkPriceAction action) => switch (action) {
    BulkPriceAction.increasePercent => bulkPriceActionIncreasePercent,
    BulkPriceAction.decreasePercent => bulkPriceActionDecreasePercent,
    BulkPriceAction.increaseAmount => bulkPriceActionIncreaseAmount,
    BulkPriceAction.decreaseAmount => bulkPriceActionDecreaseAmount,
    BulkPriceAction.set => bulkPriceActionSet,
    BulkPriceAction.costMarkup => bulkPriceActionCostMarkup,
    BulkPriceAction.costPlus => bulkPriceActionCostPlus,
    BulkPriceAction.minMarkup => bulkPriceActionMinMarkup,
    BulkPriceAction.minPrice => bulkPriceActionMinPrice,
    BulkPriceAction.maxPrice => bulkPriceActionMaxPrice,
    BulkPriceAction.round => bulkPriceActionRound,
    BulkPriceAction.ending => bulkPriceActionEnding,
  };

  String directionLabel(BulkPriceDirection direction) => switch (direction) {
    BulkPriceDirection.nearest => bulkPriceDirectionNearest,
    BulkPriceDirection.up => bulkPriceDirectionUp,
    BulkPriceDirection.down => bulkPriceDirectionDown,
  };

  String issueLabel(BulkPriceIssue issue) => switch (issue) {
    BulkPriceIssue.required => bulkPriceIssueRequired,
    BulkPriceIssue.notANumber => bulkPriceIssueNotANumber,
    BulkPriceIssue.negative => bulkPriceIssueNegative,
    BulkPriceIssue.tooManyDecimals => bulkPriceIssueTooManyDecimals,
    BulkPriceIssue.boundsReversed => bulkPriceIssueBoundsReversed,
    BulkPriceIssue.percentOver100 => bulkPriceIssuePercentOver100,
    BulkPriceIssue.zeroIncrement => bulkPriceIssueZeroIncrement,
  };

  String flagLabel(BulkPriceFlag flag) => switch (flag) {
    BulkPriceFlag.belowCost => bulkPriceFlagBelowCost,
    BulkPriceFlag.raisedToCost => bulkPriceFlagRaisedToCost,
    BulkPriceFlag.noCost => bulkPriceFlagNoCost,
    BulkPriceFlag.zero => bulkPriceFlagZero,
    BulkPriceFlag.bigChange => bulkPriceFlagBigChange,
    BulkPriceFlag.foreign => bulkPriceFlagForeign,
  };

  String viewLabel(BulkPricePreviewView view) => switch (view) {
    BulkPricePreviewView.changed => bulkPriceViewChanged,
    BulkPricePreviewView.increased => bulkPriceViewIncreased,
    BulkPricePreviewView.decreased => bulkPriceViewDecreased,
    BulkPricePreviewView.warnings => bulkPriceViewWarnings,
    BulkPricePreviewView.unchanged => bulkPriceViewUnchanged,
    BulkPricePreviewView.all => bulkPriceViewAll,
  };
}

/// Actions grouped as the step menu shows them.
const bulkPriceActionGroups = <List<BulkPriceAction>>[
  [
    BulkPriceAction.increasePercent,
    BulkPriceAction.decreasePercent,
    BulkPriceAction.increaseAmount,
    BulkPriceAction.decreaseAmount,
    BulkPriceAction.set,
  ],
  [
    BulkPriceAction.costMarkup,
    BulkPriceAction.costPlus,
    BulkPriceAction.minMarkup,
  ],
  [BulkPriceAction.minPrice, BulkPriceAction.maxPrice],
  [BulkPriceAction.round, BulkPriceAction.ending],
];

String bulkPriceActionGroupLabel(AppLocalizations l10n, int index) =>
    switch (index) {
      0 => l10n.bulkPriceActionGroupAdjust,
      1 => l10n.bulkPriceActionGroupCost,
      2 => l10n.bulkPriceActionGroupLimits,
      _ => l10n.bulkPriceActionGroupRounding,
    };

IconData bulkPriceActionIcon(BulkPriceAction action) => switch (action) {
  BulkPriceAction.increasePercent ||
  BulkPriceAction.increaseAmount => Icons.trending_up,
  BulkPriceAction.decreasePercent ||
  BulkPriceAction.decreaseAmount => Icons.trending_down,
  BulkPriceAction.set => Icons.edit_outlined,
  BulkPriceAction.costMarkup ||
  BulkPriceAction.costPlus ||
  BulkPriceAction.minMarkup => Icons.inventory_2_outlined,
  BulkPriceAction.minPrice => Icons.vertical_align_bottom,
  BulkPriceAction.maxPrice => Icons.vertical_align_top,
  BulkPriceAction.round => Icons.adjust,
  BulkPriceAction.ending => Icons.more_horiz,
};

IconData bulkPriceFieldIcon(BulkPriceField field) => switch (field) {
  BulkPriceField.name => Icons.label_outline,
  BulkPriceField.sku => Icons.tag,
  BulkPriceField.barcode => Icons.qr_code_2,
  BulkPriceField.category => Icons.category_outlined,
  BulkPriceField.supplier => Icons.local_shipping_outlined,
  BulkPriceField.product => Icons.checklist,
  BulkPriceField.price => Icons.sell_outlined,
  BulkPriceField.cost => Icons.inventory_2_outlined,
  BulkPriceField.markup => Icons.percent,
  BulkPriceField.stock => Icons.warehouse_outlined,
  BulkPriceField.isActive => Icons.toggle_on_outlined,
  BulkPriceField.isService => Icons.handyman_outlined,
  BulkPriceField.foreignPriced => Icons.currency_exchange,
};

Color bulkPriceFlagColor(BuildContext context, BulkPriceFlag flag) {
  final colors = context.pointyColors;
  return switch (flag) {
    BulkPriceFlag.belowCost || BulkPriceFlag.zero => colors.danger,
    BulkPriceFlag.raisedToCost ||
    BulkPriceFlag.noCost ||
    BulkPriceFlag.bigChange => colors.warning,
    BulkPriceFlag.foreign => colors.mutedInk,
  };
}

/// A percentage for display, kept left-to-right inside Arabic text.
String bulkPricePercent(double value, {bool signed = false}) {
  final rounded = value.abs() >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  final sign = signed && value > 0 ? '+' : '';
  return ltrIsolated('$sign$rounded%');
}

/// The suffix a step or condition value is typed in.
String bulkPriceUnitFor(BulkPriceValueKind kind) =>
    kind == BulkPriceValueKind.percent ? '%' : currencySymbol;
