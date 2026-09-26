import '../data/models/pos_user.dart';

typedef AuthorizedAction = void Function();
typedef AuthorizedAsyncAction = Future<void> Function();

enum AppCapability {
  viewDashboard,
  viewSalesDashboard,
  viewPaymentDashboard,
  viewInventoryDashboard,
  viewPurchasingDashboard,
  viewCustomerDashboard,
  viewDiscountDashboard,
  viewPrintingDashboard,
  viewReports,

  /// Sees shop-wide sales rather than only this till's own — the mirror of the
  /// backend's `user_has_full_visibility`, which scopes the invoices list to
  /// the caller's own register sessions for everyone else. Gates affordances
  /// that only make sense across people, such as filtering invoices by cashier.
  viewShopWideSales,
  viewActivityLog,
  viewFraudFindings,
  manageFraudFindings,
  viewEmployees,
  manageEmployees,
  manageOwnAccount,
  viewEmployeeLoans,
  manageEmployeeLoans,
  viewPayroll,
  managePayroll,
  accessPos,
  viewInvoices,
  processReturnsByLookup,
  accessPurchasing,
  createPurchaseOrder,
  createPosCashPurchase,
  editDraftPurchaseOrder,
  receivePurchaseOrder,
  adjustPurchaseOrder,
  cancelPurchaseOrder,
  deletePurchaseOrder,

  /// Pays a supplier against a purchase order. Not [accessPurchasing]: a buyer
  /// runs an order from draft to delivery without, in most shops, being the
  /// one who hands over the money — the purchasing agent role can read the
  /// payments and not record one, so the button would only ever refuse.
  recordSupplierPayment,
  manageContacts,

  /// Registers a new customer — at the repair counter, or to put a sale on
  /// their name. Deliberately NOT [manageContacts]: creating a record shows
  /// nothing about anybody else, while the contact book lists every customer
  /// with what they owe, and the customer dashboard adds it all up.
  createCustomers,
  collectCustomerDebt,
  checkoutSale,
  startRegisterSession,
  resumeRegisterSession,
  closeRegisterSession,
  createRegisterCashMovement,
  viewCatalogManagement,
  manageCategories,
  createProduct,
  changeProduct,
  createProductVariant,
  changeProductVariant,
  viewRegisterSessions,
  viewRegisterSessionOrders,
  manageDeviceSettings,
  manageUsers,
  manageShopSettings,
  manageSalesChannels,
  managePriceCheckers,
  viewCameras,
  watchCamerasLive,
  reviewCameraPlayback,
  exportCameraFootage,
  manageCameras,
  manageScales,
  manageMessaging,
  manageIntegrations,
  useIntegrations,
  recordIntegrationTopUp,

  /// Records a top-up somebody did on a provider's own website (LNET) as the
  /// sale it was, into a register session's drawer. It writes into another
  /// cashier's shift, so it is a manager's by default and granted to anyone
  /// else on purpose — together with the right to issue a sale, which
  /// recording one does.
  recordPortalPayments,

  /// Sees what a product cost while selling it. The single most sensitive
  /// number a shop has — what the owner pays a supplier — so it is off for a
  /// cashier by default and granted per person. Even once granted the till
  /// keeps it hidden until a keypress: a customer leaning over the counter
  /// reads the screen too.
  viewTillCost,

  /// Changes a cart line's selling price before the sale. Separate from
  /// [viewTillCost] because it is revenue rather than knowledge: a shop may
  /// well want a senior cashier to know the floor without being able to
  /// discount to it. The server records what the line would have sold for.
  overrideLinePrice,
  viewConversations,
  manageConversations,
  manageCampaigns,
  sendCampaigns,
  viewExpenses,
  manageExpenses,

  /// The categories every expense is filed under. Their own permissions, not
  /// [manageExpenses]: recording expenses does not make someone the keeper of
  /// the list the whole shop files against.
  createExpenseCategory,
  changeExpenseCategory,
  deleteExpenseCategory,
  viewPayments,

  /// Reading the shop's money accounts: which banks card and transfer money
  /// may land in. Distinct from [viewPayments] — a cashier takes payments all
  /// day without being shown the shop's accounts.
  viewMoneyAccounts,

  /// The treasury's writes, one per permission the server checks. An auditor
  /// reads every account, transfer and count without holding any of these.
  createMoneyAccount,
  changeMoneyAccount,

  /// Moving money between the shop's accounts, and across its boundary —
  /// adding funds and withdrawing are the same transfer with one side left
  /// empty, so they ride the same permission.
  recordMoneyTransfer,
  recordMoneyCount,
  viewExchangeRates,
  viewAttendance,
  manageAttendance,
  viewOperations,
  createJobs,

  /// Works a job: moves it between stages, puts it on hold, and charges
  /// labour and services on it. The server checks `operations.change_job` for
  /// all of these, so offering them to someone who can only view jobs would
  /// be a row of buttons that each refuse.
  changeJobs,
  assignJobs,
  reopenJobs,
  releaseUnpaidJobs,
  viewAssets,
  manageAssets,
  manageJobMaterials,
  manageWorkflows,
  manageRecipes,
  viewRecipes,
  viewPrepStations,
  viewDiscountRules,
  createDiscountRule,
  changeDiscountRule,
  deleteDiscountRule,
  viewStock,
  createStockMovement,
  countStock,
  applyStockCount,

  /// The places a shop keeps stock. Seeing the list and each change to it are
  /// separate rights on the server, so they are separate here: somebody who
  /// may look at the store room has no business renaming or deleting it.
  viewWarehouses,
  createWarehouse,
  changeWarehouse,
  deleteWarehouse,

  /// Which place this till sells from (`sales.change_registerprofile`). Every
  /// till may read its own; changing it moves where every later sale is taken
  /// from.
  changeRegisterWarehouse,

  /// Moving stock between those places. Sending and receiving are split
  /// because they happen at the two ends of the road, and the person who
  /// loads the van is rarely the one who unloads it. Cancelling rides on
  /// sending: the server checks `dispatch_stocktransfer` for both.
  viewStockTransfers,
  createStockTransfer,
  dispatchStockTransfer,
  receiveStockTransfer,

  /// The two lists a shop that identifies its stock works from. Separate
  /// capabilities, because a pharmacy needs lots and a phone shop needs
  /// serials, and neither should have to see the other's screen.
  viewStockUnits,
  viewStockBatches,

