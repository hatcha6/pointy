// Dev-only fixtures (safe to delete): a fake relay answering the customer API
// with a realistic shelf, orders and credit, for the preview harness and the
// widget tests. Every screen then runs its real code path.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../src/core/push/push.dart';
import '../src/config.dart';
import '../src/data/api/relay_api.dart';
import '../src/data/repositories/auth_repository.dart';
import '../src/data/repositories/catalog_repository.dart';
import '../src/data/repositories/orders_repository.dart';
import '../src/data/session/session_store.dart';
import '../src/data/settings/app_settings.dart';
import '../src/data/vault/card_vault.dart';
import '../src/data/vault/code_vault.dart';
import '../src/dependencies.dart';
import '../src/features/card_payment/moamalat_client.dart';
import '../src/features/links/link_inbox.dart';
import 'preview_scenarios.dart';
import '../src/core/analytics/analytics.dart';

const fixtureSession = CustomerSession(
  sessionId: 'session-1',
  customerId: 'customer-1',
  phone: '218912345678',
  accessToken: 'pca1.preview',
  refreshToken: 'pcr1.preview',
);

Map<String, dynamic> _item(
  String key,
  String label,
  String price, {
  String country = '',
  String regular = '',
  String promo = '',
  bool available = true,
  int rank = 0,
}) => {
  'key': key,
  'country': country,
  'label': label,
  'face_value': '',
  'face_currency': '',
  'price': price,
  'regular_price': regular.isEmpty ? price : regular,
  'promo': promo.isEmpty ? null : {'badge': promo},
  'available': available,
  'rank': rank,
};

final Map<String, dynamic> fixtureCatalog = {
  'version': 'preview-1',
  'channel': 'apk',
  'currency': 'LYD',
  'test_mode': false,
  'categories': [
    {'key': 'telecom', 'name': 'اتصالات', 'rank': 1},
    {'key': 'internet', 'name': 'الإنترنت', 'rank': 2},
    {'key': 'gaming', 'name': 'الألعاب', 'rank': 3},
    {'key': 'gift_cards', 'name': 'بطاقات الهدايا', 'rank': 4},
    {'key': 'tv', 'name': 'التلفزيون والترفيه', 'rank': 5},
  ],
  'countries': [
    {'code': 'US', 'name': 'الولايات المتحدة', 'flag': ''},
    {'code': 'GB', 'name': 'بريطانيا', 'flag': ''},
  ],
  'brands': [
    {
      'key': 'libyana',
      'name': 'ليبيانا',
      'aliases': ['Libyana'],
      'category': 'telecom',
      'rank': 1,
      'featured': true,
      'badge': 'الأكثر طلباً',
      'redeem_hint': 'اتصل بالرقم 120 متبوعاً بالرقم السري',
      'redeem': {'kind': 'dial', 'template': '120{code}'},
      'logo': '',
      'items': [
        _item('libyana-5', '5 دينار', '5.00', rank: 1),
        _item('libyana-10', '10 دينار', '10.00', rank: 2),
        _item('libyana-20', '20 دينار', '20.00', rank: 3),
        _item('libyana-50', '50 دينار', '50.00', rank: 4, available: false),
      ],
    },
    {
      'key': 'almadar',
      'name': 'المدار',
      'aliases': ['Almadar'],
      'category': 'telecom',
      'rank': 2,
      'featured': true,
      'badge': '',
      'redeem_hint': 'اطلب *112* ثم الرقم السري ثم #',
      'redeem': {'kind': 'dial', 'template': '*112*{code}#'},
      'logo': '',
      'items': [
        _item('almadar-5', '5 دينار', '5.00'),
        _item('almadar-10', '10 دينار', '10.00'),
      ],
    },
    {
      'key': 'lnet',
      'name': 'LNET',
      'aliases': ['ال نت'],
      'category': 'internet',
      'rank': 3,
      'featured': false,
      'badge': '',
      'redeem_hint': '',
      'logo': '',
      'items': [_item('lnet-30', 'باقة شهر', '30.00')],
    },
    {
      'key': 'pubg',
      'name': 'ببجي موبايل',
      'aliases': ['PUBG', 'ببجي'],
      'category': 'gaming',
      'rank': 4,
      'featured': false,
      'badge': '',
      'redeem_hint': 'midasbuy.com ← إدخال الرمز',
      'redeem': {
        'kind': 'link',
        'template': 'https://www.midasbuy.com/midasbuy/ot/redeem/pubgm',
      },
      'logo': '',
      'items': [
        _item('pubg-60', '60 شدة', '5.50', regular: '6.00', promo: 'عرض'),
        _item('pubg-325', '325 شدة', '27.00'),
        _item('pubg-660', '660 شدة', '53.00'),
      ],
    },
    {
      'key': 'apple',
      'name': 'آيتونز',
      'aliases': ['iTunes', 'Apple'],
      'category': 'gift_cards',
      'rank': 5,
      'featured': false,
      'badge': '',
      'redeem_hint': 'App Store ← صورة الحساب ← استرداد بطاقة الهدايا',
      'redeem': {
        'kind': 'link',
        'template': 'https://apps.apple.com/redeem?code={code}',
        'pattern': 'X[A-Z0-9]{15}',
      },
      'logo': '',
      'items': [
        _item('itunes-us-10', '10 دولار', '60.00', country: 'US'),
        _item('itunes-us-25', '25 دولار', '148.00', country: 'US'),
        _item('itunes-gb-10', '10 جنيه', '78.00', country: 'GB'),
      ],
    },
    {
      'key': 'netflix',
      'name': 'نتفليكس',
      'aliases': ['Netflix'],
      'category': 'tv',
      'rank': 6,
      'featured': false,
      'badge': '',
      'redeem_hint': 'netflix.com/redeem',
      'redeem': {
        'kind': 'link',
        'template': 'https://www.netflix.com/redeem?code={code}',
      },
      'logo': '',
      'items': [_item('netflix-15', '15 دولار', '92.00', available: false)],
    },
  ],
};

