/// A small in-memory shop the learning module practises against.
///
/// Not a second backend. It owns *invariants* — stock decrements, sequences
/// advance, a drawer accumulates, a debt grows and shrinks — and nothing else:
/// no discount engine, no valuation, no permissions. Where a lesson needs a
/// computed number, the seed supplies it.
///
/// Everything here is disposable. Closing a lesson throws the object away, and
/// "start over" is a constructor call.
library;

import '../../../data/services/local_scoped_json_storage.dart';
import '../engine/expectations.dart';
import 'sandbox_models.dart';

export 'sandbox_models.dart';

/// Hands out ids for things a practice run creates, and keeps their local
/// storage off the device.
///
/// Synthetic, and fresh per run, for three reasons that all bite:
///
/// * The sandboxed app writes its cart to the **device's** local storage keyed
///   by user id. A practice cart saved under a real user's id is restored into
///   the real till the next time that cashier signs in — practice goods in a
///   real sale, which is exactly what training mode must never do.
/// * A practice cart left from the previous lesson restores into the next one
///   and satisfies its first steps before the learner touches anything, so the
///   narration immediately stops describing the screen.
/// * A stock count's un-submitted keypad entry is keyed by the *count session*
///   id, which the sandbox would otherwise hand out as 1 — the id of a real
///   count on any shop that has ever run one.
///
/// Every id is registered with [PracticeStorageScopes], so anything the real
/// view models try to persist under it is diverted to memory and thrown away
/// with the process. Nothing to sweep, and nothing left behind when a learner
/// abandons a lesson halfway.
int _nextPracticeId = PracticeStorageScopes.idFloor + 1;

int nextPracticeId() {
  final id = _nextPracticeId++;
  PracticeStorageScopes.register('$id');
  return id;
}

/// The practice cashier. Named separately because every seed needs one and the
/// call sites read better for it.
int nextPracticeCashierId() => nextPracticeId();

/// The whole practice shop.
class SandboxShop {
  SandboxShop({
    required this.shopName,
    required this.categories,
    required this.products,
    required this.contacts,
    required this.cashierId,
    required this.cashierName,
    required this.cashierRole,
    this.cashierPermissions = const <String>[],
    this.requireOpeningCash = true,
  });

  final String shopName;
  final List<SandboxCategory> categories;
  final List<SandboxProduct> products;
  final List<SandboxContact> contacts;
  final int cashierId;
  final String cashierName;
  final String cashierRole;

  /// Django permission codenames the practice user holds. A cashier seed hands
  /// out none; a back-office seed hands out the ones its lessons need, so the
  /// learner never lands on a screen their practice account cannot open.
  final List<String> cashierPermissions;
  final bool requireOpeningCash;

  final List<SandboxOrder> orders = [];
  final List<SandboxPurchaseOrder> purchaseOrders = [];
  SandboxRegisterSession? session;

  int _nextOrderId = 1;
  int _nextSessionId = 1;
  int _nextReceipt = 1;
  int _nextProductId = 1000;
  int _nextVariantId = 5000;
  int _nextContactId = 500;
  int _nextPurchaseOrderId = 1;

  /// Money the shop has paid suppliers during this run.
  double supplierPaidTotal = 0;

  /// Bumped on every write so the app's "what changed" polling sees movement
  /// exactly as it would against the real backend.
  int stateVersion = 1;

  // --- lookups -------------------------------------------------------------

  Iterable<SandboxContact> get customers =>
      contacts.where((contact) => !contact.isSupplier);

  Iterable<SandboxContact> get suppliers =>
      contacts.where((contact) => contact.isSupplier);

  SandboxContact? contactById(int id) {
    for (final contact in contacts) {
      if (contact.id == id) {
        return contact;
      }
    }
    return null;
  }

  SandboxContact? contactByName(String name) {
    for (final contact in contacts) {
      if (contact.name == name) {
        return contact;
      }
    }
    return null;
  }

  SandboxVariant? variantById(int id) {
    for (final product in products) {
      for (final variant in product.variants) {
        if (variant.id == id) {
          return variant;
        }
      }
    }
    return null;
  }

  SandboxVariant? variantBySku(String sku) {
    for (final product in products) {
      for (final variant in product.variants) {
        if (variant.sku == sku) {
          return variant;
        }
      }
    }
    return null;
  }

  SandboxProduct? productOfVariant(int variantId) {
    for (final product in products) {
      if (product.variants.any((variant) => variant.id == variantId)) {
        return product;
      }
    }
    return null;
  }

