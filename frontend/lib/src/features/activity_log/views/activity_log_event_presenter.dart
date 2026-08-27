import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/analytics_event.dart';

enum ActivityLogDrillDownType { saleOrder, purchaseOrder }

class ActivityLogDrillDownTarget {
  const ActivityLogDrillDownTarget({required this.type, required this.id});

  final ActivityLogDrillDownType type;
  final int id;
}

class ActivityEventPresentation {
  const ActivityEventPresentation({
    required this.title,
    required this.summary,
    required this.icon,
  });

  final String title;
  final String summary;
  final IconData icon;
}

ActivityEventPresentation activityEventPresentation(
  AppLocalizations l10n,
  AnalyticsEventRecord event,
) {
  final target = activityLogDrillDownTarget(event);
  final knownTitle = _knownEventTitle(l10n, event.name, event);
  if (knownTitle != null) {
    return ActivityEventPresentation(
      title: knownTitle,
      summary: _businessSummary(l10n, event),
      icon: _businessEventIcon(event, target),
    );
  }

  if (event.name == 'backend.request' ||
      event.name == 'backend.response_error' ||
      event.name == 'backend.exception') {
    return ActivityEventPresentation(
      title: _requestTitle(l10n, event),
      summary: _requestSummary(l10n, event),
      icon: event.name == 'backend.exception'
          ? Icons.error_outline
          : Icons.cloud_sync_outlined,
    );
  }

  if (event.name == 'frontend.interaction') {
    return ActivityEventPresentation(
      title: _interactionTitle(l10n, event),
      summary: _interactionSummary(l10n, event),
      icon: Icons.touch_app_outlined,
    );
  }

  if (event.name == 'frontend.http_request') {
    return ActivityEventPresentation(
      title: _requestTitle(l10n, event),
      summary: _requestSummary(l10n, event),
      icon: Icons.sync_alt_outlined,
    );
  }

  return ActivityEventPresentation(
    title: l10n.activityEventUnknownTitle(event.name),
    summary: _businessSummary(l10n, event),
    icon: _businessEventIcon(event, target),
  );
}

ActivityLogDrillDownTarget? activityLogDrillDownTarget(
  AnalyticsEventRecord event,
) {
  final entityId = _intValue(event.entityId);
  if (event.entityType == 'sale_order' && entityId != null) {
    return ActivityLogDrillDownTarget(
      type: ActivityLogDrillDownType.saleOrder,
      id: entityId,
    );
  }
  if (event.entityType == 'purchase_order' && entityId != null) {
    return ActivityLogDrillDownTarget(
      type: ActivityLogDrillDownType.purchaseOrder,
      id: entityId,
    );
  }
  return null;
}

String activityLogDrillDownLabel(
  AppLocalizations l10n,
  ActivityLogDrillDownTarget target,
) {
  return switch (target.type) {
    ActivityLogDrillDownType.saleOrder => l10n.activityLogOpenInvoice,
    ActivityLogDrillDownType.purchaseOrder => l10n.activityLogOpenPurchaseOrder,
  };
}

IconData activityLogDrillDownIcon(ActivityLogDrillDownTarget target) {
  return switch (target.type) {
    ActivityLogDrillDownType.saleOrder => Icons.receipt_long_outlined,
    ActivityLogDrillDownType.purchaseOrder => Icons.add_shopping_cart_outlined,
  };
}

/// Which way a settled quantity run moved. Falls back to "decrease" only when
/// the attribute is missing, which is the pre-coalescing shape.
bool _quantityDirectionIsIncrease(AnalyticsEventRecord event) {
  return event.attributes['direction']?.toString() == 'increase';
}