/// Cards sent straight to an account, each kind of account once: a game
/// looked up by its ID (Free Fire), an ID with its zone (Mobile Legends), an
/// ID with a server to pick (Genshin), a Telegram username, a Steam login
/// and a Steam gift by invite link. Kept off [fixtureCatalog], whose brands
/// the tests reach by position; [fixtureRelay] adds them when asked.
const fixtureTopUpCategory = {
  'key': 'game_topup',
  'name': 'شحن الألعاب بالمعرّف',
  'rank': 6,
};

const _gameHint =
    'اكتب المعرّف كما يظهر في ملفك الشخصي داخل اللعبة. يصل الشحن إلى الحساب '
    'مباشرة ولا يمكن استرجاعه إذا كان المعرّف خاطئاً.';

final List<Map<String, dynamic>> fixtureTopUpBrands = [
  {
    'key': 'tu-free-fire',
    'name': 'فري فاير',
    'aliases': ['Free Fire'],
    'category': 'game_topup',
    'rank': 7,
    'featured': false,
    'badge': '',
    'redeem_hint': '',
    'logo': '',
    'target': {
      'kind': 'game_account',
      'fields': [
        {'key': 'player_id', 'label': 'معرّف اللاعب (ID)'},
      ],
      'check': 'free_fire',
      'hint': _gameHint,
    },
    'items': [
      _item('tu-free-fire-100', '100 جوهرة', '6.50', rank: 1),
      _item('tu-free-fire-310', '310 جوهرة', '19.00', rank: 2),
      _item('tu-free-fire-520', '520 جوهرة', '31.00', rank: 3),
      _item('tu-free-fire-1060', '1060 جوهرة', '62.00', rank: 4),
      _item('tu-free-fire-2180', '2180 جوهرة', '124.00', rank: 5),
      _item('tu-free-fire-weekly', 'العضوية الأسبوعية', '12.00', rank: 6),
    ],
  },
  {
    'key': 'tu-mlbb',
    'name': 'موبايل ليجندز',
    'aliases': ['Mobile Legends', 'MLBB'],
    'category': 'game_topup',
    'rank': 8,
    'featured': false,
    'badge': '',
    'redeem_hint': '',
    'logo': '',
    'target': {
      'kind': 'game_account',
      'fields': [
        {'key': 'player_id', 'label': 'معرّف اللاعب (ID)'},
        {'key': 'zone_id', 'label': 'رقم المنطقة (Zone ID)'},
      ],
      'hint':
          'افتح ملفك في اللعبة: المعرّف هو الرقم الأول، ورقم المنطقة بين '
          'القوسين بعده.',
    },
    'items': [
      _item('tu-mlbb-86', '86 ماسة', '9.50', rank: 1),
      _item('tu-mlbb-172', '172 ماسة', '19.00', rank: 2),
      _item('tu-mlbb-257', '257 ماسة', '28.00', rank: 3),
    ],
  },
  {
    'key': 'tu-genshin',
    'name': 'غينشين إمباكت',
    'aliases': ['Genshin Impact'],
    'category': 'game_topup',
    'rank': 9,
    'featured': false,
    'badge': '',
    'redeem_hint': '',
    'logo': '',
    'target': {
      'kind': 'game_account',
      'fields': [
        {'key': 'uid', 'label': 'رقم الحساب (UID)'},
        {
          'key': 'server',
          'label': 'الخادم',
          'type': 'select',
          'options': [
            {'value': 'os_usa', 'label': 'America'},
            {'value': 'os_euro', 'label': 'Europe'},
            {'value': 'os_asia', 'label': 'Asia'},
            {'value': 'os_cht', 'label': 'TW, HK, MO'},
          ],
        },
      ],
      'hint': _gameHint,
    },
    'items': [
      _item('tu-genshin-60', '60 Genesis Crystals', '4.50', rank: 1),
      _item('tu-genshin-330', '330 Genesis Crystals', '22.00', rank: 2),
      _item(
        'tu-genshin-welkin',
        'Blessing of the Welkin Moon',
        '22.00',
        rank: 3,
      ),
    ],
  },
  {
    'key': 'tg-stars',
    'name': 'نجوم تيليجرام',
    'aliases': ['Telegram Stars'],
    'category': 'game_topup',
    'rank': 10,
    'featured': false,
    'badge': '',
    'redeem_hint': '',
    'logo': '',
    'target': {
      'kind': 'telegram_username',
      'fields': [
        {'key': 'username', 'label': 'اسم المستخدم في تيليجرام'},
      ],
      'hint':
          'اسم المستخدم في تيليجرام (يبدأ بـ @)، من الإعدادات. يصل مباشرة إلى '
          'الحساب.',
    },
    'items': [
      _item('tg-stars-50', '50 نجمة', '6.00', rank: 1),
      _item('tg-stars-100', '100 نجمة', '11.50', rank: 2),
      _item('tg-stars-250', '250 نجمة', '28.00', rank: 3),
    ],
  },
  {
    'key': 'steam-topup',
    'name': 'شحن محفظة ستيم',
    'aliases': ['Steam Wallet'],
    'category': 'game_topup',
    'rank': 11,
    'featured': false,
    'badge': '',
    'redeem_hint': '',
    'logo': '',
    'platform': 'steam',
    'target': {
      'kind': 'steam_login',
      'fields': [
        {'key': 'login', 'label': 'اسم الدخول في ستيم'},
      ],
      'hint':
          'اسم الدخول إلى ستيم (Account name)، وليس اسم الملف الشخصي الظاهر '
          'للأصدقاء.',
    },
    'items': [
      _item('steam-topup-5', '5 دولار', '33.00', rank: 1),
      _item('steam-topup-10', '10 دولار', '65.00', rank: 2),
      _item('steam-topup-20', '20 دولار', '129.00', rank: 3),
    ],
  },
  {
    'key': 'sg-palworld',
    'name': 'Palworld',
    'aliases': ['بال وورلد'],
    'category': 'game_topup',
    'rank': 12,
    'featured': false,
    'badge': '',
    'redeem_hint': '',
    'logo': '',
    'platform': 'steam',
    'target': {
      'kind': 'steam_invite',
      'fields': [
        {'key': 'invite_url', 'label': 'رابط دعوة الصداقة في ستيم'},
      ],
      'hint':
          'تصلك اللعبة هدية على حسابك في ستيم. من ستيم: الأصدقاء ← إضافة صديق '
          '← انسخ رابط الدعوة السريعة والصقه هنا، ثم اقبل طلب الصداقة '
          'والهدية. لحسابات منطقة الشرق الأوسط وشمال أفريقيا (ومنها ليبيا).',
    },
    'items': [_item('sg-palworld-base', 'اللعبة الأساسية', '96.00')],
  },
];

