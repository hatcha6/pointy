/// Every widget a lesson is allowed to point at.
///
/// A **closed enum on purpose**. Lessons must never anchor on text, position or
/// index: anchoring a tutorial to copy means the first time someone rewords a
/// button every lesson touching it breaks — and worse, a *near* match keeps
/// passing while pointing at the wrong thing. The existing end-to-end test
/// still finds widgets by their Arabic label, which is exactly the trap.
///
/// Adding a lesson step that needs a new target means adding a value here:
/// visible in review, greppable, countable. `lesson_staleness_test.dart` fails
/// the build on a value nothing wraps and on a value no lesson names, so this
/// list cannot quietly fill up with anchors that point at nothing.
enum TutorAnchor {
  // --- getting to the screen -----------------------------------------------
  navigationDestination,

  // --- register session ----------------------------------------------------
  registerOpeningCashField,
  registerStartSessionButton,
  registerSessionMenuButton,
  registerSessionAction,
  registerCloseCountedCashField,
  registerCloseConfirmButton,
  registerCashMovementAmountField,
  registerCashMovementReasonField,
  registerCashMovementConfirmButton,

  // --- POS -----------------------------------------------------------------
  posCatalogSearchField,
  posProductTile,
  posCartLine,
  posCartCustomer,
  posSaleSettingsButton,
  posSaleSettingsSaveButton,
  posCheckoutButton,

  // --- shared pickers ------------------------------------------------------
  searchablePickerRow,

  // --- contacts, shared by "customer on a sale" and "supplier on an order" --
  contactSelectionTile,
  contactPickerSearchField,
  contactPickerRow,
  contactPickerCreateButton,
  contactFormNameField,
  contactFormPhoneField,
  contactFormSaveButton,

  // --- payment sheet -------------------------------------------------------
  paymentSheet,
  paymentSaleTypeSegment,
  paymentMethodSegment,
  paymentTenderAmountField,
  paymentAddTenderButton,
  paymentCardReceiptButton,
  paymentCreditDueDatePreset,
  paymentCreditDueDateClear,
  paymentConfirmButton,

  // --- money in and out, shared by customer debt and supplier payments -----
  collectDebtPickCustomerButton,
  collectDebtRecordPaymentButton,
  recordPaymentAmountField,
  recordPaymentConfirmButton,

  // --- catalogue -----------------------------------------------------------
  catalogAddProductButton,
  productNameField,
  productVariantOptionPicker,
  productVariantOptionValuesSelectAll,
  productSkuPrefixField,
  productGeneratedPriceField,
  productSkuField,
  productBarcodeField,
  productPriceField,
  productFormPrimaryButton,
  productAddUnitButton,
  productUnitBarcodeField,
  productUnitAddBarcodeButton,

  // --- purchasing ----------------------------------------------------------
  purchaseNewOrderButton,
  purchaseCatalogSearchField,
  purchaseProductTile,
  purchaseLineCostField,
  purchaseReceiveImmediatelyToggle,
  purchaseSettingsButton,
  purchaseSettingsSaveButton,
  purchaseSubmitButton,
  purchaseOrderRow,
  purchaseOrderAction,
  purchaseReceiveQuantityField,
  purchaseReceiveConfirmButton,
}
