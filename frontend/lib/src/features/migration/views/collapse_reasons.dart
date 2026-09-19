import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// Turns the server's machine codes into sentences a shop owner can act on.
///
/// The server sends codes rather than prose for the usual reason — it does not
/// own the language the screen speaks — but the codes are also the *only*
/// explanation of why a row is uncertain, so an unknown one must never render
/// blank. It falls through to the code itself, which is ugly and visible, which
/// is the right failure.
String collapseReasonLabel(AppLocalizations l10n, String code) {
  return switch (code) {
    'no_identifier' => l10n.collapseReasonNoIdentifier,
    'no_stem' => l10n.collapseReasonNoStem,
    'weak_stem' => l10n.collapseReasonWeakStem,
    'identifier_unlabelled' => l10n.collapseReasonUnlabelled,
    'identifier_odd_length' => l10n.collapseReasonOddLength,
    'imei_check_digit_failed' => l10n.collapseReasonCheckDigit,
    'vin_check_digit_failed' => l10n.collapseReasonVinCheckDigit,
    'second_identifier_present' => l10n.collapseReasonSecondIdentifier,
    'singleton_cluster' => l10n.collapseReasonSingleton,
    'no_purchase_cost' => l10n.collapseReasonNoCost,
    'gone_without_a_sale' => l10n.collapseReasonGoneWithoutSale,
    'sold_more_than_once' => l10n.collapseReasonSoldMoreThanOnce,
    'purchased_more_than_once' => l10n.collapseReasonPurchasedMoreThanOnce,
    'more_than_one_on_hand' => l10n.collapseReasonMoreThanOneOnHand,
    'duplicate_identifier' => l10n.collapseReasonDuplicateIdentifier,
    'identifier_already_in_stock' => l10n.collapseReasonAlreadyInStock,
    'multiple_variants' => l10n.collapseReasonMultipleVariants,
    'not_stock_keeping' => l10n.collapseReasonNotStockKeeping,
    'empty_name' => l10n.collapseReasonEmptyName,
    _ => code,
  };
}