/// [fixtureCatalog] with the top-up brands on its shelf.
Map<String, dynamic> get fixtureCatalogWithTopUps => {
  ...fixtureCatalog,
  'categories': [...fixtureCatalog['categories'] as List, fixtureTopUpCategory],
  'brands': [...fixtureCatalog['brands'] as List, ...fixtureTopUpBrands],
};

/// A Free Fire top-up, the way the relay answers it.
Map<String, dynamic> fixtureTopUpOrder({
  String id = 'topup-1',
  String status = 'delivered',
  String errorCode = '',
  String createdAt = '2026-10-25T18:30:00Z',
}) => fixtureOrder(
  id: id,
  status: status,
  item: 'tu-free-fire-520',
  brand: 'tu-free-fire',
  name: 'فري فاير · 520 جوهرة',
  total: '31.000',
  errorCode: errorCode,
  createdAt: createdAt,
  account: const {'player_id': '5123456789'},
);

Map<String, dynamic> fixtureOrder({
  String id = 'order-1',
  String status = 'delivered',
  String item = 'libyana-10',
  String brand = 'libyana',
  String name = 'ليبيانا · 10 دينار',
  int quantity = 1,
  String total = '10.000',
  String nextAction = '',
  bool withCodes = true,
  String errorCode = '',
  String createdAt = '2026-10-24T10:00:00Z',
  Map<String, String>? account,
}) => {
  'id': id,
  'status': status,
  'item': item,
  'brand': brand,
  'name': name,
  'quantity': quantity,
  'unit_price': total,
  'total': total,
  'credit_used': '0.000',
  'amount_due': total,
  'fee': '0.210',
  'amount_to_pay': '10.210',
  'method': 'dafa_sadad',
  'payer_hint': '091•••678',
  'next_action': nextAction,
  'error_code': errorCode,
  'codes': withCodes && status == 'delivered' && account == null
      ? [
          {'code': '4827 1930 5561 2208', 'serial': 'LY-00981234'},
        ]
      : [],
  'codes_pending': false,
  'created_at': createdAt,
  if (status == 'delivered') 'completed_at': createdAt,
  'account': account == null ? '' : account.values.join(' · '),
  'account_values': account ?? const <String, String>{},
  'delivery': account == null ? 'codes' : 'account',
};