  /// الأمانات. Split from the unit list on purpose: a shop can let its counter
  /// staff see what is owed and hand it over — that is where a consignor turns
  /// up — while writing the voucher stays with whoever takes the goods in.
  viewConsignmentPayables,
  disburseConsignmentPayout,
  manageConsignmentAgreement,
  repriceStockUnit,
  writeOffStockUnit,

  /// Stop-sale on a lot, and the safety broadcast that follows it. Its own
  /// capability rather than "can edit a lot": quarantining reaches every till
  /// in every branch in one write, and telling a hundred customers to stop
  /// using a medicine is not an edit.
  quarantineBatch,

  /// Recording, assessing and settling what happened to somebody else's
  /// goods (§6.2.2).
  manageConsignmentIncident,
  useAiAssistant,

  /// The in-app learning library.
  ///
  /// Granted unconditionally to every role — a cashier who cannot read how the
  /// till works is the problem the module exists to solve, and there is nothing
  /// in a guide to withhold. It is a capability at all because every navigation
  /// destination needs one; if a shop ever wants to withdraw it, that becomes a
  /// backend permission wired in here like the rest.
  useLearningMode,
}

class AuthorizationCapabilities {
  const AuthorizationCapabilities._(this._capabilities);

  /// Camera surfaces that a shop without a recorder must not show at all.
  ///
  /// [AppCapability.manageCameras] is deliberately absent: reaching the camera
  /// settings page is how a shop turns the feature on in the first place, so
  /// gating it on the feature being on would lock the door from the inside.
  static const _surveillanceCapabilities = {
    AppCapability.viewCameras,
    AppCapability.watchCamerasLive,
    AppCapability.reviewCameraPlayback,
    AppCapability.exportCameraFootage,
  };

  /// Removed for a shop that has not opted into identified stock, the same way
  /// cameras are removed for a shop with no recorder. Without this the two
  /// drawer entries and their ⌘K matches appeared for every shop that took the
  /// update — cashiers included, by default — for a feature nobody enabled.
  static Set<AppCapability> _trackingCapabilitiesOff(PosUser user) {
    final off = <AppCapability>{};
    if (!user.serializedInventoryEnabled) {
      off.add(AppCapability.viewStockUnits);
    }
    if (!user.batchTrackingEnabled) {
      off.add(AppCapability.viewStockBatches);
    }
    return off;
  }

