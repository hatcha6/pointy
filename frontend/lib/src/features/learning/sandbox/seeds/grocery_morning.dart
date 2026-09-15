import '../sandbox_shop.dart';

/// A dozen products a Libyan cashier recognises, three customers, two
/// suppliers, one till, nothing open.
///
/// Small and legible on purpose (§5): a learner should be able to hold the
/// whole practice shop in their head, and a lesson's expected numbers should be
/// checkable by hand. This is not a simulation dump.
///
/// One shop, two practice users. The catalogue, prices and stock stay identical
/// whichever lesson a learner opens — so what they learned on the till still
/// describes the shop when they open a purchase order — and only the account
/// they are signed in as changes.
SandboxShop groceryMorningSeed() =>
    _shop(cashierName: 'متدرّب', cashierRole: 'cashier');

/// The same shop seen from the office: a manager, who can reach the catalogue,
/// purchasing, inventory and the reports.
///
/// Seeding a back-office lesson with the cashier would open it on a screen the
/// practice account is not allowed to see — a blank pane with a permissions
/// message, which teaches the learner that the software is broken.
SandboxShop groceryBackOfficeSeed() =>
    _shop(cashierName: 'مدير التدريب', cashierRole: 'manager');

/// The back office with an order already on its way.
///
/// Receiving is a lesson about a delivery, and a delivery needs an order that
/// was placed *before* the learner sat down: ten cartons of milk from مخازن
/// الأمل, sent and unreceived — the state a receiving clerk always finds the
/// shop in.
SandboxShop groceryBackOfficeWithOrderSeed() {
  final shop = groceryBackOfficeSeed();
  final milk = shop.variantBySku('PCE1')!;
  shop.createPurchaseOrder(
    supplierId: 301,
    status: 'submitted',
    lines: [(variantId: milk.id, quantity: 10, unitCost: 2.10)],
  );
  return shop;
}

/// The same order, delivered in full and still unpaid.
///
/// Paying a supplier is a lesson about goods you already have: while anything
/// is still outstanding the shop's next step is to receive it, and the screen
/// says so by putting receiving first.
SandboxShop groceryBackOfficeWithDeliverySeed() {
  final shop = groceryBackOfficeWithOrderSeed();
  final order = shop.lastPurchaseOrder!;
  shop.receivePurchaseOrder(
    id: order.id,
    lines: [
      for (final line in order.lines)
        (variantId: line.variantId, quantity: line.quantity),
    ],
  );
  return shop;
}

SandboxShop _shop({required String cashierName, required String cashierRole}) {
  return SandboxShop(
    shopName: 'بقالة التدريب',
    cashierId: nextPracticeCashierId(),
    cashierName: cashierName,
    cashierRole: cashierRole,
    categories: const [
      SandboxCategory(id: 1, name: 'مواد غذائية'),
      SandboxCategory(id: 2, name: 'مشروبات'),
      SandboxCategory(id: 3, name: 'منظفات'),
    ],
    contacts: [
      // One customer already owes money, so the debt lessons have something to
      // collect without first having to sell on credit.
      SandboxContact(
        id: 201,
        name: 'أحمد المبروك',
        isSupplier: false,
        phone: '0910000001',
      ),
      SandboxContact(
        id: 202,
        name: 'فاطمة الزهراء',
        isSupplier: false,
        phone: '0910000002',
        balance: 120,
      ),
      SandboxContact(
        id: 203,
        name: 'مقهى الواحة',
        isSupplier: false,
        phone: '0910000003',
      ),
      SandboxContact(
        id: 301,
        name: 'مخازن الأمل',
        isSupplier: true,
        phone: '0920000001',
      ),
      SandboxContact(
        id: 302,
        name: 'شركة النور للتوزيع',
        isSupplier: true,
        phone: '0920000002',
      ),
    ],
    products: [
      _simple(1, 'خبز', 'PCE0', '6001000000011', 0.50, 40, [1]),
      _simple(2, 'حليب طازج ١ لتر', 'PCE1', '6001000000028', 3.00, 24, [1]),
      _simple(3, 'بيض ٣٠ حبة', 'PCE2', '6001000000035', 12.00, 10, [1]),
      _simple(4, 'أرز ٥ كغ', 'PCE3', '6001000000042', 22.50, 15, [1]),
      _simple(5, 'زيت ذرة ١ لتر', 'PCE4', '6001000000059', 9.75, 18, [1]),
      _simple(6, 'سكر ١ كغ', 'PCE5', '6001000000066', 4.25, 30, [1]),
      _simple(7, 'شاي أخضر', 'PCE6', '6001000000073', 6.00, 22, [1]),
      _simple(8, 'ماء ١.٥ لتر', 'PCE7', '6001000000080', 1.00, 60, [2]),
      _simple(9, 'مشروب غازي', 'PCE8', '6001000000097', 2.50, 48, [2]),
      _simple(10, 'عصير برتقال', 'PCE9', '6001000000103', 5.50, 20, [2]),
      _simple(11, 'صابون غسيل', 'PCE10', '6001000000110', 7.25, 14, [3]),
      _simple(12, 'مناديل ورقية', 'PCE11', '6001000000127', 3.75, 26, [3]),
    ],
  );
}

SandboxProduct _simple(
  int id,
  String name,
  String sku,
  String barcode,
  double price,
  double stock,
  List<int> categories,
) {
  return SandboxProduct(
    id: id,
    name: name,
    categoryIds: categories,
    variants: [
      SandboxVariant(
        // Variant ids are offset so a variant id can never be mistaken for a
        // product id in a lesson assertion.
        id: 1000 + id,
        name: '',
        sku: sku,
        barcode: barcode,
        unitPrice: price,
        stock: stock,
      ),
    ],
  );
}
