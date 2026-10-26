// Dev-only fixtures (safe to delete): a fake relay answering the customer API
// with a realistic shelf, orders and credit, for the preview harness and the
// widget tests. Every screen then runs its real code path.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
      'logo': '',
      'items': [_item('netflix-15', '15 دولار', '92.00', available: false)],
    },
  ],
};

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
  'codes': withCodes && status == 'delivered'
      ? [
          {'code': '4827 1930 5561 2208', 'serial': 'LY-00981234'},
        ]
      : [],
  'codes_pending': false,
  'created_at': createdAt,
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
}) {
  scripted?.learnShelf(jsonEncode(fixtureCatalog));
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
        return json(fixtureCatalog);
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
        return json({
          'order': fixtureOrder(
            id: 'order-new',
            status: 'awaiting_payment',
            item: body['item'] as String,
            nextAction: hosted ? 'hosted_page' : 'otp',
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
      return json({
        'order': fixtureOrder(id: 'order-new', status: confirmStatus),
      });
    }
    if (request.method == 'GET' && path.startsWith('/v1/customers/orders/')) {
      return json({
        'order': fixtureOrder(id: path.split('/').last, status: orderStatus),
      });
    }
    return json({'code': 'not_found'}, 404);
  });
}

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
        ),
  );
  final auth = AuthRepository(api: api, sessions: sessions)
    ..session.value = sessions.current;
  return CardsDependencies(
    config: CardsConfig(relayBaseUrl: base, channel: 'apk'),
    auth: auth,
    catalog: CatalogRepository(api: api, channel: 'apk'),
    orders: OrdersRepository(api: api, channel: 'apk'),
    vault: MemoryCodeVault(),
    lock: CodeLock(enabled: false),
    settings: AppSettings(),
    moamalat: moamalat ?? FakeMoamalatClient(),
    cards: cards ?? MemoryCardVault(),
    links: links,
  );
}