  SandboxProduct? productByName(String name) {
    for (final product in products) {
      if (product.name == name) {
        return product;
      }
    }
    return null;
  }

  SandboxVariant? variantByBarcode(String barcode) {
    final needle = barcode.trim();
    if (needle.isEmpty) {
      return null;
    }
    for (final product in products) {
      for (final variant in product.variants) {
        if (variant.sku == needle || variant.allBarcodes.contains(needle)) {
          return variant;
        }
      }
    }
    return null;
  }

  SandboxOrder? orderById(int id) {
    for (final order in orders) {
      if (order.id == id) {
        return order;
      }
    }
    return null;
  }

  SandboxOrder? orderByReceipt(String receiptNumber) {
    final needle = receiptNumber.trim();
    for (final order in orders) {
      if (order.receiptNumber == needle) {
        return order;
      }
    }
    return null;
  }

  SandboxPurchaseOrder? purchaseOrderById(int id) {
    for (final order in purchaseOrders) {
      if (order.id == id) {
        return order;
      }
    }
    return null;
  }

  // --- register ------------------------------------------------------------

  SandboxRegisterSession openSession({required double openingCash}) {
    final id = _nextSessionId++;
    final opened = SandboxRegisterSession(
      id: id,
      sessionNumber: 'S${id.toString().padLeft(4, '0')}',
      openingCash: openingCash,
      ownerName: cashierName,
      openedAt: DateTime.now(),
    );
    session = opened;
    stateVersion++;
    return opened;
  }

  SandboxRegisterSession? closeSession({required double countedCash}) {
    final open = session;
    if (open == null) {
      return null;
    }
    open.status = 'closed';
    open.closingCash = countedCash;
    open.closedAt = DateTime.now();
    stateVersion++;
    return open;
  }

  void recordCashMovement({required String direction, required double amount}) {
    final open = session;
    if (open == null) {
      return;
    }
    if (direction == 'pay_in') {
      open.payInTotal += amount;
    } else {
      open.payOutTotal += amount;
    }
    stateVersion++;
  }

  // --- selling -------------------------------------------------------------

  /// Records a sale: decrements stock, advances the sequences, adds the cash
  /// part to the drawer, and puts anything unpaid on the customer's account.
  /// The four things a learner has to *see* happen.
  SandboxOrder recordSale({
    required List<({int variantId, double quantity, double? unitPrice})> lines,
    required List<SandboxPayment> payments,
    required String saleType,
    int? customerId,
  }) {
    final orderLines = <SandboxOrderLine>[];
    for (final line in lines) {
      final variant = variantById(line.variantId);
      final product = productOfVariant(line.variantId);
      if (variant == null || product == null) {
        continue;
      }
      // A quotation reserves nothing and sells nothing: it is an offer, and
      // stock that moved on an offer is the classic way a quotation flow gets
      // taught wrong.
      if (saleType != 'quotation' &&
          !product.isService &&
          !product.isPrepared) {
        variant.stock -= line.quantity;
      }
      orderLines.add(
        SandboxOrderLine(
          variantId: variant.id,
          sku: variant.sku,
          productName: product.name,
          variantName: variant.name,
          quantity: line.quantity,
          unitPrice: line.unitPrice ?? variant.unitPrice,
        ),
      );
    }

    final customer = customerId == null ? null : contactById(customerId);
    final order = SandboxOrder(
      id: _nextOrderId++,
      receiptNumber: 'INV-${(_nextReceipt++).toString().padLeft(4, '0')}',
      lines: orderLines,
      payments: payments,
      saleType: saleType,
      createdAt: DateTime.now(),
      sessionId: session?.id,
      sessionNumber: session?.sessionNumber ?? '',
      cashierId: cashierId,
      cashierName: cashierName,
      customerId: customer?.id,
      customerName: customer?.name ?? '',
    );
    orders.add(order);

    final open = session;
    if (open != null && saleType != 'quotation') {
      open.cashSalesTotal += order.cashPaid;
    }
    // The unpaid remainder of a credit sale is the customer's debt. This is the
    // single number the whole آجل flow exists to move, so the practice shop
    // moves it for real.
    if (saleType == 'credit' && customer != null && order.balanceDue > 0) {
      customer.balance += order.balanceDue;
    }
    stateVersion++;
    return order;
  }