/// The fake relay. [confirmStatus] is what a confirmed order answers,
/// [orderStatus] what an order asked after answers.
///
/// With [shelf], the catalog comes from that real client (a relay holding the
/// real shelf) and everything else stays fake: signed in, orders, payment and
/// codes, so every screen can be tried on real brands without a phone or a
/// payment.
http.Client fixtureRelay({
  String confirmStatus = 'delivered',
  String orderStatus = 'delivered',
  http.Client? shelf,
  ScriptedOrders? scripted,
  bool topUps = false,
  Duration lookUpTakes = Duration.zero,
}) {
  final catalog = topUps ? fixtureCatalogWithTopUps : fixtureCatalog;
  scripted?.learnShelf(jsonEncode(catalog));
  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  return MockClient((request) async {
    final path = request.url.path;
    final played = await scripted?.answer(request, request.body, fixtureOrder);
    if (played != null) {
      return played;
    }
    switch ((request.method, path)) {
      case ('GET', '/v1/customers/catalog') when shelf != null:
        final answer = await http.Response.fromStream(
          await shelf.send(http.Request('GET', request.url)),
        );
        scripted?.learnShelf(answer.body);
        return answer;
      case ('GET', '/v1/customers/catalog'):
        return json(catalog);
      // The game knows every player but «000…», under a name for each.
      case ('POST', '/v1/customers/accounts/check'):
        await Future<void>.delayed(lookUpTakes);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final account = (body['account'] as Map).cast<String, String>();
        final item = body['item'] as String;
        if (account.values.first.startsWith('000')) {
          return json({'status': 'invalid', 'account': account.values.first});
        }
        return json({
          'status': 'valid',
          'name': item.startsWith('steam')
              ? ''
              : account.values.first == '7788990011'
              ? 'Noor.FF'
              : 'ShadowFox_LY',
          'account': account.values.join(' · '),
        });
      case ('GET', '/v1/customers/payment-methods'):
        return json({
          'methods': [
            {
              'key': 'dafa_moamalat',
              'provider': 'moamalat',
              'name': 'البطاقات المصرفية',
              'kind': 'hosted_page',
              'payer': '',
              'birth_year': false,
            },
            {
              'key': 'dafa_sadad',
              'provider': 'sadad',
              'name': 'سداد',
              'kind': 'otp',
              'payer': 'phone',
              'birth_year': true,
            },
            {
              'key': 'dafa_edfali',
              'provider': 'edfali',
              'name': 'إدفعلي',
              'kind': 'otp',
              'payer': 'phone',
              'birth_year': false,
            },
            {
              'key': 'dafa_mobicash',
              'provider': 'mobicash',
              'name': 'موبي كاش',
              'kind': 'otp',
              'payer': 'phone',
              'birth_year': false,
            },
            {
              'key': 'dafa_yussor_pay',
              'provider': 'yussor-pay',
              'name': 'يسر باي',
              'kind': 'otp',
              'payer': 'card',
              'birth_year': false,
            },
            {
              'key': 'dafa_masrafi_pay',
              'provider': 'masrafi-pay',
              'name': 'مصرفي باي',
              'kind': 'otp',
              'payer': 'phone',
              'birth_year': false,
            },
          ],
          'fee_percent': '2.00',
          'max_quantity': 10,
          'test_mode': false,
        });
      case ('GET', '/v1/customers/credit'):
        return json({
          'balance': '10.000',
          'entries': [
            {
              'kind': 'refund',
              'amount': '10.000',
              'order_id': 'order-3',
              'created_at': '2026-10-23T12:00:00Z',
            },
          ],
        });
      case ('GET', '/v1/customers/orders'):
        return json({
          'orders': [
            if (topUps) fixtureTopUpOrder(createdAt: '2026-10-24T12:00:00Z'),
            fixtureOrder(
              id: 'order-2',
              status: 'fulfilling',
              item: 'pubg-60',
              brand: 'pubg',
              name: 'ببجي موبايل · 60 شدة',
              total: '5.500',
              createdAt: '2026-10-24T11:00:00Z',
            ),
            fixtureOrder(),
            fixtureOrder(
              id: 'order-4',
              item: 'almadar-10',
              brand: 'almadar',
              name: 'المدار · 10 دينار',
              createdAt: '2026-10-22T09:00:00Z',
            ),
            fixtureOrder(
              id: 'order-3',
              status: 'refunded',
              item: 'itunes-us-10',
              brand: 'apple',
              name: 'آيتونز - الولايات المتحدة · 10 دولار',
              total: '60.000',
              createdAt: '2026-10-23T12:00:00Z',
            ),
          ],
        });
      case ('GET', '/v1/customers/me/sessions'):
        return json({
          'sessions': [
            {
              'id': 'session-1',
              'device_name': 'iPhone',
              'platform': 'ios',
              'current': true,
            },
            {
              'id': 'session-2',
              'device_name': '',
              'platform': 'web',
              'current': false,
            },
          ],
        });
      case ('POST', '/v1/customers/orders'):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final hosted = body['method'] == 'dafa_moamalat';
        final account = (body['account'] as Map?)?.cast<String, String>();
        return json({
          'order': fixtureOrder(
            id: account == null ? 'order-new' : 'topup-new',
            status: 'awaiting_payment',
            item: body['item'] as String,
            nextAction: hosted ? 'hosted_page' : 'otp',
            account: account,
          ),
        }, 201);
      case ('POST', '/v1/customers/auth/otp'):
        return json({
          'phone': '218912345678',
          'phone_masked': '091•••678',
          'code_length': 6,
          'resend_at': DateTime.now()
              .add(const Duration(seconds: 30))
              .toUtc()
              .toIso8601String(),
        });
    }
    // Campaigns: UNI1 (the university flyers) gives 5 LYD; anything else
    // is unknown. Answering where one heard of the app is always taken.
    if (path.startsWith('/v1/customers/campaigns/')) {
      final code = path.split('/')[4];
      if (code != 'UNI1') {
        return json({'code': 'unknown_campaign', 'error': 'no such code'}, 404);
      }
      return json({'campaign': fixtureCampaign});
    }
    if (request.method == 'PUT' && path == '/v1/customers/me/attribution') {
      final sent = jsonDecode(request.body) as Map<String, dynamic>;
      return json({
        'attribution': {'heard_from': sent['heard_from'] ?? ''},
        'code_accepted': sent['code'] == 'UNI1',
        if (sent['code'] == 'UNI1') 'reward': fixtureReward(),
      });
    }
    // Bank cards in the app's own form: the session Dafa signed, then the
    // receipt passed back.
    if (request.method == 'POST' && path.endsWith('/card')) {
      return json({
        'order': fixtureOrder(
          id: 'order-new',
          status: 'awaiting_payment',
          nextAction: 'hosted_page',
        ),
        'card_session': fixtureCardSession,
      });
    }
    if (request.method == 'POST' && path.endsWith('/card/complete')) {
      return json({
        'order': fixtureOrder(id: 'order-new', status: confirmStatus),
      });
    }
    if (request.method == 'POST' && path.endsWith('/cancel')) {
      return json({
        'order': fixtureOrder(id: 'order-new', status: 'cancelled'),
        'applied': true,
      });
    }
    if (request.method == 'POST' && path.endsWith('/confirm')) {
      final id = path.split('/')[4];
      return json({
        'order': id.startsWith('topup')
            ? fixtureTopUpOrder(id: id, status: confirmStatus)
            : fixtureOrder(id: 'order-new', status: confirmStatus),
      });
    }
    if (request.method == 'GET' && path.startsWith('/v1/customers/orders/')) {
      final id = path.split('/').last;
      return json({
        'order': id.startsWith('topup')
            ? fixtureTopUpOrder(id: id, status: orderStatus)
            : fixtureOrder(id: id, status: orderStatus),
      });
    }
    return json({'code': 'not_found'}, 404);
  });
}

