import 'dart:typed_data';

import 'attachment_summary.dart';
import 'contact.dart' show PaymentTermsBasis, ResolvedPaymentTerms;

/// How the cost of goods sold is decided when the same product was bought at
/// more than one price.
///
/// Chosen during first-run setup and changeable afterwards only behind an
/// explicit confirmation: the method decides what every past sale's cost *was*,
/// so switching it re-labels history that has already been reported on.
enum InventoryValuationMethod {
  movingAverage('moving_average'),
  fifo('fifo'),
  lifo('lifo');

  const InventoryValuationMethod(this.wireValue);

  final String wireValue;

  static InventoryValuationMethod fromWire(Object? value) {
    final raw = value?.toString();
    for (final method in InventoryValuationMethod.values) {
      if (method.wireValue == raw) {
        return method;
      }
    }
    // An unknown value means a newer backend or a corrupted row; fall back to
    // the default rather than failing to load the settings screen at all.
    return InventoryValuationMethod.movingAverage;
  }
}

class ShopSettings {
  const ShopSettings({
    required this.shopName,
    this.shopType = '',
    required this.receiptHeader,
    required this.receiptFooter,
    required this.enableOnlineInvoices,
    required this.requireOpeningCash,
    required this.autoPrintReceipts,
    required this.allowOverselling,
    required this.preventSellingAtLoss,
    required this.lowStockThreshold,
    required this.cashierReturnWindowHours,
    required this.enableCashPayments,
    required this.enableCardPayments,
    required this.enableTransferPayments,
    required this.requireCardPaymentReceipt,
    required this.trustedCardTerminalIds,
    required this.cardCommissionPercent,
    required this.transferCommissionPercent,
    this.autoPrintMinLineCount,
    this.autoPrintMinTotal,
    this.requireCustomerForCredit = true,
    this.allowCashierCustomerAccess = true,
    this.warnLowStockBeforeSale = true,
    this.autoPrintKitchenTickets = false,
    this.enableRepairOperations = false,
    this.enableProductionOperations = false,
    this.enableKitchenOperations = false,
    this.enableJobTracking = false,
    this.posCashPurchaseLimit,
    this.maxInvoiceDiscountAmount,
    this.enforceCustomerCreditLimits = false,
    this.defaultCustomerCreditLimit,
    this.defaultPaymentTermsDays = 0,
    this.defaultPaymentTermsBasis = PaymentTermsBasis.netDays,
    this.defaultPaymentTerms,
    this.enablePurchaseSuggestions = true,
    this.connectedIntegrations = const [],
    this.lookupIntegrations,
    this.enableSurveillance = false,
    this.surveillancePreRollSeconds = 20,
    this.surveillancePostRollSeconds = 40,
    this.inventoryValuationMethod = InventoryValuationMethod.movingAverage,
    this.currencyCode = 'LYD',
    this.currencySymbol = 'د.ل',
    this.logoAttachment,
  });

  final String shopName;

  /// The shop's vertical, picked in the first-run wizard. Empty until then.
  /// Drives small per-vertical defaults — the intake wizard reads it to open on
  /// "vehicle" for a workshop instead of making every car a two-tap correction.
  final String shopType;
  final String receiptHeader;
  final String receiptFooter;
  final bool enableOnlineInvoices;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;

  /// Auto-print floor: how much of a sale it takes before a receipt prints by
  /// itself. A sale qualifies on clearing EITHER — enough lines or enough money
  /// — so a big basket of cheap things and one expensive thing both print, and
  /// a single loaf of bread does not. Null (or 0) on both means every sale
  /// prints, which is what auto-print meant before these existed.
  ///
  /// The rule is [saleClearsAutoPrintFloor]; the backend states the same rule
  /// in `ShopSettings.sale_clears_auto_print_floor`, and the two have to agree
  /// or a shop sees the queue print a sale the till skipped.
  final int? autoPrintMinLineCount;
  final double? autoPrintMinTotal;
  final bool autoPrintKitchenTickets;
  final bool allowOverselling;
  final bool preventSellingAtLoss;
  final int lowStockThreshold;
  final int cashierReturnWindowHours;
  final bool enableCashPayments;
  final bool enableCardPayments;
  final bool enableTransferPayments;
  final bool requireCardPaymentReceipt;
  final List<String> trustedCardTerminalIds;
  final double cardCommissionPercent;
  final double transferCommissionPercent;