  /// A customer pays down what they owe. Cash lands in the drawer exactly as a
  /// sale's would — a shop that forgets this is a shop whose close never
  /// balances.
  double recordCustomerPayment({
    required int customerId,
    required double amount,
    String method = 'cash',
  }) {
    final customer = contactById(customerId);
    if (customer == null) {
      return 0;
    }
    customer.balance -= amount;
    final open = session;
    if (open != null && method == 'cash') {
      open.payInTotal += amount;
    }
    stateVersion++;
    return customer.balance;
  }

  // --- contacts ------------------------------------------------------------

  SandboxContact createContact({
    required String name,
    required bool isSupplier,
    String phone = '',
  }) {
    final contact = SandboxContact(
      id: _nextContactId++,
      name: name,
      isSupplier: isSupplier,
      phone: phone,
    );
    contacts.add(contact);
    stateVersion++;
    return contact;
  }

  // --- catalogue -----------------------------------------------------------

  SandboxProduct createProduct({
    required String name,
    required List<({String name, String sku, String barcode, double price})>
    variants,
    String unit = 'piece',
    List<int> categoryIds = const [],
  }) {
    final product = SandboxProduct(
      id: _nextProductId++,
      name: name,
      unit: unit,
      categoryIds: categoryIds,
      variants: [],
    );
    for (final (index, variant) in variants.indexed) {
      product.variants.add(
        SandboxVariant(
          id: _nextVariantId++,
          name: variant.name,
          sku: variant.sku,
          barcode: variant.barcode,
          unitPrice: variant.price,
          stock: 0,
          isDefault: index == 0,
        ),
      );
    }
    products.add(product);
    stateVersion++;
    return product;
  }

  SandboxVariant? addVariant({
    required int productId,
    required String name,
    required String sku,
    required String barcode,
    required double price,
  }) {
    for (final product in products) {
      if (product.id != productId) {
        continue;
      }
      final variant = SandboxVariant(
        id: _nextVariantId++,
        name: name,
        sku: sku,
        barcode: barcode,
        unitPrice: price,
        stock: 0,
        isDefault: product.variants.isEmpty,
      );
      product.variants.add(variant);
      stateVersion++;
      return variant;
    }
    return null;
  }

  /// Adds a packaging code to a variant. Duplicates are ignored rather than
  /// rejected: the practice shop is not the identity checker, and a lesson
  /// that dead-ends on a validation message teaches nothing.
  void addBarcode({required int variantId, required String barcode}) {
    final variant = variantById(variantId);
    final code = barcode.trim();
    if (variant == null || code.isEmpty) {
      return;
    }
    if (variant.allBarcodes.contains(code)) {
      return;
    }
    variant.extraBarcodes.add(code);
    stateVersion++;
  }

  void setVariantPrice({required int variantId, required double price}) {
    variantById(variantId)?.unitPrice = price;
    stateVersion++;
  }

  void adjustStock({required int variantId, required double delta}) {
    final variant = variantById(variantId);
    if (variant == null) {
      return;
    }
    variant.stock += delta;
    stateVersion++;
  }

  // --- purchasing ----------------------------------------------------------

  SandboxPurchaseOrder createPurchaseOrder({
    required int supplierId,
    required List<({int variantId, double quantity, double unitCost})> lines,
    String status = 'draft',
  }) {
    final supplier = contactById(supplierId);
    final id = _nextPurchaseOrderId++;
    final order = SandboxPurchaseOrder(
      id: id,
      reference: 'PO-${id.toString().padLeft(4, '0')}',
      supplierId: supplierId,
      supplierName: supplier?.name ?? '',
      createdAt: DateTime.now(),
      status: status,
      lines: [
        for (final line in lines)
          if (variantById(line.variantId) != null)
            SandboxPurchaseOrderLine(
              variantId: line.variantId,
              sku: variantById(line.variantId)!.sku,
              productName: productOfVariant(line.variantId)?.name ?? '',
              quantity: line.quantity,
              unitCost: line.unitCost,
            ),
      ],
    );
    purchaseOrders.add(order);
    stateVersion++;
    return order;
  }

  SandboxPurchaseOrder? submitPurchaseOrder(int id) {
    final order = purchaseOrderById(id);
    if (order == null) {
      return null;
    }
    order.status = 'submitted';
    stateVersion++;
    return order;
  }

