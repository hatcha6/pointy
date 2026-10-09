// Dev-only fake «كروت دفتر» menu for the voucher menu preview harness and its
// capture test: brands with and without card art (the art and the flags are
// drawn here, in code, as PNG bytes — no server, no assets), promotions,
// countries, sold-out cards, and a cost line only for a manager.
//
// The menu is built as the JSON the shop's backend serves and parsed by the
// real model, so the preview exercises the parser too. Not part of the
// shipping app. Safe to delete.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';

/// Where the fake card art claims to live. Never fetched: see
/// [voucherPreviewArtResolver].
const _artHost = 'https://preview.invalid/api/attachments';

/// A real shop's menu, as its backend served it, in place of the drawn one —
/// the capture test sets this from an exported snapshot (ops/catalog), so the
/// till can be looked at with the operator's own cards, art and flags.
Map<String, Object?> Function({required bool withCost})?
voucherPreviewMenuSource;

/// A real menu's card art, by the path of the URL the menu names it at (the
/// query's signature differs on every read, the path does not).
final Map<String, Uint8List> voucherPreviewArtByPath = {};

/// The brands the preview's screens pick out of whichever menu they are
/// given: the one whose sheet shows several countries, a one-country brand's
/// sheet, and the brand already sold into the invoice.
class VoucherPreviewPicks {
  const VoucherPreviewPicks({
    this.countries = 'itunes',
    this.single = 'libyana',
    this.seeded = 'itunes',
  });

  final String countries;
  final String single;
  final String seeded;
}

VoucherPreviewPicks voucherPreviewPicks = const VoucherPreviewPicks();

/// Draws the card art instead of fetching it — the hook
/// `PointyProductImageFrame.debugImageOverride` takes.
ImageProvider? voucherPreviewArtResolver(String url) {
  final uri = Uri.tryParse(url);
  final real = uri == null ? null : voucherPreviewArtByPath[uri.path];
  if (real != null) {
    return MemoryImage(real);
  }
  final key = uri?.pathSegments.lastOrNull;
  final bytes = key == null ? null : _art[key];
  return bytes == null ? null : MemoryImage(bytes);
}

/// The menu as the till reads it. [withCost] is a reader with full
/// visibility (a manager), who is sent each card's cost; a cashier is not.
VoucherMenu voucherPreviewMenu({bool withCost = true}) =>
    VoucherMenu.fromJson(voucherPreviewMenuJson(withCost: withCost));

/// A menu with nothing to sell: the owner has not switched the cards on.
VoucherMenu voucherPreviewEmptyMenu() => VoucherMenu.fromJson(const {
  'available': false,
  'provider': 'pointy',
  'error_code': 'not_configured',
  'categories': <Object?>[],
  'countries': <Object?>[],
  'brands': <Object?>[],
});