  /// When true a credit (آجل) or quotation (عرض سعر) sale must name a customer.
  final bool requireCustomerForCredit;
  final bool allowCashierCustomerAccess;

  /// When true the POS asks the cashier to confirm before completing a sale
  /// whose cart quantity exceeds the available stock. Turn it off (with
  /// overselling enabled) to skip that per-sale prompt.
  final bool warnLowStockBeforeSale;
  final bool enableRepairOperations;
  final bool enableProductionOperations;
  final bool enableKitchenOperations;
  final bool enableJobTracking;

  /// Per-purchase ceiling for POS cash purchases (drawer-paid POs from the
  /// sell screen). Null or 0 = no cap.
  final double? posCashPurchaseLimit;

  /// Ceiling on the discount a cashier may take off one invoice at the till.
  /// Null = no ceiling (the amount is still bounded by the sale itself). 0 is
  /// the opposite and deliberate: this shop does not discount at the counter,
  /// and the sell screen hides the field entirely.
  final double? maxInvoiceDiscountAmount;

  /// Master switch for credit ceilings. Off by default: a shop already trading
  /// on آجل keeps selling exactly as it did until an owner asks for the rule.
  final bool enforceCustomerCreditLimits;

  /// The credit (آجل) ceiling every customer inherits unless their own record
  /// overrides it. Null = no limit — which is what a shop that never sets this
  /// keeps. 0 is the opposite and deliberate: nobody buys on credit by default.
  final double? defaultCustomerCreditLimit;

  /// The shop's default credit (آجل) terms: how many days, counted from what.
  final int defaultPaymentTermsDays;
  final PaymentTermsBasis defaultPaymentTermsBasis;

  /// Those terms resolved by the server, including the due date they produce
  /// for a sale rung up today. The till proposes that date for a walk-in آجل
  /// sale; a named customer's own terms ride on the customer instead.
  final ResolvedPaymentTerms? defaultPaymentTerms;

  /// Whether the purchasing screen offers the products and quantities this shop
  /// habitually buys from the chosen supplier. Off hides all three surfaces and
  /// stops the client asking for them at all.
  final bool enablePurchaseSuggestions;

  /// Which resale providers are connected, by backend key. Read-only: the
  /// backend derives it from the configured accounts.
  ///
  /// A list rather than a flag because the till draws a *named* button for a
  /// single provider and a menu for several, and it should not need a second
  /// call to learn which.
  final List<String> connectedIntegrations;

  /// The connected providers the till draws a top-up button for: the ones a
  /// cashier looks a customer's line up on (HD Box, LNET). A provider that
  /// sells cards off a shelf (Qareeb) is connected — its float is topped up
  /// from Expenses like any other — but its cards are products in the
  /// catalog, so it gets no top-up screen.
  ///
  /// Null from a backend that predates the field, which only ever listed
  /// lookup providers anyway: [tillRechargeIntegrations] then falls back to
  /// [connectedIntegrations].
  final List<String>? lookupIntegrations;

  /// What the till's top-up button offers.
  List<String> get tillRechargeIntegrations =>
      lookupIntegrations ?? connectedIntegrations;

  /// Whether the shop resells anything at all — what hides the till's top-up
  /// button in a shop that does not.
  bool get hasIntegrations => connectedIntegrations.isNotEmpty;

  /// Whether this shop has cameras wired up. Gates the camera wall, the
  /// command-palette entry and the invoice playback panel — a shop with no DVR
  /// never sees a surface it cannot use. Turned on by the backend the first
  /// time a recorder connects.
  final bool enableSurveillance;

  /// How much footage the invoice player opens either side of the sale.
  final int surveillancePreRollSeconds;
  final int surveillancePostRollSeconds;

  /// How stock is costed. See [InventoryValuationMethod].
  final InventoryValuationMethod inventoryValuationMethod;
  final String currencyCode;
  final String currencySymbol;
  final AttachmentSummary? logoAttachment;