String? _knownEventTitle(
  AppLocalizations l10n,
  String name,
  AnalyticsEventRecord event,
) {
  // A +/- run is one event now, carrying the direction it moved rather than
  // splitting into two names. The wording is unchanged for the reader.
  if (name == 'pos.cart.line.quantity_settled') {
    return _quantityDirectionIsIncrease(event)
        ? l10n.activityEventPosLineQuantityIncreased
        : l10n.activityEventPosLineQuantityDecreased;
  }
  return switch (name) {
    'sales.checkout.completed' => l10n.activityEventCheckoutCompleted,
    'sales.order.paid' => l10n.activityEventOrderPaid,
    'sales.order.voided' => l10n.activityEventOrderVoided,
    'sales.order.returned' => l10n.activityEventOrderReturned,
    'sales.receipt.reprint.queued' => l10n.activityEventReceiptReprintQueued,
    'sales.receipt.reprint.failed' => l10n.activityEventReceiptReprintFailed,
    'sales.register_session.started' =>
      l10n.activityEventRegisterSessionStarted,
    'sales.register_session.closed' => l10n.activityEventRegisterSessionClosed,
    'sales.register_cash_movement.created' =>
      l10n.activityEventRegisterCashMovementCreated,
    'sales_history.session.selected' =>
      l10n.activityEventSalesHistorySessionSelected,
    'sales_history.order_void.completed' =>
      l10n.activityEventSalesHistoryOrderVoidCompleted,
    'sales_history.order_return.completed' =>
      l10n.activityEventSalesHistoryOrderReturnCompleted,
    'pos.register_session.started' => l10n.activityEventRegisterSessionStarted,
    'pos.register_session.resumed' => l10n.activityEventRegisterSessionResumed,
    'pos.register_session.closed' => l10n.activityEventRegisterSessionClosed,
    'pos.register_cash_movement.created' =>
      l10n.activityEventRegisterCashMovementCreated,
    'pos.cart.line.added' => l10n.activityEventPosLineAdded,
    'pos.cart.line.quantity_increased' =>
      l10n.activityEventPosLineQuantityIncreased,
    'pos.cart.line.quantity_decreased' =>
      l10n.activityEventPosLineQuantityDecreased,
    'pos.cart.line.deleted' => l10n.activityEventPosLineDeleted,
    'pos.cart.cleared' => l10n.activityEventPosCartCleared,
    'pos.checkout.started' => l10n.activityEventPosCheckoutStarted,
    'pos.checkout.completed' => l10n.activityEventPosCheckoutCompleted,
    'pos.checkout.failed' => l10n.activityEventPosCheckoutFailed,
    'pos.checkout.stock_rejected' => l10n.activityEventPosCheckoutStockRejected,
    'purchasing.draft.line.added' => l10n.activityEventPurchaseLineAdded,
    'purchasing.draft.line.quantity_increased' =>
      l10n.activityEventPurchaseLineQuantityIncreased,
    'purchasing.draft.line.quantity_decreased' =>
      l10n.activityEventPurchaseLineQuantityDecreased,
    'purchasing.draft.line.deleted' => l10n.activityEventPurchaseLineDeleted,
    'purchasing.draft.cleared' => l10n.activityEventPurchaseDraftCleared,
    'purchasing.draft.supplier.selected' =>
      l10n.activityEventPurchaseSupplierSelected,
    'purchasing.draft.submitted' => l10n.activityEventPurchaseDraftSubmitted,
    'purchasing.draft.submit_failed' =>
      l10n.activityEventPurchaseDraftSubmitFailed,
    'purchasing.purchase_order.created' =>
      l10n.activityEventPurchaseOrderCreated,
    'purchasing.purchase_order.updated' =>
      l10n.activityEventPurchaseOrderUpdated,
    'purchasing.purchase_order.submitted' =>
      l10n.activityEventPurchaseOrderSubmitted,
    'purchasing.purchase_order.received' =>
      l10n.activityEventPurchaseOrderReceived,
    'purchasing.purchase_order.adjusted' =>
      l10n.activityEventPurchaseOrderAdjusted,
    'purchasing.purchase_order.cancelled' =>
      l10n.activityEventPurchaseOrderCancelled,
    'purchasing.purchase_order.deleted' =>
      l10n.activityEventPurchaseOrderDeleted,
    'customers.customer.created' => l10n.activityEventCustomerCreated,
    'customers.customer.updated' => l10n.activityEventCustomerUpdated,
    'customers.customer.deleted' => l10n.activityEventCustomerDeleted,
    'catalog.product.created' => l10n.activityEventCatalogProductCreated,
    'catalog.product.updated' => l10n.activityEventCatalogProductUpdated,
    'catalog.product.image_uploaded' =>
      l10n.activityEventCatalogProductImageUploaded,
    'catalog.product.image_imported' =>
      l10n.activityEventCatalogProductImageImported,
    'catalog.product_variant.created' =>
      l10n.activityEventCatalogVariantCreated,
    'catalog.product_variant.updated' =>
      l10n.activityEventCatalogVariantUpdated,
    'catalog.product.variants_generated' =>
      l10n.activityEventCatalogVariantsGenerated,
    'catalog.category.created' => l10n.activityEventCatalogCategoryCreated,
    'catalog.stock_movement.created' => l10n.activityEventStockMovementCreated,
    'inventory.manual_movement.created' =>
      l10n.activityEventStockMovementCreated,
    'inventory.manual_movement.create_failed' =>
      l10n.activityEventStockMovementCreateFailed,
    'users.user.created' => l10n.activityEventUserCreated,
    'users.user.updated' => l10n.activityEventUserUpdated,
    'users.user.deleted' => l10n.activityEventUserDeleted,
    'users.management.user.created' => l10n.activityEventUserCreated,
    'users.management.user.role_changed' => l10n.activityEventUserRoleChanged,
    'users.management.user.active_changed' =>
      l10n.activityEventUserActiveChanged,
    'settings.shop.updated' => l10n.activityEventShopSettingsUpdated,
    'settings.shop.logo_uploaded' => l10n.activityEventShopLogoUploaded,
    'settings.shop.logo_removed' => l10n.activityEventShopLogoRemoved,
    'settings.shop.form_saved' => l10n.activityEventShopSettingsUpdated,
    'settings.shop.logo_upload.completed' => l10n.activityEventShopLogoUploaded,
    'settings.shop.logo_remove.completed' => l10n.activityEventShopLogoRemoved,
    'settings.device.usage_mode_changed' =>
      l10n.activityEventDeviceUsageModeChanged,
    'discounts.rule.created' => l10n.activityEventDiscountRuleCreated,
    'discounts.rule.updated' => l10n.activityEventDiscountRuleUpdated,
    'discounts.rule.enabled' => l10n.activityEventDiscountRuleEnabled,
    'discounts.rule.disabled' => l10n.activityEventDiscountRuleDisabled,
    'discounts.rule.archived' => l10n.activityEventDiscountRuleArchived,
    'discounts.management.rule.created' =>
      l10n.activityEventDiscountRuleCreated,
    'discounts.management.rule.updated' =>
      l10n.activityEventDiscountRuleUpdated,
    'discounts.management.rule.enabled' =>
      l10n.activityEventDiscountRuleEnabled,
    'discounts.management.rule.disabled' =>
      l10n.activityEventDiscountRuleDisabled,
    'discounts.management.rule.archived' =>
      l10n.activityEventDiscountRuleArchived,
    'printing.barcode_labels.printed' => l10n.activityEventBarcodeLabelsPrinted,
    'printing.barcode_labels.failed' => l10n.activityEventBarcodeLabelsFailed,
    'printing.printer.discovery_completed' =>
      l10n.activityEventPrinterDiscoveryCompleted,
    'printing.printer.discovery_failed' =>
      l10n.activityEventPrinterDiscoveryFailed,
    'printing.printer.tested' => l10n.activityEventPrinterTested,
    'printing.printer.fake_receipt_printed' =>
      l10n.activityEventPrinterFakeReceiptPrinted,
    'app.flutter_error' => l10n.activityEventAppFlutterError,
    'app.platform_error' => l10n.activityEventAppPlatformError,
    'auth.session_started' => l10n.activityEventAuthSessionStarted,
    'auth.login.succeeded' => l10n.activityEventLoginSucceeded,
    'auth.login.failed' => l10n.activityEventLoginFailed,
    'auth.logout' => l10n.activityEventLogout,
    'analytics.export.started' => l10n.activityEventAnalyticsExportStarted,
    'analytics.export.completed' => l10n.activityEventAnalyticsExportCompleted,
    'analytics.export.failed' => l10n.activityEventAnalyticsExportFailed,
    'analytics.export.downloaded' =>
      l10n.activityEventAnalyticsExportDownloaded,
    'analytics.export.download_failed' =>
      l10n.activityEventAnalyticsExportDownloadFailed,
    'report.generated' => l10n.activityEventReportGenerated,
    'report.generation_failed' => l10n.activityEventReportGenerationFailed,
    'report.previewed' => l10n.activityEventReportPreviewed,
    'report.printed' => l10n.activityEventReportPrinted,
    'report.shared' => l10n.activityEventReportShared,
    'reports.run.completed' => l10n.activityEventReportRunCompleted,
    'reports.run.failed' => l10n.activityEventReportRunFailed,
    'fraud.suspected_activity.detected' =>
      l10n.activityEventSuspectedActivityDetected,
    _ => null,
  };
}

