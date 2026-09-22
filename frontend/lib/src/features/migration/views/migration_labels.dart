import '../../../../l10n/generated/app_localizations.dart';

/// Arabic names for the things the migration API talks about.
///
/// The server sends stable keys (`entity_type`, a stage's `key`, a scope's
/// `key`) alongside an English label meant for logs and API consumers. This
/// screen renders the key; the English is only ever a fallback for something
/// added to the server after this build shipped.
///
/// Doing it this way round is what stops the import wizard from being the one
/// screen in the app that speaks English. It also means the wording can be
/// fixed without a backend release, and a run's stored history — which keeps
/// whatever label was current when it ran — still reads in Arabic today.

/// The name of an entity type, or [fallback] for one we do not know.
String migrationEntityLabel(
  AppLocalizations l10n,
  String entityType, {
  String fallback = '',
}) {
  return switch (entityType) {
    'unit' => l10n.migrationEntityUnit,
    'category' => l10n.migrationEntityCategory,
    'product' => l10n.migrationEntityProduct,
    'variant' => l10n.migrationEntityVariant,
    'product_unit' => l10n.migrationEntityProductUnit,
    'stock' => l10n.migrationEntityStock,
    'customer' => l10n.migrationEntityCustomer,
    'supplier' => l10n.migrationEntitySupplier,
    'party_balance' => l10n.migrationEntityPartyBalance,
    'purchase_order' => l10n.migrationEntityPurchaseOrder,
    'supplier_payment' => l10n.migrationEntitySupplierPayment,
    'sale' => l10n.migrationEntitySale,
    'sale_return' => l10n.migrationEntitySaleReturn,
    'payment' => l10n.migrationEntityPayment,
    'employee' => l10n.migrationEntityEmployee,
    'payroll_run' => l10n.migrationEntityPayrollRun,
    'expense_category' => l10n.migrationEntityExpenseCategory,
    'expense' => l10n.migrationEntityExpense,
    'money_account' => l10n.migrationEntityMoneyAccount,
    'collapse' => l10n.migrationEntityCollapse,
    _ => fallback.isEmpty ? entityType : fallback,
  };
}

/// The name of a stage in a run or a preparation timeline.
///
/// Import runs emit one stage per entity, so the entity names are the larger
/// half of this map; the rest are the framing stages of preparation and of the
/// §12 collapse planner.
String migrationStageLabel(
  AppLocalizations l10n,
  String key, {
  String fallback = '',
}) {
  return switch (key) {
    'identify' => l10n.migrationStageIdentify,
    'convert' => l10n.migrationStageConvert,
    'prepare' => l10n.migrationStagePrepare,
    'detect' => l10n.migrationStageDetect,
    'analyze' => l10n.migrationStageAnalyze,
    'tidy' => l10n.migrationStageTidy,
    'catalogue' => l10n.migrationStageCatalogue,
    'history' => l10n.migrationStageHistory,
    'cluster' => l10n.migrationStageCluster,
    'propose' => l10n.migrationStagePropose,
    _ => migrationEntityLabel(l10n, key, fallback: fallback),
  };
}

/// The name and the sentence under it for a named import scope.
({String label, String subtitle})? migrationScopeCopy(
  AppLocalizations l10n,
  String key,
) {
  return switch (key) {
    'everything' => (
      label: l10n.migrationScopeEverythingLabel,
      subtitle: l10n.migrationScopeEverythingSubtitle,
    ),
    'opening_position' => (
      label: l10n.migrationScopeOpeningPositionLabel,
      subtitle: l10n.migrationScopeOpeningPositionSubtitle,
    ),
    'catalogue_only' => (
      label: l10n.migrationScopeCatalogueOnlyLabel,
      subtitle: l10n.migrationScopeCatalogueOnlySubtitle,
    ),
    'custom' => (
      label: l10n.migrationScopeCustomLabel,
      subtitle: l10n.migrationScopeCustomSubtitle,
    ),
    _ => null,
  };
}

/// "الأصناف، العملاء والموردون" — a list a sentence can end with.
String migrationEntityList(
  AppLocalizations l10n,
  Iterable<String> entityTypes,
) {
  final names = [
    for (final entity in entityTypes) migrationEntityLabel(l10n, entity),
  ];
  if (names.length < 2) return names.join();
  return '${names.take(names.length - 1).join('، ')} و${names.last}';
}