  bool get hasPosCashPurchaseLimit =>
      posCashPurchaseLimit != null && posCashPurchaseLimit! > 0;

  /// Whether a cashier may discount an invoice at all. Unlike the cash-purchase
  /// cap, 0 is a real answer here and it is "no" — so an explicit zero turns the
  /// field off rather than meaning "no rule".
  bool get allowsInvoiceDiscount =>
      maxInvoiceDiscountAmount == null || maxInvoiceDiscountAmount! > 0;

  /// Whether the ceiling actually bounds anything, as opposed to being absent.
  bool get hasInvoiceDiscountLimit =>
      maxInvoiceDiscountAmount != null && maxInvoiceDiscountAmount! > 0;

  /// Whether the shop has expressed any default at all. Unlike the cash-purchase
  /// cap, 0 counts: it means "no credit by default", not "no rule".
  bool get hasDefaultCustomerCreditLimit => defaultCustomerCreditLimit != null;

  /// Whether auto-printing is limited to sales of a certain size at all.
  bool get hasAutoPrintFloor =>
      (autoPrintMinLineCount ?? 0) > 0 || (autoPrintMinTotal ?? 0) > 0;

  /// Whether a sale of this shape is big enough to print a receipt by itself.
  ///
  /// Whichever floors the shop set, clearing *either* is enough: a basket of
  /// cheap things qualifies on [lineCount], one expensive thing on [total]. A
  /// floor of 0 reads as no floor — a cleared box must not quietly mean "every
  /// sale qualifies", which is what a literal `lineCount >= 0` would say.
  ///
  /// The backend asks the same question of the same numbers before it queues a
  /// receipt; keep the two in step.
  bool saleClearsAutoPrintFloor({
    required int lineCount,
    required double total,
  }) {
    final minLines = autoPrintMinLineCount ?? 0;
    final minTotal = autoPrintMinTotal ?? 0;
    if (minLines <= 0 && minTotal <= 0) {
      return true;
    }
    if (minLines > 0 && lineCount >= minLines) {
      return true;
    }
    return minTotal > 0 && total >= minTotal;
  }