String _businessSummary(AppLocalizations l10n, AnalyticsEventRecord event) {
  final values = <String>[
    if (_stringAttribute(event, 'product_name').isNotEmpty)
      l10n.activityLogProductSummary(
        _productDisplayName(event),
        _quantityValue(event).toString(),
      ),
    if (_stringAttribute(event, 'receipt_number').isNotEmpty)
      l10n.saleReceiptTitle(_stringAttribute(event, 'receipt_number')),
    if (_stringAttribute(event, 'order_number').isNotEmpty)
      l10n.purchaseOrderNumberValue(_stringAttribute(event, 'order_number')),
    if (_stringAttribute(event, 'supplier_name').isNotEmpty)
      l10n.activityLogSupplierSummary(_stringAttribute(event, 'supplier_name')),
    if (_stringAttribute(event, 'target_user_label').isNotEmpty)
      l10n.activityLogUserSummary(_stringAttribute(event, 'target_user_label')),
    if (_stringAttribute(event, 'discount_rule_name').isNotEmpty)
      l10n.activityLogDiscountRuleSummary(
        _stringAttribute(event, 'discount_rule_name'),
      ),
    if (_stringAttribute(event, 'report_type').isNotEmpty)
      l10n.activityLogReportSummary(_stringAttribute(event, 'report_type')),
    if (_stringAttribute(event, 'movement_type').isNotEmpty)
      l10n.activityLogMovementTypeSummary(
        _stringAttribute(event, 'movement_type'),
      ),
    if (_stringAttribute(event, 'source').isNotEmpty)
      l10n.activityLogUiSourceSummary(
        _uiSourceLabel(l10n, _stringAttribute(event, 'source')),
      ),
    if (event.registerSessionReference.isNotEmpty)
      l10n.activityLogSessionSummary(event.registerSessionReference),
    if (_metric(event, 'total') != null)
      l10n.activityLogTotalSummary(_metric(event, 'total')!.toStringAsFixed(2)),
    if (_metric(event, 'cart_total') != null)
      l10n.activityLogCartTotalSummary(
        _metric(event, 'cart_total')!.toStringAsFixed(2),
      ),
    if (_metric(event, 'draft_total') != null)
      l10n.activityLogDraftTotalSummary(
        _metric(event, 'draft_total')!.toStringAsFixed(2),
      ),
    if (_lineCount(event) != null) l10n.lineItemCount(_lineCount(event)!),
    if (_stringAttribute(event, 'reason').isNotEmpty)
      l10n.activityLogReasonSummary(_stringAttribute(event, 'reason')),
    if (event.name.startsWith('fraud.') &&
        _stringAttribute(event, 'rule_code').isNotEmpty)
      l10n.activityLogSuspicionRuleSummary(
        _stringAttribute(event, 'rule_code'),
      ),
  ];
  return values.join(' - ');
}