/// A campaign as the app sees it: the flyers on the university's walls.
const Map<String, Object> fixtureCampaign = {
  'code': 'UNI1',
  'kind': 'flyer',
  'display_name': 'ملصق جامعة مصراتة',
  'landing': '/',
  'reward': '5.000',
};

/// The credit a campaign just gave, as the relay says it: [kind] and [via]
/// pick the reason the sheet gives.
Map<String, Object> fixtureReward({
  String kind = 'flyer',
  String via = 'link',
  String name = 'ملصق جامعة مصراتة',
  String code = 'UNI1',
}) => {
  'amount': '5.000',
  'code': code,
  'kind': kind,
  'display_name': name,
  'via': via,
};

/// A checkout as the relay hands it over: Moamalat's published test
/// merchant, 10.21 LYD.
const Map<String, Object> fixtureCardSession = {
  'mid': '10081014649',
  'tid': '99179395',
  'amount': 10210,
  'merchant_reference': 'pay-1-1791849555',
  'trx_date_time': '202610252130',
  'secure_hash':
      'B3E74617629FEB6570E4CAE2395BCD136C8859840108407E5EE2A0AF7DDF955C',
  'test': true,
};

/// Moamalat, played on the phone: the checkout opens at once, and a charge
/// asks for the bank's confirmation when [verify] (then succeeds), is
/// refused when [decline], and is otherwise paid.
class FakeMoamalatClient extends MoamalatClient {
  FakeMoamalatClient({this.verify = false, this.decline = false});