  factory ShopSettings.fromJson(Map<String, Object?> json) {
    final logoJson = json['logo_attachment'];
    return ShopSettings(
      shopName: json['shop_name']?.toString() ?? '',
      shopType: json['shop_type']?.toString() ?? '',
      receiptHeader: json['receipt_header']?.toString() ?? '',
      receiptFooter: json['receipt_footer']?.toString() ?? '',
      enableOnlineInvoices: _boolFromJson(
        json['enable_online_invoices'],
        false,
      ),
      requireOpeningCash: json['require_opening_cash'] is bool
          ? json['require_opening_cash'] as bool
          : json['require_opening_cash']?.toString() != 'false',
      autoPrintReceipts: json['auto_print_receipts'] is bool
          ? json['auto_print_receipts'] as bool
          : json['auto_print_receipts']?.toString() == 'true',
      autoPrintMinLineCount: json['auto_print_min_line_count'] == null
          ? null
          : _intFromJson(json['auto_print_min_line_count'], 0),
      autoPrintMinTotal: json['auto_print_min_total'] == null
          ? null
          : _moneyFromJson(json['auto_print_min_total'], 0),
      autoPrintKitchenTickets: _boolFromJson(
        json['auto_print_kitchen_tickets'],
        false,
      ),
      allowOverselling: json['allow_overselling'] is bool
          ? json['allow_overselling'] as bool
          : json['allow_overselling']?.toString() == 'true',
      preventSellingAtLoss: _boolFromJson(
        json['prevent_selling_at_loss'],
        true,
      ),
      lowStockThreshold: (json['low_stock_threshold'] as num?)?.toInt() ?? 5,
      cashierReturnWindowHours:
          (json['cashier_return_window_hours'] as num?)?.toInt() ?? 42,
      enableCashPayments: _boolFromJson(json['enable_cash_payments'], true),
      enableCardPayments: _boolFromJson(json['enable_card_payments'], true),
      enableTransferPayments: _boolFromJson(
        json['enable_transfer_payments'],
        true,
      ),
      requireCardPaymentReceipt: _boolFromJson(
        json['require_card_payment_receipt'],
        false,
      ),
      trustedCardTerminalIds: _stringListFromJson(
        json['trusted_card_terminal_ids'],
      ),
      cardCommissionPercent: _moneyFromJson(json['card_commission_percent'], 1),
      transferCommissionPercent: _moneyFromJson(
        json['transfer_commission_percent'],
        0,
      ),
      requireCustomerForCredit: _boolFromJson(
        json['require_customer_for_credit'],
        true,
      ),
      allowCashierCustomerAccess: _boolFromJson(
        json['allow_cashier_customer_access'],
        true,
      ),
      warnLowStockBeforeSale: _boolFromJson(
        json['warn_low_stock_before_sale'],
        true,
      ),
      enableRepairOperations: _boolFromJson(
        json['enable_repair_operations'],
        false,
      ),
      enableProductionOperations: _boolFromJson(
        json['enable_production_operations'],
        false,
      ),
      enableKitchenOperations: _boolFromJson(
        json['enable_kitchen_operations'],
        false,
      ),
      enableJobTracking: _boolFromJson(json['enable_job_tracking'], false),
      posCashPurchaseLimit: json['pos_cash_purchase_limit'] == null
          ? null
          : _moneyFromJson(json['pos_cash_purchase_limit'], 0),
      maxInvoiceDiscountAmount: json['max_invoice_discount_amount'] == null
          ? null
          : _moneyFromJson(json['max_invoice_discount_amount'], 0),
      enforceCustomerCreditLimits: _boolFromJson(
        json['enforce_customer_credit_limits'],
        false,
      ),
      defaultPaymentTermsDays:
          (json['default_payment_terms_days'] as num?)?.toInt() ?? 0,
      defaultPaymentTermsBasis: PaymentTermsBasis.fromApi(
        json['default_payment_terms_basis']?.toString(),
      ),
      defaultPaymentTerms: ResolvedPaymentTerms.fromJson(
        json['default_payment_terms'],
      ),
      defaultCustomerCreditLimit: json['default_customer_credit_limit'] == null
          ? null
          : _moneyFromJson(json['default_customer_credit_limit'], 0),
      enablePurchaseSuggestions: _boolFromJson(
        json['enable_purchase_suggestions'],
        true,
      ),
      connectedIntegrations:
          (json['connected_integrations'] as List<Object?>? ?? const [])
              .map((value) => value.toString())
              .toList(growable: false),
      lookupIntegrations: json['lookup_integrations'] is List
          ? (json['lookup_integrations'] as List<Object?>)
                .map((value) => value.toString())
                .toList(growable: false)
          : null,
      enableSurveillance: _boolFromJson(json['enable_surveillance'], false),
      surveillancePreRollSeconds: _intFromJson(
        json['surveillance_pre_roll_seconds'],
        20,
      ),
      surveillancePostRollSeconds: _intFromJson(
        json['surveillance_post_roll_seconds'],
        40,
      ),
      inventoryValuationMethod: InventoryValuationMethod.fromWire(
        json['inventory_valuation_method'],
      ),
      currencyCode: json['currency_code']?.toString() ?? 'LYD',
      currencySymbol: json['currency_symbol']?.toString() ?? 'د.ل',
      logoAttachment: logoJson is Map<String, Object?>
          ? AttachmentSummary.fromJson(logoJson)
          : null,
    );
  }
}