String _requestTitle(AppLocalizations l10n, AnalyticsEventRecord event) {
  return l10n.activityBackendRequestTitle(
    _methodLabel(l10n, _requestMethod(event)),
    _requestTargetLabel(l10n, event),
  );
}

String _requestSummary(AppLocalizations l10n, AnalyticsEventRecord event) {
  final status = _metric(event, 'status_code')?.round();
  final path = _requestPath(event);
  final method = _requestMethod(event);
  if (status == null) {
    return l10n.activityLogMethodPathSummary(method, path);
  }
  return l10n.activityLogRequestSummary(method, path, status);
}

String _interactionTitle(AppLocalizations l10n, AnalyticsEventRecord event) {
  return l10n.activityFrontendInteractionTitle(
    _interactionActionLabel(l10n, _stringAttribute(event, 'action')),
    _interactionTargetLabel(l10n, event),
  );
}

String _interactionSummary(AppLocalizations l10n, AnalyticsEventRecord event) {
  final action = _stringAttribute(event, 'action');
  final target = _stringAttribute(event, 'target');
  if (action.isEmpty && target.isEmpty) {
    return l10n.activityLogNoSummary;
  }
  return l10n.activityLogInteractionSummary(
    action.isEmpty ? l10n.activityLogMissingValue : action,
    target.isEmpty ? l10n.activityLogMissingValue : target,
  );
}