  bool verify;
  bool decline;
  final List<CardDetails> charged = [];
  final List<Map<String, String>?> verifications = [];

  @override
  Future<MoamalatCheckout> open(CardSession session) async => MoamalatCheckout(
    session: session,
    token: 'session-token',
    merchantName: 'TEST',
    currency: 434,
  );

  @override
  Future<ChargeStep> charge(
    MoamalatCheckout checkout,
    CardDetails card, {
    required Uri returnUrl,
    Map<String, String>? verification,
  }) async {
    charged.add(card);
    verifications.add(verification);
    if (decline) {
      throw const MoamalatException(12, 'Declined');
    }
    if (verify && verification == null) {
      return ChargeNeedsVerification(Uri.parse('https://acs.bank.preview/otp'));
    }
    return ChargeDone({
      'MerchantReference': checkout.session.merchantReference,
      'Amount': '${checkout.session.amount}',
      'SecureHash': 'F' * 64,
    });
  }
}

/// The app's dependencies on the fake relay, signed in or not. With
/// [shelfRelay], the catalog and its art come from that real relay.
CardsDependencies fixtureDependencies({
  bool signedIn = true,
  http.Client? client,
  Uri? shelfRelay,
  PreviewScenarios? scenarios,
  MoamalatClient? moamalat,
  CardVault? cards,
  LinkInbox? links,
  Analytics? analytics,
  Push? push,
  String channel = 'apk',
  bool topUps = false,
  Duration lookUpTakes = Duration.zero,
}) {
  final sessions = MemorySessionStore(signedIn ? fixtureSession : null);
  final base = shelfRelay ?? Uri.parse('https://relay.preview');
  final api = RelayApi(
    baseUrl: base,
    sessions: sessions,
    client:
        client ??
        fixtureRelay(
          shelf: shelfRelay == null ? null : http.Client(),
          scripted: scenarios == null ? null : ScriptedOrders(scenarios),
          topUps: topUps,
          lookUpTakes: lookUpTakes,
        ),
  );
  final auth = AuthRepository(
    api: api,
    sessions: sessions,
    analytics: analytics,
  )..session.value = sessions.current;
  return CardsDependencies(
    config: CardsConfig(
      relayBaseUrl: base,
      channel: channel,
      // The web banner's listings, so a phone-sized preview shows it.
      iosStoreUrl: 'https://apps.apple.com/app/id0000000000',
      androidStoreUrl:
          'https://play.google.com/store/apps/details?id=ly.dftr.cards',
    ),
    auth: auth,
    catalog: CatalogRepository(api: api, channel: channel),
    orders: OrdersRepository(api: api, channel: channel, analytics: analytics),
    vault: MemoryCodeVault(),
    lock: CodeLock(enabled: false),
    settings: AppSettings(),
    moamalat: moamalat ?? FakeMoamalatClient(),
    cards: cards ?? MemoryCardVault(),
    links: links,
    analytics: analytics,
    push: push ?? FixturePush(),
  );
}

/// Notifications as a phone has them, turned on with no phone to ask:
/// the onboarding's notifications step and the account's switch show.
class FixturePush extends Push {
  bool _on = false;

  @override
  bool get available => true;

  @override
  bool get enabled => _on;

  @override
  Future<bool> setEnabled(bool on) async {
    _on = on;
    notifyListeners();
    return true;
  }
}