class ShopLogoUpload {
  const ShopLogoUpload({
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  final String filename;
  final Uint8List bytes;
  final String contentType;
}

/// Marks a [ShopSettingsDraft.copyWith] argument as "not supplied".
///
/// Needed only for the nullable money fields, where `null` is a real value
/// ("no limit") and so cannot double as "leave it alone".
const Object _keep = Object();

class ShopSettingsDraft {
  const ShopSettingsDraft({
    required this.shopName,
    required this.receiptHeader,
    required this.receiptFooter,
    required this.enableOnlineInvoices,
    required this.requireOpeningCash,
    required this.autoPrintReceipts,
    required this.allowOverselling,
    required this.preventSellingAtLoss,
    required this.lowStockThreshold,
    required this.cashierReturnWindowHours,
    required this.enableCashPayments,
    required this.enableCardPayments,
    required this.enableTransferPayments,
    required this.requireCardPaymentReceipt,
    required this.trustedCardTerminalIds,
    required this.cardCommissionPercent,
    required this.transferCommissionPercent,
    this.autoPrintMinLineCount,
    this.autoPrintMinTotal,
    this.requireCustomerForCredit = true,
    this.allowCashierCustomerAccess = true,
    this.warnLowStockBeforeSale = true,
    this.autoPrintKitchenTickets = false,
    this.enableRepairOperations = false,
    this.enableProductionOperations = false,
    this.enableKitchenOperations = false,
    this.enableJobTracking = false,
    this.posCashPurchaseLimit,
    this.maxInvoiceDiscountAmount,
    this.enforceCustomerCreditLimits = false,
    this.defaultCustomerCreditLimit,
    this.defaultPaymentTermsDays = 0,
    this.defaultPaymentTermsBasis = PaymentTermsBasis.netDays,
    this.enablePurchaseSuggestions = true,
    this.enableSurveillance = false,
    this.surveillancePreRollSeconds = 20,
    this.surveillancePostRollSeconds = 40,
    this.inventoryValuationMethod = InventoryValuationMethod.movingAverage,
    this.valuationMethodChangeAcknowledged = false,
  });

  final bool enforceCustomerCreditLimits;
  final double? defaultCustomerCreditLimit;

  /// The shop's default credit (آجل) terms — the two columns the form edits.
  /// The resolved answer they produce lives on [ShopSettings], not here.
  final int defaultPaymentTermsDays;
  final PaymentTermsBasis defaultPaymentTermsBasis;
  final String shopName;
  final String receiptHeader;
  final String receiptFooter;
  final bool enableOnlineInvoices;
  final bool requireOpeningCash;
  final bool autoPrintReceipts;
  final int? autoPrintMinLineCount;
  final double? autoPrintMinTotal;
  final bool autoPrintKitchenTickets;
  final bool allowOverselling;
  final bool preventSellingAtLoss;
  final int lowStockThreshold;
  final int cashierReturnWindowHours;
  final bool enableCashPayments;
  final bool enableCardPayments;
  final bool enableTransferPayments;
  final bool requireCardPaymentReceipt;
  final List<String> trustedCardTerminalIds;
  final double cardCommissionPercent;
  final double transferCommissionPercent;
  final bool requireCustomerForCredit;
  final bool allowCashierCustomerAccess;
  final bool warnLowStockBeforeSale;
  final bool enableRepairOperations;
  final bool enableProductionOperations;
  final bool enableKitchenOperations;
  final bool enableJobTracking;
  final double? posCashPurchaseLimit;
  final double? maxInvoiceDiscountAmount;
  final bool enablePurchaseSuggestions;
  final bool enableSurveillance;
  final int surveillancePreRollSeconds;
  final int surveillancePostRollSeconds;
  final InventoryValuationMethod inventoryValuationMethod;

  /// Every editable field, copied from a loaded [ShopSettings].
  ///
  /// A draft is sent whole, so a page that builds one from a handful of its own
  /// controls silently resets every field it forgot to a default. Start from
  /// here and override what the page actually edits.
  factory ShopSettingsDraft.fromSettings(ShopSettings settings) {
    return ShopSettingsDraft(
      shopName: settings.shopName,
      receiptHeader: settings.receiptHeader,
      receiptFooter: settings.receiptFooter,
      enableOnlineInvoices: settings.enableOnlineInvoices,
      requireOpeningCash: settings.requireOpeningCash,
      autoPrintReceipts: settings.autoPrintReceipts,
      autoPrintMinLineCount: settings.autoPrintMinLineCount,
      autoPrintMinTotal: settings.autoPrintMinTotal,
      autoPrintKitchenTickets: settings.autoPrintKitchenTickets,
      allowOverselling: settings.allowOverselling,
      warnLowStockBeforeSale: settings.warnLowStockBeforeSale,
      preventSellingAtLoss: settings.preventSellingAtLoss,
      lowStockThreshold: settings.lowStockThreshold,
      cashierReturnWindowHours: settings.cashierReturnWindowHours,
      enableCashPayments: settings.enableCashPayments,
      enableCardPayments: settings.enableCardPayments,
      enableTransferPayments: settings.enableTransferPayments,
      requireCardPaymentReceipt: settings.requireCardPaymentReceipt,
      trustedCardTerminalIds: settings.trustedCardTerminalIds,
      cardCommissionPercent: settings.cardCommissionPercent,
      transferCommissionPercent: settings.transferCommissionPercent,
      requireCustomerForCredit: settings.requireCustomerForCredit,
      enforceCustomerCreditLimits: settings.enforceCustomerCreditLimits,
      defaultCustomerCreditLimit: settings.defaultCustomerCreditLimit,
      defaultPaymentTermsDays: settings.defaultPaymentTermsDays,
      defaultPaymentTermsBasis: settings.defaultPaymentTermsBasis,
      allowCashierCustomerAccess: settings.allowCashierCustomerAccess,
      posCashPurchaseLimit: settings.posCashPurchaseLimit,
      maxInvoiceDiscountAmount: settings.maxInvoiceDiscountAmount,
      enableRepairOperations: settings.enableRepairOperations,
      enableProductionOperations: settings.enableProductionOperations,
      enableKitchenOperations: settings.enableKitchenOperations,
      enableJobTracking: settings.enableJobTracking,
      enablePurchaseSuggestions: settings.enablePurchaseSuggestions,
      enableSurveillance: settings.enableSurveillance,
      surveillancePreRollSeconds: settings.surveillancePreRollSeconds,
      surveillancePostRollSeconds: settings.surveillancePostRollSeconds,
      inventoryValuationMethod: settings.inventoryValuationMethod,
    );
  }

  /// One-shot confirmation that the user has read the warning about changing
  /// the valuation method. Never stored — the backend refuses the change
  /// without it once stock has moved, and forgets it immediately after.
  final bool valuationMethodChangeAcknowledged;

  ShopSettingsDraft acknowledgingValuationMethodChange() {
    return copyWith(valuationMethodChangeAcknowledged: true);
  }

  /// A copy with some fields replaced and **every other field carried**.
  ///
  /// Total on purpose. A draft goes out as the whole payload (see [toJson]), so
  /// a copy that quietly drops a field resets it on the shop, and a screen that
  /// hand-assembles a draft from its own controls resets everything it forgot.
  /// The safe pattern for any screen that edits a subset is therefore
  /// `ShopSettingsDraft.fromSettings(stored).copyWith(...)`, and this method is
  /// what makes it safe: the fields a caller does not name cannot go missing.
  ///
  /// The two money fields are nullable and null is a real value there — "no
  /// limit" — so they take a sentinel rather than a plain null default. Pass
  /// `posCashPurchaseLimit: null` to clear one; omit it to keep it.
  ShopSettingsDraft copyWith({
    String? shopName,
    String? receiptHeader,
    String? receiptFooter,
    bool? enableOnlineInvoices,
    bool? requireOpeningCash,
    bool? autoPrintReceipts,
    Object? autoPrintMinLineCount = _keep,
    Object? autoPrintMinTotal = _keep,
    bool? autoPrintKitchenTickets,
    bool? allowOverselling,
    bool? warnLowStockBeforeSale,
    bool? preventSellingAtLoss,
    int? lowStockThreshold,
    int? cashierReturnWindowHours,
    bool? enableCashPayments,
    bool? enableCardPayments,
    bool? enableTransferPayments,
    bool? requireCardPaymentReceipt,
    List<String>? trustedCardTerminalIds,
    double? cardCommissionPercent,
    double? transferCommissionPercent,
    bool? requireCustomerForCredit,
    bool? enforceCustomerCreditLimits,
    Object? defaultCustomerCreditLimit = _keep,
    int? defaultPaymentTermsDays,
    PaymentTermsBasis? defaultPaymentTermsBasis,
    bool? allowCashierCustomerAccess,
    Object? posCashPurchaseLimit = _keep,
    Object? maxInvoiceDiscountAmount = _keep,
    bool? enableRepairOperations,
    bool? enableProductionOperations,
    bool? enableKitchenOperations,
    bool? enableJobTracking,
    bool? enablePurchaseSuggestions,
    bool? enableSurveillance,
    int? surveillancePreRollSeconds,
    int? surveillancePostRollSeconds,
    InventoryValuationMethod? inventoryValuationMethod,
    bool? valuationMethodChangeAcknowledged,
  }) {
    return ShopSettingsDraft(
      shopName: shopName ?? this.shopName,
      receiptHeader: receiptHeader ?? this.receiptHeader,
      receiptFooter: receiptFooter ?? this.receiptFooter,
      enableOnlineInvoices: enableOnlineInvoices ?? this.enableOnlineInvoices,
      requireOpeningCash: requireOpeningCash ?? this.requireOpeningCash,
      autoPrintReceipts: autoPrintReceipts ?? this.autoPrintReceipts,
      autoPrintMinLineCount: identical(autoPrintMinLineCount, _keep)
          ? this.autoPrintMinLineCount
          : autoPrintMinLineCount as int?,
      autoPrintMinTotal: identical(autoPrintMinTotal, _keep)
          ? this.autoPrintMinTotal
          : autoPrintMinTotal as double?,
      autoPrintKitchenTickets:
          autoPrintKitchenTickets ?? this.autoPrintKitchenTickets,
      allowOverselling: allowOverselling ?? this.allowOverselling,
      warnLowStockBeforeSale:
          warnLowStockBeforeSale ?? this.warnLowStockBeforeSale,
      preventSellingAtLoss: preventSellingAtLoss ?? this.preventSellingAtLoss,
      lowStockThreshold: lowStockThreshold ?? this.lowStockThreshold,
      cashierReturnWindowHours:
          cashierReturnWindowHours ?? this.cashierReturnWindowHours,
      enableCashPayments: enableCashPayments ?? this.enableCashPayments,
      enableCardPayments: enableCardPayments ?? this.enableCardPayments,
      enableTransferPayments:
          enableTransferPayments ?? this.enableTransferPayments,
      requireCardPaymentReceipt:
          requireCardPaymentReceipt ?? this.requireCardPaymentReceipt,
      trustedCardTerminalIds:
          trustedCardTerminalIds ?? this.trustedCardTerminalIds,
      cardCommissionPercent:
          cardCommissionPercent ?? this.cardCommissionPercent,
      transferCommissionPercent:
          transferCommissionPercent ?? this.transferCommissionPercent,
      requireCustomerForCredit:
          requireCustomerForCredit ?? this.requireCustomerForCredit,
      enforceCustomerCreditLimits:
          enforceCustomerCreditLimits ?? this.enforceCustomerCreditLimits,
      defaultCustomerCreditLimit: identical(defaultCustomerCreditLimit, _keep)
          ? this.defaultCustomerCreditLimit
          : defaultCustomerCreditLimit as double?,
      defaultPaymentTermsDays:
          defaultPaymentTermsDays ?? this.defaultPaymentTermsDays,
      defaultPaymentTermsBasis:
          defaultPaymentTermsBasis ?? this.defaultPaymentTermsBasis,
      allowCashierCustomerAccess:
          allowCashierCustomerAccess ?? this.allowCashierCustomerAccess,
      posCashPurchaseLimit: identical(posCashPurchaseLimit, _keep)
          ? this.posCashPurchaseLimit
          : posCashPurchaseLimit as double?,
      maxInvoiceDiscountAmount: identical(maxInvoiceDiscountAmount, _keep)
          ? this.maxInvoiceDiscountAmount
          : maxInvoiceDiscountAmount as double?,
      enableRepairOperations:
          enableRepairOperations ?? this.enableRepairOperations,
      enableProductionOperations:
          enableProductionOperations ?? this.enableProductionOperations,
      enableKitchenOperations:
          enableKitchenOperations ?? this.enableKitchenOperations,
      enableJobTracking: enableJobTracking ?? this.enableJobTracking,
      enablePurchaseSuggestions:
          enablePurchaseSuggestions ?? this.enablePurchaseSuggestions,
      enableSurveillance: enableSurveillance ?? this.enableSurveillance,
      surveillancePreRollSeconds:
          surveillancePreRollSeconds ?? this.surveillancePreRollSeconds,
      surveillancePostRollSeconds:
          surveillancePostRollSeconds ?? this.surveillancePostRollSeconds,
      inventoryValuationMethod:
          inventoryValuationMethod ?? this.inventoryValuationMethod,
      valuationMethodChangeAcknowledged:
          valuationMethodChangeAcknowledged ??
          this.valuationMethodChangeAcknowledged,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'shop_name': shopName,
      'receipt_header': receiptHeader,
      'receipt_footer': receiptFooter,
      'enable_online_invoices': enableOnlineInvoices,
      'require_opening_cash': requireOpeningCash,
      'auto_print_receipts': autoPrintReceipts,
      // Null clears the floor — an empty box on the settings form means "print
      // every sale", so it has to reach the server as a null and not be
      // dropped from the payload.
      'auto_print_min_line_count': autoPrintMinLineCount,
      'auto_print_min_total': autoPrintMinTotal?.toStringAsFixed(2),
      'auto_print_kitchen_tickets': autoPrintKitchenTickets,
      'allow_overselling': allowOverselling,
      'prevent_selling_at_loss': preventSellingAtLoss,
      'low_stock_threshold': lowStockThreshold,
      'cashier_return_window_hours': cashierReturnWindowHours,
      'enable_cash_payments': enableCashPayments,
      'enable_card_payments': enableCardPayments,
      'enable_transfer_payments': enableTransferPayments,
      'require_card_payment_receipt': requireCardPaymentReceipt,
      'trusted_card_terminal_ids': trustedCardTerminalIds,
      'card_commission_percent': cardCommissionPercent.toStringAsFixed(2),
      'transfer_commission_percent': transferCommissionPercent.toStringAsFixed(
        2,
      ),
      'require_customer_for_credit': requireCustomerForCredit,
      'allow_cashier_customer_access': allowCashierCustomerAccess,
      'warn_low_stock_before_sale': warnLowStockBeforeSale,
      'enable_repair_operations': enableRepairOperations,
      'enable_production_operations': enableProductionOperations,
      'enable_kitchen_operations': enableKitchenOperations,
      'enable_job_tracking': enableJobTracking,
      'pos_cash_purchase_limit': posCashPurchaseLimit?.toStringAsFixed(2),
      'max_invoice_discount_amount': maxInvoiceDiscountAmount?.toStringAsFixed(
        2,
      ),
      'enforce_customer_credit_limits': enforceCustomerCreditLimits,
      'default_payment_terms_days': defaultPaymentTermsDays,
      'default_payment_terms_basis': defaultPaymentTermsBasis.apiValue,
      'default_customer_credit_limit': defaultCustomerCreditLimit
          ?.toStringAsFixed(2),
      'enable_purchase_suggestions': enablePurchaseSuggestions,
      'enable_surveillance': enableSurveillance,
      'surveillance_pre_roll_seconds': surveillancePreRollSeconds,
      'surveillance_post_roll_seconds': surveillancePostRollSeconds,
      'inventory_valuation_method': inventoryValuationMethod.wireValue,
      // Only sent when the user has actually confirmed, so an ordinary save
      // can never carry a stale acknowledgement.
      if (valuationMethodChangeAcknowledged)
        'valuation_method_change_acknowledged': true,
    };
  }
}

bool _boolFromJson(Object? value, bool fallback) {
  if (value is bool) {
    return value;
  }
  if (value == null) {
    return fallback;
  }
  return value.toString() == 'true';
}

int _intFromJson(Object? value, int fallback) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _moneyFromJson(Object? value, double fallback) {
  if (value == null) {
    return fallback;
  }
  return double.tryParse(value.toString()) ?? fallback;
}

List<String> _stringListFromJson(Object? value) {
  if (value is! List<Object?>) {
    return const [];
  }
  return value
      .map((item) => item?.toString().trim().toUpperCase() ?? '')
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);
}