Map<String, Object?> voucherPreviewMenuJson({bool withCost = true}) {
  final source = voucherPreviewMenuSource;
  if (source != null) {
    return source(withCost: withCost);
  }
  var nextVariant = 9100;
  Map<String, Object?> brand({
    required int productId,
    required String key,
    required String name,
    required String category,
    required List<_Card> cards,
    bool featured = false,
    String badge = '',
    String redeemHint = '',
    bool art = false,
  }) {
    final variants = <Map<String, Object?>>[];
    final items = <Map<String, Object?>>[];
    for (final card in cards) {
      final variantId = nextVariant++;
      final countryName = _countryNames[card.country] ?? card.country;
      final variantName = '$countryName · ${card.label}';
      variants.add({
        'id': variantId,
        'product': productId,
        'name': variantName,
        'sku': 'DFT-${key.toUpperCase()}-${card.country}-$variantId',
        'unit_price': card.price.toStringAsFixed(2),
        'is_active': true,
        'is_service': true,
      });
      items.add({
        'variant_id': variantId,
        'key': '$key-${card.country.toLowerCase()}-$variantId',
        'label': card.label,
        'name': variantName,
        'country': card.country,
        'face_value': card.face,
        'face_currency': card.currency,
        'price': card.price.toStringAsFixed(2),
        'regular_price': (card.regular ?? card.price).toStringAsFixed(2),
        'badge': card.badge,
        'promo_ends_at': card.badge.isEmpty ? null : '2026-10-20T00:00:00Z',
        'available': card.available,
        'exceeds_float': card.beyond,
        if (withCost) 'cost': card.cost.toStringAsFixed(2),
      });
    }
    return {
      'key': key,
      'name': name,
      'category': category,
      'featured': featured,
      'badge': badge,
      'has_promo': cards.any((card) => card.badge.isNotEmpty),
      'redeem_hint': redeemHint,
      'product': {
        'id': productId,
        'name': name,
        'is_active': true,
        'is_service': true,
        'is_system': true,
        'system_kind': 'voucher',
        'quantity_on_hand': 0,
        if (art)
          'primary_image': {
            'id': productId,
            'original_filename': '$key.png',
            'content_type': 'image/png',
            'content_url': '$_artHost/$productId/content/$key?token=preview',
            'download_url': '$_artHost/$productId/download/',
            'is_primary': true,
          },
        'variants': variants,
      },
      'items': items,
    };
  }

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
      {'key': 'streaming', 'name': 'الترفيه'},
    ],
    'countries': [
      for (final code in const ['US', 'GB', 'AE', 'SA', 'TR', 'LY', 'EU', 'WW'])
        {
          'code': code,
          'name': _countryNames[code],
          // No flag for "worldwide": the till draws its code instead.
          'flag': code == 'WW' ? null : base64Encode(_flags[code]!),
        },
    ],
    'brands': [
      brand(
        productId: 9001,
        key: 'itunes',
        name: 'آيتونز',
        category: 'gift_cards',
        featured: true,
        badge: 'الأكثر مبيعاً',
        redeemHint: 'App Store ← الحساب ← استرداد بطاقة هدية',
        art: true,
        cards: const [
          _Card('US', '10 دولار', '10', 'USD', 60, 52),
          _Card(
            'US',
            '25 دولار',
            '25',
            'USD',
            145,
            128,
            regular: 150,
            badge: 'عرض',
          ),
          _Card('US', '50 دولار', '50', 'USD', 290, 260),
          _Card('US', '100 دولار', '100', 'USD', 575, 520, available: false),
          _Card('GB', '10 جنيه', '10', 'GBP', 75, 66),
          _Card('GB', '25 جنيه', '25', 'GBP', 185, 165),
          _Card('AE', '50 درهم', '50', 'AED', 80, 70),
          _Card('AE', '100 درهم', '100', 'AED', 158, 140),
          _Card('SA', '50 ريال', '50', 'SAR', 78, 69),
          _Card('TR', '100 ليرة', '100', 'TRY', 22, 18),
        ],
      ),
      brand(
        productId: 9002,
        key: 'playstation',
        name: 'بلايستيشن',
        category: 'games',
        redeemHint: 'PlayStation Store ← استرداد الرموز',
        art: true,
        cards: const [
          _Card('US', '10 دولار', '10', 'USD', 62, 54),
          _Card(
            'US',
            '20 دولار',
            '20',
            'USD',
            118,
            100,
            regular: 124,
            badge: 'خصم',
          ),
          _Card('US', '50 دولار', '50', 'USD', 300, 262, beyond: true),
          _Card('AE', '50 درهم', '50', 'AED', 82, 72),
          _Card('SA', '100 ريال', '100', 'SAR', 160, 141),
        ],
      ),
      brand(
        productId: 9003,
        key: 'google_play',
        name: 'جوجل بلاي',
        category: 'gift_cards',
        redeemHint: 'متجر Play ← القائمة ← استرداد رمز',
        cards: const [
          _Card('US', '10 دولار', '10', 'USD', 61, 53),
          _Card('US', '25 دولار', '25', 'USD', 150, 132),
          _Card('EU', '15 يورو', '15', 'EUR', 99, 87),
        ],
      ),
      brand(
        productId: 9004,
        key: 'libyana',
        name: 'ليبيانا',
        category: 'telecom',
        featured: true,
        redeemHint: 'اطلب *122*الرقم السري# من خط ليبيانا',
        art: true,
        cards: const [
          _Card('LY', '5 دينار', '5', 'LYD', 5, 4.85),
          _Card('LY', '10 دينار', '10', 'LYD', 10, 9.7),
          _Card('LY', '20 دينار', '20', 'LYD', 20, 19.4),
          _Card('LY', '30 دينار', '30', 'LYD', 30, 29.1),
        ],
      ),
      brand(
        productId: 9005,
        key: 'xbox',
        name: 'إكس بوكس',
        category: 'games',
        art: true,
        cards: const [
          _Card('US', '15 دولار', '15', 'USD', 92, 80),
          _Card('US', '25 دولار', '25', 'USD', 152, 133),
        ],
      ),
      brand(
        productId: 9006,
        key: 'almadar',
        name: 'المدار الجديد',
        category: 'telecom',
        cards: const [
          _Card('LY', '5 دينار', '5', 'LYD', 5, 4.8),
          _Card('LY', '10 دينار', '10', 'LYD', 10, 9.6),
          _Card('LY', '20 دينار', '20', 'LYD', 20, 19.2),
        ],
      ),
      brand(
        productId: 9007,
        key: 'netflix',
        name: 'نتفليكس',
        category: 'streaming',
        art: true,
        cards: const [
          _Card('US', '25 دولار', '25', 'USD', 150, 131, badge: 'عرض الشهر'),
          _Card('GB', '20 جنيه', '20', 'GBP', 148, 130),
          _Card('AE', '100 درهم', '100', 'AED', 160, 140),
          _Card('SA', '100 ريال', '100', 'SAR', 158, 139),
          _Card('TR', '200 ليرة', '200', 'TRY', 43, 37),
          _Card('EU', '25 يورو', '25', 'EUR', 165, 145),
        ],
      ),
      brand(
        productId: 9008,
        key: 'pubg',
        name: 'شدات ببجي موبايل',
        category: 'games',
        badge: 'جديد',
        cards: const [
          _Card('WW', '60 شدة', '60', 'UC', 6, 5.1),
          _Card('WW', '325 شدة', '325', 'UC', 28, 24.5),
          _Card('WW', '660 شدة', '660', 'UC', 55, 48),
        ],
      ),
      brand(
        productId: 9009,
        key: 'steam',
        name: 'ستيم',
        category: 'games',
        art: true,
        cards: const [
          _Card('US', '20 دولار', '20', 'USD', 122, 106, available: false),
          _Card('EU', '20 يورو', '20', 'EUR', 132, 116, available: false),
        ],
      ),
    ],
  };
}

