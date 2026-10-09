import 'package:pointy_frontend/dev/services_fixtures.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';

import 'voucher_menu_testing.dart';

/// The menu of the shared fixture (آيتونز, بلايستيشن, ليبيانا), the direct
/// services, and a prepaid Mastercard that answers to «Visa».
VoucherMenu searchMenu({bool aliases = true}) {
  final json = voucherMenuJson(withCost: false);
  json['services'] = servicesPreviewMenuServicesJson();
  final brands = <Object?>[...(json['brands']! as List)];
  final libyana = (brands.last! as Map).cast<String, Object?>();
  brands.add({
    ...libyana,
    'key': 'mastercard',
    'name': 'ماستركارد',
    'category': 'gift_cards',
    if (aliases) 'aliases': ['Mastercard', 'Visa', 'فيزا'],
  });
  json['brands'] = brands;
  return VoucherMenu.fromJson(json);
}
