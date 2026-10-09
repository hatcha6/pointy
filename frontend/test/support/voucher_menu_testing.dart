import 'dart:convert';
import 'dart:typed_data';

/// A real 1×1 PNG, so a flag decodes and draws in a widget test.
final Uint8List voucherFlagBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// The «كروت دفتر» menu as `GET /api/integrations/vouchers/menu/` serves it:
/// آيتونز for two countries (one card on promotion, one dearer than the
/// voucher balance, one sold out), بلايستيشن and ليبيانا for one each.
///
/// [withCost] is a reader with full visibility; a cashier is sent no cost.
Map<String, Object?> voucherMenuJson({
  bool withCost = true,
  List<Map<String, Object?>> extraCategories = const [],
}) {
  Map<String, Object?> item(
    int variantId,
    String country,
    String countryName,
    String label,
    double price, {
    double? regular,
    double cost = 0,
    String badge = '',
    bool available = true,
    bool exceedsFloat = false,
  }) {
    return {
      'variant_id': variantId,
      'key': 'card-$variantId',
      'label': label,
      'name': '$countryName · $label',
      'country': country,
      'face_value': label.split(' ').first,
      'face_currency': switch (country) {
        'US' => 'USD',
        'GB' => 'GBP',
        _ => 'LYD',
      },
      'price': price.toStringAsFixed(2),
      'regular_price': (regular ?? price).toStringAsFixed(2),
      'badge': badge,
      'promo_ends_at': badge.isEmpty ? null : '2026-10-20T00:00:00Z',
      'available': available,
      'exceeds_float': exceedsFloat,
      if (withCost) 'cost': cost.toStringAsFixed(2),
    };
  }

  Map<String, Object?> product(
    int id,
    String name,
    List<Map<String, Object?>> items, {
    bool art = false,
  }) {
    return {
      'id': id,
      'name': name,
      'is_active': true,
      'is_service': true,
      'is_system': true,
      'system_kind': 'voucher',
      'quantity_on_hand': 0,
      if (art)
        'primary_image': {
          'id': id,
          'original_filename': '$id.png',
          'content_type': 'image/png',
          'content_url':
              'http://127.0.0.1:8000/api/attachments/$id/content/?token=t',
          'download_url': 'http://127.0.0.1:8000/api/attachments/$id/download/',
          'is_primary': true,
        },
      'variants': [
        for (final card in items)
          {
            'id': card['variant_id'],
            'product': id,
            'name': card['name'],
            'sku': 'DFT-${card['variant_id']}',
            'unit_price': card['price'],
            'is_active': true,
            'is_service': true,
          },
      ],
    };
  }

  const us = 'الولايات المتحدة';
  const gb = 'المملكة المتحدة';
  const ly = 'ليبيا';
  final itunes = [
    item(9101, 'US', us, '10 دولار', 60, cost: 52),
    item(
      9102,
      'US',
      us,
      '25 دولار',
      145,
      regular: 150,
      cost: 128,
      badge: 'عرض',
    ),
    item(9103, 'US', us, '50 دولار', 290, cost: 260, exceedsFloat: true),
    item(9104, 'US', us, '100 دولار', 575, cost: 520, available: false),
    item(9105, 'GB', gb, '10 جنيه', 75, cost: 66),
    item(9106, 'GB', gb, '25 جنيه', 185, cost: 165),
  ];
  final playstation = [
    item(9201, 'US', us, '20 دولار', 118, cost: 100),
    item(9202, 'US', us, '50 دولار', 300, cost: 262),
  ];
  final libyana = [
    item(9401, 'LY', ly, '5 دينار', 5, cost: 4.85),
    item(9402, 'LY', ly, '10 دينار', 10, cost: 9.7),
  ];

  return {
    'available': true,
    'provider': 'pointy',
    'error_code': '',
    'balance': '345.50',
    'balance_at': '2026-10-07T09:30:00Z',
    'categories': [
      {'key': 'gift_cards', 'name': 'بطاقات الهدايا'},
      {'key': 'games', 'name': 'الألعاب'},
      {'key': 'telecom', 'name': 'الاتصالات'},
      ...extraCategories,
    ],
    'countries': [
      {'code': 'US', 'name': us, 'flag': base64Encode(voucherFlagBytes)},
      {
        'code': 'GB',
        'name': gb,
        'flag': 'data:image/png;base64,${base64Encode(voucherFlagBytes)}',
      },
      {'code': 'LY', 'name': ly, 'flag': null},
    ],
    'brands': [
      {
        'key': 'itunes',
        'name': 'آيتونز',
        'category': 'gift_cards',
        'featured': true,
        'badge': 'الأكثر مبيعاً',
        'has_promo': true,
        'redeem_hint': 'App Store ← الحساب ← استرداد بطاقة هدية',
        'product': product(9001, 'آيتونز', itunes, art: true),
        'items': itunes,
      },
      {
        'key': 'playstation',
        'name': 'بلايستيشن',
        'category': 'games',
        'featured': false,
        'badge': '',
        'has_promo': false,
        'redeem_hint': '',
        'product': product(9002, 'بلايستيشن', playstation),
        'items': playstation,
      },
      {
        'key': 'libyana',
        'name': 'ليبيانا',
        'category': 'telecom',
        'featured': false,
        'badge': '',
        'has_promo': false,
        'redeem_hint': '',
        'product': product(9004, 'ليبيانا', libyana),
        'items': libyana,
      },
    ],
  };
}