String _methodLabel(AppLocalizations l10n, String method) {
  return switch (method) {
    'GET' => l10n.activityRequestMethodGet,
    'POST' => l10n.activityRequestMethodPost,
    'PUT' || 'PATCH' => l10n.activityRequestMethodPatch,
    'DELETE' => l10n.activityRequestMethodDelete,
    _ => l10n.activityRequestMethodOther,
  };
}

String _requestTargetLabel(AppLocalizations l10n, AnalyticsEventRecord event) {
  final path = _requestPath(event);
  if (path.contains('/analytics-events')) {
    return l10n.activityTargetActivityLog;
  }
  if (path.contains('/users')) {
    return l10n.activityTargetUsers;
  }
  if (path.contains('/orders/checkout')) {
    return l10n.activityTargetCheckout;
  }
  if (path.contains('/orders')) {
    return l10n.activityTargetInvoices;
  }
  if (path.contains('/purchase-orders')) {
    return l10n.activityTargetPurchaseOrders;
  }
  if (path.contains('/customers')) {
    return l10n.activityTargetCustomers;
  }
  if (path.contains('/suppliers')) {
    return l10n.activityTargetSuppliers;
  }
  if (path.contains('/products') ||
      path.contains('/product-categories') ||
      path.contains('/stock')) {
    return l10n.activityTargetCatalog;
  }
  if (path.contains('/register-sessions')) {
    return l10n.activityTargetRegisterSessions;
  }
  if (path.contains('/discount-rules')) {
    return l10n.activityTargetDiscounts;
  }
  if (path.contains('/reports')) {
    return l10n.activityTargetReports;
  }
  if (path.contains('/auth')) {
    return l10n.activityTargetAuth;
  }
  return l10n.activityTargetSystem;
}

String _interactionActionLabel(AppLocalizations l10n, String action) {
  return switch (action) {
    'navigation_selected' => l10n.activityInteractionNavigation,
    'logout_selected' => l10n.activityInteractionLogout,
    'product_tile_selected' => l10n.activityInteractionProductSelected,
    'pointer_down' ||
    'pointer_up' ||
    'pointer_cancel' => l10n.activityInteractionPointer,
    'pointer_scroll' ||
    'scroll_start' ||
    'scroll_update' ||
    'scroll_end' ||
    'user_scroll' => l10n.activityInteractionScroll,
    'key_down' || 'key_repeat' => l10n.activityInteractionKeyboard,
    'focus_changed' => l10n.activityInteractionFocus,
    _ => l10n.activityInteractionGeneral,
  };
}

String _interactionTargetLabel(
  AppLocalizations l10n,
  AnalyticsEventRecord event,
) {
  final destination = _stringAttribute(event, 'destination');
  if (destination.isNotEmpty) {
    return _destinationLabel(l10n, destination);
  }
  final target = _stringAttribute(event, 'target');
  return switch (target) {
    'product_tile' => l10n.activityTargetCatalog,
    'pointer' => l10n.activityTargetCurrentScreen,
    'scrollable' => l10n.activityTargetCurrentScreen,
    'keyboard' => l10n.activityTargetCurrentScreen,
    _ => l10n.activityTargetCurrentScreen,
  };
}

String _destinationLabel(AppLocalizations l10n, String destination) {
  return switch (destination) {
    'dashboard' => l10n.dashboardDrawerLabel,
    'pos' => l10n.posDrawerLabel,
    'purchasing' => l10n.purchasingDrawerLabel,
    'contacts' => l10n.contactsDrawerLabel,
    'catalog' => l10n.catalogDrawerLabel,
    'categories' => l10n.categoriesDrawerLabel,
    'registerSessions' => l10n.registerSessionsDrawerLabel,
    'discounts' => l10n.discountsDrawerLabel,
    'reports' => l10n.reportsDrawerLabel,
    'activityLog' => l10n.activityLogDrawerLabel,
    'deviceSettings' => l10n.deviceSettingsDrawerLabel,
    'users' => l10n.usersDrawerLabel,
    'settings' => l10n.settingsDrawerLabel,
    _ => l10n.activityTargetCurrentScreen,
  };
}