  /// Receiving is where stock actually arrives. A delivery that came up short
  /// is the whole point of the lesson, so receiving less than ordered is a
  /// first-class outcome and leaves the order `partially_received`.
  SandboxPurchaseOrder? receivePurchaseOrder({
    required int id,
    required List<({int variantId, double quantity})> lines,
  }) {
    final order = purchaseOrderById(id);
    if (order == null) {
      return null;
    }
    for (final received in lines) {
      for (final line in order.lines) {
        if (line.variantId != received.variantId) {
          continue;
        }
        line.receivedQuantity += received.quantity;
        variantById(line.variantId)?.stock += received.quantity;
      }
    }
    order.status = order.isFullyReceived
        ? 'received'
        : (order.isPartiallyReceived ? 'partially_received' : order.status);
    stateVersion++;
    return order;
  }

  void recordSupplierPayment({
    required int supplierId,
    required double amount,
    int? purchaseOrderId,
    String method = 'cash',
  }) {
    supplierPaidTotal += amount;
    contactById(supplierId)?.balance -= amount;
    if (purchaseOrderId != null) {
      purchaseOrderById(purchaseOrderId)?.paidTotal += amount;
    }
    final open = session;
    if (open != null && method == 'cash') {
      open.payOutTotal += amount;
    }
    stateVersion++;
  }

  // --- what a lesson asserts on -------------------------------------------

  double stockOf(String sku) => variantBySku(sku)?.stock ?? double.nan;

  double get drawerCash => session?.expectedCash ?? 0;

  int get orderCount => orders.length;

  SandboxOrder? get lastOrder => orders.isEmpty ? null : orders.last;

  SandboxPurchaseOrder? get lastPurchaseOrder =>
      purchaseOrders.isEmpty ? null : purchaseOrders.last;

  /// One reader for every number an expectation can ask for. Returning NaN for
  /// an unknown key is deliberate: NaN compares false against everything, so a
  /// lesson naming a product that no longer exists fails instead of quietly
  /// passing on a zero.
  double readMetric(TutorShopMetric metric, String? key) {
    return switch (metric) {
      TutorShopMetric.orderCount => orders.length.toDouble(),
      TutorShopMetric.stock => stockOf(key ?? ''),
      TutorShopMetric.drawerCash => drawerCash,
      TutorShopMetric.drawerPayIn => session?.payInTotal ?? double.nan,
      TutorShopMetric.drawerPayOut => session?.payOutTotal ?? double.nan,
      TutorShopMetric.productCount => products.length.toDouble(),
      TutorShopMetric.variantCount =>
        productByName(key ?? '')?.variants.length.toDouble() ?? double.nan,
      TutorShopMetric.barcodeCount =>
        variantBySku(key ?? '')?.allBarcodes.length.toDouble() ?? double.nan,
      TutorShopMetric.unitPrice =>
        variantBySku(key ?? '')?.unitPrice ?? double.nan,
      TutorShopMetric.customerCount => customers.length.toDouble(),
      TutorShopMetric.customerBalance =>
        contactByName(key ?? '')?.balance ?? double.nan,
      TutorShopMetric.purchaseOrderCount => purchaseOrders.length.toDouble(),
      TutorShopMetric.receivedQuantity => _receivedQuantityOf(key ?? ''),
      TutorShopMetric.supplierPaidTotal => supplierPaidTotal,
      TutorShopMetric.lastOrderTotal => lastOrder?.total ?? double.nan,
      TutorShopMetric.lastOrderPaidTotal => lastOrder?.paid ?? double.nan,
      TutorShopMetric.paymentCount => _paymentCountOf(key ?? ''),
      TutorShopMetric.sessionOpen => session?.status == 'open' ? 1 : 0,
    };
  }

  String readText(TutorShopText field) {
    return switch (field) {
      TutorShopText.lastOrderSaleType => lastOrder?.saleType ?? '',
      TutorShopText.lastPurchaseOrderStatus => lastPurchaseOrder?.status ?? '',
      TutorShopText.sessionStatus => session?.status ?? '',
    };
  }

  double _receivedQuantityOf(String sku) {
    final order = lastPurchaseOrder;
    if (order == null) {
      return double.nan;
    }
    for (final line in order.lines) {
      if (line.sku == sku) {
        return line.receivedQuantity;
      }
    }
    return double.nan;
  }

  double _paymentCountOf(String method) {
    final order = lastOrder;
    if (order == null) {
      return double.nan;
    }
    return order.payments
        .where((payment) => payment.method == method)
        .length
        .toDouble();
  }
}
