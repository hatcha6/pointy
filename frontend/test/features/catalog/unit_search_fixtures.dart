import 'package:pointy_frontend/src/data/models/stock_unit.dart';

/// The identifier lookup's answers, as the server sends them, for the catalog's
/// unit-search tests and the screenshot run.
const imei = '351234567890116';
const secondImei = '356938035643809';

Map<String, Object?> liveUnitJson({int id = 41, String code = imei}) => {
  'id': id,
  'variant': 7,
  'code': code,
  'identifier_kind': 'imei',
  'secondary_code': secondImei,
  'status': 'in_stock',
  'warehouse': 1,
  'warehouse_name': 'المحل الرئيسي',
  'product_name': 'آيفون 13 برو',
  'variant_name': 'آيفون 13 برو · 256GB أزرق',
  'list_price': null,
  'asking_price': '1450.00',
  'in_stock_since': DateTime.now()
      .subtract(const Duration(days: 23))
      .toIso8601String(),
  'customer': null,
  'customer_name': '',
  'sold_order': null,
  'sold_receipt_number': '',
};

Map<String, Object?> soldUnitJson({
  int id = 40,
  String customerName = 'أحمد علي',
  int orderId = 900,
  String receipt = 'INV-000123',
  DateTime? soldAt,
  DateTime? warrantyExpiresOn,
  bool withSale = true,
}) => {
  'id': id,
  'variant': 7,
  'code': imei,
  'identifier_kind': 'imei',
  'secondary_code': secondImei,
  'status': 'sold',
  'warehouse': 1,
  'warehouse_name': 'المحل الرئيسي',
  'product_name': 'آيفون 13 برو',
  'variant_name': 'آيفون 13 برو · 256GB أزرق',
  'sold_price': '1400.00',
  'asking_price': '1450.00',
  'sold_at': (soldAt ?? DateTime(2026, 3, 12, 11)).toIso8601String(),
  'warranty_expires_on': (warrantyExpiresOn ?? DateTime(2027, 3, 12))
      .toIso8601String()
      .substring(0, 10),
  'customer': 5,
  if (withSale) ...{
    'customer_name': customerName,
    'sold_order': orderId,
    'sold_receipt_number': receipt,
  },
};

StockUnitLookup lookupOf({
  Map<String, Object?>? unit,
  List<Map<String, Object?>> history = const [],
  Map<String, Object?>? warranty,
}) => StockUnitLookup.fromJson({
  'unit': unit,
  'history': history,
  'warranty': warranty,
});

Map<String, Object?> coveredWarranty({int repairs = 0}) => {
  'sold_at': '2026-03-12T11:00:00',
  'customer': 5,
  'expires_on': '2027-03-12',
  'is_covered': true,
  'days_remaining': 158,
  'repair_count': repairs,
};
