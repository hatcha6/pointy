import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/customer_activity.dart';
import '../../../data/models/payment_card.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/sale_order_page.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/payment_proof_printer.dart';

class CustomerDetailsViewModel extends ChangeNotifier {
  CustomerDetailsViewModel({
    required ContactRepository contactRepository,
    required Customer initialCustomer,
    required ShopSettingsRepository shopSettingsRepository,
    required PrintingRepository printingRepository,
  }) : _contactRepository = contactRepository,
       _shopSettingsRepository = shopSettingsRepository,
       _customer = initialCustomer,
       _summary = CustomerSalesSummary.empty(initialCustomer.id),
       _paymentProofPrinter = PaymentProofPrinter(
         printingRepository: printingRepository,
         shopSettingsRepository: shopSettingsRepository,
       ) {
    load();
  }

  final ContactRepository _contactRepository;
  final ShopSettingsRepository _shopSettingsRepository;
  final PaymentProofPrinter _paymentProofPrinter;

  ContactRepository get repository => _contactRepository;

  Customer _customer;
  CustomerSalesSummary _summary;
  List<SaleOrder> _orderHistory = [];
  List<CustomerAdjustmentHistoryEntry> _adjustmentHistory = [];
  List<PaymentCard> _cards = [];
  bool _isLoadingCustomer = false;
  bool _isLoadingSummary = false;
  bool _isLoadingOrders = false;
  bool _isLoadingAdjustments = false;
  bool _isLoadingCards = false;
  bool _hasCardsError = false;
  bool _isSaving = false;
  bool _isLoadingMoreOrders = false;
  bool _isLoadingMoreAdjustments = false;
  bool _hasMoreOrders = true;
  bool _hasMoreAdjustments = true;
  int _nextOrderPage = 1;
  int _nextAdjustmentPage = 1;
  bool _hasCustomerError = false;
  bool _hasSummaryError = false;
  bool _hasOrderError = false;
  bool _hasAdjustmentError = false;
  bool _isRecordingPayment = false;
  bool _hasPaymentError = false;
  final Map<String, String> _idempotencyKeysBySignature = {};

  Customer get customer => _customer;
  CustomerSalesSummary get summary => _summary;

  /// Total the customer still owes across their open debt invoices.
  double get outstandingBalance => _summary.outstandingBalance;
  bool get isRecordingPayment => _isRecordingPayment;
  bool get hasPaymentError => _hasPaymentError;
  List<SaleOrder> get orderHistory => List.unmodifiable(_orderHistory);
  List<CustomerAdjustmentHistoryEntry> get adjustmentHistory =>
      List.unmodifiable(_adjustmentHistory);
  List<PaymentCard> get cards => List.unmodifiable(_cards);
  bool get isLoadingCards => _isLoadingCards;
  bool get hasCardsError => _hasCardsError;
  bool get isSaving => _isSaving;

  /// Set the customer's contact consent, then reload so the UI reflects the
  /// server-recorded state. Backend enforces the ``crm.manage_consent``
  /// permission — a forbidden change fails and the toggle reverts.
  Future<bool> setConsent({bool? marketingOptedOut, bool? doNotContact}) async {
    if (_isSaving) {
      return false;
    }
    _isSaving = true;
    notifyListeners();

    final result = await _contactRepository.setCustomerConsent(
      _customer.id,
      marketingOptedOut: marketingOptedOut,
      doNotContact: doNotContact,
    );
    var ok = false;
    if (result is Ok<void>) {
      final refreshed = await _contactRepository.loadCustomer(_customer.id);
      if (refreshed is Ok<Customer>) {
        _customer = refreshed.value;
      }
      ok = true;
    }

    _isSaving = false;
    notifyListeners();
    return ok;
  }

  bool get isLoadingCustomer => _isLoadingCustomer;
  bool get isLoadingSummary => _isLoadingSummary;
  bool get isLoadingOrders => _isLoadingOrders;
  bool get isLoadingAdjustments => _isLoadingAdjustments;
  bool get isLoadingMoreOrders => _isLoadingMoreOrders;
  bool get isLoadingMoreAdjustments => _isLoadingMoreAdjustments;
  bool get hasMoreOrders => _hasMoreOrders;
  bool get hasMoreAdjustments => _hasMoreAdjustments;
  bool get hasCustomerError => _hasCustomerError;
  bool get hasSummaryError => _hasSummaryError;
  bool get hasOrderError => _hasOrderError;
  bool get hasAdjustmentError => _hasAdjustmentError;

  Future<void> load() async {
    await Future.wait([
      loadCustomer(),
      loadSummary(),
      loadOrderHistory(),
      loadAdjustmentHistory(),
      loadCards(),
    ]);
  }