  factory AuthorizationCapabilities.forUser(PosUser user) {
    if (user.role.isManager) {
      final all = Set.of(AppCapability.values);
      // AI is a paid shop entitlement, so even managers only see the assistant
      // when the shop's subscription has it active.
      if (!user.aiAvailable) {
        all.remove(AppCapability.useAiAssistant);
      }
      if (!user.surveillanceEnabled) {
        all.removeAll(_surveillanceCapabilities);
      }
      all.removeAll(_trackingCapabilitiesOff(user));
      return AuthorizationCapabilities._(all);
    }

    // Deliberately no dashboard capabilities here: revenue aggregates would
    // tell a cashier exactly how much cash the drawer should hold, defeating
    // the blind close. Dashboards are granted below from explicit reporting
    // permissions instead.
    final capabilities = <AppCapability>{
      AppCapability.accessPos,
      AppCapability.manageOwnAccount,
      AppCapability.checkoutSale,
      AppCapability.startRegisterSession,
      AppCapability.resumeRegisterSession,
      AppCapability.closeRegisterSession,
      AppCapability.createRegisterCashMovement,
      AppCapability.manageDeviceSettings,
      AppCapability.useLearningMode,
    };

    // Manager-controlled: lets cashiers look up customers (to attach one to a
    // credit/quote sale) and collect customer debt via the focused collect-debt
    // flow. The backend enforces the same flag on the customer endpoints.
    if (user.allowCashierCustomerAccess) {
      capabilities.add(AppCapability.collectCustomerDebt);
    }

    if (user.permissions.isNotEmpty) {
      if (_hasAny(user, const ['add_product', 'catalog.add_product'])) {
        capabilities
          ..add(AppCapability.viewCatalogManagement)
          ..add(AppCapability.createProduct);
      }
      if (_hasAny(user, const [
        'add_productvariant',
        'catalog.add_productvariant',
      ])) {
        capabilities
          ..add(AppCapability.viewCatalogManagement)
          ..add(AppCapability.createProductVariant);
      }
      if (_hasAny(user, const [
        'add_productcategory',
        'change_productcategory',
        'delete_productcategory',
        'catalog.add_productcategory',
        'catalog.change_productcategory',
        'catalog.delete_productcategory',
      ])) {
        capabilities.add(AppCapability.manageCategories);
      }
      if (_hasAny(user, const [
        'change_product',
        'delete_product',
        'catalog.change_product',
        'catalog.delete_product',
      ])) {
        capabilities
          ..add(AppCapability.viewCatalogManagement)
          ..add(AppCapability.changeProduct);
      }
      if (_hasAny(user, const [
        'change_productvariant',
        'delete_productvariant',
        'catalog.change_productvariant',
        'catalog.delete_productvariant',
      ])) {
        capabilities
          ..add(AppCapability.viewCatalogManagement)
          ..add(AppCapability.changeProductVariant);
      }
      // Units of measure and scale-label rules are managed from the catalog
      // screen's own toolbar, so holding either has to open that screen —
      // otherwise the grant is a right with no way to use it.
      if (_hasAny(user, const [
        'add_unitofmeasure',
        'change_unitofmeasure',
        'delete_unitofmeasure',
        'add_scalebarcoderule',
        'change_scalebarcoderule',
        'delete_scalebarcoderule',
        'catalog.add_unitofmeasure',
        'catalog.change_unitofmeasure',
        'catalog.delete_unitofmeasure',
        'catalog.add_scalebarcoderule',
        'catalog.change_scalebarcoderule',
        'catalog.delete_scalebarcoderule',
      ])) {
        capabilities.add(AppCapability.viewCatalogManagement);
      }
      if (_hasAny(user, const [
        'view_stockitem',
        'view_stockmovement',
        'inventory.view_stockitem',
        'inventory.view_stockmovement',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewInventoryDashboard)
          ..add(AppCapability.viewStock);
      }
      if (_hasAny(user, const [
        'add_stockmovement',
        'inventory.add_stockmovement',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewInventoryDashboard)
          ..add(AppCapability.viewStock)
          ..add(AppCapability.createStockMovement);
      }
      // Stock counting is granted on its own permission so floor staff can run
      // counts without seeing inventory dashboards. Applying adjustments is a
      // separate, stronger permission (managers get it via their domain).
      if (_hasAny(user, const ['add_stockcount', 'inventory.add_stockcount'])) {
        capabilities.add(AppCapability.countStock);
      }
      if (_hasAny(user, const ['view_stockunit', 'inventory.view_stockunit'])) {
        capabilities.add(AppCapability.viewStockUnits);
      }
      if (_hasAny(user, const [
        'view_stockbatch',
        'inventory.view_stockbatch',
      ])) {
        capabilities.add(AppCapability.viewStockBatches);
      }
      if (_hasAny(user, const [
        'view_consignment_liability',
        'inventory.view_consignment_liability',
      ])) {
        capabilities.add(AppCapability.viewConsignmentPayables);
      }
      if (_hasAny(user, const [
        'disburse_consignment_payout',
        'inventory.disburse_consignment_payout',
      ])) {
        capabilities.add(AppCapability.disburseConsignmentPayout);
      }
      if (_hasAny(user, const [
        'manage_consignmentagreement',
        'inventory.manage_consignmentagreement',
      ])) {
        capabilities.add(AppCapability.manageConsignmentAgreement);
      }
      if (_hasAny(user, const [
        'quarantine_batch',
        'inventory.quarantine_batch',
      ])) {
        capabilities.add(AppCapability.quarantineBatch);
      }
      if (_hasAny(user, const [
        'manage_consignmentincident',
        'inventory.manage_consignmentincident',
      ])) {
        capabilities.add(AppCapability.manageConsignmentIncident);
      }
      if (_hasAny(user, const [
        'reprice_stockunit',
        'inventory.reprice_stockunit',
      ])) {
        capabilities.add(AppCapability.repriceStockUnit);
      }
      if (_hasAny(user, const [
        'write_off_stockunit',
        'inventory.write_off_stockunit',
      ])) {
        capabilities.add(AppCapability.writeOffStockUnit);
      }
      if (_hasAny(user, const [
        'apply_stockcount',
        'inventory.apply_stockcount',
      ])) {
        capabilities.add(AppCapability.applyStockCount);
      }
      // Warehouses. The page is the list, and the server answers the list for
      // view_warehouse alone, so only that opens it: adding, editing or
      // deleting a place grants its own button, never the page to put it on.
      if (_hasAny(user, const ['view_warehouse', 'inventory.view_warehouse'])) {
        capabilities.add(AppCapability.viewWarehouses);
      }
      if (_hasAny(user, const ['add_warehouse', 'inventory.add_warehouse'])) {
        capabilities.add(AppCapability.createWarehouse);
      }
      if (_hasAny(user, const [
        'change_warehouse',
        'inventory.change_warehouse',
      ])) {
        capabilities.add(AppCapability.changeWarehouse);
      }
      if (_hasAny(user, const [
        'delete_warehouse',
        'inventory.delete_warehouse',
      ])) {
        capabilities.add(AppCapability.deleteWarehouse);
      }
      if (_hasAny(user, const [
        'change_registerprofile',
        'sales.change_registerprofile',
      ])) {
        capabilities.add(AppCapability.changeRegisterWarehouse);
      }
      if (_hasAny(user, const [
        'view_stocktransfer',
        'inventory.view_stocktransfer',
      ])) {
        capabilities.add(AppCapability.viewStockTransfers);
      }
      // Both, as the composer needs both: it offers only what the source
      // actually holds, and that list is the stock endpoint, which answers to
      // view_stockitem. Without it every search is refused and the picker
      // reads as a place with nothing in it.
      if (_hasAny(user, const [
            'add_stocktransfer',
            'inventory.add_stocktransfer',
          ]) &&
          _hasAny(user, const ['view_stockitem', 'inventory.view_stockitem'])) {
        capabilities.add(AppCapability.createStockTransfer);
      }
      if (_hasAny(user, const [
        'dispatch_stocktransfer',
        'inventory.dispatch_stocktransfer',
      ])) {
        capabilities.add(AppCapability.dispatchStockTransfer);
      }
      if (_hasAny(user, const [
        'receive_stocktransfer',
        'inventory.receive_stocktransfer',
      ])) {
        capabilities.add(AppCapability.receiveStockTransfer);
      }
      if (_hasAny(user, const [
        'view_purchaseorder',
        'change_purchaseorder',
        'purchasing.view_purchaseorder',
        'purchasing.change_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewPurchasingDashboard)
          ..add(AppCapability.accessPurchasing);
      }
      if (_hasAny(user, const [
        'add_purchaseorder',
        'purchasing.add_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewPurchasingDashboard)
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.createPurchaseOrder);
      }
      // Deliberately grants NO purchasing-screen access: the POS quick cash
      // purchase is its own narrow capability, usable entirely from the sell
      // screen (mirrors how process_return_lookup stays out of invoices).
      if (_hasAny(user, const [
        'add_pos_cash_purchase',
        'purchasing.add_pos_cash_purchase',
      ])) {
        capabilities.add(AppCapability.createPosCashPurchase);
      }
      if (_hasAny(user, const [
        'edit_draft_purchaseorder',
        'purchasing.edit_draft_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.editDraftPurchaseOrder);
      }
      if (_hasAny(user, const [
        'receive_purchaseorder',
        'purchasing.receive_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.receivePurchaseOrder);
      }
      if (_hasAny(user, const [
        'adjust_received_purchaseorder',
        'purchasing.adjust_received_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.adjustPurchaseOrder);
      }
      if (_hasAny(user, const [
        'cancel_purchaseorder',
        'purchasing.cancel_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.cancelPurchaseOrder);
      }
      if (_hasAny(user, const [
        'delete_purchaseorder',
        'purchasing.delete_purchaseorder',
      ])) {
        capabilities
          ..add(AppCapability.accessPurchasing)
          ..add(AppCapability.deletePurchaseOrder);
      }
      // Money leaving the shop, so it rides its own right rather than access
      // to purchasing. It opens no screen: without reading purchase orders
      // there is no order to pay.
      if (_hasAny(user, const [
        'add_supplierpayment',
        'purchasing.add_supplierpayment',
      ])) {
        capabilities.add(AppCapability.recordSupplierPayment);
      }
      // Reading the contact book: every customer and supplier, and what each
      // one owes. Only the permission to *view* them opens it — and the
      // customer dashboard that totals those balances.
      if (_hasAny(user, const [
        'view_customer',
        'customers.view_customer',
        'view_supplier',
        'purchasing.view_supplier',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewCustomerDashboard)
          ..add(AppCapability.manageContacts);
      }
      // Registering a customer is not reading the book. A cashier given "add
      // customers" so the repair counter can take in a walk-in's phone used to
      // land on a dashboard of every customer's balance at the next sign-in
      // (field export, 2026-09-25). Adding, editing or deleting records grants
      // no screen of its own: without the view permission there is nothing to
      // edit or delete from.
      if (_hasAny(user, const ['add_customer', 'customers.add_customer'])) {
        capabilities.add(AppCapability.createCustomers);
      }
      if (_hasAny(user, const [
        'view_registersession',
        'sales.view_registersession',
      ])) {
        capabilities.add(AppCapability.viewRegisterSessions);
      }
      if (_hasAny(user, const ['view_order', 'sales.view_order'])) {
        capabilities
          ..add(AppCapability.viewInvoices)
          ..add(AppCapability.viewRegisterSessions)
          ..add(AppCapability.viewRegisterSessionOrders);
      }
      // Returns desk: look up a single invoice by number and return/exchange it
      // without browsing the full invoice list (a scoped, audited grant).
      if (_hasAny(user, const [
        'process_return_lookup',
        'sales.process_return_lookup',
      ])) {
        capabilities.add(AppCapability.processReturnsByLookup);
      }
      if (_hasAny(user, const ['add_order', 'sales.add_order'])) {
        capabilities
          ..add(AppCapability.accessPos)
          ..add(AppCapability.checkoutSale);
      }
      if (_hasAny(user, const [
        'add_registersession',
        'sales.add_registersession',
      ])) {
        capabilities
          ..add(AppCapability.accessPos)
          ..add(AppCapability.startRegisterSession)
          ..add(AppCapability.resumeRegisterSession);
      }
      if (_hasAny(user, const [
        'change_registersession',
        'sales.change_registersession',
      ])) {
        capabilities
          ..add(AppCapability.accessPos)
          ..add(AppCapability.closeRegisterSession);
      }
      if (_hasAny(user, const [
        'add_registercashmovement',
        'sales.add_registercashmovement',
      ])) {
        capabilities
          ..add(AppCapability.accessPos)
          ..add(AppCapability.createRegisterCashMovement);
      }
      // Revenue dashboards are reserved for reporting roles: holding the POS
      // permissions (view_payment, view_order) alone must not reveal shop-wide
      // cash totals to the person counting the drawer.
      if (_hasAny(user, const ['view_reportrun', 'reports.view_reportrun'])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewSalesDashboard)
          // Same permission the backend reads for `user_has_full_visibility`,
          // so what the UI offers and what the list returns agree.
          ..add(AppCapability.viewShopWideSales);
        if (_hasAny(user, const ['view_payment', 'payments.view_payment'])) {
          capabilities.add(AppCapability.viewPaymentDashboard);
        }
        if (_hasAny(user, const ['view_printjob', 'printing.view_printjob'])) {
          capabilities.add(AppCapability.viewPrintingDashboard);
        }
      }
      if (_hasAny(user, const ['view_employee', 'employees.view_employee'])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees);
      }
      if (_hasAny(user, const [
        'view_employeeloan',
        'employees.view_employeeloan',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees)
          ..add(AppCapability.viewEmployeeLoans);
      }
      if (_hasAny(user, const [
        'change_employeeloan',
        'approve_employeeloan',
        'reject_employeeloan',
        'employees.change_employeeloan',
        'employees.approve_employeeloan',
        'employees.reject_employeeloan',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees)
          ..add(AppCapability.viewEmployeeLoans)
          ..add(AppCapability.manageEmployeeLoans);
      }
      if (_hasAny(user, const [
        'add_employee',
        'change_employee',
        'delete_employee',
        'add_compensationplan',
        'change_compensationplan',
        'employees.add_employee',
        'employees.change_employee',
        'employees.delete_employee',
        'employees.add_compensationplan',
        'employees.change_compensationplan',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees)
          ..add(AppCapability.manageEmployees);
      }
      if (_hasAny(user, const [
        'view_payrollrun',
        'employees.view_payrollrun',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewPayroll);
      }
      if (_hasAny(user, const [
        'add_payrollrun',
        'change_payrollrun',
        'delete_payrollrun',
        'approve_payrollrun',
        'mark_payrollrun_paid',
        'void_payrollrun',
        'employees.add_payrollrun',
        'employees.change_payrollrun',
        'employees.delete_payrollrun',
        'employees.approve_payrollrun',
        'employees.mark_payrollrun_paid',
        'employees.void_payrollrun',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewEmployees)
          ..add(AppCapability.viewPayroll)
          ..add(AppCapability.managePayroll);
      }
      if (_hasAny(user, const [
        'add_user',
        'change_user',
        'delete_user',
        'view_user',
        'auth.add_user',
        'auth.change_user',
        'auth.delete_user',
        'auth.view_user',
      ])) {
        capabilities.add(AppCapability.manageUsers);
      }
      if (_hasAny(user, const [
        'change_shopsettings',
        'core.change_shopsettings',
      ])) {
        capabilities.add(AppCapability.manageShopSettings);
      }
      if (_hasAny(user, const [
        'change_saleschannel',
        'channels.change_saleschannel',
      ])) {
        capabilities.add(AppCapability.manageSalesChannels);
      }
      if (_hasAny(user, const [
        'view_pricecheckerdevice',
        'add_pricecheckerdevice',
        'change_pricecheckerdevice',
        'delete_pricecheckerdevice',
        'price_checker.view_pricecheckerdevice',
        'price_checker.add_pricecheckerdevice',
        'price_checker.change_pricecheckerdevice',
        'price_checker.delete_pricecheckerdevice',
      ])) {
        capabilities.add(AppCapability.managePriceCheckers);
      }
      if (_hasAny(user, const [
        'manage_gateways',
        'messaging.manage_gateways',
      ])) {
        capabilities.add(AppCapability.manageMessaging);
      }
      // Resale providers. Configuring one stores an agency credential that can
      // spend the shop's float, so it rides the manage right rather than the
      // general settings one — a cashier who may *use* an integration at the
      // till still has no business seeing its password field.
      if (_hasAny(user, const [
        'manage_integrations',
        'integrations.manage_integrations',
      ])) {
        capabilities.add(AppCapability.manageIntegrations);
      }
      // Selling a top-up is till work, so a cashier has it. Whether the button
      // appears at all is a separate question, answered by whether the shop
      // has actually connected a provider (ShopSettings.hasIntegrations).
      if (_hasAny(user, const [
        'use_integrations',
        'integrations.use_integrations',
      ])) {
        capabilities.add(AppCapability.useIntegrations);
      }
      // Recording money paid into a provider float. Its own right, because
      // the person who walks to the provider's office and pays is almost
      // never the one who configures the account — gating the record on
      // manage_integrations meant the only person who knew a top-up had
      // happened was the one who could not write it down.
      if (_hasAny(user, const [
        'record_integration_topup',
        'integrations.record_integration_topup',
      ])) {
        capabilities.add(AppCapability.recordIntegrationTopUp);
      }
      // Both, as the backend demands both: recording a website payment
      // issues an invoice, and issuing one is sales.add_order's to do.
      if (_hasAny(user, const [
            'record_portal_payment',
            'integrations.record_portal_payment',
          ]) &&
          _hasAny(user, const ['add_order', 'sales.add_order'])) {
        capabilities.add(AppCapability.recordPortalPayments);
      }
      // Cost at the till, and repricing a line there. Two rights on purpose:
      // knowing what a thing cost and deciding what it sells for are held by
      // different people in most shops.
      if (_hasAny(user, const ['view_till_cost', 'sales.view_till_cost'])) {
        capabilities.add(AppCapability.viewTillCost);
      }
      if (_hasAny(user, const [
        'override_line_price',
        'sales.override_line_price',
      ])) {
        capabilities.add(AppCapability.overrideLinePrice);
      }
      // Cameras. Watching, reviewing recordings and exporting a copy are three
      // different levels of trust, so they are three permissions — a floor
      // supervisor typically holds the first two and not the third.
      if (_hasAny(user, const ['view_camera', 'surveillance.view_camera'])) {
        capabilities.add(AppCapability.viewCameras);
      }
      if (_hasAny(user, const ['view_live', 'surveillance.view_live'])) {
        capabilities
          ..add(AppCapability.viewCameras)
          ..add(AppCapability.watchCamerasLive);
      }
      if (_hasAny(user, const [
        'view_playback',
        'surveillance.view_playback',
      ])) {
        capabilities
          ..add(AppCapability.viewCameras)
          ..add(AppCapability.reviewCameraPlayback);
      }
      if (_hasAny(user, const [
        'export_footage',
        'surveillance.export_footage',
      ])) {
        capabilities.add(AppCapability.exportCameraFootage);
      }
      if (_hasAny(user, const [
        'add_recorder',
        'change_recorder',
        'delete_recorder',
        'surveillance.add_recorder',
        'surveillance.change_recorder',
        'surveillance.delete_recorder',
      ])) {
        capabilities
          ..add(AppCapability.viewCameras)
          ..add(AppCapability.manageCameras);
      }
      // Sending prices to a scale changes what the shop's stickers say, so it
      // rides its own right rather than the general settings one. Setting a
      // scale up opens the same screen.
      if (_hasAny(user, const [
        'push_scale',
        'add_scale',
        'change_scale',
        'delete_scale',
        'scales.push_scale',
        'scales.add_scale',
        'scales.change_scale',
        'scales.delete_scale',
      ])) {
        capabilities.add(AppCapability.manageScales);
      }
      if (_hasAny(user, const [
        'view_conversations',
        'crm.view_conversations',
      ])) {
        capabilities.add(AppCapability.viewConversations);
      }
      if (_hasAny(user, const [
        'manage_conversations',
        'crm.manage_conversations',
      ])) {
        capabilities
          ..add(AppCapability.viewConversations)
          ..add(AppCapability.manageConversations);
      }
      if (_hasAny(user, const ['manage_campaigns', 'crm.manage_campaigns'])) {
        capabilities.add(AppCapability.manageCampaigns);
      }
      if (_hasAny(user, const ['send_campaigns', 'crm.send_campaigns'])) {
        capabilities
          ..add(AppCapability.manageCampaigns)
          ..add(AppCapability.sendCampaigns);
      }
      if (_hasAny(user, const [
        'view_attendanceday',
        'attendance.view_attendanceday',
      ])) {
        capabilities.add(AppCapability.viewAttendance);
      }
      if (_hasAny(user, const [
        'change_biotimeconnection',
        'attendance.change_biotimeconnection',
      ])) {
        capabilities
          ..add(AppCapability.viewAttendance)
          ..add(AppCapability.manageAttendance);
      }
      if (_hasAny(user, const ['view_job', 'operations.view_job'])) {
        capabilities.add(AppCapability.viewOperations);
      }
      if (_hasAny(user, const ['add_job', 'operations.add_job'])) {
        capabilities
          ..add(AppCapability.viewOperations)
          ..add(AppCapability.createJobs);
      }
      if (_hasAny(user, const ['change_job', 'operations.change_job'])) {
        capabilities
          ..add(AppCapability.viewOperations)
          ..add(AppCapability.changeJobs);
      }
      if (_hasAny(user, const ['assign_job', 'operations.assign_job'])) {
        capabilities
          ..add(AppCapability.viewOperations)
          ..add(AppCapability.assignJobs);
      }
      if (_hasAny(user, const ['reopen_job', 'operations.reopen_job'])) {
        capabilities
          ..add(AppCapability.viewOperations)
          ..add(AppCapability.reopenJobs);
      }
      // Handing a customer's property back before the job is settled. Managers
      // only, and the button only appears for someone who can actually do it —
      // offering an override that then 400s teaches staff to distrust the app.
      if (_hasAny(user, const [
        'release_unpaid_job',
        'operations.release_unpaid_job',
      ])) {
        capabilities.add(AppCapability.releaseUnpaidJobs);
      }
      if (_hasAny(user, const ['view_asset', 'customers.view_asset'])) {
        capabilities.add(AppCapability.viewAssets);
      }
      if (_hasAny(user, const ['change_asset', 'customers.change_asset'])) {
        capabilities
          ..add(AppCapability.viewAssets)
          ..add(AppCapability.manageAssets);
      }
      if (_hasAny(user, const [
        'add_jobmaterial',
        'operations.add_jobmaterial',
      ])) {
        capabilities.add(AppCapability.manageJobMaterials);
      }
      if (_hasAny(user, const [
        'change_workflowtemplate',
        'operations.change_workflowtemplate',
      ])) {
        capabilities.add(AppCapability.manageWorkflows);
      }
      if (_hasAny(user, const [
        'view_billofmaterials',
        'catalog.view_billofmaterials',
      ])) {
        capabilities.add(AppCapability.viewRecipes);
      }
      if (_hasAny(user, const [
        'add_billofmaterials',
        'change_billofmaterials',
        'delete_billofmaterials',
        'catalog.add_billofmaterials',
        'catalog.change_billofmaterials',
        'catalog.delete_billofmaterials',
      ])) {
        capabilities
          ..add(AppCapability.viewRecipes)
          ..add(AppCapability.manageRecipes);
      }
      if (_hasAny(user, const [
        'view_prepstation',
        'printing.view_prepstation',
      ])) {
        capabilities.add(AppCapability.viewPrepStations);
      }
      if (_hasAny(user, const [
        'view_discountrule',
        'discounts.view_discountrule',
        'view_reportrun',
        'reports.view_reportrun',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewDiscountDashboard)
          ..add(AppCapability.viewDiscountRules);
      }
      if (_hasAny(user, const [
        'add_discountrule',
        'discounts.add_discountrule',
      ])) {
        capabilities
          ..add(AppCapability.viewDiscountRules)
          ..add(AppCapability.createDiscountRule);
      }
      if (_hasAny(user, const [
        'change_discountrule',
        'discounts.change_discountrule',
      ])) {
        capabilities
          ..add(AppCapability.viewDiscountRules)
          ..add(AppCapability.changeDiscountRule);
      }
      if (_hasAny(user, const [
        'delete_discountrule',
        'discounts.delete_discountrule',
      ])) {
        capabilities
          ..add(AppCapability.viewDiscountRules)
          ..add(AppCapability.deleteDiscountRule);
      }
      if (_hasAny(user, const [
        'view_analyticsevent',
        'analytics.view_analyticsevent',
      ])) {
        capabilities
          ..add(AppCapability.viewDashboard)
          ..add(AppCapability.viewActivityLog);
      }
      if (_hasAny(user, const [
        'view_fraudfinding',
        'fraud.view_fraudfinding',
      ])) {
        capabilities.add(AppCapability.viewFraudFindings);
      }
      if (_hasAny(user, const ['view_expense', 'expenses.view_expense'])) {
        capabilities.add(AppCapability.viewExpenses);
      }
      // The payments ledger shows both money-IN (customer payments) and
      // money-OUT (supplier payments); gate it on the customer payment view
      // perm, the primary money ledger. It does not open الخزينة — that is the
      // money position, on viewMoneyAccounts below — because every cashier
      // holds this one for the till.
      if (_hasAny(user, const ['view_payment', 'payments.view_payment'])) {
        capabilities.add(AppCapability.viewPayments);
      }
      if (_hasAny(user, const [
        'view_moneyaccount',
        'treasury.view_moneyaccount',
      ])) {
        capabilities.add(AppCapability.viewMoneyAccounts);
      }
      // Each treasury button asks for exactly what the server will. None of
      // them opens the screen: its balances need the view permission above.
      if (_hasAny(user, const [
        'add_moneyaccount',
        'treasury.add_moneyaccount',
      ])) {
        capabilities.add(AppCapability.createMoneyAccount);
      }
      if (_hasAny(user, const [
        'change_moneyaccount',
        'treasury.change_moneyaccount',
      ])) {
        capabilities.add(AppCapability.changeMoneyAccount);
      }
      if (_hasAny(user, const [
        'add_moneytransfer',
        'treasury.add_moneytransfer',
      ])) {
        capabilities.add(AppCapability.recordMoneyTransfer);
      }
      if (_hasAny(user, const ['add_moneycount', 'treasury.add_moneycount'])) {
        capabilities.add(AppCapability.recordMoneyCount);
      }
      // Reading a rate is not the same as trading in one: an accountant costing
      // imports holds this without any of the dashboard's revenue permissions,
      // so it grants the rates band and nothing else.
      if (_hasAny(user, const ['view_exchangerate', 'fx.view_exchangerate'])) {
        capabilities.add(AppCapability.viewExchangeRates);
      }
      if (_hasAny(user, const [
        'add_expense',
        'change_expense',
        'delete_expense',
        'expenses.add_expense',
        'expenses.change_expense',
        'expenses.delete_expense',
      ])) {
        capabilities
          ..add(AppCapability.viewExpenses)
          ..add(AppCapability.manageExpenses);
      }
      if (_hasAny(user, const [
        'add_expensecategory',
        'expenses.add_expensecategory',
      ])) {
        capabilities.add(AppCapability.createExpenseCategory);
      }
      if (_hasAny(user, const [
        'change_expensecategory',
        'expenses.change_expensecategory',
      ])) {
        capabilities.add(AppCapability.changeExpenseCategory);
      }
      if (_hasAny(user, const [
        'delete_expensecategory',
        'expenses.delete_expensecategory',
      ])) {
        capabilities.add(AppCapability.deleteExpenseCategory);
      }
      if (_hasAny(user, const [
        'change_fraudfinding',
        'fraud.change_fraudfinding',
      ])) {
        capabilities
          ..add(AppCapability.viewFraudFindings)
          ..add(AppCapability.manageFraudFindings);
      }
      if (_hasAny(user, const [
        'view_reportrun',
        'reports.view_reportrun',
        'view_order',
        'sales.view_order',
        'view_registersession',
        'sales.view_registersession',
        'view_payment',
        'payments.view_payment',
        'view_stockitem',
        'inventory.view_stockitem',
        'view_stockmovement',
        'inventory.view_stockmovement',
        'view_purchaseorder',
        'purchasing.view_purchaseorder',
        'view_customer',
        'customers.view_customer',
        'view_supplier',
        'purchasing.view_supplier',
        'view_discountrule',
        'discounts.view_discountrule',
      ])) {
        capabilities.add(AppCapability.viewReports);
      }
    }

    if (user.aiAvailable) {
      capabilities.add(AppCapability.useAiAssistant);
    }

    // Held permissions do not conjure cameras: a shop with no recorder shows no
    // camera surface to anyone, whatever they are allowed to do once there is
    // one. Applied last so it wins over every grant above.
    if (!user.surveillanceEnabled) {
      capabilities.removeAll(_surveillanceCapabilities);
    }
    // Held permissions do not conjure the feature either: the roles grant
    // view_stockunit to every cashier, which is right once a shop identifies
    // its stock and wrong for every shop that does not.
    capabilities.removeAll(_trackingCapabilitiesOff(user));

    return AuthorizationCapabilities._(capabilities);
  }

  final Set<AppCapability> _capabilities;

  bool allows(AppCapability capability) => _capabilities.contains(capability);

  /// What may be done to one particular product: these capabilities, less
  /// every way of changing it when it is a *system* product — one a feature
  /// owns and writes (a recharge service product, a provider's card). The
  /// server refuses those writes for every role, managers included; this is
  /// what keeps the buttons from being offered in the first place.
  AuthorizationCapabilities forProduct({required bool isSystem}) {
    if (!isSystem) {
      return this;
    }
    return AuthorizationCapabilities._(
      Set.of(_capabilities)..removeAll(const {
        AppCapability.changeProduct,
        AppCapability.createProductVariant,
        AppCapability.changeProductVariant,
        AppCapability.createStockMovement,
      }),
    );
  }

  bool get canCollectCustomerDebt => allows(AppCapability.collectCustomerDebt);

  bool get canViewDashboard => allows(AppCapability.viewDashboard);
  bool get canViewExchangeRates => allows(AppCapability.viewExchangeRates);
  bool get canViewSalesDashboard => allows(AppCapability.viewSalesDashboard);
  bool get canViewPaymentDashboard =>
      allows(AppCapability.viewPaymentDashboard);
  bool get canViewInventoryDashboard =>
      allows(AppCapability.viewInventoryDashboard);
  bool get canViewPurchasingDashboard =>
      allows(AppCapability.viewPurchasingDashboard);
  bool get canViewCustomerDashboard =>
      allows(AppCapability.viewCustomerDashboard);
  bool get canViewDiscountDashboard =>
      allows(AppCapability.viewDiscountDashboard);
  bool get canViewPrintingDashboard =>
      allows(AppCapability.viewPrintingDashboard);
  bool get canViewReports => allows(AppCapability.viewReports);
  bool get canViewShopWideSales => allows(AppCapability.viewShopWideSales);
  bool get canViewActivityLog => allows(AppCapability.viewActivityLog);
  bool get canViewFraudFindings => allows(AppCapability.viewFraudFindings);
  bool get canManageFraudFindings => allows(AppCapability.manageFraudFindings);
  bool get canViewEmployees => allows(AppCapability.viewEmployees);
  bool get canManageEmployees => allows(AppCapability.manageEmployees);
  bool get canManageOwnAccount => allows(AppCapability.manageOwnAccount);
  bool get canViewEmployeeLoans => allows(AppCapability.viewEmployeeLoans);
  bool get canManageEmployeeLoans => allows(AppCapability.manageEmployeeLoans);
  bool get canViewPayroll => allows(AppCapability.viewPayroll);
  bool get canManagePayroll => allows(AppCapability.managePayroll);
  bool get canViewAttendance => allows(AppCapability.viewAttendance);
  bool get canManageAttendance => allows(AppCapability.manageAttendance);
  bool get canAccessPos => allows(AppCapability.accessPos);
  bool get canViewInvoices => allows(AppCapability.viewInvoices);
  bool get canProcessReturnsByLookup =>
      allows(AppCapability.processReturnsByLookup);
  bool get canAccessPurchasing => allows(AppCapability.accessPurchasing);
  bool get canCreatePurchaseOrder => allows(AppCapability.createPurchaseOrder);
  bool get canEditDraftPurchaseOrder =>
      allows(AppCapability.editDraftPurchaseOrder);
  bool get canReceivePurchaseOrder =>
      allows(AppCapability.receivePurchaseOrder);
  bool get canAdjustPurchaseOrder => allows(AppCapability.adjustPurchaseOrder);
  bool get canCancelPurchaseOrder => allows(AppCapability.cancelPurchaseOrder);
  bool get canDeletePurchaseOrder => allows(AppCapability.deletePurchaseOrder);
  bool get canRecordSupplierPayment =>
      allows(AppCapability.recordSupplierPayment);
  bool get canManageContacts => allows(AppCapability.manageContacts);
  bool get canCreateCustomers => allows(AppCapability.createCustomers);
  bool get canCheckoutSale => allows(AppCapability.checkoutSale);
  bool get canStartRegisterSession =>
      allows(AppCapability.startRegisterSession);
  bool get canResumeRegisterSession =>
      allows(AppCapability.resumeRegisterSession);
  bool get canCloseRegisterSession =>
      allows(AppCapability.closeRegisterSession);
  bool get canCreateRegisterCashMovement =>
      allows(AppCapability.createRegisterCashMovement);
  bool get canCreatePosCashPurchase =>
      allows(AppCapability.createPosCashPurchase);
  bool get canViewCatalogManagement =>
      allows(AppCapability.viewCatalogManagement);
  bool get canManageCategories => allows(AppCapability.manageCategories);
  bool get canCreateProduct => allows(AppCapability.createProduct);
  bool get canChangeProduct => allows(AppCapability.changeProduct);
  bool get canCreateProductVariant =>
      allows(AppCapability.createProductVariant);
  bool get canChangeProductVariant =>
      allows(AppCapability.changeProductVariant);
  bool get canViewRegisterSessions =>
      allows(AppCapability.viewRegisterSessions);
  bool get canViewRegisterSessionOrders =>
      allows(AppCapability.viewRegisterSessionOrders);
  bool get canManageDeviceSettings =>
      allows(AppCapability.manageDeviceSettings);
  bool get canManageUsers => allows(AppCapability.manageUsers);
  bool get canManageShopSettings => allows(AppCapability.manageShopSettings);
  bool get canManageSalesChannels => allows(AppCapability.manageSalesChannels);
  bool get canManagePriceCheckers => allows(AppCapability.managePriceCheckers);
  bool get canViewCameras => allows(AppCapability.viewCameras);
  bool get canWatchCamerasLive => allows(AppCapability.watchCamerasLive);
  bool get canReviewCameraPlayback =>
      allows(AppCapability.reviewCameraPlayback);
  bool get canExportCameraFootage => allows(AppCapability.exportCameraFootage);
  bool get canManageCameras => allows(AppCapability.manageCameras);
  bool get canManageScales => allows(AppCapability.manageScales);
  bool get canManageMessaging => allows(AppCapability.manageMessaging);
  bool get canManageIntegrations => allows(AppCapability.manageIntegrations);
  bool get canUseIntegrations => allows(AppCapability.useIntegrations);
  bool get canRecordIntegrationTopUp =>
      allows(AppCapability.recordIntegrationTopUp);
  bool get canRecordPortalPayments =>
      allows(AppCapability.recordPortalPayments);
  bool get canViewConversations => allows(AppCapability.viewConversations);
  bool get canViewTillCost => allows(AppCapability.viewTillCost);
  bool get canOverrideLinePrice => allows(AppCapability.overrideLinePrice);
  bool get canManageConversations => allows(AppCapability.manageConversations);
  bool get canManageCampaigns => allows(AppCapability.manageCampaigns);
  bool get canSendCampaigns => allows(AppCapability.sendCampaigns);
  bool get canViewExpenses => allows(AppCapability.viewExpenses);
  bool get canManageExpenses => allows(AppCapability.manageExpenses);
  bool get canCreateExpenseCategory =>
      allows(AppCapability.createExpenseCategory);
  bool get canChangeExpenseCategory =>
      allows(AppCapability.changeExpenseCategory);
  bool get canDeleteExpenseCategory =>
      allows(AppCapability.deleteExpenseCategory);
  bool get canViewPayments => allows(AppCapability.viewPayments);
  bool get canViewMoneyAccounts => allows(AppCapability.viewMoneyAccounts);
  bool get canCreateMoneyAccount => allows(AppCapability.createMoneyAccount);
  bool get canChangeMoneyAccount => allows(AppCapability.changeMoneyAccount);
  bool get canRecordMoneyTransfer => allows(AppCapability.recordMoneyTransfer);
  bool get canRecordMoneyCount => allows(AppCapability.recordMoneyCount);
  bool get canViewOperations => allows(AppCapability.viewOperations);
  bool get canCreateJobs => allows(AppCapability.createJobs);
  bool get canChangeJobs => allows(AppCapability.changeJobs);
  bool get canAssignJobs => allows(AppCapability.assignJobs);
  bool get canReopenJobs => allows(AppCapability.reopenJobs);
  bool get canReleaseUnpaidJobs => allows(AppCapability.releaseUnpaidJobs);
  bool get canViewAssets => allows(AppCapability.viewAssets);
  bool get canManageAssets => allows(AppCapability.manageAssets);
  bool get canManageJobMaterials => allows(AppCapability.manageJobMaterials);
  bool get canManageWorkflows => allows(AppCapability.manageWorkflows);
  bool get canManageRecipes => allows(AppCapability.manageRecipes);

  /// Whether `boms/` and `prep-stations/` may be requested at all.
  ///
  /// Gate the *call*, not the response. A cashier client was polling both — 278
  /// and 63 requests answered 403 — and a 403 costs a round trip, a
  /// permission check, a 5xx-tracking row and a log line before it says no.
  bool get canViewRecipes => allows(AppCapability.viewRecipes);
  bool get canViewPrepStations => allows(AppCapability.viewPrepStations);
  bool get canViewDiscountRules => allows(AppCapability.viewDiscountRules);
  bool get canCreateDiscountRule => allows(AppCapability.createDiscountRule);
  bool get canChangeDiscountRule => allows(AppCapability.changeDiscountRule);
  bool get canDeleteDiscountRule => allows(AppCapability.deleteDiscountRule);
  bool get canViewStock => allows(AppCapability.viewStock);
  bool get canViewStockUnits => allows(AppCapability.viewStockUnits);
  bool get canViewStockBatches => allows(AppCapability.viewStockBatches);
  bool get canViewConsignmentPayables =>
      allows(AppCapability.viewConsignmentPayables);
  bool get canDisburseConsignmentPayout =>
      allows(AppCapability.disburseConsignmentPayout);
  bool get canManageConsignmentAgreement =>
      allows(AppCapability.manageConsignmentAgreement);
  bool get canQuarantineBatch => allows(AppCapability.quarantineBatch);
  bool get canManageConsignmentIncident =>
      allows(AppCapability.manageConsignmentIncident);
  bool get canRepriceStockUnit => allows(AppCapability.repriceStockUnit);
  bool get canWriteOffStockUnit => allows(AppCapability.writeOffStockUnit);
  bool get canCreateStockMovement => allows(AppCapability.createStockMovement);
  bool get canCountStock => allows(AppCapability.countStock);
  bool get canApplyStockCount => allows(AppCapability.applyStockCount);
  bool get canViewWarehouses => allows(AppCapability.viewWarehouses);
  bool get canCreateWarehouse => allows(AppCapability.createWarehouse);
  bool get canChangeWarehouse => allows(AppCapability.changeWarehouse);
  bool get canDeleteWarehouse => allows(AppCapability.deleteWarehouse);
  bool get canChangeRegisterWarehouse =>
      allows(AppCapability.changeRegisterWarehouse);
  bool get canViewStockTransfers => allows(AppCapability.viewStockTransfers);
  bool get canCreateStockTransfer => allows(AppCapability.createStockTransfer);
  bool get canDispatchStockTransfer =>
      allows(AppCapability.dispatchStockTransfer);
  bool get canReceiveStockTransfer =>
      allows(AppCapability.receiveStockTransfer);

  AuthorizedAction? actionFor(
    AppCapability capability,
    AuthorizedAction action,
  ) {
    return allows(capability) ? action : null;
  }

  AuthorizedAsyncAction? asyncActionFor(
    AppCapability capability,
    AuthorizedAsyncAction action,
  ) {
    return allows(capability) ? action : null;
  }

  static bool _hasAny(PosUser user, Iterable<String> permissions) {
    return permissions.any(user.permissions.contains);
  }
}