String _uiSourceLabel(AppLocalizations l10n, String source) {
  return switch (source) {
    'product_tile' => l10n.activityUiSourceProductTile,
    'variant_picker' => l10n.activityUiSourceVariantPicker,
    'barcode_lookup' => l10n.activityUiSourceBarcodeLookup,
    'hardware_scanner' => l10n.activityUiSourceHardwareScanner,
    'camera_scanner' => l10n.activityUiSourceCameraScanner,
    'cart_quantity_button' => l10n.activityUiSourceCartQuantityButton,
    'cart_delete_button' => l10n.activityUiSourceCartDeleteButton,
    'cart_clear_button' => l10n.activityUiSourceCartClearButton,
    'purchase_catalog' ||
    'purchase_catalog_tile' => l10n.activityUiSourcePurchaseCatalog,
    'purchase_barcode_lookup' => l10n.activityUiSourcePurchaseBarcodeLookup,
    'purchase_camera_scanner' => l10n.activityUiSourcePurchaseCameraScanner,
    'purchase_draft_quantity_button' =>
      l10n.activityUiSourcePurchaseDraftQuantityButton,
    'purchase_draft_clear_button' =>
      l10n.activityUiSourcePurchaseDraftClearButton,
    'register_session_gate' => l10n.activityUiSourceRegisterSessionGate,
    'register_session_close_sheet' =>
      l10n.activityUiSourceRegisterSessionCloseSheet,
    'register_cash_movement_sheet' =>
      l10n.activityUiSourceRegisterCashMovementSheet,
    'register_session_history' => l10n.activityUiSourceRegisterSessionHistory,
    'sale_order_details_sheet' => l10n.activityUiSourceSaleOrderDetailsSheet,
    'catalog_product_form' => l10n.activityUiSourceCatalogProductForm,
    'catalog_product_details' => l10n.activityUiSourceCatalogProductDetails,
    'catalog_variant_form' => l10n.activityUiSourceCatalogVariantForm,
    'catalog_variant_generator' => l10n.activityUiSourceCatalogVariantGenerator,
    'category_management' => l10n.activityUiSourceCategoryManagement,
    'stock_movement_form' => l10n.activityUiSourceStockMovementForm,
    'barcode_label_panel' => l10n.activityUiSourceBarcodeLabelPanel,
    'user_management' => l10n.activityUiSourceUserManagement,
    'shop_settings' => l10n.activityUiSourceShopSettings,
    'device_settings' => l10n.activityUiSourceDeviceSettings,
    'discount_management' => l10n.activityUiSourceDiscountManagement,
    'reports_screen' => l10n.activityUiSourceReportsScreen,
    'analytics_export_sheet' => l10n.activityUiSourceAnalyticsExportSheet,
    'printing_settings' => l10n.activityUiSourcePrintingSettings,
    _ => l10n.activityUiSourceUnknown(source),
  };
}