  Future<void> loadCards() async {
    _isLoadingCards = true;
    _hasCardsError = false;
    notifyListeners();

    final result = await _contactRepository.loadCustomerCards(
      customerId: _customer.id,
    );
    switch (result) {
      case Ok<PaymentCardPage>():
        _cards = result.value.cards;
      case Error<PaymentCardPage>():
        _cards = [];
        _hasCardsError = true;
    }

    _isLoadingCards = false;
    notifyListeners();
  }

  /// Adopts the customer returned by the edit sheet (which performed the
  /// PATCH itself, mirroring the create flow) into this view's state.
  void applyUpdatedCustomer(Customer customer) {
    _customer = customer;
    notifyListeners();
  }

  /// Names a placeholder card-customer, claiming it as a real customer.
  Future<bool> claim(String fullName) async {
    if (_isSaving) {
      return false;
    }
    _isSaving = true;
    notifyListeners();

    final result = await _contactRepository.patchCustomer(_customer.id, {
      'full_name': fullName,
      'is_auto_created': false,
    });
    final ok = result is Ok<Customer>;
    if (ok) {
      _customer = result.value;
    }

    _isSaving = false;
    notifyListeners();
    return ok;
  }

  /// Folds this customer into [targetId]; on success this customer no longer
  /// exists, so callers should leave the detail view.
  Future<bool> mergeInto(int targetId) async {
    if (_isSaving) {
      return false;
    }
    _isSaving = true;
    notifyListeners();

    final result = await _contactRepository.mergeCustomer(
      customerId: targetId,
      sourceId: _customer.id,
    );

    _isSaving = false;
    notifyListeners();
    return result is Ok<Customer>;
  }

  Future<bool> reassignCard(int cardId, int targetCustomerId) async {
    if (_isSaving) {
      return false;
    }
    _isSaving = true;
    notifyListeners();

    final result = await _contactRepository.reassignCard(
      cardId: cardId,
      customerId: targetCustomerId,
    );
    final ok = result is Ok<PaymentCard>;

    _isSaving = false;
    notifyListeners();
    if (ok) {
      await loadCards();
    }
    return ok;
  }

  Future<void> loadCustomer() async {
    _isLoadingCustomer = true;
    _hasCustomerError = false;
    notifyListeners();

    final result = await _contactRepository.loadCustomer(_customer.id);
    switch (result) {
      case Ok<Customer>():
        _customer = result.value;
      case Error<Customer>():
        _hasCustomerError = true;
    }

    _isLoadingCustomer = false;
    notifyListeners();
  }

  Future<void> loadSummary() async {
    _isLoadingSummary = true;
    _hasSummaryError = false;
    notifyListeners();

    final result = await _contactRepository.loadCustomerSalesSummary(
      _customer.id,
    );
    switch (result) {
      case Ok<CustomerSalesSummary>():
        _summary = result.value;
      case Error<CustomerSalesSummary>():
        _summary = CustomerSalesSummary.empty(_customer.id);
        _hasSummaryError = true;
    }

    _isLoadingSummary = false;
    notifyListeners();
  }

  /// Trusted card terminals for the receipt-scan dialog (empty on failure), so
  /// the account collection validates card receipts the same way the POS and
  /// per-invoice flows do.
  Future<List<String>> loadTrustedCardTerminalIds() {
    return _shopSettingsRepository.loadTrustedCardTerminalIds();
  }

  /// Records a cash/card/transfer payment against the customer's account (the
  /// backend allocates it oldest-first across open debt invoices), then
  /// refreshes the summary and invoice history. Pass [cardReceiptUrl] for the
  /// card method. When [printProof] is set, prints a "سند قبض" proof for the
  /// just-recorded payment. Uses a signature-based idempotency key so an
  /// accidental double-tap is a no-op on the server.
  Future<bool> recordAccountPayment({
    required PaymentMethod method,
    required double amount,
    String cardReceiptUrl = '',
    bool printProof = false,
  }) async {
    if (_isRecordingPayment) {
      return false;
    }

    _isRecordingPayment = true;
    _hasPaymentError = false;
    notifyListeners();

    final signature = _accountPaymentSignature(
      method: method,
      amount: amount,
      cardReceiptUrl: cardReceiptUrl,
    );
    final result = await _contactRepository.recordCustomerAccountPayment(
      _customer.id,
      method: method.apiValue,
      amount: amount,
      cardReceiptUrl: cardReceiptUrl,
      idempotencyKey: _idempotencyKeyFor(signature),
    );
    final didRecord = result is Ok<CustomerSalesSummary>;
    // The record response carries the post-payment summary (the representative
    // payment id + balance after); capture it before the reload below replaces
    // `_summary` with a plain fetch that doesn't include the payment id.
    CustomerSalesSummary? recordedSummary;
    if (didRecord) {
      _clearIdempotencyKey(signature);
      _summary = result.value;
      recordedSummary = result.value;
    } else {
      _hasPaymentError = true;
    }

    _isRecordingPayment = false;
    notifyListeners();

    if (didRecord) {
      // Reload the summary + invoice history so allocated balances and
      // payment statuses reflect the new payment.
      await Future.wait([loadSummary(), loadOrderHistory()]);
      if (printProof && recordedSummary != null) {
        await _printAccountProof(
          summary: recordedSummary,
          method: method,
          amount: amount,
        );
      }
    }
    return didRecord;
  }