class _Card {
  const _Card(
    this.country,
    this.label,
    this.face,
    this.currency,
    this.price,
    this.cost, {
    this.regular,
    this.badge = '',
    this.available = true,
    this.beyond = false,
  });

  final String country;
  final String label;
  final String face;
  final String currency;
  final double price;
  final double cost;
  final double? regular;
  final String badge;
  final bool available;
  final bool beyond;
}

const _countryNames = {
  'US': 'الولايات المتحدة',
  'GB': 'المملكة المتحدة',
  'AE': 'الإمارات',
  'SA': 'السعودية',
  'TR': 'تركيا',
  'LY': 'ليبيا',
  'EU': 'أوروبا',
  'WW': 'عالمي',
};

// --- drawn card art ---------------------------------------------------------

final Map<String, Uint8List> _art = {
  'itunes': _cardArt(
    top: const [255, 94, 158],
    bottom: const [118, 72, 255],
    title: 'iTunes',
    subtitle: 'GIFT CARD',
  ),
  'playstation': _cardArt(
    top: const [0, 112, 209],
    bottom: const [0, 40, 120],
    title: 'PlayStation',
    subtitle: 'STORE',
  ),
  'libyana': _cardArt(
    top: const [196, 0, 134],
    bottom: const [86, 12, 99],
    title: 'Libyana',
    subtitle: 'PREPAID',
  ),
  'xbox': _cardArt(
    top: const [22, 160, 22],
    bottom: const [10, 80, 10],
    title: 'XBOX',
    subtitle: 'GIFT CARD',
  ),
  'netflix': _cardArt(
    top: const [32, 32, 32],
    bottom: const [10, 10, 10],
    title: 'NETFLIX',
    subtitle: 'GIFT CARD',
    ink: const [229, 9, 20],
  ),
  'steam': _cardArt(
    top: const [42, 71, 94],
    bottom: const [23, 26, 33],
    title: 'STEAM',
    subtitle: 'WALLET CODE',
  ),
};