IconData _businessEventIcon(
  AnalyticsEventRecord event,
  ActivityLogDrillDownTarget? target,
) {
  if (event.isFraudSignal) {
    return Icons.gpp_maybe_outlined;
  }
  if (event.name.startsWith('fraud.')) {
    return Icons.manage_search_outlined;
  }
  if (target != null) {
    return activityLogDrillDownIcon(target);
  }
  return switch (event.name) {
    'sales.checkout.completed' => Icons.receipt_long_outlined,
    'sales.order.voided' => Icons.block_outlined,
    'sales.order.returned' => Icons.keyboard_return_outlined,
    'sales.receipt.reprint.queued' => Icons.print_outlined,
    'sales.receipt.reprint.failed' => Icons.print_disabled_outlined,
    'sales.register_session.started' => Icons.point_of_sale_outlined,
    'sales.register_session.closed' => Icons.lock_clock_outlined,
    'sales.register_cash_movement.created' =>
      Icons.account_balance_wallet_outlined,
    String name when name.startsWith('sales_history.') =>
      Icons.manage_history_outlined,
    String name when name.startsWith('pos.register_session.') =>
      Icons.point_of_sale_outlined,
    'pos.register_cash_movement.created' =>
      Icons.account_balance_wallet_outlined,
    'pos.cart.line.added' => Icons.add_shopping_cart_outlined,
    'pos.cart.line.quantity_increased' => Icons.add_circle_outline,
    'pos.cart.line.quantity_decreased' => Icons.remove_circle_outline,
    'pos.cart.line.quantity_settled' =>
      _quantityDirectionIsIncrease(event)
          ? Icons.add_circle_outline
          : Icons.remove_circle_outline,
    'pos.cart.line.deleted' => Icons.remove_shopping_cart_outlined,
    'pos.cart.cleared' => Icons.delete_sweep_outlined,
    String name when name.startsWith('pos.checkout.') =>
      Icons.shopping_cart_checkout_outlined,
    'purchasing.draft.line.added' => Icons.add_circle_outline,
    'purchasing.draft.line.quantity_increased' => Icons.add_circle_outline,
    'purchasing.draft.line.quantity_decreased' => Icons.remove_circle_outline,
    'purchasing.draft.line.deleted' => Icons.remove_circle_outline,
    'purchasing.draft.cleared' => Icons.delete_sweep_outlined,
    'purchasing.draft.supplier.selected' => Icons.local_shipping_outlined,
    'purchasing.draft.submitted' => Icons.assignment_turned_in_outlined,
    'purchasing.draft.submit_failed' => Icons.error_outline,
    String name when name.startsWith('purchasing.') =>
      Icons.add_shopping_cart_outlined,
    String name when name.startsWith('customers.') => Icons.contacts_outlined,
    String name when name.startsWith('catalog.') => Icons.inventory_2_outlined,
    String name when name.startsWith('inventory.') => Icons.move_down_outlined,
    String name when name.startsWith('users.') =>
      Icons.admin_panel_settings_outlined,
    String name when name.startsWith('settings.') => Icons.settings_outlined,
    String name when name.startsWith('discounts.') => Icons.percent_outlined,
    String name when name.startsWith('printing.') => Icons.print_outlined,
    String name when name.startsWith('analytics.') =>
      Icons.file_download_outlined,
    String name
        when name.startsWith('report.') || name.startsWith('reports.') =>
      Icons.assessment_outlined,
    String name when name.startsWith('auth.') => Icons.login_outlined,
    _ => Icons.fact_check_outlined,
  };
}

String _requestMethod(AnalyticsEventRecord event) {
  return _stringAttribute(event, 'method').toUpperCase();
}

String _requestPath(AnalyticsEventRecord event) {
  final attributePath = _stringAttribute(event, 'path');
  if (attributePath.isNotEmpty) {
    return attributePath;
  }
  return event.requestPath.isEmpty ? '/' : event.requestPath;
}

String _stringAttribute(AnalyticsEventRecord event, String key) {
  return event.attributes[key]?.toString().trim() ?? '';
}

num? _metric(AnalyticsEventRecord event, String key) {
  final value = event.metrics[key];
  if (value is num) {
    return value;
  }
  return num.tryParse(value?.toString() ?? '');
}

int? _intMetric(AnalyticsEventRecord event, String key) {
  return _metric(event, key)?.round();
}

int? _lineCount(AnalyticsEventRecord event) {
  final attributeValue = event.attributes['line_count'];
  return int.tryParse(attributeValue?.toString() ?? '') ??
      _intMetric(event, 'item_count');
}

String _productDisplayName(AnalyticsEventRecord event) {
  final product = _stringAttribute(event, 'product_name');
  final variant = _stringAttribute(event, 'variant_name');
  if (variant.isEmpty || variant == product) {
    return product;
  }
  return '$product / $variant';
}

int _quantityValue(AnalyticsEventRecord event) {
  final value =
      event.metrics['quantity'] ??
      event.attributes['new_quantity'] ??
      event.attributes['quantity'];
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _intValue(String value) {
  return int.tryParse(value.trim());
}
