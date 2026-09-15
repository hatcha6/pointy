import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../sandbox/sandbox_shop.dart';

/// What the runner reads to decide whether a step is done.
///
/// Split deliberately between the widget tree (what the learner can see) and
/// the sandbox shop (what actually moved). A lesson that only checked the
/// screen would pass while teaching a sale that never happened.
class TutorState {
  const TutorState({
    required this.shop,
    required this.countOf,
    required this.textOf,
  });

  final SandboxShop shop;
  final int Function(TutorAnchor anchor, {String? id}) countOf;
  final String? Function(TutorAnchor anchor, {String? id}) textOf;

  bool isVisible(TutorAnchor anchor, {String? id}) =>
      countOf(anchor, id: id) > 0;
}

/// A number the practice shop can be asked for.
///
/// One enum and one class instead of twenty near-identical ones: every
/// expectation below is "read a number out of the shop and compare it", and
/// spelling that out twenty times buys nothing but twenty places to get the
/// tolerance wrong.
enum TutorShopMetric {
  orderCount,
  stock,
  drawerCash,
  drawerPayIn,
  drawerPayOut,
  productCount,
  variantCount,
  barcodeCount,
  unitPrice,
  customerCount,
  customerBalance,
  purchaseOrderCount,
  receivedQuantity,
  supplierPaidTotal,
  lastOrderTotal,
  lastOrderPaidTotal,
  paymentCount,
  sessionOpen,
}

/// Text the practice shop can be asked for — a status, a type, a name.
enum TutorShopText { lastOrderSaleType, lastPurchaseOrderStatus, sessionStatus }

sealed class TutorExpect {
  const TutorExpect();

  const factory TutorExpect.visible(TutorAnchor anchor, {String? id}) =
      TutorExpectVisible;
  const factory TutorExpect.fieldEquals(
    TutorAnchor anchor,
    String value, {
    String? id,
  }) = TutorExpectFieldEquals;
  const factory TutorExpect.anchorCount(
    TutorAnchor anchor,
    int count, {
    String? id,
  }) = TutorExpectAnchorCount;
  const factory TutorExpect.all(List<TutorExpect> parts) = TutorExpectAll;
  const factory TutorExpect.sessionOpen() = TutorExpectShopValue.sessionOpen;

  // --- the shop's own numbers ---------------------------------------------
  const factory TutorExpect.orderCount(int count) =
      TutorExpectShopValue.orderCount;
  const factory TutorExpect.stockOf(String sku, double quantity) =
      TutorExpectShopValue.stockOf;
  const factory TutorExpect.drawerCash(double amount) =
      TutorExpectShopValue.drawerCash;
  const factory TutorExpect.drawerPaidIn(double amount) =
      TutorExpectShopValue.drawerPaidIn;
  const factory TutorExpect.drawerPaidOut(double amount) =
      TutorExpectShopValue.drawerPaidOut;
  const factory TutorExpect.productCount(int count) =
      TutorExpectShopValue.productCount;
  const factory TutorExpect.variantCountOf(String product, int count) =
      TutorExpectShopValue.variantCountOf;
  const factory TutorExpect.barcodeCountOf(String sku, int count) =
      TutorExpectShopValue.barcodeCountOf;
  const factory TutorExpect.unitPriceOf(String sku, double price) =
      TutorExpectShopValue.unitPriceOf;
  const factory TutorExpect.customerCount(int count) =
      TutorExpectShopValue.customerCount;
  const factory TutorExpect.customerBalanceOf(String name, double balance) =
      TutorExpectShopValue.customerBalanceOf;
  const factory TutorExpect.purchaseOrderCount(int count) =
      TutorExpectShopValue.purchaseOrderCount;
  const factory TutorExpect.receivedQuantityOf(String sku, double quantity) =
      TutorExpectShopValue.receivedQuantityOf;
  const factory TutorExpect.supplierPaidTotal(double amount) =
      TutorExpectShopValue.supplierPaidTotal;
  const factory TutorExpect.lastOrderTotal(double amount) =
      TutorExpectShopValue.lastOrderTotal;
  const factory TutorExpect.lastOrderPaidTotal(double amount) =
      TutorExpectShopValue.lastOrderPaidTotal;
  const factory TutorExpect.paymentCountOf(String method, int count) =
      TutorExpectShopValue.paymentCountOf;

  // --- the shop's own words ------------------------------------------------
  const factory TutorExpect.lastOrderSaleType(String saleType) =
      TutorExpectShopWord.lastOrderSaleType;
  const factory TutorExpect.lastPurchaseOrderStatus(String status) =
      TutorExpectShopWord.lastPurchaseOrderStatus;
  const factory TutorExpect.sessionStatus(String status) =
      TutorExpectShopWord.sessionStatus;

  bool isSatisfiedBy(TutorState state);

  /// Anchors this expectation reads.
  ///
  /// An expectation can name an anchor no step ever points at — "the cart now
  /// says أحمد" is checked, never tapped — so the staleness guard has to walk
  /// these too, or a dead anchor hides behind a lesson that still passes for
  /// the wrong reason.
  Iterable<TutorAnchor> get anchorsRead => const [];

  /// Human-readable failure line for CI. Arabic would be wrong here — this is
  /// read by whoever broke the build, in a test report.
  String describe();
}

class TutorExpectVisible extends TutorExpect {
  const TutorExpectVisible(this.anchor, {this.id});

  final TutorAnchor anchor;
  final String? id;

  @override
  bool isSatisfiedBy(TutorState state) => state.isVisible(anchor, id: id);

  @override
  Iterable<TutorAnchor> get anchorsRead => [anchor];