  /// Best-effort "سند قبض" for the just-recorded account payment. The payment
  /// spans the customer's open invoices, so the proof carries the
  /// representative payment id + the balance remaining afterwards (there's no
  /// single invoice number). A print failure must not flip the recorded
  /// payment to a failure, so this is awaited only after the record succeeds.
  Future<void> _printAccountProof({
    required CustomerSalesSummary summary,
    required PaymentMethod method,
    required double amount,
  }) async {
    final paymentId = summary.representativePaymentId;
    if (paymentId == null) {
      return;
    }
    final phone = _customer.phone.trim();
    await _paymentProofPrinter.printCustomerAccountReceipt(
      paymentId: paymentId,
      partyName: _customer.fullName,
      partyContact: phone.isNotEmpty ? phone : _customer.customerNumber,
      amount: amount,
      method: method,
      balanceAfter: summary.outstandingBalance,
    );
  }

  String _accountPaymentSignature({
    required PaymentMethod method,
    required double amount,
    String cardReceiptUrl = '',
  }) {
    return [
      'customer-account-payment',
      _customer.id,
      method.apiValue,
      amount.toStringAsFixed(2),
      cardReceiptUrl,
    ].join(':');
  }

  String _idempotencyKeyFor(String signature) {
    return _idempotencyKeysBySignature.putIfAbsent(
      signature,
      () => 'customer-account-payment:${generateAnalyticsEventId()}',
    );
  }

  void _clearIdempotencyKey(String signature) {
    _idempotencyKeysBySignature.remove(signature);
  }

  Future<void> loadOrderHistory() async {
    _isLoadingOrders = true;
    _hasOrderError = false;
    _hasMoreOrders = true;
    _nextOrderPage = 1;
    notifyListeners();

    final result = await _contactRepository.loadCustomerOrderHistory(
      customerId: _customer.id,
      page: _nextOrderPage,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _orderHistory = result.value.orders;
        _hasMoreOrders = result.value.hasMore;
        _nextOrderPage = 2;
      case Error<SaleOrderPage>():
        _orderHistory = [];
        _hasMoreOrders = false;
        _hasOrderError = true;
    }

    _isLoadingOrders = false;
    notifyListeners();
  }

  Future<void> loadMoreOrderHistory() async {
    if (_isLoadingOrders || _isLoadingMoreOrders || !_hasMoreOrders) {
      return;
    }

    _isLoadingMoreOrders = true;
    notifyListeners();

    final result = await _contactRepository.loadCustomerOrderHistory(
      customerId: _customer.id,
      page: _nextOrderPage,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _orderHistory = [..._orderHistory, ...result.value.orders];
        _hasMoreOrders = result.value.hasMore;
        _nextOrderPage += 1;
      case Error<SaleOrderPage>():
        _hasMoreOrders = false;
        _hasOrderError = true;
    }

    _isLoadingMoreOrders = false;
    notifyListeners();
  }

  Future<void> loadAdjustmentHistory() async {
    _isLoadingAdjustments = true;
    _hasAdjustmentError = false;
    _hasMoreAdjustments = true;
    _nextAdjustmentPage = 1;
    notifyListeners();

    final result = await _contactRepository.loadCustomerAdjustmentHistory(
      customerId: _customer.id,
      page: _nextAdjustmentPage,
    );
    switch (result) {
      case Ok<CustomerAdjustmentHistoryPage>():
        _adjustmentHistory = result.value.entries;
        _hasMoreAdjustments = result.value.hasMore;
        _nextAdjustmentPage = 2;
      case Error<CustomerAdjustmentHistoryPage>():
        _adjustmentHistory = [];
        _hasMoreAdjustments = false;
        _hasAdjustmentError = true;
    }

    _isLoadingAdjustments = false;
    notifyListeners();
  }

  Future<void> loadMoreAdjustmentHistory() async {
    if (_isLoadingAdjustments ||
        _isLoadingMoreAdjustments ||
        !_hasMoreAdjustments) {
      return;
    }

    _isLoadingMoreAdjustments = true;
    notifyListeners();

    final result = await _contactRepository.loadCustomerAdjustmentHistory(
      customerId: _customer.id,
      page: _nextAdjustmentPage,
    );
    switch (result) {
      case Ok<CustomerAdjustmentHistoryPage>():
        _adjustmentHistory = [..._adjustmentHistory, ...result.value.entries];
        _hasMoreAdjustments = result.value.hasMore;
        _nextAdjustmentPage += 1;
      case Error<CustomerAdjustmentHistoryPage>():
        _hasMoreAdjustments = false;
        _hasAdjustmentError = true;
    }

    _isLoadingMoreAdjustments = false;
    notifyListeners();
  }
}