/// A 16:10 gift card: a vertical gradient, two soft discs, the brand's word
/// mark and a small caption — enough to look like real art on the till.
Uint8List _cardArt({
  required List<int> top,
  required List<int> bottom,
  required String title,
  required String subtitle,
  List<int> ink = const [255, 255, 255],
}) {
  const width = 480;
  const height = 300;
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    final t = y / (height - 1);
    int mix(int a, int b) => (a + (b - a) * t).round();
    img.fillRect(
      image,
      x1: 0,
      y1: y,
      x2: width - 1,
      y2: y,
      color: img.ColorRgba8(
        mix(top[0], bottom[0]),
        mix(top[1], bottom[1]),
        mix(top[2], bottom[2]),
        255,
      ),
    );
  }
  img.fillCircle(
    image,
    x: width - 60,
    y: 40,
    radius: 150,
    color: img.ColorRgba8(255, 255, 255, 26),
    antialias: true,
  );
  img.fillCircle(
    image,
    x: 30,
    y: height + 40,
    radius: 130,
    color: img.ColorRgba8(255, 255, 255, 18),
    antialias: true,
  );
  img.drawString(
    image,
    title,
    font: img.arial48,
    y: height ~/ 2 - 40,
    color: img.ColorRgba8(ink[0], ink[1], ink[2], 255),
  );
  img.drawString(
    image,
    subtitle,
    font: img.arial24,
    y: height ~/ 2 + 22,
    color: img.ColorRgba8(255, 255, 255, 200),
  );
  return img.encodePng(image);
}

// --- drawn flags --------------------------------------------------------------

final Map<String, Uint8List> _flags = {
  'US': _flagUs(),
  'GB': _flagGb(),
  'AE': _flagAe(),
  'SA': _flagSa(),
  'TR': _flagTr(),
  'LY': _flagLy(),
  'EU': _flagEu(),
};

const _flagWidth = 72;
const _flagHeight = 48;

img.Image _blankFlag(List<int> rgb) {
  final image = img.Image(
    width: _flagWidth,
    height: _flagHeight,
    numChannels: 4,
  );
  img.fill(image, color: img.ColorRgba8(rgb[0], rgb[1], rgb[2], 255));
  return image;
}

void _band(img.Image image, int x1, int y1, int x2, int y2, List<int> rgb) {
  img.fillRect(
    image,
    x1: x1,
    y1: y1,
    x2: x2,
    y2: y2,
    color: img.ColorRgba8(rgb[0], rgb[1], rgb[2], 255),
  );
}

void _disc(img.Image image, int x, int y, int radius, List<int> rgb) {
  img.fillCircle(
    image,
    x: x,
    y: y,
    radius: radius,
    color: img.ColorRgba8(rgb[0], rgb[1], rgb[2], 255),
    antialias: true,
  );
}