  @override
  String describe() => 'anchor ${TutorTargetId(anchor, id)} is on screen';
}

class TutorExpectFieldEquals extends TutorExpect {
  const TutorExpectFieldEquals(this.anchor, this.value, {this.id});

  final TutorAnchor anchor;
  final String value;
  final String? id;

  @override
  bool isSatisfiedBy(TutorState state) =>
      state.textOf(anchor, id: id)?.trim() == value;

  @override
  Iterable<TutorAnchor> get anchorsRead => [anchor];

  @override
  String describe() => 'field ${TutorTargetId(anchor, id)} contains "$value"';
}

class TutorExpectAnchorCount extends TutorExpect {
  const TutorExpectAnchorCount(this.anchor, this.count, {this.id});

  final TutorAnchor anchor;
  final int count;
  final String? id;

  @override
  bool isSatisfiedBy(TutorState state) =>
      state.countOf(anchor, id: id) == count;

  @override
  Iterable<TutorAnchor> get anchorsRead => [anchor];

  @override
  String describe() =>
      'anchor ${TutorTargetId(anchor, id)} appears $count time(s)';
}

/// Reads one number out of the practice shop and compares it.
class TutorExpectShopValue extends TutorExpect {
  const TutorExpectShopValue._(this.metric, this.value, [this.key]);

  const TutorExpectShopValue.orderCount(int count)
    : this._(TutorShopMetric.orderCount, count);
  const TutorExpectShopValue.stockOf(String sku, double quantity)
    : this._(TutorShopMetric.stock, quantity, sku);
  const TutorExpectShopValue.drawerCash(double amount)
    : this._(TutorShopMetric.drawerCash, amount);
  const TutorExpectShopValue.drawerPaidIn(double amount)
    : this._(TutorShopMetric.drawerPayIn, amount);
  const TutorExpectShopValue.drawerPaidOut(double amount)
    : this._(TutorShopMetric.drawerPayOut, amount);
  const TutorExpectShopValue.productCount(int count)
    : this._(TutorShopMetric.productCount, count);
  const TutorExpectShopValue.variantCountOf(String product, int count)
    : this._(TutorShopMetric.variantCount, count, product);
  const TutorExpectShopValue.barcodeCountOf(String sku, int count)
    : this._(TutorShopMetric.barcodeCount, count, sku);
  const TutorExpectShopValue.unitPriceOf(String sku, double price)
    : this._(TutorShopMetric.unitPrice, price, sku);
  const TutorExpectShopValue.customerCount(int count)
    : this._(TutorShopMetric.customerCount, count);
  const TutorExpectShopValue.customerBalanceOf(String name, double balance)
    : this._(TutorShopMetric.customerBalance, balance, name);
  const TutorExpectShopValue.purchaseOrderCount(int count)
    : this._(TutorShopMetric.purchaseOrderCount, count);
  const TutorExpectShopValue.receivedQuantityOf(String sku, double quantity)
    : this._(TutorShopMetric.receivedQuantity, quantity, sku);
  const TutorExpectShopValue.supplierPaidTotal(double amount)
    : this._(TutorShopMetric.supplierPaidTotal, amount);
  const TutorExpectShopValue.lastOrderTotal(double amount)
    : this._(TutorShopMetric.lastOrderTotal, amount);
  const TutorExpectShopValue.lastOrderPaidTotal(double amount)
    : this._(TutorShopMetric.lastOrderPaidTotal, amount);
  const TutorExpectShopValue.paymentCountOf(String method, int count)
    : this._(TutorShopMetric.paymentCount, count, method);
  const TutorExpectShopValue.sessionOpen()
    : this._(TutorShopMetric.sessionOpen, 1);

  final TutorShopMetric metric;
  final num value;
  final String? key;

  @override
  bool isSatisfiedBy(TutorState state) =>
      (state.shop.readMetric(metric, key) - value).abs() < 0.001;

  @override
  String describe() {
    if (metric == TutorShopMetric.sessionOpen) {
      return 'a register session is open';
    }
    final subject = key == null ? metric.name : '${metric.name} of $key';
    return '$subject is $value';
  }
}

/// Reads one word out of the practice shop and compares it.
class TutorExpectShopWord extends TutorExpect {
  const TutorExpectShopWord._(this.field, this.value);

  const TutorExpectShopWord.lastOrderSaleType(String saleType)
    : this._(TutorShopText.lastOrderSaleType, saleType);
  const TutorExpectShopWord.lastPurchaseOrderStatus(String status)
    : this._(TutorShopText.lastPurchaseOrderStatus, status);
  const TutorExpectShopWord.sessionStatus(String status)
    : this._(TutorShopText.sessionStatus, status);

  final TutorShopText field;
  final String value;

  @override
  bool isSatisfiedBy(TutorState state) => state.shop.readText(field) == value;

  @override
  String describe() => '${field.name} is "$value"';
}

class TutorExpectAll extends TutorExpect {
  const TutorExpectAll(this.parts);

  final List<TutorExpect> parts;

  @override
  Iterable<TutorAnchor> get anchorsRead => [
    for (final part in parts) ...part.anchorsRead,
  ];

  @override
  bool isSatisfiedBy(TutorState state) =>
      parts.every((part) => part.isSatisfiedBy(state));

  @override
  String describe() => parts.map((part) => part.describe()).join(' AND ');

  /// The first part that is not yet true — what CI should name.
  TutorExpect? firstUnsatisfied(TutorState state) {
    for (final part in parts) {
      if (!part.isSatisfiedBy(state)) {
        return part;
      }
    }
    return null;
  }
}