Uint8List _flagUs() {
  final image = _blankFlag(const [255, 255, 255]);
  for (var stripe = 0; stripe < 13; stripe += 2) {
    final y1 = (stripe * _flagHeight / 13).round();
    final y2 = ((stripe + 1) * _flagHeight / 13).round() - 1;
    _band(image, 0, y1, _flagWidth - 1, y2, const [178, 34, 52]);
  }
  _band(image, 0, 0, 30, 25, const [60, 59, 110]);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 5; col++) {
      _disc(image, 4 + col * 6, 4 + row * 6, 1, const [255, 255, 255]);
    }
  }
  return img.encodePng(image);
}

Uint8List _flagGb() {
  final image = _blankFlag(const [1, 33, 105]);
  final white = img.ColorRgba8(255, 255, 255, 255);
  final red = img.ColorRgba8(200, 16, 46, 255);
  img.drawLine(
    image,
    x1: 0,
    y1: 0,
    x2: _flagWidth - 1,
    y2: _flagHeight - 1,
    color: white,
    thickness: 9,
  );
  img.drawLine(
    image,
    x1: _flagWidth - 1,
    y1: 0,
    x2: 0,
    y2: _flagHeight - 1,
    color: white,
    thickness: 9,
  );
  img.drawLine(
    image,
    x1: 0,
    y1: 0,
    x2: _flagWidth - 1,
    y2: _flagHeight - 1,
    color: red,
    thickness: 3,
  );
  img.drawLine(
    image,
    x1: _flagWidth - 1,
    y1: 0,
    x2: 0,
    y2: _flagHeight - 1,
    color: red,
    thickness: 3,
  );
  _band(image, 30, 0, 41, _flagHeight - 1, const [255, 255, 255]);
  _band(image, 0, 18, _flagWidth - 1, 29, const [255, 255, 255]);
  _band(image, 32, 0, 39, _flagHeight - 1, const [200, 16, 46]);
  _band(image, 0, 20, _flagWidth - 1, 27, const [200, 16, 46]);
  return img.encodePng(image);
}

Uint8List _flagAe() {
  final image = _blankFlag(const [255, 255, 255]);
  _band(image, 0, 0, _flagWidth - 1, 15, const [0, 115, 47]);
  _band(image, 0, 32, _flagWidth - 1, _flagHeight - 1, const [0, 0, 0]);
  _band(image, 0, 0, 17, _flagHeight - 1, const [255, 0, 0]);
  return img.encodePng(image);
}

Uint8List _flagSa() {
  final image = _blankFlag(const [0, 108, 53]);
  _band(image, 16, 18, 56, 22, const [255, 255, 255]);
  _band(image, 20, 31, 52, 33, const [255, 255, 255]);
  return img.encodePng(image);
}

Uint8List _flagTr() {
  final image = _blankFlag(const [227, 10, 23]);
  _disc(image, 27, 24, 12, const [255, 255, 255]);
  _disc(image, 30, 24, 10, const [227, 10, 23]);
  _disc(image, 42, 24, 4, const [255, 255, 255]);
  return img.encodePng(image);
}

Uint8List _flagLy() {
  final image = _blankFlag(const [0, 0, 0]);
  _band(image, 0, 0, _flagWidth - 1, 11, const [231, 0, 19]);
  _band(image, 0, 36, _flagWidth - 1, _flagHeight - 1, const [35, 158, 70]);
  _disc(image, 34, 24, 7, const [255, 255, 255]);
  _disc(image, 36, 24, 6, const [0, 0, 0]);
  _disc(image, 42, 24, 2, const [255, 255, 255]);
  return img.encodePng(image);
}

Uint8List _flagEu() {
  final image = _blankFlag(const [0, 51, 153]);
  for (var star = 0; star < 12; star++) {
    final angle = star * math.pi / 6;
    final x = (_flagWidth / 2 + 14 * math.cos(angle)).round();
    final y = (_flagHeight / 2 + 14 * math.sin(angle)).round();
    _disc(image, x, y, 2, const [255, 204, 0]);
  }
  return img.encodePng(image);
}
